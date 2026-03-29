import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'skill_base.dart';
import 'skill_file_utils.dart';

/// 浏览器自动化技能（持久进程版）
/// 
/// 使用长期运行的 Playwright Node.js 进程，浏览器保持打开状态，
/// 多次调用之间复用同一个浏览器实例。
/// 
/// 【基础操作】
/// - open/navigate: 打开网页
/// - screenshot: 截图（整页/元素）
/// - click: 点击元素
/// - fill: 填写表单
/// - scrape: 抓取数据
/// - scroll: 滚动页面
/// - wait: 等待元素/时间
/// 
/// 【高级操作】
/// - type: 模拟打字（带延迟）
/// - hover: 悬停元素
/// - select: 下拉选择
/// - upload: 文件上传
/// - download: 文件下载
/// - keyboard: 键盘操作
/// - mouse: 鼠标操作
/// - drag: 拖拽
/// - iframe: iframe 内操作
/// - cookies: Cookie 管理
/// - evaluate: 执行 JavaScript
/// - pdf: 生成 PDF
/// - multi: 多步骤链式操作
/// 
/// 【智能定位】
/// - selector: CSS 选择器
/// - text: 文本内容
/// - role: ARIA 角色（button/link/heading）
/// - label: 标签文本
/// - placeholder: 占位符文本
/// - position: 坐标位置
/// 
/// 【高级特性】
/// - 持久进程：浏览器跨多次调用保持打开
/// - close action: 可手动关闭浏览器
/// - 空闲 30 分钟自动关闭浏览器（进程保留，下次自动重启）
/// 
/// 【前提条件】
/// - 安装 Node.js: https://nodejs.org/
/// - 安装 Playwright: npx playwright install chromium
class BrowserSkill extends GooseSkill {
  /// Playwright 持久进程
  Process? _serverProcess;
  
  /// 服务器脚本路径
  String? _serverScriptPath;
  
  /// Node modules 目录
  String? _scriptDir;
  
  /// 本地 node_modules 是否已初始化
  bool _npmInitialized = false;
  
  /// 命令计数器（用于匹配请求/响应）
  int _cmdId = 0;
  
  /// stdin 输出的行缓冲
  final StringBuffer _stdoutBuffer = StringBuffer();
  
  /// 指令响应的 Completer，key 为 cmdId
  final Map<int, Completer<Map<String, dynamic>>> _pendingCommands = {};
  
  /// 是否正在启动中（防止并发启动）
  bool _starting = false;
  
  /// 检测 Playwright 是否可用
  Future<(bool, String)> _checkPlaywrightAvailable() async {
    try {
      final nodeResult = await Process.run(
        'node',
        ['--version'],
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      );
      
      if (nodeResult.exitCode != 0) {
        return (false, 'Node.js 未安装。请先安装 Node.js: https://nodejs.org/');
      }
      
      final nodeVersion = (nodeResult.stdout as String).trim();
      
      final pwResult = await Process.run(
        'npx',
        ['playwright', '--version'],
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      );
      
      if (pwResult.exitCode != 0) {
        return (false, 'Playwright 未安装。请运行: npx playwright install');
      }
      
      final pwVersion = (pwResult.stdout as String).trim();
      return (true, 'Playwright $pwVersion 可用 (Node $nodeVersion)');
    } catch (e) {
      return (false, '检测失败: $e');
    }
  }
  
  /// 确保脚本目录存在，并初始化 Playwright npm 依赖
  Future<String> _ensureScriptDir() async {
    if (_scriptDir == null) {
      final appDir = await getApplicationDocumentsDirectory();
      _scriptDir = p.join(appDir.path, 'goose_baby', 'browser_scripts');
      await Directory(_scriptDir!).create(recursive: true);
    }
    
    if (!_npmInitialized) {
      final nodeModulesDir = Directory(p.join(_scriptDir!, 'node_modules', 'playwright'));
      if (!nodeModulesDir.existsSync()) {
        debugPrint('🌐 首次使用，正在安装 Playwright npm 包...');
        try {
          final result = await Process.run(
            'npm',
            ['install', 'playwright', '--no-save', '--no-audit', '--no-fund'],
            workingDirectory: _scriptDir,
            stdoutEncoding: utf8,
            stderrEncoding: utf8,
          ).timeout(const Duration(minutes: 3));
          
          if (result.exitCode == 0) {
            _npmInitialized = true;
            debugPrint('🌐 Playwright npm 包安装成功');
          } else {
            debugPrint('🌐 Playwright npm 包安装失败: ${result.stderr}');
          }
        } catch (e) {
          debugPrint('🌐 Playwright npm 包安装异常: $e');
        }
      } else {
        _npmInitialized = true;
      }
    }
    
    return _scriptDir!;
  }
  
  /// 确保 Playwright 持久进程已启动
  Future<void> _ensureServer() async {
    // 如果进程已存在且 stdin 可写，直接复用
    if (_serverProcess != null) {
      try {
        // 通过 kill(pid, 0) 检查进程是否还活着
        final result = Process.runSync('kill', ['-0', '${_serverProcess!.pid}']);
        if (result.exitCode == 0) {
          // 进程还活着，检查 stdin 是否可写
          try {
            _serverProcess!.stdin.write('');
            return; // 进程还活着，直接复用
          } catch (_) {
            // stdin 已关闭
          }
        }
      } catch (_) {
        // 进程已死，需要重启
      }
      _serverProcess = null;
    }
    
    if (_starting) {
      // 等待另一个启动完成
      while (_starting) {
        await Future.delayed(const Duration(milliseconds: 100));
      }
      return;
    }
    
    _starting = true;
    try {
      final scriptDir = await _ensureScriptDir();
      
      // 复制 playwright_server.js 到脚本目录（仅首次或文件不存在时）
      _serverScriptPath ??= p.join(scriptDir, 'playwright_server.js');
      if (!File(_serverScriptPath!).existsSync()) {
        // 从应用资源或脚本目录复制
        final sourcePath = p.join(Directory.current.path, 'scripts', 'playwright_server.js');
        final sourceFile = File(sourcePath);
        if (sourceFile.existsSync()) {
          await sourceFile.copy(_serverScriptPath!);
        } else {
          // 内嵌备用脚本
          await File(_serverScriptPath!).writeAsString(_fallbackServerScript);
        }
      }
      
      debugPrint('🌐 启动 Playwright 持久进程...');
      
      _serverProcess = await Process.start(
        'node',
        [_serverScriptPath!],
        workingDirectory: scriptDir,
      );
      
      // 监听 stderr（日志输出）
      _serverProcess!.stderr.transform(utf8.decoder).listen(
        (data) => debugPrint('🌐 [PW] $data'),
        onError: (e) => debugPrint('🌐 [PW] stderr error: $e'),
      );
      
      // 监听 stdout（JSON 协议）
      _serverProcess!.stdout.transform(utf8.decoder).listen(
        (data) => _handleServerOutput(data),
        onError: (e) => debugPrint('🌐 [PW] stdout error: $e'),
        onDone: () {
          debugPrint('🌐 Playwright 持久进程已退出');
          // 所有等待中的指令返回失败
          for (final completer in _pendingCommands.values) {
            if (!completer.isCompleted) {
              completer.complete({'success': false, 'error': '服务进程已退出'});
            }
          }
          _pendingCommands.clear();
          _serverProcess = null;
        },
      );
      
      // 监听进程退出
      _serverProcess!.exitCode.then((code) {
        debugPrint('🌐 Playwright 持久进程退出，exitCode: $code');
        _serverProcess = null;
      });
      
      // 等待进程启动完成（给一点时间初始化）
      await Future.delayed(const Duration(milliseconds: 500));
      debugPrint('🌐 Playwright 持久进程已启动 (PID: ${_serverProcess!.pid})');
    } finally {
      _starting = false;
    }
  }
  
  /// 处理服务器输出，解析 JSON 并分发到对应的 Completer
  void _handleServerOutput(String data) {
    _stdoutBuffer.write(data);
    
    // 按行分割
    final lines = _stdoutBuffer.toString().split('\n');
    _stdoutBuffer.clear();
    
    // 最后一行可能不完整，保留到下次
    for (int i = 0; i < lines.length; i++) {
      final line = lines[i].trim();
      if (i == lines.length - 1 && !data.endsWith('\n') && line.isNotEmpty) {
        _stdoutBuffer.write(line);
        continue;
      }
      if (line.isEmpty) continue;
      
      try {
        final response = jsonDecode(line) as Map<String, dynamic>;
        final id = response['id'] as int?;
        if (id != null && _pendingCommands.containsKey(id)) {
          final completer = _pendingCommands.remove(id)!;
          if (!completer.isCompleted) {
            completer.complete(response);
          }
        }
      } catch (_) {
        // 非 JSON 行，忽略（可能是日志输出）
      }
    }
  }
  
  /// 向持久进程发送指令并等待响应
  Future<Map<String, dynamic>> _sendCommand(
    String action,
    Map<String, dynamic> args, {
    Duration timeout = const Duration(minutes: 5),
  }) async {
    await _ensureServer();
    
    if (_serverProcess == null) {
      return {'success': false, 'error': 'Playwright 服务进程未运行'};
    }
    
    final id = _cmdId++;
    final completer = Completer<Map<String, dynamic>>();
    _pendingCommands[id] = completer;
    
    final cmd = jsonEncode({'action': action, 'args': args, 'id': id});
    _serverProcess!.stdin.writeln(cmd);
    
    // 等待响应，带超时
    try {
      return await completer.future.timeout(timeout);
    } on TimeoutException {
      _pendingCommands.remove(id);
      return {'success': false, 'error': '操作超时（${timeout.inMinutes}分钟）'};
    }
  }
  
  /// 关闭持久进程（含浏览器）
  // 暂时保留，供未来清理使用
  // ignore: unused_element
  Future<void> _shutdownServer() async {
    if (_serverProcess == null) return;
    
    try {
      // 发送 exit 指令
      final id = _cmdId++;
      final completer = Completer<Map<String, dynamic>>();
      _pendingCommands[id] = completer;
      
      _serverProcess!.stdin.writeln(jsonEncode({'action': 'exit', 'args': {}, 'id': id}));
      
      // 等待响应或超时
      await completer.future.timeout(const Duration(seconds: 3));
    } catch (_) {}
    
    // 强制杀死
    try {
      if (_serverProcess != null) {
        _killProcess(_serverProcess!.pid);
        _serverProcess = null;
      }
    } catch (_) {}
    
    _pendingCommands.clear();
  }
  
  /// 杀死进程树
  void _killProcess(int pid) {
    try {
      if (Platform.isMacOS || Platform.isLinux) {
        Process.runSync('pkill', ['-P', '$pid']);
        Process.killPid(pid, ProcessSignal.sigkill);
      } else if (Platform.isWindows) {
        Process.killPid(pid, ProcessSignal.sigkill);
        Process.runSync('taskkill', ['/F', '/T', '/PID', '$pid']);
      }
    } catch (_) {}
  }
  
  /// 清理可能残留的僵尸 chromium/headless 浏览器进程
  Future<void> _cleanupZombieProcesses() async {
    try {
      if (Platform.isMacOS || Platform.isLinux) {
        const cmd = [
          '-c',
          r'pgrep -f "chromium.*--headless" | while read pid; do elapsed=$(ps -o etimes= -p $pid 2>/dev/null || echo 0); if [ "$elapsed" -gt 600 ]; then kill -9 $pid 2>/dev/null; fi; done',
        ];
        await Process.run(
          'bash',
          cmd,
          stdoutEncoding: utf8,
          stderrEncoding: utf8,
        ).timeout(const Duration(seconds: 5));
      } else if (Platform.isWindows) {
        final psCmd = r'Get-Process -Name chrome,chromium -ErrorAction SilentlyContinue | '
            r'Where-Object { $_.StartTime -and (Get-Date) - $_.StartTime -gt [TimeSpan]::FromMinutes(10) } '
            r'| Stop-Process -Force';
        await Process.run(
          'powershell',
          ['-Command', psCmd],
          stdoutEncoding: utf8,
          stderrEncoding: utf8,
        ).timeout(const Duration(seconds: 5));
      }
    } catch (e) {
      debugPrint('🌐 清理僵尸进程异常: $e');
    }
  }

  // ==================== Skill 接口实现 ====================
  
  @override
  String get id => 'browser';

  @override
  String get name => '浏览器自动化';

  @override
  String get description =>
      '浏览器自动化技能（持久进程版）。浏览器打开后保持运行，多次调用之间复用同一个浏览器实例，不会自动关闭。\n\n'
      '【基础操作】\n'
      '- open/navigate: 打开网页\n'
      '- screenshot: 截图（整页/元素）\n'
      '- click: 点击元素\n'
      '- fill: 填写表单\n'
      '- scrape: 抓取数据\n'
      '- scroll: 滚动页面\n'
      '- wait: 等待元素/时间\n\n'
      '【高级操作】\n'
      '- type: 模拟打字\n'
      '- hover: 悬停元素\n'
      '- select: 下拉选择\n'
      '- upload/download: 文件上传下载\n'
      '- keyboard/mouse: 键盘鼠标操作\n'
      '- drag: 拖拽\n'
      '- iframe: iframe 内操作\n'
      '- cookies: Cookie 管理\n'
      '- evaluate: 执行 JavaScript\n'
      '- pdf: 生成 PDF\n'
      '- multi: 多步骤链式操作\n\n'
      '【生命周期】\n'
      '- close: 关闭浏览器（进程保留，下次操作自动重启）\n'
      '- 浏览器打开后不会自动关闭，可连续执行多次操作\n'
      '- 空闲 30 分钟自动关闭浏览器（进程保留）\n\n'
      '【智能定位】支持 selector、text、role、label、placeholder、position\n'
      '【前提条件】npx playwright install chromium';

  @override
  String get icon => '🌐';

  @override
  String get category => '内置工具';

  @override
  List<SkillParam> get params => [
    const SkillParam(
      name: 'action',
      description: '操作类型: open/navigate/click/fill/type/hover/scroll/screenshot/scrape/select/upload/download/wait/keyboard/mouse/drag/iframe/cookies/evaluate/pdf/multi/close',
      type: 'string',
      required: true,
    ),
    const SkillParam(name: 'url', description: '目标 URL', type: 'string', required: false),
    const SkillParam(name: 'selector', description: 'CSS 选择器', type: 'string', required: false),
    const SkillParam(name: 'text', description: '文本内容（用于点击或等待）', type: 'string', required: false),
    const SkillParam(name: 'value', description: '填写值', type: 'string', required: false),
    const SkillParam(name: 'role', description: 'ARIA 角色（button/link/heading）', type: 'string', required: false),
    const SkillParam(name: 'label', description: '标签文本（表单元素）', type: 'string', required: false),
    const SkillParam(name: 'placeholder', description: '占位符文本', type: 'string', required: false),
    const SkillParam(name: 'output_path', description: '输出文件路径', type: 'string', required: false),
    const SkillParam(name: 'timeout', description: '超时时间（毫秒），默认 30000', type: 'int', required: false, defaultValue: 30000),
    const SkillParam(name: 'headless', description: '无头模式，默认 false（有界面）', type: 'bool', required: false, defaultValue: false),
    const SkillParam(name: 'wait_for', description: '操作后等待的选择器', type: 'string', required: false),
    const SkillParam(name: 'full_page', description: '整页截图', type: 'bool', required: false, defaultValue: true),
    const SkillParam(name: 'attribute', description: '要获取的元素属性', type: 'string', required: false),
    const SkillParam(name: 'multiple', description: '获取多个元素', type: 'bool', required: false, defaultValue: false),
    const SkillParam(name: 'key', description: '按键名称', type: 'string', required: false),
    const SkillParam(name: 'keys', description: '多个按键（逗号分隔）', type: 'string', required: false),
    const SkillParam(name: 'modifier', description: '修饰键 (Ctrl/Alt/Shift/Meta)', type: 'string', required: false),
    const SkillParam(name: 'direction', description: '滚动方向 (up/down)', type: 'string', required: false, defaultValue: 'down'),
    const SkillParam(name: 'distance', description: '滚动距离（像素）', type: 'int', required: false, defaultValue: 500),
    const SkillParam(name: 'position', description: '坐标位置 {"x": 100, "y": 200}', type: 'string', required: false),
    const SkillParam(name: 'steps', description: '多步骤操作数组', type: 'string', required: false),
    const SkillParam(name: 'cookies', description: 'Cookie 数组或 JSON', type: 'string', required: false),
    const SkillParam(name: 'script', description: 'JavaScript 代码', type: 'string', required: false),
    const SkillParam(name: 'files', description: '上传文件路径数组', type: 'string', required: false),
    const SkillParam(name: 'selectors', description: '多个选择器（JSON数组）', type: 'string', required: false),
    const SkillParam(name: 'viewport_width', description: '视口宽度', type: 'int', required: false, defaultValue: 1920),
    const SkillParam(name: 'viewport_height', description: '视口高度', type: 'int', required: false, defaultValue: 1080),
    const SkillParam(name: 'user_agent', description: '用户代理', type: 'string', required: false),
    const SkillParam(name: 'block_resources', description: '阻止的资源类型（如 image,font,stylesheet）', type: 'string', required: false),
    const SkillParam(name: 'submit', description: '填写后提交表单', type: 'bool', required: false, defaultValue: false),
    const SkillParam(name: 'press_enter', description: '填写后按 Enter', type: 'bool', required: false, defaultValue: false),
    const SkillParam(name: 'delay', description: '延迟（毫秒）', type: 'int', required: false, defaultValue: 0),
    const SkillParam(name: 'extract_text', description: '提取页面文本', type: 'bool', required: false, defaultValue: false),
    const SkillParam(name: 'extract_links', description: '提取页面链接', type: 'bool', required: false, defaultValue: false),
  ];

  @override
  Future<SkillResult> execute(Map<String, dynamic> args, {void Function(String line)? onOutput}) async {
    final action = args['action'] as String?;
    
    if (action == null || action.isEmpty) {
      return SkillResult.fail('请指定 action 参数');
    }
    
    // 检查 Playwright 可用性
    final (available, message) = await _checkPlaywrightAvailable();
    if (!available) {
      return SkillResult.fail(
        '❌ 浏览器自动化不可用\n'
        '💡 $message\n\n'
        '【安装步骤】\n'
        '1. 安装 Node.js: https://nodejs.org/\n'
        '2. 安装 Playwright: npx playwright install chromium'
      );
    }
    
    debugPrint('🌐 $message');
    
    // 启动前清理可能残留的僵尸 chromium 进程（仅 headless 模式）
    await _cleanupZombieProcesses();
    
    // 处理特殊参数
    _processSpecialArgs(args);
    
    // 通过持久进程发送指令
    final timeout = Duration(minutes: (args['timeout_minutes'] as int?) ?? 5);
    onOutput?.call('🌐 正在执行浏览器操作: $action...');
    
    Map<String, dynamic> result;
    
    if (action == 'close') {
      result = await _sendCommand('close', args, timeout: const Duration(seconds: 10));
    } else {
      result = await _sendCommand(action, args, timeout: timeout);
    }
    
    return _formatResult(result, action);
  }
  
  void _processSpecialArgs(Map<String, dynamic> args) {
    // 解析 JSON 参数
    for (final key in ['position', 'steps', 'cookies', 'files', 'selectors']) {
      if (args[key] is String && (args[key] as String).isNotEmpty) {
        try {
          args[key] = jsonDecode(args[key] as String);
        } catch (_) {}
      }
    }
    
    // 处理 block_resources
    if (args['block_resources'] is String) {
      args['block_resources'] = (args['block_resources'] as String).split(',').map((s) => s.trim()).toList();
    }
    
    // 默认输出路径
    if (args['output_path'] == null) {
      final workDir = SkillFileUtils.effectiveWorkingDir;
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      if (args['action'] == 'screenshot') {
        args['output_path'] = '$workDir/screenshot_$timestamp.png';
      } else if (args['action'] == 'pdf') {
        args['output_path'] = '$workDir/page_$timestamp.pdf';
      }
    }
  }
  
  SkillResult _formatResult(Map<String, dynamic> result, String action) {
    if (result['success'] == true) {
      final parts = <String>['✅ 浏览器操作成功'];
      
      if (result['title'] != null) {
        parts.add('📄 标题: ${result['title']}');
      }
      if (result['url'] != null) {
        parts.add('🔗 URL: ${result['url']}');
      }
      if (result['message'] != null) {
        parts.add('📝 ${result['message']}');
      }
      if (result['screenshot_path'] != null) {
        parts.add('📸 截图: ${result['screenshot_path']}');
      }
      if (result['pdf_path'] != null) {
        parts.add('📄 PDF: ${result['pdf_path']}');
      }
      if (result['download_path'] != null) {
        parts.add('📥 下载: ${result['download_path']}');
      }
      if (result['scroll_position'] != null) {
        parts.add('📜 滚动位置: ${result['scroll_position']}');
      }
      
      if (result['data'] != null) {
        final data = result['data'];
        if (data is List) {
          parts.add('📊 数据 (${data.length} 条):');
          for (int i = 0; i < data.length && i < 10; i++) {
            final item = data[i].toString();
            parts.add('   ${i + 1}. ${item.length > 100 ? '${item.substring(0, 100)}...' : item}');
          }
          if (data.length > 10) {
            parts.add('   ... 还有 ${data.length - 10} 条');
          }
        } else {
          final dataStr = data.toString();
          parts.add('📊 数据: ${dataStr.length > 500 ? '${dataStr.substring(0, 500)}...' : dataStr}');
        }
      }
      
      if (result['links'] != null) {
        final links = result['links'] as List;
        parts.add('🔗 链接 (${links.length} 个):');
        for (int i = 0; i < links.length && i < 10; i++) {
          final link = links[i] as Map;
          parts.add('   - ${link['text']}: ${link['href']}');
        }
      }
      
      if (result['cookies'] != null) {
        final cookies = result['cookies'] as List;
        parts.add('🍪 Cookie (${cookies.length} 个)');
      }
      
      if (result['steps_completed'] != null) {
        parts.add('📋 完成 ${result['steps_completed']} 个步骤');
      }
      
      if (result['text'] != null) {
        final text = result['text'].toString();
        parts.add('📝 文本 (${text.length} 字符):');
        parts.add(text.length > 1000 ? '${text.substring(0, 1000)}...' : text);
      }
      
      return SkillResult.ok(parts.join('\n'), data: result);
    } else {
      return SkillResult.fail('❌ 浏览器操作失败: ${result['error'] ?? "未知错误"}');
    }
  }
  
  /// 备用内嵌服务器脚本（当外部文件不存在时使用）
  static const String _fallbackServerScript = r'''
const { chromium } = require('playwright');
let browser = null, context = null, page = null;

async function ensureBrowser(args = {}) {
  if (!browser) {
    browser = await chromium.launch({ headless: args.headless !== undefined ? args.headless : false, slowMo: args.slow_mo || 0 });
    context = await browser.newContext({ viewport: { width: args.viewport_width || 1920, height: args.viewport_height || 1080 } });
    page = await context.newPage();
    page.setDefaultTimeout(args.timeout || 30000);
  }
  return page;
}

function escapeJs(s) { return String(s).replace(/\\/g,'\\\\').replace(/'/g,"\\'").replace(/\n/g,'\\n').replace(/\r/g,'\\r').replace(/\t/g,'\\t'); }

async function handle(cmd) {
  const { action, args = {}, id } = cmd;
  try {
    switch (action) {
      case 'launch': {
        if (browser) { const ps = context ? context.pages() : browser.pages(); page = ps.length > 0 ? ps[0] : (context ? await context.newPage() : await browser.newPage()); return { id, success: true, message: '浏览器已在运行' }; }
        browser = await chromium.launch({ headless: args.headless !== undefined ? args.headless : false });
        context = await browser.newContext({ viewport: { width: args.viewport_width || 1920, height: args.viewport_height || 1080 } });
        page = await context.newPage(); page.setDefaultTimeout(args.timeout || 30000);
        return { id, success: true, message: '浏览器已启动' };
      }
      case 'close': { if (browser) { try { await Promise.race([browser.close(), new Promise(r => setTimeout(r, 5000))]); } catch(_){} browser = null; context = null; page = null; } return { id, success: true, message: '浏览器已关闭' }; }
      case 'exit': { if (browser) { try { await Promise.race([browser.close(), new Promise(r => setTimeout(r, 3000))]); } catch(_){} } setTimeout(() => process.exit(0), 200); return { id, success: true }; }
      case 'navigate': case 'open': { await ensureBrowser(args); await page.goto(args.url || '', { waitUntil: args.wait_until || 'domcontentloaded', timeout: args.timeout || 60000 }); if (args.wait_for) await page.waitForSelector(args.wait_for, { timeout: args.timeout || 30000 }); return { id, success: true, title: await page.title(), url: page.url() }; }
      case 'click': { await ensureBrowser(args); if (args.text) await page.getByText(args.text).first().click(); else if (args.role) await page.getByRole(args.role, args.name ? {name: args.name} : {}).first().click(); else if (args.label) await page.getByLabel(args.label).first().click(); else if (args.position) await page.mouse.click(args.position.x, args.position.y); else if (args.selector) await page.click(args.selector); else return { id, success: false, error: '需要 selector/text/role/label/position' }; if (args.wait_for) await page.waitForSelector(args.wait_for); return { id, success: true, url: page.url(), title: await page.title(), message: '已点击' }; }
      case 'fill': { await ensureBrowser(args); const v = escapeJs(args.value || ''); if (args.label) await page.getByLabel(args.label).fill(v); else if (args.placeholder) await page.getByPlaceholder(args.placeholder).fill(v); else if (args.selector) await page.fill(args.selector, v); else return { id, success: false, error: '需要 selector/label/placeholder' }; if (args.press_enter || args.submit) { await page.keyboard.press('Enter'); await page.waitForLoadState('domcontentloaded'); } return { id, success: true, url: page.url(), title: await page.title(), message: '已填写' }; }
      case 'type': { await ensureBrowser(args); if (args.selector) await page.type(args.selector, escapeJs(args.text || ''), { delay: args.delay || 50 }); else await page.keyboard.type(escapeJs(args.text || ''), { delay: args.delay || 50 }); return { id, success: true }; }
      case 'hover': { await ensureBrowser(args); if (args.position) await page.mouse.move(args.position.x, args.position.y); else if (args.selector) await page.hover(args.selector); return { id, success: true }; }
      case 'scroll': { await ensureBrowser(args); if (args.selector) await page.locator(args.selector).scrollIntoViewIfNeeded(); else if (args.to_bottom) await page.evaluate(() => window.scrollTo(0, document.body.scrollHeight)); else await page.evaluate(() => window.scrollBy(0, args.direction === 'up' ? -(args.distance||500) : (args.distance||500))); return { id, success: true }; }
      case 'screenshot': { await ensureBrowser(args); const sp = args.output_path || 'screenshot.png'; if (args.selector) { const el = await page.$(args.selector); if (!el) return { id, success: false, error: '元素未找到' }; await el.screenshot({path:sp}); } else await page.screenshot({path:sp, fullPage: args.full_page !== false}); return { id, success: true, screenshot_path: sp }; }
      case 'scrape': { await ensureBrowser(args); if (args.extract_text) { const t = await page.evaluate(() => document.body.innerText); return { id, success: true, title: await page.title(), text: t }; } if (args.extract_links) { const links = await page.evaluate(() => Array.from(document.querySelectorAll('a')).map(a=>({text:a.textContent?.trim(),href:a.href})).filter(l=>l.text&&l.href)); return { id, success: true, links }; } const c = await page.content(); return { id, success: true, title: await page.title(), html_length: c.length }; }
      case 'wait': { await ensureBrowser(args); if (args.time) await page.waitForTimeout(args.time); else if (args.selector) await page.waitForSelector(args.selector, {state: args.state || 'visible', timeout: args.timeout || 30000}); else if (args.until) await page.waitForLoadState(args.until); else await page.waitForLoadState('networkidle'); return { id, success: true }; }
      case 'keyboard': { await ensureBrowser(args); if (args.key) await page.keyboard.press(args.modifier ? args.modifier+'+'+args.key : args.key); else if (args.keys) { for (const k of args.keys.split(',')) await page.keyboard.press(k.trim()); } else if (args.text) await page.keyboard.type(args.text, {delay: args.delay||50}); return { id, success: true }; }
      case 'mouse': { await ensureBrowser(args); const a = args.mouse_action; if (a==='move') await page.mouse.move(args.x, args.y); else if (a==='click') await page.mouse.click(args.x, args.y); else if (a==='down') await page.mouse.down(); else if (a==='up') await page.mouse.up(); else if (a==='wheel') await page.mouse.wheel(args.x, args.y); return { id, success: true }; }
      case 'evaluate': { await ensureBrowser(args); const r = await page.evaluate(new Function('return '+args.script)()); return { id, success: true, result: r }; }
      case 'multi': { await ensureBrowser(args); const steps = args.steps||[]; for (const s of steps) { switch(s.action) { case 'navigate': await page.goto(s.url,{waitUntil:s.wait_until||'domcontentloaded'}); break; case 'click': await page.click(s.selector); break; case 'fill': await page.fill(s.selector,s.value||''); break; case 'wait': s.time ? await page.waitForTimeout(s.time) : s.selector && await page.waitForSelector(s.selector); break; case 'hover': await page.hover(s.selector); break; case 'scroll': await page.evaluate(()=>window.scrollBy(0,s.distance||500)); break; case 'screenshot': await page.screenshot({path:s.output_path||'step.png'}); break; } } return { id, success: true, title: await page.title(), url: page.url() }; }
      default: return { id, success: false, error: '未知操作: '+action };
    }
  } catch(e) { return { id, success: false, error: e.message }; }
}

let buf = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', async (chunk) => { buf += chunk; const lines = buf.split('\n'); buf = lines.pop(); for (const line of lines) { const t = line.trim(); if (!t) continue; try { const cmd = JSON.parse(t); process.stdout.write(JSON.stringify(await handle(cmd))+'\n'); } catch(e) { process.stdout.write(JSON.stringify({success:false,error:e.message})+'\n'); } } });
process.stdin.on('end', () => { if (browser) browser.close().catch(()=>{}).then(()=>process.exit(0)); else process.exit(0); });
''';
}
