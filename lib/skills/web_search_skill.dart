import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:dio/dio.dart';
import '../utils/type_utils.dart';
import 'skill_base.dart';

/// 搜索引擎类型
enum SearchProvider {
  tavily,
  brave,
  exa,
  wikipedia,
  arxiv,
}

/// 搜索引擎配置
class SearchProviderConfig {
  final String name;
  final String description;
  final bool requiresApiKey;
  final String? apiKeyHint;
  final String? signUpUrl;
  
  const SearchProviderConfig({
    required this.name,
    required this.description,
    this.requiresApiKey = false,
    this.apiKeyHint,
    this.signUpUrl,
  });
}

/// 网络搜索技能
/// 
/// 支持多种搜索引擎：Tavily、Brave Search、Exa、Wikipedia、ArXiv
class WebSearchSkill extends GooseSkill {
  /// 各搜索引擎的 API 密钥
  String? _tavilyApiKey;
  String? _braveApiKey;
  String? _exaApiKey;
  

  
  /// API 端点
  static const Map<SearchProvider, String> _apiUrls = {
    SearchProvider.tavily: 'https://api.tavily.com/search',
    SearchProvider.brave: 'https://api.search.brave.com/res/v1/web/search',
    SearchProvider.exa: 'https://api.exa.ai/search',
    SearchProvider.wikipedia: 'https://en.wikipedia.org/api/rest_v1/page/summary/',
    SearchProvider.arxiv: 'http://export.arxiv.org/api/query',
  };
  
  /// 搜索引擎配置信息
  static const Map<SearchProvider, SearchProviderConfig> _providerConfigs = {
    SearchProvider.tavily: SearchProviderConfig(
      name: 'Tavily',
      description: 'AI 优化搜索，高质量结果',
      requiresApiKey: true,
      apiKeyHint: 'tvly-xxx...',
      signUpUrl: 'https://tavily.com',
    ),
    SearchProvider.brave: SearchProviderConfig(
      name: 'Brave Search',
      description: '隐私优先，实时网页搜索',
      requiresApiKey: true,
      apiKeyHint: 'BSAxxx...',
      signUpUrl: 'https://brave.com/search/api/',
    ),
    SearchProvider.exa: SearchProviderConfig(
      name: 'Exa',
      description: '语义搜索，智能内容发现',
      requiresApiKey: true,
      apiKeyHint: 'xxx...',
      signUpUrl: 'https://exa.ai',
    ),
    SearchProvider.wikipedia: SearchProviderConfig(
      name: 'Wikipedia',
      description: '维基百科知识查询',
      requiresApiKey: false,
    ),
    SearchProvider.arxiv: SearchProviderConfig(
      name: 'ArXiv',
      description: '学术论文搜索',
      requiresApiKey: false,
    ),
  };
  
  /// HTTP 客户端
  final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 30),
    receiveTimeout: const Duration(seconds: 60),
  ));
  
  /// 设置 API 密钥
  void setApiKey(SearchProvider provider, String? key) {
    switch (provider) {
      case SearchProvider.tavily:
        _tavilyApiKey = key;
        break;
      case SearchProvider.brave:
        _braveApiKey = key;
        break;
      case SearchProvider.exa:
        _exaApiKey = key;
        break;
      default:
        break;
    }
  }
  
  @override
  String get id => 'web_search';

  @override
  String get name => '网络搜索';

  @override
  String get description =>
      '多引擎网络搜索，支持 Wikipedia、ArXiv、Tavily、Brave、Exa。\n'
      '【免费引擎】Wikipedia、ArXiv - 无需配置\n'
      '【付费引擎】Tavily、Brave、Exa - 需 API Key\n'
      '【推荐】默认使用 Wikipedia，专业搜索请选择对应引擎。';

  @override
  String get icon => '🔍';

  @override
  String get category => '内置工具';

  @override
  List<SkillParam> get params => [
    const SkillParam(
      name: 'query',
      description: '搜索关键词或问题',
      type: 'string',
      required: true,
    ),
    const SkillParam(
      name: 'provider',
      description: '搜索引擎: wikipedia(默认)、arxiv、tavily、brave、exa',
      type: 'string',
      required: false,
      defaultValue: 'wikipedia',
    ),
    const SkillParam(
      name: 'max_results',
      description: '返回结果数量，默认 5',
      type: 'int',
      required: false,
      defaultValue: 5,
    ),
    const SkillParam(
      name: 'api_key',
      description: 'API Key（仅付费引擎需要）',
      type: 'string',
      required: false,
    ),
    // Tavily 专用参数
    const SkillParam(
      name: 'search_depth',
      description: '[Tavily] 搜索深度: basic 或 advanced',
      type: 'string',
      required: false,
      defaultValue: 'basic',
    ),
    const SkillParam(
      name: 'include_domains',
      description: '[Tavily/Exa] 限制搜索域名（JSON 数组）',
      type: 'string',
      required: false,
    ),
    const SkillParam(
      name: 'exclude_domains',
      description: '[Tavily] 排除搜索域名（JSON 数组）',
      type: 'string',
      required: false,
    ),
    // ArXiv 专用参数
    const SkillParam(
      name: 'arxiv_category',
      description: '[ArXiv] 学科分类: cs.AI, cs.LG, physics 等',
      type: 'string',
      required: false,
    ),
  ];

  @override
  Future<SkillResult> execute(Map<String, dynamic> args, {void Function(String line)? onOutput}) async {
    final query = args['query'] as String?;
    if (query == null || query.isEmpty) {
      return SkillResult.fail('请输入搜索关键词');
    }
    
    // 解析搜索引擎
    final providerStr = (args['provider'] as String?)?.toLowerCase() ?? 'wikipedia';
    final provider = _parseProvider(providerStr);
    
    // 检查 API Key
    final config = _providerConfigs[provider]!;
    String? apiKey = args['api_key'] as String?;
    
    if (config.requiresApiKey) {
      apiKey ??= _getApiKey(provider);
      if (apiKey == null || apiKey.isEmpty) {
        return SkillResult.fail(
          '❌ ${config.name} 需要 API Key\n'
          '💡 获取方式:\n'
          '   1. 访问 ${config.signUpUrl} 注册\n'
          '   2. 获取 API Key (${config.apiKeyHint})\n'
          '   3. 通过参数 api_key 传入\n'
          '💡 或使用免费引擎: wikipedia, arxiv'
        );
      }
    }
    
    try {
      debugPrint('🔍 ${config.name} 搜索: $query');
      
      switch (provider) {
        case SearchProvider.tavily:
          return await _searchTavily(query, args, apiKey!);
        case SearchProvider.brave:
          return await _searchBrave(query, args, apiKey!);
        case SearchProvider.exa:
          return await _searchExa(query, args, apiKey!);
        case SearchProvider.wikipedia:
          return await _searchWikipedia(query);
        case SearchProvider.arxiv:
          return await _searchArxiv(query, args);
      }
    } on DioException catch (e) {
      return _handleDioError(e, config.name);
    } catch (e) {
      debugPrint('🔍 搜索异常: $e');
      return SkillResult.fail('搜索异常: $e');
    }
  }
  
  /// 解析搜索引擎
  SearchProvider _parseProvider(String str) {
    switch (str) {
      case 'tavily':
        return SearchProvider.tavily;
      case 'brave':
        return SearchProvider.brave;
      case 'exa':
        return SearchProvider.exa;
      case 'arxiv':
        return SearchProvider.arxiv;
      case 'wikipedia':
      default:
        return SearchProvider.wikipedia;
    }
  }
  
  /// 获取 API Key
  String? _getApiKey(SearchProvider provider) {
    switch (provider) {
      case SearchProvider.tavily:
        return _tavilyApiKey;
      case SearchProvider.brave:
        return _braveApiKey;
      case SearchProvider.exa:
        return _exaApiKey;
      default:
        return null;
    }
  }
  
  // ============== Tavily 搜索 ==============
  
  Future<SkillResult> _searchTavily(String query, Map<String, dynamic> args, String apiKey) async {
    final maxResults = ((args['max_results'] as int?) ?? 5).clamp(1, 10);
    final searchDepth = args['search_depth'] as String? ?? 'basic';
    final includeAnswer = (args['include_answer'] as bool?) ?? true;
    
    List<String>? includeDomains = _parseDomains(args['include_domains']);
    List<String>? excludeDomains = _parseDomains(args['exclude_domains']);
    
    final response = await _dio.post(
      _apiUrls[SearchProvider.tavily]!,
      options: Options(headers: {
        'Authorization': 'Bearer $apiKey',
        'Content-Type': 'application/json',
      }),
      data: {
        'query': query,
        'search_depth': searchDepth,
        'max_results': maxResults,
        'include_answer': includeAnswer,
        if (includeDomains != null) 'include_domains': includeDomains,
        if (excludeDomains != null) 'exclude_domains': excludeDomains,
      },
    );
    
    if (response.statusCode != 200) {
      return SkillResult.fail('搜索失败: HTTP ${response.statusCode}');
    }
    
    return _formatTavilyResults(safeMap(response.data), query);
  }
  
  SkillResult _formatTavilyResults(Map<String, dynamic> data, String query) {
    final buffer = StringBuffer();
    
    // AI 答案摘要
    final answer = data['answer'] as String?;
    if (answer != null && answer.isNotEmpty) {
      buffer.writeln('## 📝 答案摘要');
      buffer.writeln(answer);
      buffer.writeln();
    }
    
    // 搜索结果
    final results = data['results'] as List?;
    if (results != null && results.isNotEmpty) {
      buffer.writeln('## 🔍 搜索结果 (${results.length} 条)');
      buffer.writeln();
      
      for (int i = 0; i < results.length; i++) {
        final result = safeMap(results[i]);
        final title = result['title'] as String? ?? '无标题';
        final url = result['url'] as String? ?? '';
        final content = result['content'] as String? ?? '';
        final score = result['score'] as num?;
        
        buffer.writeln('### ${i + 1}. $title');
        if (score != null) buffer.writeln('📊 相关度: ${(score * 100).toStringAsFixed(0)}%');
        if (url.isNotEmpty) buffer.writeln('🔗 $url');
        if (content.isNotEmpty) {
          buffer.writeln();
          buffer.writeln(content.length > 300 ? '${content.substring(0, 300)}...' : content);
        }
        buffer.writeln();
      }
    }
    
    if (results == null || results.isEmpty) {
      buffer.writeln('未找到相关结果');
    }
    
    return SkillResult.ok(buffer.toString());
  }
  
  // ============== Brave Search ==============
  
  Future<SkillResult> _searchBrave(String query, Map<String, dynamic> args, String apiKey) async {
    final count = ((args['max_results'] as int?) ?? 5).clamp(1, 20);
    
    final response = await _dio.get(
      _apiUrls[SearchProvider.brave]!,
      queryParameters: {
        'q': query,
        'count': count,
      },
      options: Options(headers: {
        'Accept': 'application/json',
        'Accept-Encoding': 'gzip',
        'X-Subscription-Token': apiKey,
      }),
    );
    
    if (response.statusCode != 200) {
      return SkillResult.fail('搜索失败: HTTP ${response.statusCode}');
    }
    
    return _formatBraveResults(safeMap(response.data), query);
  }
  
  SkillResult _formatBraveResults(Map<String, dynamic> data, String query) {
    final buffer = StringBuffer();
    final web = safeMap(data['web']);
    final results = web['results'] as List?;
    
    if (results != null && results.isNotEmpty) {
      buffer.writeln('## 🔍 搜索结果 (${results.length} 条)');
      buffer.writeln();
      
      for (int i = 0; i < results.length; i++) {
        final result = safeMap(results[i]);
        final title = result['title'] as String? ?? '无标题';
        final url = result['url'] as String? ?? '';
        final description = result['description'] as String? ?? '';
        
        buffer.writeln('### ${i + 1}. $title');
        if (url.isNotEmpty) buffer.writeln('🔗 $url');
        if (description.isNotEmpty) {
          buffer.writeln();
          buffer.writeln(description.length > 300 ? '${description.substring(0, 300)}...' : description);
        }
        buffer.writeln();
      }
    }
    
    if (results == null || results.isEmpty) {
      buffer.writeln('未找到相关结果');
    }
    
    return SkillResult.ok(buffer.toString());
  }
  
  // ============== Exa 搜索 ==============
  
  Future<SkillResult> _searchExa(String query, Map<String, dynamic> args, String apiKey) async {
    final numResults = ((args['max_results'] as int?) ?? 5).clamp(1, 10);
    List<String>? includeDomains = _parseDomains(args['include_domains']);
    
    final response = await _dio.post(
      _apiUrls[SearchProvider.exa]!,
      options: Options(headers: {
        'x-api-key': apiKey,
        'Content-Type': 'application/json',
      }),
      data: {
        'query': query,
        'numResults': numResults,
        'useAutoprompt': true,
        if (includeDomains != null) 'includeDomains': includeDomains,
      },
    );
    
    if (response.statusCode != 200) {
      return SkillResult.fail('搜索失败: HTTP ${response.statusCode}');
    }
    
    return _formatExaResults(safeMap(response.data), query);
  }
  
  SkillResult _formatExaResults(Map<String, dynamic> data, String query) {
    final buffer = StringBuffer();
    final results = data['results'] as List?;
    
    if (results != null && results.isNotEmpty) {
      buffer.writeln('## 🔍 搜索结果 (${results.length} 条)');
      buffer.writeln();
      
      for (int i = 0; i < results.length; i++) {
        final result = safeMap(results[i]);
        final title = result['title'] as String? ?? '无标题';
        final url = result['url'] as String? ?? '';
        final text = result['text'] as String? ?? '';
        final score = result['score'] as num?;
        
        buffer.writeln('### ${i + 1}. $title');
        if (score != null) buffer.writeln('📊 相关度: ${(score * 100).toStringAsFixed(0)}%');
        if (url.isNotEmpty) buffer.writeln('🔗 $url');
        if (text.isNotEmpty) {
          buffer.writeln();
          buffer.writeln(text.length > 300 ? '${text.substring(0, 300)}...' : text);
        }
        buffer.writeln();
      }
    }
    
    if (results == null || results.isEmpty) {
      buffer.writeln('未找到相关结果');
    }
    
    return SkillResult.ok(buffer.toString());
  }
  
  // ============== Wikipedia 搜索 ==============
  
  Future<SkillResult> _searchWikipedia(String query) async {
    // 先搜索获取页面标题
    final searchUrl = 'https://en.wikipedia.org/w/api.php?action=opensearch&search=${Uri.encodeComponent(query)}&limit=5&format=json';
    
    final searchResponse = await _dio.get(searchUrl);
    if (searchResponse.statusCode != 200) {
      return SkillResult.fail('搜索失败: HTTP ${searchResponse.statusCode}');
    }
    
    final searchData = searchResponse.data as List;
    if (searchData.length < 2) {
      return SkillResult.fail('搜索格式错误');
    }
    
    final titles = searchData[1] as List;
    final urls = searchData[3] as List?;
    
    if (titles.isEmpty) {
      return SkillResult.fail('未找到相关词条，请尝试英文关键词');
    }
    
    final buffer = StringBuffer();
    buffer.writeln('## 📚 Wikipedia 搜索结果 (${titles.length} 条)');
    buffer.writeln();
    
    // 获取前几个词条的摘要
    for (int i = 0; i < titles.length && i < 5; i++) {
      final title = titles[i] as String;
      final url = urls != null && i < urls.length ? urls[i] as String : '';
      
      try {
        // 获取页面摘要
        final summaryUrl = '${_apiUrls[SearchProvider.wikipedia]}${Uri.encodeComponent(title)}';
        final summaryResponse = await _dio.get(summaryUrl);
        
        if (summaryResponse.statusCode == 200) {
          final summary = safeMap(summaryResponse.data);
          final extract = summary['extract'] as String? ?? '';
          
          buffer.writeln('### ${i + 1}. $title');
          if (url.isNotEmpty) buffer.writeln('🔗 $url');
          if (extract.isNotEmpty) {
            buffer.writeln();
            buffer.writeln(extract.length > 400 ? '${extract.substring(0, 400)}...' : extract);
          }
          buffer.writeln();
        }
      } catch (e) {
        buffer.writeln('### ${i + 1}. $title');
        if (url.isNotEmpty) buffer.writeln('🔗 $url');
        buffer.writeln();
      }
    }
    
    return SkillResult.ok(buffer.toString());
  }
  
  // ============== ArXiv 搜索 ==============
  
  Future<SkillResult> _searchArxiv(String query, Map<String, dynamic> args) async {
    final maxResults = ((args['max_results'] as int?) ?? 5).clamp(1, 20);
    final category = args['arxiv_category'] as String?;
    
    // 构建 ArXiv API 查询
    String searchQuery = query;
    if (category != null && category.isNotEmpty) {
      searchQuery = 'cat:$category AND $query';
    }
    
    final url = '${_apiUrls[SearchProvider.arxiv]}?search_query=${Uri.encodeComponent(searchQuery)}&max_results=$maxResults&sortBy=relevance';
    
    final response = await _dio.get(url);
    if (response.statusCode != 200) {
      return SkillResult.fail('搜索失败: HTTP ${response.statusCode}');
    }
    
    return _parseArxivXml(response.data as String, query);
  }
  
  SkillResult _parseArxivXml(String xml, String query) {
    final buffer = StringBuffer();
    
    // 简单解析 XML（不依赖 XML 库）
    final entries = <Map<String, String>>[];
    final entryRegex = RegExp(r'<entry>([\s\S]*?)</entry>', multiLine: true);
    
    for (final match in entryRegex.allMatches(xml)) {
      final entryXml = match.group(1) ?? '';
      final entry = <String, String>{};
      
      // 提取标题
      final titleMatch = RegExp(r'<title>([\s\S]*?)</title>').firstMatch(entryXml);
      if (titleMatch != null) {
        entry['title'] = titleMatch.group(1)?.trim() ?? '';
      }
      
      // 提取摘要
      final summaryMatch = RegExp(r'<summary>([\s\S]*?)</summary>').firstMatch(entryXml);
      if (summaryMatch != null) {
        entry['summary'] = summaryMatch.group(1)?.trim() ?? '';
      }
      
      // 提取链接
      final linkMatch = RegExp(r'href="([^"]*)"').firstMatch(entryXml);
      if (linkMatch != null) {
        entry['link'] = linkMatch.group(1) ?? '';
      }
      
      // 提取作者
      final authorMatches = RegExp(r'<name>(.*?)</name>').allMatches(entryXml);
      final authors = authorMatches.map((m) => m.group(1) ?? '').take(5).join(', ');
      entry['authors'] = authors;
      
      // 提取发布日期
      final publishedMatch = RegExp(r'<published>(.*?)</published>').firstMatch(entryXml);
      if (publishedMatch != null) {
        entry['published'] = publishedMatch.group(1)?.substring(0, 10) ?? '';
      }
      
      if (entry.isNotEmpty) {
        entries.add(entry);
      }
    }
    
    if (entries.isEmpty) {
      return SkillResult.fail('未找到相关论文，请尝试英文关键词');
    }
    
    buffer.writeln('## 📄 ArXiv 论文搜索 (${entries.length} 篇)');
    buffer.writeln();
    
    for (int i = 0; i < entries.length; i++) {
      final entry = entries[i];
      final title = entry['title'] ?? '无标题';
      final authors = entry['authors'] ?? '';
      final published = entry['published'] ?? '';
      final link = entry['link'] ?? '';
      final summary = entry['summary'] ?? '';
      
      buffer.writeln('### ${i + 1}. $title');
      if (authors.isNotEmpty) buffer.writeln('👥 作者: $authors');
      if (published.isNotEmpty) buffer.writeln('📅 发布: $published');
      if (link.isNotEmpty) buffer.writeln('🔗 $link');
      if (summary.isNotEmpty) {
        buffer.writeln();
        buffer.writeln('**摘要**: ${summary.length > 300 ? '${summary.substring(0, 300)}...' : summary}');
      }
      buffer.writeln();
    }
    
    return SkillResult.ok(buffer.toString());
  }
  
  // ============== 工具方法 ==============
  
  /// 解析域名列表
  List<String>? _parseDomains(dynamic value) {
    if (value == null) return null;
    
    if (value is List) {
      return value.map((e) => e.toString()).toList();
    }
    
    if (value is String) {
      if (value.trim().isEmpty) return null;
      if (value.trim().startsWith('[')) {
        try {
          final decoded = jsonDecode(value);
          if (decoded is List) {
            return decoded.map((e) => e.toString()).toList();
          }
        } catch (_) {}
      }
      return value.split(',').map((d) => d.trim()).where((d) => d.isNotEmpty).toList();
    }
    
    return null;
  }
  
  /// 处理网络错误
  SkillResult _handleDioError(DioException e, String provider) {
    if (e.type == DioExceptionType.connectionTimeout ||
        e.type == DioExceptionType.sendTimeout ||
        e.type == DioExceptionType.receiveTimeout) {
      return SkillResult.fail('网络超时，请稍后重试');
    }
    
    if (e.response?.statusCode == 401) {
      return SkillResult.fail('$provider API Key 无效');
    }
    
    if (e.response?.statusCode == 429) {
      return SkillResult.fail('$provider API 配额已用完');
    }
    
    debugPrint('🔍 $provider 错误: ${e.message}');
    return SkillResult.fail('搜索失败: ${e.message}');
  }
  
  /// 获取所有搜索引擎信息
  static Map<SearchProvider, SearchProviderConfig> getProviderConfigs() => _providerConfigs;
}
