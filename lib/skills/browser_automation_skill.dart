import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'skill_base.dart';

/// 浏览器自动化技能（增强版）
/// 
/// 提供完整的浏览器自动化能力：
/// - 持久化会话：跨多个操作保持浏览器状态
/// - 多步骤操作：支持链式执行
/// - 高级交互：悬停、拖拽、键盘操作
/// - 文件上传、iframe、Cookie 管理
/// - 智能元素定位：文本、角色、标签等
/// - 网络拦截：监控请求和响应
class BrowserAutomationSkill extends GooseSkill {
  /// 浏览器会话管理器
  static final BrowserSessionManager _sessionManager = BrowserSessionManager();
  
  /// Playwright 脚本目录
  String? _scriptDir;
  
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
  
  /// 确保脚本目录存在
  Future<String> _ensureScriptDir() async {
    if (_scriptDir != null) return _scriptDir!;
    
    final appDir = await getApplicationDocumentsDirectory();
    _scriptDir = p.join(appDir.path, 'goose_baby', 'browser_scripts');
    await Directory(_scriptDir!).create(recursive: true);
    return _scriptDir!;
  }
  
  /// 执行 Playwright 脚本
  Future<Map<String, dynamic>> _executeScript(String script, {Duration timeout = const Duration(minutes: 5)}) async {
    final scriptDir = await _ensureScriptDir();
    final scriptPath = p.join(scriptDir, 'browser_${DateTime.now().millisecondsSinceEpoch}.js');
    
    try {
      await File(scriptPath).writeAsString(script);
      debugPrint('🌐 执行浏览器脚本: ${p.basename(scriptPath)}');
      
      final result = await Process.run(
        'node',
        [scriptPath],
        workingDirectory: scriptDir,
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      ).timeout(timeout);
      
      final stdout = (result.stdout as String).trim();
      final stderr = (result.stderr as String).trim();
      
      if (stdout.isNotEmpty) {
        try {
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
      return {'success': false, 'error': '操作超时（${timeout.inMinutes}分钟）'};
    } catch (e) {
      return {'success': false, 'error': e.toString()};
    } finally {
      try {
        await File(scriptPath).delete();
      } catch (_) {}
    }
  }

  // ==================== 脚本生成方法 ====================
  
  String _generateScript(String action, Map<String, dynamic> args) {
    final buffer = StringBuffer();
    final sessionId = args['session_id'] as String?;
    final keepAlive = args['keep_alive'] as bool? ?? false;
    
    // 标准头部
    buffer.writeln("const { chromium, firefox, webkit } = require('playwright');");
    buffer.writeln("const path = require('path');");
    buffer.writeln('');
    buffer.writeln('(async () => {');
    buffer.writeln('  let browser, context, page;');
    buffer.writeln('  try {');
    
    // 会话恢复或新会话
    if (sessionId != null && _sessionManager.hasSession(sessionId)) {
      final session = _sessionManager.getSession(sessionId)!;
      buffer.writeln("    // 恢复会话: $sessionId");
      buffer.writeln("    const userDataDir = '${session.userDataDir.replaceAll('\\', '\\\\')}';");
      buffer.writeln("    browser = await chromium.launchPersistentContext(userDataDir, {");
      buffer.writeln("      headless: ${args['headless'] ?? false},");
      buffer.writeln("      viewport: { width: ${args['viewport_width'] ?? 1920}, height: ${args['viewport_height'] ?? 1080} },");
      if (args['user_agent'] != null) {
        buffer.writeln("      userAgent: '${args['user_agent']}',");
      }
      if (args['locale'] != null) {
        buffer.writeln("      locale: '${args['locale']}',");
      }
      if (args['timezone'] != null) {
        buffer.writeln("      timezoneId: '${args['timezone']}',");
      }
      buffer.writeln("    });");
      buffer.writeln("    const pages = browser.pages();");
      buffer.writeln("    page = pages.length > 0 ? pages[0] : await browser.newPage();");
    } else {
      buffer.writeln("    // 新建浏览器实例");
      buffer.writeln("    browser = await chromium.launch({");
      buffer.writeln("      headless: ${args['headless'] ?? false},");
      if (args['slow_mo'] != null) {
        buffer.writeln("      slowMo: ${args['slow_mo']},");
      }
      buffer.writeln("    });");
      buffer.writeln("    context = await browser.newContext({");
      buffer.writeln("      viewport: { width: ${args['viewport_width'] ?? 1920}, height: ${args['viewport_height'] ?? 1080} },");
      if (args['user_agent'] != null) {
        buffer.writeln("      userAgent: '${args['user_agent']}',");
      }
      if (args['locale'] != null) {
        buffer.writeln("      locale: '${args['locale']}',");
      }
      if (args['timezone'] != null) {
        buffer.writeln("      timezoneId: '${args['timezone']}',");
      }
      if (args['ignore_https_errors'] == true) {
        buffer.writeln("      ignoreHTTPSErrors: true,");
      }
      buffer.writeln("    });");
      
      // 设置网络拦截
      if (args['intercept_requests'] == true || args['block_resources'] != null) {
        _generateNetworkInterception(buffer, args);
      }
      
      // 设置 Cookie
      if (args['cookies'] != null) {
        _generateSetCookies(buffer, args['cookies']);
      }
      
      // 设置认证
      if (args['basic_auth'] != null) {
        final auth = args['basic_auth'] as Map<String, dynamic>;
        buffer.writeln("    await context.setHTTPCredentials({");
        buffer.writeln("      username: '${auth['username']}',");
        buffer.writeln("      password: '${auth['password']}',");
        buffer.writeln("    });");
      }
      
      // 设置额外的请求头
      if (args['extra_headers'] != null) {
        final headers = args['extra_headers'] as Map<String, dynamic>;
        buffer.writeln("    await context.setExtraHTTPHeaders(${jsonEncode(headers)});");
      }
      
      buffer.writeln("    page = await context.newPage();");
    }
    
    // 设置默认超时
    buffer.writeln("    page.setDefaultTimeout(${args['timeout'] ?? 30000});");
    
    // 根据操作类型生成脚本
    switch (action) {
      case 'navigate':
        _generateNavigateAction(buffer, args);
        break;
      case 'click':
        _generateClickAction(buffer, args);
        break;
      case 'fill':
        _generateFillAction(buffer, args);
        break;
      case 'type':
        _generateTypeAction(buffer, args);
        break;
      case 'hover':
        _generateHoverAction(buffer, args);
        break;
      case 'scroll':
        _generateScrollAction(buffer, args);
        break;
      case 'screenshot':
        _generateScreenshotAction(buffer, args);
        break;
      case 'scrape':
        _generateScrapeAction(buffer, args);
        break;
      case 'select':
        _generateSelectAction(buffer, args);
        break;
      case 'upload':
        _generateUploadAction(buffer, args);
        break;
      case 'download':
        _generateDownloadAction(buffer, args);
        break;
      case 'wait':
        _generateWaitAction(buffer, args);
        break;
      case 'keyboard':
        _generateKeyboardAction(buffer, args);
        break;
      case 'mouse':
        _generateMouseAction(buffer, args);
        break;
      case 'drag':
        _generateDragAction(buffer, args);
        break;
      case 'iframe':
        _generateIframeAction(buffer, args);
        break;
      case 'cookies':
        _generateCookiesAction(buffer, args);
        break;
      case 'evaluate':
        _generateEvaluateAction(buffer, args);
        break;
      case 'pdf':
        _generatePdfAction(buffer, args);
        break;
      case 'multi':
        _generateMultiStepAction(buffer, args);
        break;
      case 'close':
        _generateCloseAction(buffer, args);
        break;
      default:
        buffer.writeln("    console.log(JSON.stringify({ success: false, error: 'Unknown action: $action' }));");
    }
    
    // 会话保存或关闭
    buffer.writeln('  } catch (error) {');
    buffer.writeln("    console.log(JSON.stringify({ success: false, error: error.message, stack: error.stack }));");
    buffer.writeln('  } finally {');
    if (keepAlive && sessionId != null) {
      buffer.writeln("    // 保持会话活跃");
    } else if (args['keep_alive'] == true) {
      buffer.writeln("    // 保持浏览器打开");
    } else {
      buffer.writeln("    if (browser) await browser.close();");
    }
    buffer.writeln('  }');
    buffer.writeln('})();');
    
    return buffer.toString();
  }
  
  // ==================== 网络拦截 ====================
  
  void _generateNetworkInterception(StringBuffer buffer, Map<String, dynamic> args) {
    buffer.writeln("    await context.route('**', async route => {");
    
    // 阻止特定资源类型
    if (args['block_resources'] != null) {
      final resources = (args['block_resources'] as List).map((r) => "'$r'").join(', ');
      buffer.writeln("      const blockedTypes = [$resources];");
      buffer.writeln("      if (blockedTypes.includes(route.request().resourceType())) {");
      buffer.writeln("        await route.abort();");
      buffer.writeln("        return;");
      buffer.writeln("      }");
    }
    
    // 请求拦截
    if (args['intercept_requests'] == true) {
      buffer.writeln("      const request = route.request();");
      buffer.writeln("      // 可以在这里修改请求");
      buffer.writeln("      await route.continue();");
    } else {
      buffer.writeln("      await route.continue();");
    }
    
    buffer.writeln("    });");
  }
  
  void _generateSetCookies(StringBuffer buffer, dynamic cookies) {
    if (cookies is String) {
      try {
        cookies = jsonDecode(cookies);
      } catch (_) {
        return;
      }
    }
    if (cookies is List) {
      buffer.writeln("    await context.addCookies(${jsonEncode(cookies)});");
    }
  }
  
  // ==================== 导航操作 ====================
  
  void _generateNavigateAction(StringBuffer buffer, Map<String, dynamic> args) {
    final url = args['url'] as String? ?? '';
    final waitUntil = args['wait_until'] as String? ?? 'domcontentloaded';
    
    buffer.writeln("    await page.goto('$url', {");
    buffer.writeln("      waitUntil: '$waitUntil',");
    buffer.writeln("      timeout: ${args['timeout'] ?? 60000},");
    buffer.writeln("    });");
    
    // 等待特定条件
    if (args['wait_for'] != null) {
      buffer.writeln("    await page.waitForSelector('${args['wait_for']}', { timeout: ${args['timeout'] ?? 30000} });");
    }
    
    buffer.writeln("    const title = await page.title();");
    buffer.writeln("    const pageUrl = page.url();");
    buffer.writeln("    console.log(JSON.stringify({ success: true, title, url: pageUrl }));");
  }
  
  // ==================== 点击操作 ====================
  
  void _generateClickAction(StringBuffer buffer, Map<String, dynamic> args) {
    final selector = args['selector'] as String?;
    final text = args['text'] as String?;
    final role = args['role'] as String?;
    final label = args['label'] as String?;
    final position = args['position'] as Map<String, dynamic>?;
    
    // 智能定位元素
    if (text != null) {
      buffer.writeln("    await page.getByText('${_escapeJs(text)}').first().click({");
    } else if (role != null) {
      buffer.writeln("    await page.getByRole('$role'");
      if (args['name'] != null) {
        buffer.writeln(", { name: '${_escapeJs(args['name'] as String)}' }");
      }
      buffer.writeln(").first().click({");
    } else if (label != null) {
      buffer.writeln("    await page.getByLabel('${_escapeJs(label)}').first().click({");
    } else if (position != null) {
      buffer.writeln("    await page.mouse.click(${position['x']}, ${position['y']}, {");
    } else if (selector != null) {
      buffer.writeln("    await page.click('${_escapeJs(selector)}', {");
    } else {
      buffer.writeln("    console.log(JSON.stringify({ success: false, error: '需要 selector、text、role、label 或 position 参数' }));");
      buffer.writeln("    return;");
      return;
    }
    
    // 点击选项
    buffer.writeln("      button: '${args['button'] ?? 'left'}',");
    buffer.writeln("      clickCount: ${args['click_count'] ?? 1},");
    buffer.writeln("      delay: ${args['delay'] ?? 0},");
    if (args['force'] == true) {
      buffer.writeln("      force: true,");
    }
    buffer.writeln("    });");
    
    // 点击后等待
    if (args['wait_for_navigation'] == true) {
      buffer.writeln("    await page.waitForLoadState('domcontentloaded');");
    } else if (args['wait_for'] != null) {
      buffer.writeln("    await page.waitForSelector('${args['wait_for']}', { timeout: ${args['timeout'] ?? 30000} });");
    }
    
    buffer.writeln("    const pageUrl = page.url();");
    buffer.writeln("    const title = await page.title();");
    buffer.writeln("    console.log(JSON.stringify({ success: true, url: pageUrl, title, message: '已点击元素' }));");
  }
  
  // ==================== 填写表单 ====================
  
  void _generateFillAction(StringBuffer buffer, Map<String, dynamic> args) {
    final selector = args['selector'] as String?;
    final label = args['label'] as String?;
    final placeholder = args['placeholder'] as String?;
    final value = args['value'] as String? ?? '';
    final escapedValue = _escapeJs(value);
    
    // 智能定位
    if (label != null) {
      buffer.writeln("    await page.getByLabel('${_escapeJs(label)}').fill('$escapedValue');");
    } else if (placeholder != null) {
      buffer.writeln("    await page.getByPlaceholder('${_escapeJs(placeholder)}').fill('$escapedValue');");
    } else if (selector != null) {
      buffer.writeln("    await page.fill('${_escapeJs(selector)}', '$escapedValue');");
    } else {
      buffer.writeln("    console.log(JSON.stringify({ success: false, error: '需要 selector、label 或 placeholder 参数' }));");
      return;
    }
    
    // 清空后填写
    if (args['clear_first'] == true) {
      buffer.writeln("    await page.fill('${_escapeJs(selector ?? '')}', '');");
      buffer.writeln("    await page.fill('${_escapeJs(selector ?? '')}', '$escapedValue');");
    }
    
    // 提交表单
    if (args['press_enter'] == true) {
      buffer.writeln("    await page.keyboard.press('Enter');");
      buffer.writeln("    await page.waitForLoadState('domcontentloaded');");
    } else if (args['submit'] == true) {
      if (args['submit_selector'] != null) {
        buffer.writeln("    await page.click('${_escapeJs(args['submit_selector'] as String)}');");
      } else {
        buffer.writeln("    await page.keyboard.press('Enter');");
      }
      buffer.writeln("    await page.waitForLoadState('domcontentloaded');");
    }
    
    buffer.writeln("    const pageUrl = page.url();");
    buffer.writeln("    const title = await page.title();");
    buffer.writeln("    console.log(JSON.stringify({ success: true, url: pageUrl, title, message: '已填写表单' }));");
  }
  
  // ==================== 模拟打字 ====================
  
  void _generateTypeAction(StringBuffer buffer, Map<String, dynamic> args) {
    final selector = args['selector'] as String?;
    final text = args['text'] as String? ?? '';
    final delay = args['delay'] as int? ?? 50;
    final escapedText = _escapeJs(text);
    
    if (selector != null) {
      buffer.writeln("    await page.type('${_escapeJs(selector)}', '$escapedText', { delay: $delay });");
    } else {
      // 直接在当前焦点元素打字
      buffer.writeln("    await page.keyboard.type('$escapedText', { delay: $delay });");
    }
    
    buffer.writeln("    console.log(JSON.stringify({ success: true, message: '已输入文本' }));");
  }
  
  // ==================== 悬停操作 ====================
  
  void _generateHoverAction(StringBuffer buffer, Map<String, dynamic> args) {
    final selector = args['selector'] as String?;
    final position = args['position'] as Map<String, dynamic>?;
    
    if (position != null) {
      buffer.writeln("    await page.mouse.move(${position['x']}, ${position['y']});");
    } else if (selector != null) {
      buffer.writeln("    await page.hover('${_escapeJs(selector)}');");
    } else {
      buffer.writeln("    console.log(JSON.stringify({ success: false, error: '需要 selector 或 position 参数' }));");
      return;
    }
    
    // 悬停后等待
    if (args['wait_for'] != null) {
      buffer.writeln("    await page.waitForSelector('${args['wait_for']}', { timeout: ${args['timeout'] ?? 30000} });");
    }
    
    buffer.writeln("    console.log(JSON.stringify({ success: true, message: '已悬停' }));");
  }
  
  // ==================== 滚动操作 ====================
  
  void _generateScrollAction(StringBuffer buffer, Map<String, dynamic> args) {
    final direction = args['direction'] as String? ?? 'down';
    final distance = args['distance'] as int? ?? 500;
    final selector = args['selector'] as String?;
    final toBottom = args['to_bottom'] as bool? ?? false;
    
    if (selector != null) {
      // 滚动到元素可见
      buffer.writeln("    await page.locator('${_escapeJs(selector)}').scrollIntoViewIfNeeded();");
    } else if (toBottom == true) {
      // 滚动到底部
      buffer.writeln("    await page.evaluate(() => window.scrollTo(0, document.body.scrollHeight));");
    } else {
      // 按方向和距离滚动
      final scrollY = direction == 'up' ? '-$distance' : '$distance';
      buffer.writeln("    await page.evaluate(() => window.scrollBy(0, $scrollY));");
    }
    
    // 等待滚动完成
    buffer.writeln("    await page.waitForTimeout(300);");
    
    buffer.writeln("    const scrollY = await page.evaluate(() => window.scrollY);");
    buffer.writeln("    const scrollHeight = await page.evaluate(() => document.body.scrollHeight);");
    buffer.writeln("    console.log(JSON.stringify({ success: true, scroll_position: scrollY, page_height: scrollHeight }));");
  }
  
  // ==================== 截图操作 ====================
  
  void _generateScreenshotAction(StringBuffer buffer, Map<String, dynamic> args) {
    final outputPath = args['output_path'] as String?;
    final selector = args['selector'] as String?;
    final fullPage = args['full_page'] as bool? ?? true;
    final mask = args['mask'] as List<dynamic>?;
    
    buffer.writeln("    const screenshotPath = '$outputPath' || path.join(process.cwd(), 'screenshot_${DateTime.now().millisecondsSinceEpoch}.png');");
    
    if (selector != null) {
      buffer.writeln("    const element = await page.\$('${_escapeJs(selector)}');");
      buffer.writeln("    if (element) {");
      buffer.writeln("      await element.screenshot({ path: screenshotPath });");
      buffer.writeln("    } else {");
      buffer.writeln("      console.log(JSON.stringify({ success: false, error: '元素未找到: $selector' }));");
      buffer.writeln("      return;");
      buffer.writeln("    }");
    } else {
      buffer.writeln("    await page.screenshot({");
      buffer.writeln("      path: screenshotPath,");
      buffer.writeln("      fullPage: $fullPage,");
      if (mask != null && mask.isNotEmpty) {
        buffer.writeln("      mask: [");
        for (final sel in mask) {
          buffer.writeln("        page.locator('${_escapeJs(sel.toString())}'),");
        }
        buffer.writeln("      ],");
      }
      if (args['animations'] != null) {
        buffer.writeln("      animations: '${args['animations']}',");
      }
      buffer.writeln("    });");
    }
    
    buffer.writeln("    console.log(JSON.stringify({ success: true, screenshot_path: screenshotPath, message: '截图已保存' }));");
  }
  
  // ==================== 数据抓取 ====================
  
  void _generateScrapeAction(StringBuffer buffer, Map<String, dynamic> args) {
    final selectors = args['selectors'] as List<dynamic>?;
    final selector = args['selector'] as String?;
    final attribute = args['attribute'] as String?;
    final multiple = args['multiple'] as bool? ?? false;
    final extractLinks = args['extract_links'] as bool? ?? false;
    final extractText = args['extract_text'] as bool? ?? false;
    
    if (selectors != null && selectors.isNotEmpty) {
      // 多选择器批量抓取
      buffer.writeln("    const results = {};");
      for (final sel in selectors) {
        final selStr = sel.toString();
        buffer.writeln("    results['$selStr'] = await page.\$\$('${_escapeJs(selStr)}').then(els => Promise.all(els.map(el => el.textContent().then(t => t?.trim()))));");
      }
      buffer.writeln("    console.log(JSON.stringify({ success: true, data: results }));");
    } else if (selector != null) {
      // 单选择器抓取
      if (multiple == true) {
        if (attribute != null) {
          buffer.writeln("    const elements = await page.\$\$('${_escapeJs(selector)}');");
          buffer.writeln("    const results = await Promise.all(elements.map(el => el.getAttribute('$attribute')));");
        } else {
          buffer.writeln("    const elements = await page.\$\$('${_escapeJs(selector)}');");
          buffer.writeln("    const results = await Promise.all(elements.map(el => el.textContent().then(t => t?.trim())));");
        }
        buffer.writeln("    console.log(JSON.stringify({ success: true, data: results.filter(r => r) }));");
      } else {
        if (attribute != null) {
          buffer.writeln("    const element = await page.\$('${_escapeJs(selector)}');");
          buffer.writeln("    const result = element ? await element.getAttribute('$attribute') : null;");
        } else {
          buffer.writeln("    const element = await page.\$('${_escapeJs(selector)}');");
          buffer.writeln("    const result = element ? await element.textContent() : null;");
        }
        buffer.writeln("    console.log(JSON.stringify({ success: true, data: result }));");
      }
    } else if (extractText == true) {
      // 提取整页文本
      buffer.writeln("    const text = await page.evaluate(() => document.body.innerText);");
      buffer.writeln("    const title = await page.title();");
      buffer.writeln("    const html = await page.content();");
      buffer.writeln("    console.log(JSON.stringify({ success: true, title, text, html_length: html.length }));");
    } else if (extractLinks == true) {
      // 提取所有链接
      buffer.writeln("    const links = await page.evaluate(() => {");
      buffer.writeln("      return Array.from(document.querySelectorAll('a')).map(a => ({");
      buffer.writeln("        text: a.textContent?.trim(),");
      buffer.writeln("        href: a.href,");
      buffer.writeln("      })).filter(l => l.text && l.href);");
      buffer.writeln("    });");
      buffer.writeln("    console.log(JSON.stringify({ success: true, links }));");
    } else {
      // 抓取页面结构
      buffer.writeln("    const content = await page.content();");
      buffer.writeln("    const title = await page.title();");
      buffer.writeln("    const url = page.url();");
      buffer.writeln("    console.log(JSON.stringify({ success: true, title, url, html_length: content.length }));");
    }
  }
  
  // ==================== 下拉选择 ====================
  
  void _generateSelectAction(StringBuffer buffer, Map<String, dynamic> args) {
    final selector = args['selector'] as String? ?? '';
    final value = args['value'] as String?;
    final label = args['label'] as String?;
    final index = args['index'] as int?;
    
    if (value != null) {
      buffer.writeln("    await page.selectOption('${_escapeJs(selector)}', '$value');");
    } else if (label != null) {
      buffer.writeln("    await page.selectOption('${_escapeJs(selector)}', { label: '${_escapeJs(label)}' });");
    } else if (index != null) {
      buffer.writeln("    await page.selectOption('${_escapeJs(selector)}', { index: $index });");
    } else {
      buffer.writeln("    console.log(JSON.stringify({ success: false, error: '需要 value、label 或 index 参数' }));");
      return;
    }
    
    buffer.writeln("    console.log(JSON.stringify({ success: true, message: '已选择选项' }));");
  }
  
  // ==================== 文件上传 ====================
  
  void _generateUploadAction(StringBuffer buffer, Map<String, dynamic> args) {
    final selector = args['selector'] as String? ?? '';
    final files = args['files'] as List<dynamic>?;
    
    if (files == null || files.isEmpty) {
      buffer.writeln("    console.log(JSON.stringify({ success: false, error: '需要 files 参数' }));");
      return;
    }
    
    final filePaths = files.map((f) => "'${_escapeJs(f.toString())}'").join(', ');
    buffer.writeln("    await page.setInputFiles('${_escapeJs(selector)}', [$filePaths]);");
    buffer.writeln("    console.log(JSON.stringify({ success: true, message: '已上传 ${files.length} 个文件' }));");
  }
  
  // ==================== 文件下载 ====================
  
  void _generateDownloadAction(StringBuffer buffer, Map<String, dynamic> args) {
    final downloadSelector = args['download_selector'] as String?;
    final url = args['url'] as String?;
    final savePath = args['save_path'] as String?;
    
    if (downloadSelector != null) {
      // 点击下载链接并等待下载
      buffer.writeln("    const [ download ] = await Promise.all([");
      buffer.writeln("      page.waitForEvent('download'),");
      buffer.writeln("      page.click('${_escapeJs(downloadSelector)}'),");
      buffer.writeln("    ]);");
      buffer.writeln("    const downloadPath = '$savePath' || path.join(process.cwd(), download.suggestedFilename());");
      buffer.writeln("    await download.saveAs(downloadPath);");
      buffer.writeln("    console.log(JSON.stringify({ success: true, download_path: downloadPath, filename: download.suggestedFilename() }));");
    } else if (url != null) {
      // 直接下载 URL
      buffer.writeln("    const response = await page.request.get('$url');");
      buffer.writeln("    const downloadPath = '$savePath' || path.join(process.cwd(), 'download_${DateTime.now().millisecondsSinceEpoch}');");
      buffer.writeln("    await response.body().then(body => require('fs').writeFileSync(downloadPath, body));");
      buffer.writeln("    console.log(JSON.stringify({ success: true, download_path: downloadPath }));");
    } else {
      buffer.writeln("    console.log(JSON.stringify({ success: false, error: '需要 download_selector 或 url 参数' }));");
    }
  }
  
  // ==================== 等待操作 ====================
  
  void _generateWaitAction(StringBuffer buffer, Map<String, dynamic> args) {
    final selector = args['selector'] as String?;
    final waitTime = args['time'] as int?;
    final waitUntil = args['until'] as String?;
    final waitForUrl = args['url'] as String?;
    final text = args['text'] as String?;
    
    if (waitTime != null) {
      buffer.writeln("    await page.waitForTimeout($waitTime);");
      buffer.writeln("    console.log(JSON.stringify({ success: true, message: '等待 $waitTime ms 完成' }));");
    } else if (selector != null) {
      final state = args['state'] as String? ?? 'visible';
      buffer.writeln("    await page.waitForSelector('${_escapeJs(selector)}', { state: '$state', timeout: ${args['timeout'] ?? 30000} });");
      buffer.writeln("    console.log(JSON.stringify({ success: true, message: '元素已出现' }));");
    } else if (text != null) {
      buffer.writeln("    await page.waitForSelector('text=${_escapeJs(text)}', { timeout: ${args['timeout'] ?? 30000} });");
      buffer.writeln("    console.log(JSON.stringify({ success: true, message: '文本已出现' }));");
    } else if (waitForUrl != null) {
      buffer.writeln("    await page.waitForURL('$waitForUrl', { timeout: ${args['timeout'] ?? 30000} });");
      buffer.writeln("    console.log(JSON.stringify({ success: true, message: 'URL 已匹配' }));");
    } else if (waitUntil != null) {
      buffer.writeln("    await page.waitForLoadState('$waitUntil');");
      buffer.writeln("    console.log(JSON.stringify({ success: true, message: '页面状态已就绪' }));");
    } else {
      buffer.writeln("    await page.waitForLoadState('networkidle');");
      buffer.writeln("    console.log(JSON.stringify({ success: true, message: '网络空闲' }));");
    }
  }
  
  // ==================== 键盘操作 ====================
  
  void _generateKeyboardAction(StringBuffer buffer, Map<String, dynamic> args) {
    final key = args['key'] as String?;
    final keys = args['keys'] as String?;
    final modifier = args['modifier'] as String?;
    final text = args['text'] as String?;
    final delay = args['delay'] as int? ?? 50;
    
    if (key != null) {
      // 单个按键
      if (modifier != null) {
        buffer.writeln("    await page.keyboard.press('$modifier+$key');");
      } else {
        buffer.writeln("    await page.keyboard.press('$key');");
      }
    } else if (keys != null) {
      // 多个按键
      final keyList = (keys as String).split(',');
      for (final k in keyList) {
        buffer.writeln("    await page.keyboard.press('${k.trim()}');");
      }
    } else if (text != null) {
      // 输入文本
      buffer.writeln("    await page.keyboard.type('${_escapeJs(text)}', { delay: $delay });");
    } else {
      buffer.writeln("    console.log(JSON.stringify({ success: false, error: '需要 key、keys 或 text 参数' }));");
      return;
    }
    
    buffer.writeln("    console.log(JSON.stringify({ success: true, message: '键盘操作完成' }));");
  }
  
  // ==================== 鼠标操作 ====================
  
  void _generateMouseAction(StringBuffer buffer, Map<String, dynamic> args) {
    final action = args['mouse_action'] as String?;
    final x = args['x'] as int?;
    final y = args['y'] as int?;
    final button = args['button'] as String? ?? 'left';
    final clickCount = args['click_count'] as int? ?? 1;
    
    if (action == 'move' && x != null && y != null) {
      buffer.writeln("    await page.mouse.move($x, $y);");
    } else if (action == 'click' && x != null && y != null) {
      buffer.writeln("    await page.mouse.click($x, $y, { button: '$button', clickCount: $clickCount });");
    } else if (action == 'down') {
      buffer.writeln("    await page.mouse.down({ button: '$button' });");
    } else if (action == 'up') {
      buffer.writeln("    await page.mouse.up({ button: '$button' });");
    } else if (action == 'wheel' && x != null && y != null) {
      buffer.writeln("    await page.mouse.wheel($x, $y);");
    } else {
      buffer.writeln("    console.log(JSON.stringify({ success: false, error: '需要有效的鼠标操作' }));");
      return;
    }
    
    buffer.writeln("    console.log(JSON.stringify({ success: true, message: '鼠标操作完成' }));");
  }
  
  // ==================== 拖拽操作 ====================
  
  void _generateDragAction(StringBuffer buffer, Map<String, dynamic> args) {
    final sourceSelector = args['source'] as String?;
    final targetSelector = args['target'] as String?;
    final sourcePos = args['source_position'] as Map<String, dynamic>?;
    final targetPos = args['target_position'] as Map<String, dynamic>?;
    
    if (sourceSelector != null && targetSelector != null) {
      buffer.writeln("    await page.dragAndDrop('${_escapeJs(sourceSelector)}', '${_escapeJs(targetSelector)}');");
    } else if (sourcePos != null && targetPos != null) {
      buffer.writeln("    await page.mouse.move(${sourcePos['x']}, ${sourcePos['y']});");
      buffer.writeln("    await page.mouse.down();");
      buffer.writeln("    await page.mouse.move(${targetPos['x']}, ${targetPos['y']});");
      buffer.writeln("    await page.mouse.up();");
    } else {
      buffer.writeln("    console.log(JSON.stringify({ success: false, error: '需要 source 和 target 参数' }));");
      return;
    }
    
    buffer.writeln("    console.log(JSON.stringify({ success: true, message: '拖拽完成' }));");
  }
  
  // ==================== iframe 操作 ====================
  
  void _generateIframeAction(StringBuffer buffer, Map<String, dynamic> args) {
    final iframeSelector = args['iframe_selector'] as String?;
    final subAction = args['sub_action'] as String?;
    final subArgs = args['sub_args'] as Map<String, dynamic>?;
    
    if (iframeSelector == null) {
      buffer.writeln("    console.log(JSON.stringify({ success: false, error: '需要 iframe_selector 参数' }));");
      return;
    }
    
    buffer.writeln("    const frame = page.frameLocator('${_escapeJs(iframeSelector)}');");
    
    if (subAction != null && subArgs != null) {
      buffer.writeln("    // 在 iframe 内执行: $subAction");
      switch (subAction) {
        case 'click':
          buffer.writeln("    await frame.locator('${_escapeJs(subArgs['selector'] as String)}').click();");
          break;
        case 'fill':
          buffer.writeln("    await frame.locator('${_escapeJs(subArgs['selector'] as String)}').fill('${_escapeJs(subArgs['value'] as String? ?? '')}');");
          break;
        case 'scrape':
          buffer.writeln("    const content = await frame.locator('${_escapeJs(subArgs['selector'] as String? ?? 'body')}').textContent();");
          buffer.writeln("    console.log(JSON.stringify({ success: true, data: content }));");
          break;
        default:
          buffer.writeln("    console.log(JSON.stringify({ success: false, error: '不支持的 iframe 子操作' }));");
      }
    } else {
      buffer.writeln("    console.log(JSON.stringify({ success: true, message: '已定位到 iframe' }));");
    }
  }
  
  // ==================== Cookie 操作 ====================
  
  void _generateCookiesAction(StringBuffer buffer, Map<String, dynamic> args) {
    final action = args['cookie_action'] as String?;
    
    switch (action) {
      case 'get':
        buffer.writeln("    const cookies = await context.cookies();");
        buffer.writeln("    console.log(JSON.stringify({ success: true, cookies }));");
        break;
      case 'set':
        final cookies = args['cookies'];
        if (cookies != null) {
          _generateSetCookies(buffer, cookies);
          buffer.writeln("    console.log(JSON.stringify({ success: true, message: '已设置 Cookie' }));");
        } else {
          buffer.writeln("    console.log(JSON.stringify({ success: false, error: '需要 cookies 参数' }));");
        }
        break;
      case 'clear':
        buffer.writeln("    await context.clearCookies();");
        buffer.writeln("    console.log(JSON.stringify({ success: true, message: '已清除所有 Cookie' }));");
        break;
      default:
        buffer.writeln("    const cookies = await context.cookies();");
        buffer.writeln("    console.log(JSON.stringify({ success: true, cookies }));");
    }
  }
  
  // ==================== JavaScript 执行 ====================
  
  void _generateEvaluateAction(StringBuffer buffer, Map<String, dynamic> args) {
    final script = args['script'] as String? ?? '';
    
    buffer.writeln("    const result = await page.evaluate(() => {");
    buffer.writeln("      $script");
    buffer.writeln("    });");
    buffer.writeln("    console.log(JSON.stringify({ success: true, result }));");
  }
  
  // ==================== PDF 生成 ====================
  
  void _generatePdfAction(StringBuffer buffer, Map<String, dynamic> args) {
    final outputPath = args['output_path'] as String?;
    final format = args['format'] as String? ?? 'A4';
    final printBackground = args['print_background'] as bool? ?? true;
    final margin = args['margin'] as Map<String, dynamic>?;
    
    buffer.writeln("    const pdfPath = '$outputPath' || path.join(process.cwd(), 'page_${DateTime.now().millisecondsSinceEpoch}.pdf');");
    buffer.writeln("    await page.pdf({");
    buffer.writeln("      path: pdfPath,");
    buffer.writeln("      format: '$format',");
    buffer.writeln("      printBackground: $printBackground,");
    if (margin != null) {
      buffer.writeln("      margin: {");
      buffer.writeln("        top: '${margin['top'] ?? '20px'}',");
      buffer.writeln("        bottom: '${margin['bottom'] ?? '20px'}',");
      buffer.writeln("        left: '${margin['left'] ?? '20px'}',");
      buffer.writeln("        right: '${margin['right'] ?? '20px'}',");
      buffer.writeln("      },");
    }
    buffer.writeln("    });");
    buffer.writeln("    console.log(JSON.stringify({ success: true, pdf_path: pdfPath, message: 'PDF 已生成' }));");
  }
  
  // ==================== 多步骤操作 ====================
  
  void _generateMultiStepAction(StringBuffer buffer, Map<String, dynamic> args) {
    final steps = args['steps'] as List<dynamic>?;
    
    if (steps == null || steps.isEmpty) {
      buffer.writeln("    console.log(JSON.stringify({ success: false, error: '需要 steps 参数' }));");
      return;
    }
    
    buffer.writeln("    const results = [];");
    
    for (int i = 0; i < steps.length; i++) {
      final step = steps[i] as Map<String, dynamic>;
      final stepAction = step['action'] as String?;
      buffer.writeln("    // 步骤 ${i + 1}: $stepAction");
      
      switch (stepAction) {
        case 'navigate':
          buffer.writeln("    await page.goto('${step['url']}', { waitUntil: '${step['wait_until'] ?? 'domcontentloaded'}' });");
          break;
        case 'click':
          buffer.writeln("    await page.click('${_escapeJs(step['selector'] as String)}');");
          if (step['wait_for'] != null) {
            buffer.writeln("    await page.waitForSelector('${_escapeJs(step['wait_for'] as String)}');");
          }
          break;
        case 'fill':
          buffer.writeln("    await page.fill('${_escapeJs(step['selector'] as String)}', '${_escapeJs(step['value'] as String? ?? '')}');");
          break;
        case 'type':
          buffer.writeln("    await page.type('${_escapeJs(step['selector'] as String? ?? '')}', '${_escapeJs(step['text'] as String? ?? '')}');");
          break;
        case 'wait':
          if (step['time'] != null) {
            buffer.writeln("    await page.waitForTimeout(${step['time']});");
          } else if (step['selector'] != null) {
            buffer.writeln("    await page.waitForSelector('${_escapeJs(step['selector'] as String)}');");
          }
          break;
        case 'hover':
          buffer.writeln("    await page.hover('${_escapeJs(step['selector'] as String)}');");
          break;
        case 'scroll':
          buffer.writeln("    await page.evaluate(() => window.scrollBy(0, ${step['distance'] ?? 500}));");
          break;
        case 'screenshot':
          buffer.writeln("    await page.screenshot({ path: '${step['output_path'] ?? 'step_${i + 1}.png'}' });");
          break;
        case 'keyboard':
          buffer.writeln("    await page.keyboard.press('${step['key']}');");
          break;
        default:
          buffer.writeln("    // 未知步骤: $stepAction");
      }
      
      buffer.writeln("    results.push({ step: ${i + 1}, action: '$stepAction', status: 'completed' });");
    }
    
    buffer.writeln("    const pageUrl = page.url();");
    buffer.writeln("    const title = await page.title();");
    buffer.writeln("    console.log(JSON.stringify({ success: true, title, url: pageUrl, steps_completed: results.length, results }));");
  }
  
  // ==================== 关闭会话 ====================
  
  void _generateCloseAction(StringBuffer buffer, Map<String, dynamic> args) {
    final sessionId = args['session_id'] as String?;
    
    if (sessionId != null) {
      buffer.writeln("    // 关闭会话: $sessionId");
    }
    buffer.writeln("    if (browser) await browser.close();");
    buffer.writeln("    console.log(JSON.stringify({ success: true, message: '浏览器已关闭' }));");
  }
  
  // ==================== 工具方法 ====================
  
  String _escapeJs(String input) {
    return input
        .replaceAll('\\', '\\\\')
        .replaceAll("'", "\\'")
        .replaceAll('\n', '\\n')
        .replaceAll('\r', '\\r')
        .replaceAll('\t', '\\t');
  }

  // ==================== Skill 接口实现 ====================
  
  @override
  String get id => 'browser_automation';

  @override
  String get name => '浏览器自动化';

  @override
  String get description =>
      '完整的浏览器自动化能力，基于 Playwright。\n\n'
      '【支持的操作】\n'
      '- navigate: 导航到网页\n'
      '- click: 点击元素（支持文本/角色/标签定位）\n'
      '- fill: 填写表单（支持 label/placeholder 定位）\n'
      '- type: 模拟打字（带延迟）\n'
      '- hover: 悬停元素\n'
      '- scroll: 滚动页面\n'
      '- screenshot: 截图（整页/元素）\n'
      '- scrape: 抓取数据\n'
      '- select: 下拉选择\n'
      '- upload: 文件上传\n'
      '- download: 文件下载\n'
      '- wait: 智能等待\n'
      '- keyboard: 键盘操作\n'
      '- mouse: 鼠标操作\n'
      '- drag: 拖拽\n'
      '- iframe: iframe 内操作\n'
      '- cookies: Cookie 管理\n'
      '- evaluate: 执行 JavaScript\n'
      '- pdf: 生成 PDF\n'
      '- multi: 多步骤链式操作\n\n'
      '【智能定位】支持 selector、text、role、label、placeholder 等多种方式\n'
      '【前提条件】npx playwright install chromium';

  @override
  String get icon => '🌐';

  @override
  String get category => '内置工具';

  @override
  List<SkillParam> get params => [
    const SkillParam(
      name: 'action',
      description: '操作类型: navigate/click/fill/type/hover/scroll/screenshot/scrape/select/upload/download/wait/keyboard/mouse/drag/iframe/cookies/evaluate/pdf/multi/close',
      type: 'string',
      required: true,
    ),
    const SkillParam(name: 'url', description: '目标 URL', type: 'string', required: false),
    const SkillParam(name: 'selector', description: 'CSS 选择器', type: 'string', required: false),
    const SkillParam(name: 'text', description: '文本内容（用于点击或等待）', type: 'string', required: false),
    const SkillParam(name: 'value', description: '填写值', type: 'string', required: false),
    const SkillParam(name: 'role', description: 'ARIA 角色（button/link/heading 等）', type: 'string', required: false),
    const SkillParam(name: 'label', description: '标签文本（表单元素）', type: 'string', required: false),
    const SkillParam(name: 'placeholder', description: '占位符文本', type: 'string', required: false),
    const SkillParam(name: 'name', description: '元素名称属性', type: 'string', required: false),
    const SkillParam(name: 'output_path', description: '输出文件路径', type: 'string', required: false),
    const SkillParam(name: 'timeout', description: '超时时间（毫秒），默认 30000', type: 'int', required: false, defaultValue: 30000),
    const SkillParam(name: 'headless', description: '无头模式，默认 false（显示浏览器）', type: 'bool', required: false, defaultValue: false),
    const SkillParam(name: 'keep_alive', description: '保持浏览器打开', type: 'bool', required: false, defaultValue: false),
    const SkillParam(name: 'wait_for', description: '操作后等待的选择器', type: 'string', required: false),
    const SkillParam(name: 'full_page', description: '整页截图', type: 'bool', required: false, defaultValue: true),
    const SkillParam(name: 'attribute', description: '要获取的元素属性', type: 'string', required: false),
    const SkillParam(name: 'multiple', description: '获取多个元素', type: 'bool', required: false, defaultValue: false),
    const SkillParam(name: 'button', description: '鼠标按钮 (left/right/middle)', type: 'string', required: false, defaultValue: 'left'),
    const SkillParam(name: 'click_count', description: '点击次数', type: 'int', required: false, defaultValue: 1),
    const SkillParam(name: 'delay', description: '延迟（毫秒）', type: 'int', required: false, defaultValue: 0),
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
    const SkillParam(name: 'viewport_width', description: '视口宽度', type: 'int', required: false, defaultValue: 1920),
    const SkillParam(name: 'viewport_height', description: '视口高度', type: 'int', required: false, defaultValue: 1080),
    const SkillParam(name: 'user_agent', description: '用户代理', type: 'string', required: false),
    const SkillParam(name: 'block_resources', description: '阻止的资源类型（如 image,font,stylesheet）', type: 'string', required: false),
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
    
    // 处理特殊参数
    _processSpecialArgs(args);
    
    // 生成并执行脚本
    final script = _generateScript(action, args);
    debugPrint('🌐 生成 Playwright 脚本 (${script.length} 字符)');
    
    final timeout = Duration(minutes: (args['timeout_minutes'] as int?) ?? 5);
    final result = await _executeScript(script, timeout: timeout);
    
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
      final workDir = Directory.current.path;
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
      
      // 数据结果
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
      
      // 链接结果
      if (result['links'] != null) {
        final links = result['links'] as List;
        parts.add('🔗 链接 (${links.length} 个):');
        for (int i = 0; i < links.length && i < 10; i++) {
          final link = links[i] as Map;
          parts.add('   - ${link['text']}: ${link['href']}');
        }
      }
      
      // Cookie 结果
      if (result['cookies'] != null) {
        final cookies = result['cookies'] as List;
        parts.add('🍪 Cookie (${cookies.length} 个)');
      }
      
      // 多步骤结果
      if (result['steps_completed'] != null) {
        parts.add('📋 完成 ${result['steps_completed']} 个步骤');
      }
      
      // 页面文本
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
}

/// 浏览器会话管理器
class BrowserSessionManager {
  final Map<String, BrowserSession> _sessions = {};
  
  bool hasSession(String sessionId) => _sessions.containsKey(sessionId);
  
  BrowserSession? getSession(String sessionId) => _sessions[sessionId];
  
  String createSession({String? userDataDir}) {
    final sessionId = 'session_${DateTime.now().millisecondsSinceEpoch}';
    _sessions[sessionId] = BrowserSession(
      id: sessionId,
      userDataDir: userDataDir ?? '/tmp/playwright_$sessionId',
      createdAt: DateTime.now(),
    );
    return sessionId;
  }
  
  void closeSession(String sessionId) {
    _sessions.remove(sessionId);
  }
}

/// 浏览器会话
class BrowserSession {
  final String id;
  final String userDataDir;
  final DateTime createdAt;
  
  BrowserSession({
    required this.id,
    required this.userDataDir,
    required this.createdAt,
  });
}
