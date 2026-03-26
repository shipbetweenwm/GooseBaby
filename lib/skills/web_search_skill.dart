import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:dio/dio.dart';
import '../utils/type_utils.dart';
import 'skill_base.dart';

/// 网络搜索技能
/// 
/// 使用 Tavily API 进行网络搜索
/// 获取实时、准确的搜索结果
class WebSearchSkill extends GooseSkill {
  /// Tavily API 密钥（运行时设置）
  String? _apiKey;
  
  /// API 端点
  static const String _apiUrl = 'https://api.tavily.com/search';
  
  /// HTTP 客户端
  final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 30),
    receiveTimeout: const Duration(seconds: 60),
  ));
  
  /// 设置 API 密钥
  set apiKey(String? key) => _apiKey = key;
  
  @override
  String get id => 'web_search';

  @override
  String get name => '网络搜索';

  @override
  String get description =>
      '使用 Tavily API 进行网络搜索，获取实时、准确的信息。\n'
      '【前置条件】需要 Tavily API Key，可在 https://tavily.com 免费注册获取。\n'
      '【适用场景】查询最新信息、实时数据、新闻动态、技术文档等。\n'
      '【注意】每次搜索消耗 API 配额，请合理使用。';

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
      name: 'search_depth',
      description: '搜索深度: basic(快速) 或 advanced(深度)，默认 basic',
      type: 'string',
      required: false,
      defaultValue: 'basic',
    ),
    const SkillParam(
      name: 'max_results',
      description: '返回结果数量，默认 5，最多 10',
      type: 'int',
      required: false,
      defaultValue: 5,
    ),
    const SkillParam(
      name: 'include_domains',
      description: '限制搜索域名（JSON 数组格式），如 ["github.com", "stackoverflow.com"]',
      type: 'string',
      required: false,
    ),
    const SkillParam(
      name: 'exclude_domains',
      description: '排除搜索域名（JSON 数组格式）',
      type: 'string',
      required: false,
    ),
    const SkillParam(
      name: 'include_answer',
      description: '是否包含 AI 生成的答案摘要，默认 true',
      type: 'bool',
      required: false,
      defaultValue: true,
    ),
    const SkillParam(
      name: 'include_raw_content',
      description: '是否包含网页原始内容，默认 false',
      type: 'bool',
      required: false,
      defaultValue: false,
    ),
    const SkillParam(
      name: 'api_key',
      description: 'Tavily API Key（可选，如未全局配置）',
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
    
    // 获取 API Key
    final apiKey = args['api_key'] as String? ?? _apiKey;
    if (apiKey == null || apiKey.isEmpty) {
      return SkillResult.fail(
        '❌ 未配置 Tavily API Key\n'
        '💡 获取方式:\n'
        '   1. 访问 https://tavily.com 免费注册\n'
        '   2. 在控制台获取 API Key\n'
        '   3. 通过参数 api_key 传入或在设置中配置'
      );
    }
    
    final searchDepth = args['search_depth'] as String? ?? 'basic';
    final maxResults = ((args['max_results'] as int?) ?? 5).clamp(1, 10);
    final includeAnswer = (args['include_answer'] as bool?) ?? true;
    final includeRawContent = (args['include_raw_content'] as bool?) ?? false;
    
    // 解析域名列表
    List<String>? includeDomains;
    List<String>? excludeDomains;
    
    if (args['include_domains'] != null) {
      includeDomains = _parseDomains(args['include_domains']);
    }
    if (args['exclude_domains'] != null) {
      excludeDomains = _parseDomains(args['exclude_domains']);
    }
    
    try {
      debugPrint('🔍 Tavily 搜索: $query');
      
      final response = await _dio.post(
        _apiUrl,
        options: Options(
          headers: {
            'Authorization': 'Bearer $apiKey',
            'Content-Type': 'application/json',
          },
        ),
        data: {
          'query': query,
          'search_depth': searchDepth,
          'max_results': maxResults,
          'include_answer': includeAnswer,
          'include_raw_content': includeRawContent,
          if (includeDomains != null) 'include_domains': includeDomains,
          if (excludeDomains != null) 'exclude_domains': excludeDomains,
        },
      );
      
      if (response.statusCode != 200) {
        return SkillResult.fail('搜索失败: HTTP ${response.statusCode}');
      }
      
      final data = safeMap(response.data);
      return _formatResults(data, query);
      
    } on DioException catch (e) {
      if (e.type == DioExceptionType.connectionTimeout ||
          e.type == DioExceptionType.sendTimeout ||
          e.type == DioExceptionType.receiveTimeout) {
        return SkillResult.fail('网络超时，请稍后重试');
      }
      
      if (e.response?.statusCode == 401) {
        return SkillResult.fail('API Key 无效，请检查配置');
      }
      
      if (e.response?.statusCode == 429) {
        return SkillResult.fail('API 配额已用完，请稍后重试或升级套餐');
      }
      
      debugPrint('🔍 Tavily 错误: ${e.message}');
      return SkillResult.fail('搜索失败: ${e.message}');
      
    } catch (e) {
      debugPrint('🔍 搜索异常: $e');
      return SkillResult.fail('搜索异常: $e');
    }
  }
  
  /// 解析域名列表
  List<String> _parseDomains(dynamic value) {
    if (value == null) return [];
    
    if (value is List) {
      return value.map((e) => e.toString()).toList();
    }
    
    if (value is String) {
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
    
    return [];
  }
  
  /// 格式化搜索结果
  SkillResult _formatResults(Map<String, dynamic> data, String query) {
    final buffer = StringBuffer();
    
    // AI 生成的答案摘要
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
        if (score != null) {
          buffer.writeln('📊 相关度: ${(score * 100).toStringAsFixed(0)}%');
        }
        if (url.isNotEmpty) {
          buffer.writeln('🔗 $url');
        }
        if (content.isNotEmpty) {
          buffer.writeln();
          // 截断过长的内容
          final displayContent = content.length > 300
              ? '${content.substring(0, 300)}...'
              : content;
          buffer.writeln(displayContent);
        }
        buffer.writeln();
      }
    }
    
    // 相关问题
    final relatedQuestions = data['related_questions'] as List?;
    if (relatedQuestions != null && relatedQuestions.isNotEmpty) {
      buffer.writeln('## 💡 相关问题');
      for (final q in relatedQuestions.take(5)) {
        buffer.writeln('• $q');
      }
      buffer.writeln();
    }
    
    // 无结果
    if ((results == null || results.isEmpty) && (answer == null || answer.isEmpty)) {
      buffer.writeln('未找到相关结果，请尝试更换关键词');
    }
    
    return SkillResult.ok(buffer.toString(), data: {
      'query': query,
      'answer': answer,
      'results': results,
      'related_questions': relatedQuestions,
    });
  }
}
