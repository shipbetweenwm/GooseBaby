import 'package:flutter/foundation.dart';
import 'package:dio/dio.dart';
import '../utils/type_utils.dart';
import '../utils/storage.dart';
import '../ai/memory/memory_manager.dart';
import 'skill_base.dart';

/// 新闻获取技能
///
/// 数据源策略（按优先级降级）：
/// 1. GNews API — 需要免费 API key，支持中文关键词搜索
/// 2. RSS 聚合 — 无需 key，来源包括 BBC中文、CNN、Google News RSS 等
///
/// freenewsapi.com 已于 2025 年起返回 403，已废弃。
class NewsSkill extends GooseSkill {
  /// HTTP 客户端
  final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 15),
    receiveTimeout: const Duration(seconds: 30),
  ));

  /// GNews API key（可选，为空时自动降级到 RSS）
  String? _gnewsApiKey;

  /// 记忆管理器（三级查找兜底）
  MemoryManager? _memoryManager;

  /// 注入 MemoryManager
  void setMemoryManager(MemoryManager manager) => _memoryManager = manager;

  /// 设置 GNews API key
  void setGNewsApiKey(String? key) => _gnewsApiKey = key;

  /// 三级查找 GNews API Key
  String? _resolveGNewsApiKey(String? callArg) {
    if (callArg != null && callArg.isNotEmpty) return callArg;
    if (_gnewsApiKey != null && _gnewsApiKey!.isNotEmpty) return _gnewsApiKey;
    final hive = StorageManager.getSearchApiKey('gnews');
    if (hive != null && hive.isNotEmpty) return hive;
    final mem = _memoryManager?.searchApiKeyFromMemory('gnews');
    if (mem != null && mem.isNotEmpty) {
      debugPrint('🔑 [News] 从记忆中找到 GNews API key');
      return mem;
    }
    return null;
  }

  // ── RSS 源表（免费，无需 key） ──
  // 按语言/地区分组，降级时按顺序尝试
  static const Map<String, List<String>> _rssFeeds = {
    'chinese': [
      'https://feeds.bbci.co.uk/zhongwen/simp/rss.xml',              // BBC 中文
      'https://news.google.com/rss?hl=zh-CN&gl=CN&ceid=CN:zh-Hans',  // Google News 中文
      'https://www.zaobao.com/rss/realtime/china',                    // 联合早报
    ],
    'english': [
      'https://feeds.bbci.co.uk/news/world/rss.xml',                 // BBC World
      'https://rss.cnn.com/rss/edition.rss',                         // CNN
      'https://news.google.com/rss?hl=en-US&gl=US&ceid=US:en',       // Google News EN
    ],
    'default': [
      'https://news.google.com/rss?hl=zh-CN&gl=CN&ceid=CN:zh-Hans',
      'https://feeds.bbci.co.uk/zhongwen/simp/rss.xml',
    ],
  };

  @override
  String get id => 'news';

  @override
  String get name => '新闻获取';

  @override
  String get description =>
      '获取最新新闻资讯。支持两种数据源：\n'
      '【免费 RSS】无需配置，直接可用（BBC中文/Google News等）\n'
      '【GNews API】需要 api_key，支持关键词搜索（免费 key 可在 gnews.io 获取）\n'
      '适合用于定时任务每天推送新闻摘要。';

  @override
  String get icon => '📰';

  @override
  String get category => '内置工具';

  @override
  List<SkillParam> get params => [
    const SkillParam(
      name: 'language',
      description: '新闻语言: chinese(默认)、english',
      type: 'string',
      required: false,
      defaultValue: 'chinese',
    ),
    const SkillParam(
      name: 'keyword',
      description: '关键词搜索（需要 GNews api_key）',
      type: 'string',
      required: false,
    ),
    const SkillParam(
      name: 'max_results',
      description: '返回新闻数量，默认 5 条，最多 10 条',
      type: 'int',
      required: false,
      defaultValue: 5,
    ),
    const SkillParam(
      name: 'api_key',
      description: 'GNews API Key（可选）。免费 key 在 https://gnews.io 注册获取',
      type: 'string',
      required: false,
    ),
    const SkillParam(
      name: 'format',
      description: '输出格式: summary(摘要列表，默认)、bubble(气泡单条)',
      type: 'string',
      required: false,
      defaultValue: 'summary',
    ),
  ];

  @override
  Future<SkillResult> execute(Map<String, dynamic> args, {void Function(String line)? onOutput}) async {
    final language = (args['language'] as String? ?? 'chinese').toLowerCase();
    final keyword = args['keyword'] as String?;
    final maxResults = ((args['max_results'] as int?) ?? 5).clamp(1, 10);
    final format = args['format'] as String? ?? 'summary';
    final apiKey = _resolveGNewsApiKey(args['api_key'] as String?);

    // ── 优先 GNews（有 key 且有关键词时） ──
    if (apiKey != null && apiKey.isNotEmpty) {
      final gnewsResult = await _fetchGNews(
        keyword: keyword,
        language: language,
        maxResults: maxResults,
        apiKey: apiKey,
      );
      if (gnewsResult != null) {
        return _format(gnewsResult, format, '🔍 GNews');
      }
      debugPrint('📰 GNews 失败，降级到 RSS');
    }

    // ── 降级：RSS 聚合 ──
    final rssResult = await _fetchRss(language: language, maxResults: maxResults);
    if (rssResult != null) {
      return _format(rssResult, format, '📡 RSS');
    }

    return SkillResult.fail(
      '❌ 暂时无法获取新闻（网络受限或 RSS 源不可达）\n\n'
      '💬 **用 GNews 获取更好的中文新闻**：\n'
      '   1. 访问 https://gnews.io 免费注册\n'
      '   2. 获取 API Key 后，直接在对话框告诉鹅宝：\n'
      '      "我的 GNews key 是 xxxxxxxxxxxxxxxx"\n'
      '   鹅宝会记住，以后自动使用 🧠\n\n'
      '🌐 也可以检查网络连接是否能访问 BBC / Google News',
    );
  }

  // ══════════════════════════════════════════
  // GNews API
  // ══════════════════════════════════════════

  Future<List<_NewsItem>?> _fetchGNews({
    String? keyword,
    required String language,
    required int maxResults,
    required String apiKey,
  }) async {
    try {
      final langCode = _toGNewsLang(language);
      String url;
      Map<String, dynamic> params;

      if (keyword != null && keyword.isNotEmpty) {
        url = 'https://gnews.io/api/v4/search';
        params = {
          'q': keyword,
          'lang': langCode,
          'max': maxResults,
          'apikey': apiKey,
          'sortby': 'publishedAt',
        };
      } else {
        url = 'https://gnews.io/api/v4/top-headlines';
        params = {
          'lang': langCode,
          'max': maxResults,
          'apikey': apiKey,
        };
      }

      debugPrint('📰 GNews 请求: $url');
      final response = await _dio.get(url, queryParameters: params);

      if (response.statusCode != 200) {
        debugPrint('📰 GNews HTTP ${response.statusCode}');
        return null;
      }

      final data = safeMap(response.data);
      final articles = data['articles'] as List?;
      if (articles == null || articles.isEmpty) return null;

      return articles.map((a) {
        final m = safeMap(a);
        return _NewsItem(
          title: m['title'] as String? ?? '无标题',
          url: m['url'] as String? ?? '',
          source: safeMap(m['source'])['name'] as String? ?? '',
          publishedAt: m['publishedAt'] as String? ?? '',
          description: m['description'] as String? ?? '',
        );
      }).toList();
    } on DioException catch (e) {
      debugPrint('📰 GNews 错误: ${e.response?.statusCode} ${e.message}');
      return null;
    } catch (e) {
      debugPrint('📰 GNews 异常: $e');
      return null;
    }
  }

  // ══════════════════════════════════════════
  // RSS 聚合（无需 key）
  // ══════════════════════════════════════════

  Future<List<_NewsItem>?> _fetchRss({
    required String language,
    required int maxResults,
  }) async {
    final feeds = _rssFeeds[language] ?? _rssFeeds['default']!;

    for (final feedUrl in feeds) {
      try {
        debugPrint('📰 RSS 请求: $feedUrl');
        final response = await _dio.get(
          feedUrl,
          options: Options(
            headers: {
              'User-Agent': 'Mozilla/5.0 (compatible; GooseBaby/1.0)',
              'Accept': 'application/rss+xml, application/xml, text/xml',
            },
            responseType: ResponseType.plain,
            validateStatus: (s) => s != null && s < 500,
          ),
        );

        if (response.statusCode != 200) {
          debugPrint('📰 RSS HTTP ${response.statusCode} for $feedUrl');
          continue;
        }

        final items = _parseRss(response.data as String, maxResults);
        if (items.isNotEmpty) return items;
      } catch (e) {
        debugPrint('📰 RSS 失败 $feedUrl: $e');
        continue;
      }
    }
    return null;
  }

  /// 简单 RSS XML 解析（不依赖外部库）
  List<_NewsItem> _parseRss(String xml, int max) {
    final items = <_NewsItem>[];
    final itemRegex = RegExp(r'<item[^>]*>([\s\S]*?)</item>', multiLine: true);

    for (final match in itemRegex.allMatches(xml)) {
      if (items.length >= max) break;
      final block = match.group(1) ?? '';

      String extractTag(String tag) {
        // 处理 CDATA 和普通内容
        final cdataMatch = RegExp('<$tag>[^<]*<!\\[CDATA\\[(.*?)\\]\\]>[^<]*</$tag>',
            dotAll: true).firstMatch(block);
        if (cdataMatch != null) return cdataMatch.group(1)?.trim() ?? '';
        final plainMatch = RegExp('<$tag>(.*?)</$tag>', dotAll: true).firstMatch(block);
        return plainMatch?.group(1)?.trim() ?? '';
      }

      final title = extractTag('title');
      if (title.isEmpty) continue;

      final url = (() {
        // 优先 <link>，RSS 中 link 可能在 CDATA 或普通
        final linkMatch = RegExp(r'<link>\s*(https?://[^\s<]+)').firstMatch(block);
        if (linkMatch != null) return linkMatch.group(1) ?? '';
        // 备用：<guid isPermaLink="true">
        final guidMatch = RegExp(r'<guid[^>]*>(https?://[^\s<]+)</guid>').firstMatch(block);
        return guidMatch?.group(1) ?? '';
      })();

      final pubDate = extractTag('pubDate');
      final description = extractTag('description');
      final source = (() {
        final srcMatch = RegExp(r'<source[^>]*>(.*?)</source>', dotAll: true).firstMatch(block);
        return srcMatch?.group(1)?.trim() ?? '';
      })();

      items.add(_NewsItem(
        title: title,
        url: url,
        source: source,
        publishedAt: pubDate,
        description: description.length > 200
            ? '${description.substring(0, 200)}...'
            : description,
      ));
    }

    return items;
  }

  // ══════════════════════════════════════════
  // 格式化输出
  // ══════════════════════════════════════════

  SkillResult _format(List<_NewsItem> news, String format, String sourceLabel) {
    if (format == 'bubble') {
      final item = news.first;
      final shortTitle = item.title.length > 40
          ? '${item.title.substring(0, 40)}...'
          : item.title;
      return SkillResult.ok('📰 $shortTitle', data: {'news': news.map((n) => n.toMap()).toList()});
    }

    final buffer = StringBuffer();
    buffer.writeln('## 📰 新闻速递（${news.length} 条，来源: $sourceLabel）');
    buffer.writeln();
    for (int i = 0; i < news.length; i++) {
      final item = news[i];
      buffer.write('${i + 1}. ${item.title}');
      if (item.source.isNotEmpty) buffer.write('  ·  ${item.source}');
      buffer.writeln();
      if (item.url.isNotEmpty) buffer.writeln('   🔗 ${item.url}');
    }

    return SkillResult.ok(
      buffer.toString().trim(),
      data: {'news': news.map((n) => n.toMap()).toList()},
    );
  }

  // ══════════════════════════════════════════
  // 工具方法
  // ══════════════════════════════════════════

  String _toGNewsLang(String lang) {
    const map = {
      'chinese': 'zh',
      'english': 'en',
      'japanese': 'ja',
      'korean': 'ko',
      'french': 'fr',
      'german': 'de',
      'spanish': 'es',
    };
    return map[lang] ?? lang;
  }
}

/// 新闻条目数据结构
class _NewsItem {
  final String title;
  final String url;
  final String source;
  final String publishedAt;
  final String description;

  const _NewsItem({
    required this.title,
    required this.url,
    required this.source,
    required this.publishedAt,
    required this.description,
  });

  Map<String, dynamic> toMap() => {
    'title': title,
    'url': url,
    'source': source,
    'publishedAt': publishedAt,
    'description': description,
  };
}
