import 'package:flutter/foundation.dart';
import 'package:dio/dio.dart';
import 'skill_base.dart';

/// 网页抓取技能
///
/// 直接通过 HTTP 请求抓取网页内容，并转换为结构化格式
/// 不依赖 Playwright，更轻量、更快速
class WebFetchSkill extends GooseSkill {
  /// HTTP 客户端
  final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 15),
    receiveTimeout: const Duration(seconds: 30),
    followRedirects: true,
    maxRedirects: 5,
  ));

  /// 用户代理
  static const String _defaultUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

  @override
  String get id => 'web_fetch';

  @override
  String get name => '网页抓取';

  @override
  String get description =>
      '抓取网页内容并转换为结构化格式。'
      '【主要用途】\n'
      '- 获取网页文本内容\n'
      '- 提取文章、文档内容\n'
      '- 分析网页结构\n'
      '【优势】轻量快速，不依赖 Playwright\n'
      '【限制】无法执行 JavaScript，不适合动态加载的页面';

  @override
  String get icon => '📄';

  @override
  String get category => '内置工具';

  @override
  List<SkillParam> get params => [
        const SkillParam(
          name: 'url',
          description: '要抓取的网页 URL（必须是完整的 HTTP/HTTPS 链接）',
          type: 'string',
          required: true,
        ),
        const SkillParam(
          name: 'fetch_info',
          description: '要从页面中提取的信息描述',
          type: 'string',
          required: false,
        ),
        const SkillParam(
          name: 'selector',
          description: 'CSS 选择器，用于提取特定元素内容（可选，支持 .class 和 #id）',
          type: 'string',
          required: false,
        ),
        const SkillParam(
          name: 'max_length',
          description: '返回内容的最大字符数，默认 8000',
          type: 'int',
          required: false,
          defaultValue: 8000,
        ),
        const SkillParam(
          name: 'include_links',
          description: '是否包含页面中的链接列表，默认 true',
          type: 'bool',
          required: false,
          defaultValue: true,
        ),
      ];

  @override
  Future<SkillResult> execute(Map<String, dynamic> args,
      {void Function(String line)? onOutput}) async {
    final url = args['url'] as String?;
    if (url == null || url.isEmpty) {
      return SkillResult.fail('请提供要抓取的 URL');
    }

    // 验证 URL
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      return SkillResult.fail(
          'URL 必须以 http:// 或 https:// 开头');
    }

    final fetchInfo = args['fetch_info'] as String?;
    final selector = args['selector'] as String?;
    final maxLength = (args['max_length'] as int?) ?? 8000;
    final includeLinks = (args['include_links'] as bool?) ?? true;

    try {
      debugPrint('📄 抓取网页: $url');

      final response = await _dio.get(
        url,
        options: Options(
          headers: {
            'User-Agent': _defaultUserAgent,
            'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
            'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
          },
          responseType: ResponseType.plain,
        ),
      );

      if (response.statusCode != 200) {
        return SkillResult.fail('HTTP 错误: ${response.statusCode}');
      }

      final html = response.data as String;
      if (html.isEmpty) {
        return SkillResult.fail('页面内容为空');
      }

      final finalUrl = response.realUri.toString();

      final result = _parseHtml(
        html: html,
        url: finalUrl,
        fetchInfo: fetchInfo,
        selector: selector,
        maxLength: maxLength,
        includeLinks: includeLinks,
      );

      return result;
    } on DioException catch (e) {
      if (e.type == DioExceptionType.connectionTimeout ||
          e.type == DioExceptionType.sendTimeout ||
          e.type == DioExceptionType.receiveTimeout) {
        return SkillResult.fail('网络超时，请稍后重试');
      }

      if (e.type == DioExceptionType.connectionError) {
        return SkillResult.fail('无法连接到服务器，请检查 URL 是否正确');
      }

      debugPrint('📄 抓取错误: ${e.message}');
      return SkillResult.fail('抓取失败: ${e.message}');
    } catch (e) {
      debugPrint('📄 抓取异常: $e');
      return SkillResult.fail('抓取异常: $e');
    }
  }

  /// 解析 HTML 内容
  SkillResult _parseHtml({
    required String html,
    required String url,
    String? fetchInfo,
    String? selector,
    required int maxLength,
    required bool includeLinks,
  }) {
    final buffer = StringBuffer();

    // 提取标题
    final title = _extractTitle(html);
    if (title.isNotEmpty) {
      buffer.writeln('# $title');
      buffer.writeln();
    }

    // 提取正文内容
    String content;
    if (selector != null && selector.isNotEmpty) {
      content = _extractBySelector(html, selector);
    } else {
      content = _extractMainContent(html);
    }

    // 转换为 Markdown
    content = _htmlToMarkdown(content);

    // 截断
    if (content.length > maxLength) {
      content = '${content.substring(0, maxLength)}...\n\n[内容已截断]';
    }

    buffer.writeln(content);

    // 提取链接
    if (includeLinks) {
      final links = _extractLinks(html, url);
      if (links.isNotEmpty) {
        buffer.writeln();
        buffer.writeln('## 相关链接');
        for (final link in links.take(10)) {
          buffer.writeln('- [${link['text']}](${link['url']})');
        }
        if (links.length > 10) {
          buffer.writeln('- ... 还有 ${links.length - 10} 个链接');
        }
      }
    }

    // 根据 fetchInfo 添加提示
    String additionalInfo = '';
    if (fetchInfo != null && fetchInfo.isNotEmpty) {
      additionalInfo = '\n\n提取目标: $fetchInfo';
    }

    return SkillResult.ok(
      '成功抓取网页\n\n${buffer.toString()}$additionalInfo',
      data: {
        'url': url,
        'title': title,
        'content': content,
      },
    );
  }

  /// 提取标题
  String _extractTitle(String html) {
    // 尝试 <title> 标签
    var match = RegExp(r'<title[^>]*>([^<]+)</title>', caseSensitive: false)
        .firstMatch(html);
    if (match != null) {
      return _decodeHtmlEntities(match.group(1)!.trim());
    }

    // 尝试 <h1> 标签
    match = RegExp(r'<h1[^>]*>([^<]+)</h1>', caseSensitive: false)
        .firstMatch(html);
    if (match != null) {
      return _decodeHtmlEntities(match.group(1)!.trim());
    }

    return '';
  }

  /// 提取主要内容
  String _extractMainContent(String html) {
    var content = html;

    // 移除不需要的标签
    final removePatterns = [
      r'<script[^>]*>[\s\S]*?</script>',
      r'<style[^>]*>[\s\S]*?</style>',
      r'<nav[^>]*>[\s\S]*?</nav>',
      r'<footer[^>]*>[\s\S]*?</footer>',
      r'<aside[^>]*>[\s\S]*?</aside>',
      r'<header[^>]*>[\s\S]*?</header>',
      r'<noscript[^>]*>[\s\S]*?</noscript>',
      r'<iframe[^>]*>[\s\S]*?</iframe>',
      r'<!--[\s\S]*?-->',
    ];

    for (final pattern in removePatterns) {
      content = content.replaceAll(RegExp(pattern, caseSensitive: false), '');
    }

    // 尝试找到主要内容区域
    final mainPatterns = [
      r'<main[^>]*>([\s\S]*?)</main>',
      r'<article[^>]*>([\s\S]*?)</article>',
      r'<div[^>]*class="[^"]*content[^"]*"[^>]*>([\s\S]*?)</div>',
      r'<div[^>]*class="[^"]*article[^"]*"[^>]*>([\s\S]*?)</div>',
      r'<body[^>]*>([\s\S]*?)</body>',
    ];

    for (final pattern in mainPatterns) {
      final match = RegExp(pattern, caseSensitive: false).firstMatch(content);
      if (match != null) {
        content = match.group(1)!;
        break;
      }
    }

    return content;
  }

  /// 按选择器提取内容
  String _extractBySelector(String html, String selector) {
    RegExp pattern;
    if (selector.startsWith('.')) {
      final className = selector.substring(1);
      pattern = RegExp(
        '<[^>]*class="[^"]*$className[^"]*"[^>]*>([\\s\\S]*?)</[^>]*>',
        caseSensitive: false,
      );
    } else if (selector.startsWith('#')) {
      final idName = selector.substring(1);
      pattern = RegExp(
        '<[^>]*id="$idName"[^>]*>([\\s\\S]*?)</[^>]*>',
        caseSensitive: false,
      );
    } else {
      pattern = RegExp(
        '<$selector[^>]*>([\\s\\S]*?)</$selector>',
        caseSensitive: false,
      );
    }

    final matches = pattern.allMatches(html);
    final results = <String>[];
    for (final match in matches) {
      results.add(match.group(1)!);
    }

    return results.join('\n\n');
  }

  /// HTML 转 Markdown
  String _htmlToMarkdown(String html) {
    var md = html;

    // 处理标题
    for (int i = 1; i <= 6; i++) {
      md = md.replaceAllMapped(
        RegExp('<h$i[^>]*>([^<]+)</h$i>', caseSensitive: false),
        (m) => '\n${'#' * i} ${m.group(1)}\n',
      );
    }

    // 处理段落
    md = md.replaceAllMapped(
      RegExp(r'<p[^>]*>([\s\S]*?)</p>', caseSensitive: false),
      (m) => '\n${m.group(1)}\n',
    );

    // 处理链接
    md = md.replaceAllMapped(
      RegExp(r'<a[^>]*href="([^"]+)"[^>]*>([^<]+)</a>', caseSensitive: false),
      (m) => '[${m.group(2)}](${m.group(1)})',
    );

    // 处理加粗
    md = md.replaceAllMapped(
      RegExp(r'<(strong|b)[^>]*>([^<]+)</\1>', caseSensitive: false),
      (m) => '**${m.group(2)}**',
    );

    // 处理斜体
    md = md.replaceAllMapped(
      RegExp(r'<(em|i)[^>]*>([^<]+)</\1>', caseSensitive: false),
      (m) => '*${m.group(2)}*',
    );

    // 处理代码块
    md = md.replaceAllMapped(
      RegExp(r'<pre[^>]*><code[^>]*>([\s\S]*?)</code></pre>', caseSensitive: false),
      (m) => '\n```\n${m.group(1)}\n```\n',
    );

    // 处理行内代码
    md = md.replaceAllMapped(
      RegExp(r'<code[^>]*>([^<]+)</code>', caseSensitive: false),
      (m) => '`${m.group(1)}`',
    );

    // 处理列表
    md = md.replaceAllMapped(
      RegExp(r'<li[^>]*>([^<]+)</li>', caseSensitive: false),
      (m) => '- ${m.group(1)}',
    );

    // 处理换行
    md = md.replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n');

    // 移除剩余的 HTML 标签
    md = md.replaceAll(RegExp(r'<[^>]+>'), '');

    // 解码 HTML 实体
    md = _decodeHtmlEntities(md);

    // 清理多余空白
    md = md.replaceAll(RegExp(r'\n{3,}'), '\n\n');
    md = md.replaceAll(RegExp(r' {2,}'), ' ');

    return md.trim();
  }

  /// 解码 HTML 实体
  String _decodeHtmlEntities(String text) {
    return text
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&apos;', "'")
        .replaceAllMapped(
          RegExp(r'&#(\d+);'),
          (m) => String.fromCharCode(int.parse(m.group(1)!)),
        )
        .replaceAllMapped(
          RegExp(r'&#x([0-9a-fA-F]+);'),
          (m) => String.fromCharCode(int.parse(m.group(1)!, radix: 16)),
        );
  }

  /// 提取链接
  List<Map<String, String>> _extractLinks(String html, String baseUrl) {
    final links = <Map<String, String>>[];
    final pattern = RegExp(r'<a[^>]*href="([^"]+)"[^>]*>([^<]*)</a>', caseSensitive: false);

    for (final match in pattern.allMatches(html)) {
      var href = match.group(1)!;
      final text = _decodeHtmlEntities(match.group(2)!.trim());

      // 跳过空链接、锚点、JavaScript
      if (href.isEmpty ||
          href.startsWith('#') ||
          href.startsWith('javascript:') ||
          href.startsWith('mailto:')) {
        continue;
      }

      // 转换相对路径为绝对路径
      if (!href.startsWith('http')) {
        try {
          final base = Uri.parse(baseUrl);
          href = base.resolve(href).toString();
        } catch (_) {
          continue;
        }
      }

      // 去重
      if (!links.any((l) => l['url'] == href)) {
        links.add({'url': href, 'text': text.isNotEmpty ? text : href});
      }
    }

    return links;
  }
}
