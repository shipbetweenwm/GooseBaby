import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'skill_base.dart';
import 'skill_file_utils.dart';

/// Web 交互技能
/// 通过 Playwright (Node.js) 实现浏览器自动化操作
/// 
/// 支持的操作:
/// - open: 打开网页
/// - screenshot: 截图
/// - click: 点击元素
/// - fill: 填写表单
/// - scrape: 数据抓取
/// - scroll: 滚动页面
/// - wait: 等待元素
/// - close: 关闭浏览器
class WebInteractSkill extends GooseSkill {
  /// Playwright 脚本目录
  String? _scriptDir;
  
  /// 检测 Playwright 是否可用
  Future<(bool, String)> _checkPlaywrightAvailable() async {
    try {
      // 1. 检查 Node.js 是否安装
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
      debugPrint('🌐 Node.js 版本: $nodeVersion');
      
      // 2. 检查 Playwright 是否安装
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
      debugPrint('🌐 Playwright 版本: $pwVersion');
      
      return (true, 'Playwright $pwVersion 可用');
    } catch (e) {
      return (false, '检测失败: $e');
    }
  }
  
  /// 确保脚本目录存在
  Future<String> _ensureScriptDir() async {
    if (_scriptDir != null) return _scriptDir!;
    
    final appDir = await getApplicationDocumentsDirectory();
    _scriptDir = p.join(appDir.path, 'goose_baby', 'web_scripts');
    await Directory(_scriptDir!).create(recursive: true);
    return _scriptDir!;
  }
  
  /// 生成并执行 Playwright 脚本
  Future<Map<String, dynamic>> _executeScript(String script) async {
    final scriptDir = await _ensureScriptDir();
    final scriptPath = p.join(scriptDir, 'web_action_${DateTime.now().millisecondsSinceEpoch}.js');
    
    try {
      // 写入脚本
      await File(scriptPath).writeAsString(script);
      
      debugPrint('🌐 执行 Web 脚本: $scriptPath');
      
      // 执行脚本
      final result = await Process.run(
        'node',
        [scriptPath],
        workingDirectory: scriptDir,
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      ).timeout(const Duration(minutes: 3));
      
      final stdout = (result.stdout as String).trim();
      final stderr = (result.stderr as String).trim();
      
      // 解析 JSON 结果
      if (stdout.isNotEmpty) {
        try {
          // 尝试提取 JSON（可能包含其他输出）
          final jsonMatch = RegExp(r'\{[\s\S]*\}').firstMatch(stdout);
          if (jsonMatch != null) {
            return jsonDecode(jsonMatch.group(0)!);
          }
          return {'success': true, 'output': stdout};
        } catch (_) {
          return {'success': true, 'output': stdout};
        }
      }
      
      return {
        'success': result.exitCode == 0,
        'error': stderr.isNotEmpty ? stderr : 'No output',
        'exitCode': result.exitCode,
      };
    } on TimeoutException {
      return {'success': false, 'error': '操作超时（3分钟）'};
    } catch (e) {
      return {'success': false, 'error': e.toString()};
    } finally {
      // 清理临时脚本
      try {
        await File(scriptPath).delete();
      } catch (_) {}
    }
  }
  
  /// 生成 Playwright 脚本
  String _generateScript(String action, Map<String, dynamic> args) {
    final buffer = StringBuffer();
    buffer.writeln('const { chromium } = require(\'playwright\');');
    buffer.writeln('(async () => {');
    buffer.writeln('  try {');
    
    switch (action) {
      case 'open':
        _generateOpenScript(buffer, args);
        break;
      case 'screenshot':
        _generateScreenshotScript(buffer, args);
        break;
      case 'click':
        _generateClickScript(buffer, args);
        break;
      case 'fill':
        _generateFillScript(buffer, args);
        break;
      case 'scrape':
        _generateScrapeScript(buffer, args);
        break;
      case 'scroll':
        _generateScrollScript(buffer, args);
        break;
      case 'wait':
        _generateWaitScript(buffer, args);
        break;
      case 'navigate':
        _generateNavigateScript(buffer, args);
        break;
      case 'evaluate':
        _generateEvaluateScript(buffer, args);
        break;
      case 'close':
        _generateCloseScript(buffer, args);
        break;
      default:
        buffer.writeln('    console.log(JSON.stringify({ success: false, error: "Unknown action: $action" }));');
    }
    
    buffer.writeln('  } catch (error) {');
    buffer.writeln('    console.log(JSON.stringify({ success: false, error: error.message }));');
    buffer.writeln('  }');
    buffer.writeln('})();');
    
    return buffer.toString();
  }
  
  void _generateOpenScript(StringBuffer buffer, Map<String, dynamic> args) {
    final url = args['url'] as String? ?? '';
    final headless = args['headless'] as bool? ?? true;
    final width = args['viewport_width'] as int? ?? 1920;
    final height = args['viewport_height'] as int? ?? 1080;
    final waitFor = args['wait_for'] as String?;
    final timeout = args['timeout'] as int? ?? 30000;
    
    buffer.writeln('    const browser = await chromium.launch({ headless: $headless });');
    buffer.writeln('    const context = await browser.newContext({ viewport: { width: $width, height: $height } });');
    buffer.writeln('    const page = await context.newPage();');
    buffer.writeln('    await page.goto(\'$url\', { timeout: $timeout, waitUntil: "domcontentloaded" });');
    
    if (waitFor != null && waitFor.isNotEmpty) {
      buffer.writeln('    await page.waitForSelector(\'$waitFor\', { timeout: $timeout });');
    }
    
    buffer.writeln('    const title = await page.title();');
    buffer.writeln('    const pageUrl = page.url();');
    buffer.writeln('    console.log(JSON.stringify({ success: true, title, url: pageUrl, message: "页面已打开" }));');
    buffer.writeln('    await browser.close();');
  }
  
  void _generateScreenshotScript(StringBuffer buffer, Map<String, dynamic> args) {
    final url = args['url'] as String?;
    final selector = args['selector'] as String?;
    final outputPath = args['output_path'] as String? ?? 'screenshot.png';
    final fullPage = args['full_page'] as bool? ?? true;
    final width = args['viewport_width'] as int? ?? 1920;
    final height = args['viewport_height'] as int? ?? 1080;
    final headless = args['headless'] as bool? ?? true;
    final timeout = args['timeout'] as int? ?? 30000;
    
    buffer.writeln('    const browser = await chromium.launch({ headless: $headless });');
    buffer.writeln('    const context = await browser.newContext({ viewport: { width: $width, height: $height } });');
    buffer.writeln('    const page = await context.newPage();');
    
    if (url != null && url.isNotEmpty) {
      buffer.writeln('    await page.goto(\'$url\', { timeout: $timeout, waitUntil: "domcontentloaded" });');
    }
    
    if (selector != null && selector.isNotEmpty) {
      buffer.writeln('    await page.waitForSelector(\'$selector\', { timeout: $timeout });');
      buffer.writeln("    const element = await page.\$('${selector.replaceAll("'", "\\'")}');");
      buffer.writeln('    if (element) {');
      buffer.writeln("      await element.screenshot({ path: '$outputPath' });");
      buffer.writeln('    }');
    } else {
      buffer.writeln("    await page.screenshot({ path: '$outputPath', fullPage: $fullPage });");
    }
    
    buffer.writeln('    const title = await page.title();');
    buffer.writeln("    console.log(JSON.stringify({ success: true, title, screenshot_path: '$outputPath', message: \"截图已保存\" }));");
    buffer.writeln('    await browser.close();');
  }
  
  void _generateClickScript(StringBuffer buffer, Map<String, dynamic> args) {
    final url = args['url'] as String?;
    final selector = args['selector'] as String? ?? '';
    final waitFor = args['wait_for'] as String?;
    final timeout = args['timeout'] as int? ?? 30000;
    final clickCount = args['click_count'] as int? ?? 1;
    final delay = args['delay'] as int? ?? 0;
    final headless = args['headless'] as bool? ?? true;
    
    buffer.writeln('    const browser = await chromium.launch({ headless: $headless });');
    buffer.writeln('    const page = await browser.newPage();');
    
    if (url != null && url.isNotEmpty) {
      buffer.writeln('    await page.goto(\'$url\', { timeout: $timeout, waitUntil: "domcontentloaded" });');
    }
    
    buffer.writeln('    await page.waitForSelector(\'$selector\', { timeout: $timeout });');
    
    if (delay > 0) {
      buffer.writeln('    await page.waitForTimeout($delay);');
    }
    
    buffer.writeln('    await page.click(\'$selector\', { clickCount: $clickCount });');
    
    if (waitFor != null && waitFor.isNotEmpty) {
      buffer.writeln('    await page.waitForSelector(\'$waitFor\', { timeout: $timeout });');
    }
    
    buffer.writeln('    const pageUrl = page.url();');
    buffer.writeln('    const title = await page.title();');
    buffer.writeln('    console.log(JSON.stringify({ success: true, url: pageUrl, title, message: "已点击元素" }));');
    buffer.writeln('    await browser.close();');
  }
  
  void _generateFillScript(StringBuffer buffer, Map<String, dynamic> args) {
    final url = args['url'] as String?;
    final selector = args['selector'] as String? ?? '';
    final value = args['value'] as String? ?? '';
    final submit = args['submit'] as bool? ?? false;
    final submitSelector = args['submit_selector'] as String?;
    final timeout = args['timeout'] as int? ?? 30000;
    final headless = args['headless'] as bool? ?? true;
    final pressEnter = args['press_enter'] as bool? ?? false;
    
    buffer.writeln('    const browser = await chromium.launch({ headless: $headless });');
    buffer.writeln('    const page = await browser.newPage();');
    
    if (url != null && url.isNotEmpty) {
      buffer.writeln('    await page.goto(\'$url\', { timeout: $timeout, waitUntil: "domcontentloaded" });');
    }
    
    buffer.writeln('    await page.waitForSelector(\'$selector\', { timeout: $timeout });');
    
    // 转义 value 中的特殊字符
    final escapedValue = value.replaceAll('\\', '\\\\').replaceAll("'", "\\'").replaceAll('\n', '\\n');
    buffer.writeln('    await page.fill(\'$selector\', \'$escapedValue\');');
    
    if (pressEnter == true) {
      buffer.writeln('    await page.press(\'$selector\', \'Enter\');');
    } else if (submit == true) {
      if (submitSelector != null && submitSelector.isNotEmpty) {
        buffer.writeln('    await page.click(\'$submitSelector\');');
      } else {
        buffer.writeln('    await page.keyboard.press(\'Enter\');');
      }
      buffer.writeln('    await page.waitForLoadState("domcontentloaded");');
    }
    
    buffer.writeln('    const pageUrl = page.url();');
    buffer.writeln('    const title = await page.title();');
    buffer.writeln('    console.log(JSON.stringify({ success: true, url: pageUrl, title, message: "已填写表单" }));');
    buffer.writeln('    await browser.close();');
  }
  
  void _generateScrapeScript(StringBuffer buffer, Map<String, dynamic> args) {
    final url = args['url'] as String?;
    final selectors = args['selectors'] as List<dynamic>?;
    final selector = args['selector'] as String?;
    final attribute = args['attribute'] as String?;
    final multiple = args['multiple'] as bool? ?? false;
    final timeout = args['timeout'] as int? ?? 30000;
    final headless = args['headless'] as bool? ?? true;
    final waitFor = args['wait_for'] as String?;
    
    buffer.writeln('    const browser = await chromium.launch({ headless: $headless });');
    buffer.writeln('    const page = await browser.newPage();');
    
    if (url != null && url.isNotEmpty) {
      buffer.writeln('    await page.goto(\'$url\', { timeout: $timeout, waitUntil: "domcontentloaded" });');
    }
    
    if (waitFor != null && waitFor.isNotEmpty) {
      buffer.writeln('    await page.waitForSelector(\'$waitFor\', { timeout: $timeout });');
    }
    
    if (selectors != null && selectors.isNotEmpty) {
      // 多选择器模式
      buffer.writeln('    const results = {};');
      for (final sel in selectors) {
        final selStr = sel.toString();
        buffer.writeln('    results[\'$selStr\'] = await page.\$\$(\'$selStr\').then(els => Promise.all(els.map(el => el.textContent())));');
      }
      buffer.writeln('    console.log(JSON.stringify({ success: true, data: results }));');
    } else if (selector != null && selector.isNotEmpty) {
      if (multiple == true) {
        if (attribute != null && attribute.isNotEmpty) {
          buffer.writeln('    const elements = await page.\$\$(\'$selector\');');
          buffer.writeln('    const results = await Promise.all(elements.map(el => el.getAttribute(\'$attribute\')));');
          buffer.writeln('    console.log(JSON.stringify({ success: true, data: results.filter(r => r) }));');
        } else {
          buffer.writeln('    const elements = await page.\$\$(\'$selector\');');
          buffer.writeln('    const results = await Promise.all(elements.map(el => el.textContent()));');
          buffer.writeln('    console.log(JSON.stringify({ success: true, data: results.filter(r => r) }));');
        }
      } else {
        if (attribute != null && attribute.isNotEmpty) {
          buffer.writeln('    const element = await page.\$(\'$selector\');');
          buffer.writeln('    const result = element ? await element.getAttribute(\'$attribute\') : null;');
          buffer.writeln('    console.log(JSON.stringify({ success: true, data: result }));');
        } else {
          buffer.writeln('    const element = await page.\$(\'$selector\');');
          buffer.writeln('    const result = element ? await element.textContent() : null;');
          buffer.writeln('    console.log(JSON.stringify({ success: true, data: result }));');
        }
      }
    } else {
      // 抓取整个页面的文本
      buffer.writeln('    const content = await page.content();');
      buffer.writeln('    const text = await page.evaluate(() => document.body.innerText);');
      buffer.writeln('    const title = await page.title();');
      buffer.writeln('    console.log(JSON.stringify({ success: true, title, text, html_length: content.length }));');
    }
    
    buffer.writeln('    await browser.close();');
  }
  
  void _generateScrollScript(StringBuffer buffer, Map<String, dynamic> args) {
    final url = args['url'] as String?;
    final direction = args['direction'] as String? ?? 'down';
    final distance = args['distance'] as int? ?? 500;
    final times = args['times'] as int? ?? 1;
    final timeout = args['timeout'] as int? ?? 30000;
    final headless = args['headless'] as bool? ?? true;
    
    buffer.writeln('    const browser = await chromium.launch({ headless: $headless });');
    buffer.writeln('    const page = await browser.newPage();');
    
    if (url != null && url.isNotEmpty) {
      buffer.writeln('    await page.goto(\'$url\', { timeout: $timeout, waitUntil: "domcontentloaded" });');
    }
    
    final scrollY = direction == 'up' ? '-$distance' : '$distance';
    for (int i = 0; i < times; i++) {
      buffer.writeln('    await page.evaluate(() => window.scrollBy(0, $scrollY));');
      buffer.writeln('    await page.waitForTimeout(300);');
    }
    
    buffer.writeln('    const scrollY = await page.evaluate(() => window.scrollY);');
    buffer.writeln('    console.log(JSON.stringify({ success: true, scroll_position: scrollY, message: "已滚动页面" }));');
    buffer.writeln('    await browser.close();');
  }
  
  void _generateWaitScript(StringBuffer buffer, Map<String, dynamic> args) {
    final url = args['url'] as String?;
    final selector = args['selector'] as String?;
    final timeout = args['timeout'] as int? ?? 30000;
    final waitTime = args['wait_time'] as int?;
    final headless = args['headless'] as bool? ?? true;
    
    buffer.writeln('    const browser = await chromium.launch({ headless: $headless });');
    buffer.writeln('    const page = await browser.newPage();');
    
    if (url != null && url.isNotEmpty) {
      buffer.writeln('    await page.goto(\'$url\', { timeout: $timeout, waitUntil: "domcontentloaded" });');
    }
    
    if (waitTime != null && waitTime > 0) {
      buffer.writeln('    await page.waitForTimeout($waitTime);');
      buffer.writeln('    console.log(JSON.stringify({ success: true, message: "等待完成" }));');
    } else if (selector != null && selector.isNotEmpty) {
      buffer.writeln('    await page.waitForSelector(\'$selector\', { timeout: $timeout });');
      buffer.writeln('    console.log(JSON.stringify({ success: true, message: "元素已出现" }));');
    } else {
      buffer.writeln('    await page.waitForLoadState("networkidle");');
      buffer.writeln('    console.log(JSON.stringify({ success: true, message: "页面加载完成" }));');
    }
    
    buffer.writeln('    await browser.close();');
  }
  
  void _generateNavigateScript(StringBuffer buffer, Map<String, dynamic> args) {
    final url = args['url'] as String? ?? '';
    final timeout = args['timeout'] as int? ?? 30000;
    final headless = args['headless'] as bool? ?? true;
    
    buffer.writeln('    const browser = await chromium.launch({ headless: $headless });');
    buffer.writeln('    const page = await browser.newPage();');
    buffer.writeln('    await page.goto(\'$url\', { timeout: $timeout, waitUntil: "domcontentloaded" });');
    buffer.writeln('    const title = await page.title();');
    buffer.writeln('    const pageUrl = page.url();');
    buffer.writeln('    console.log(JSON.stringify({ success: true, title, url: pageUrl, message: "已导航到页面" }));');
    buffer.writeln('    await browser.close();');
  }
  
  void _generateEvaluateScript(StringBuffer buffer, Map<String, dynamic> args) {
    final url = args['url'] as String?;
    final script = args['script'] as String? ?? '';
    final timeout = args['timeout'] as int? ?? 30000;
    final headless = args['headless'] as bool? ?? true;
    
    buffer.writeln('    const browser = await chromium.launch({ headless: $headless });');
    buffer.writeln('    const page = await browser.newPage();');
    
    if (url != null && url.isNotEmpty) {
      buffer.writeln('    await page.goto(\'$url\', { timeout: $timeout, waitUntil: "domcontentloaded" });');
    }
    
    buffer.writeln('    const result = await page.evaluate(() => { $script });');
    buffer.writeln('    console.log(JSON.stringify({ success: true, result }));');
    buffer.writeln('    await browser.close();');
  }
  
  void _generateCloseScript(StringBuffer buffer, Map<String, dynamic> args) {
    buffer.writeln('    // 此脚本使用独立浏览器实例，无需关闭');
    buffer.writeln('    console.log(JSON.stringify({ success: true, message: "浏览器会话已结束" }));');
  }

  @override
  String get id => 'web_interact';

  @override
  String get name => 'Web 浏览器交互';

  @override
  String get description =>
      '通过 Playwright 实现浏览器自动化操作。'
      '【支持的操作】\n'
      '- open: 打开网页\n'
      '- screenshot: 截取网页截图\n'
      '- click: 点击页面元素\n'
      '- fill: 填写表单\n'
      '- scrape: 抓取页面数据\n'
      '- scroll: 滚动页面\n'
      '- wait: 等待元素或时间\n'
      '- evaluate: 执行 JavaScript\n\n'
      '【前提条件】需要安装 Playwright: npx playwright install\n'
      '【推荐】先用 screenshot 获取页面结构，再进行元素操作';

  @override
  String get icon => '🌐';

  @override
  String get category => '内置工具';

  @override
  List<SkillParam> get params => [
    const SkillParam(
      name: 'action',
      description: '操作类型: open(打开), screenshot(截图), click(点击), fill(填写), scrape(抓取), scroll(滚动), wait(等待), evaluate(执行JS)',
      type: 'string',
      required: true,
    ),
    const SkillParam(
      name: 'url',
      description: '目标网页 URL（部分操作需要）',
      type: 'string',
      required: false,
    ),
    const SkillParam(
      name: 'selector',
      description: 'CSS 选择器，用于定位页面元素。例如: "button.submit", "#login-form", "input[name=email]"',
      type: 'string',
      required: false,
    ),
    const SkillParam(
      name: 'value',
      description: '填写表单时的值（用于 fill 操作）',
      type: 'string',
      required: false,
    ),
    const SkillParam(
      name: 'output_path',
      description: '截图保存路径（用于 screenshot 操作），默认在工作目录下',
      type: 'string',
      required: false,
    ),
    const SkillParam(
      name: 'attribute',
      description: '要获取的元素属性（用于 scrape 操作），如 "href", "src", "data-id"',
      type: 'string',
      required: false,
    ),
    const SkillParam(
      name: 'multiple',
      description: '是否获取多个匹配元素（用于 scrape 操作）',
      type: 'bool',
      required: false,
      defaultValue: false,
    ),
    const SkillParam(
      name: 'headless',
      description: '是否使用无头模式（不显示浏览器窗口），默认 true',
      type: 'bool',
      required: false,
      defaultValue: true,
    ),
    const SkillParam(
      name: 'full_page',
      description: '是否截取整个页面（用于 screenshot 操作），默认 true',
      type: 'bool',
      required: false,
      defaultValue: true,
    ),
    const SkillParam(
      name: 'submit',
      description: '填写表单后是否提交（用于 fill 操作）',
      type: 'bool',
      required: false,
      defaultValue: false,
    ),
    const SkillParam(
      name: 'press_enter',
      description: '填写表单后是否按 Enter 键（用于 fill 操作）',
      type: 'bool',
      required: false,
      defaultValue: false,
    ),
    const SkillParam(
      name: 'wait_for',
      description: '等待指定选择器出现后再执行操作',
      type: 'string',
      required: false,
    ),
    const SkillParam(
      name: 'timeout',
      description: '超时时间（毫秒），默认 30000',
      type: 'int',
      required: false,
      defaultValue: 30000,
    ),
    const SkillParam(
      name: 'script',
      description: '要执行的 JavaScript 代码（用于 evaluate 操作）',
      type: 'string',
      required: false,
    ),
    const SkillParam(
      name: 'direction',
      description: '滚动方向: up 或 down（用于 scroll 操作）',
      type: 'string',
      required: false,
      defaultValue: 'down',
    ),
    const SkillParam(
      name: 'distance',
      description: '滚动距离（像素），默认 500（用于 scroll 操作）',
      type: 'int',
      required: false,
      defaultValue: 500,
    ),
    const SkillParam(
      name: 'selectors',
      description: '多个 CSS 选择器数组（用于 scrape 操作批量抓取）',
      type: 'string',
      required: false,
    ),
  ];

  @override
  Future<SkillResult> execute(Map<String, dynamic> args) async {
    final action = args['action'] as String?;
    
    if (action == null || action.isEmpty) {
      return SkillResult.fail('请指定 action 参数');
    }
    
    // 检查 Playwright 是否可用
    final (available, message) = await _checkPlaywrightAvailable();
    if (!available) {
      return SkillResult.fail(
        '❌ Web 交互不可用\n'
        '💡 $message\n\n'
        '【安装步骤】\n'
        '1. 安装 Node.js: https://nodejs.org/\n'
        '2. 安装 Playwright: npx playwright install chromium\n'
        '   (或: npm install playwright && npx playwright install chromium)'
      );
    }
    
    debugPrint('🌐 $message');
    
    // 处理输出路径
    if (args['output_path'] == null && action == 'screenshot') {
      final workDir = SkillFileUtils.effectiveWorkingDir;
      args['output_path'] = '$workDir/screenshot_${DateTime.now().millisecondsSinceEpoch}.png';
    }
    
    // 解析 selectors 参数（可能是 JSON 字符串）
    if (args['selectors'] is String) {
      try {
        args['selectors'] = jsonDecode(args['selectors'] as String);
      } catch (_) {}
    }
    
    // 生成并执行脚本
    final script = _generateScript(action, args);
    debugPrint('🌐 生成 Playwright 脚本:\n$script');
    
    final result = await _executeScript(script);
    
    if (result['success'] == true) {
      final outputParts = <String>['✅ Web 操作成功'];
      
      if (result['title'] != null) {
        outputParts.add('📄 页面标题: ${result['title']}');
      }
      if (result['url'] != null) {
        outputParts.add('🔗 URL: ${result['url']}');
      }
      if (result['message'] != null) {
        outputParts.add('📝 ${result['message']}');
      }
      if (result['screenshot_path'] != null) {
        outputParts.add('📸 截图已保存: ${result['screenshot_path']}');
      }
      if (result['data'] != null) {
        final data = result['data'];
        if (data is List) {
          outputParts.add('📊 抓取到 ${data.length} 条数据:');
          for (int i = 0; i < data.length && i < 10; i++) {
            final item = data[i].toString();
            outputParts.add('   ${i + 1}. ${item.length > 100 ? '${item.substring(0, 100)}...' : item}');
          }
          if (data.length > 10) {
            outputParts.add('   ... 还有 ${data.length - 10} 条');
          }
        } else if (data is Map) {
          outputParts.add('📊 抓取结果:');
          for (final entry in data.entries.take(10)) {
            outputParts.add('   ${entry.key}: ${entry.value}');
          }
        } else {
          final dataStr = data.toString();
          outputParts.add('📊 数据: ${dataStr.length > 500 ? '${dataStr.substring(0, 500)}...' : dataStr}');
        }
      }
      if (result['text'] != null) {
        final text = result['text'].toString();
        outputParts.add('📝 页面文本 (${text.length} 字符):');
        outputParts.add(text.length > 1000 ? '${text.substring(0, 1000)}...' : text);
      }
      
      return SkillResult.ok(outputParts.join('\n'), data: result);
    } else {
      return SkillResult.fail('❌ Web 操作失败: ${result['error'] ?? "未知错误"}');
    }
  }
}
