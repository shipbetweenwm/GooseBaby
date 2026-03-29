import 'package:flutter/foundation.dart';
import 'package:dio/dio.dart';
import '../utils/type_utils.dart';
import '../utils/storage.dart';
import '../ai/memory/memory_manager.dart';
import 'skill_base.dart';

/// 网络搜索技能 — 使用 Tavily API
///
/// Tavily 专为 AI Agent 设计，支持中英文搜索，返回质量高。
/// 免费注册：https://tavily.com （1000次/月）
class WebSearchSkill extends GooseSkill {
  /// Tavily API Key（运行时注入）
  String? _tavilyApiKey;

  /// 记忆管理器（三级查找兜底）
  MemoryManager? _memoryManager;

  static const String _tavilyUrl = 'https://api.tavily.com/search';

  final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 30),
    receiveTimeout: const Duration(seconds: 60),
  ));

  /// 注入 MemoryManager
  void setMemoryManager(MemoryManager manager) => _memoryManager = manager;

  /// 注入 API Key
  void setApiKey(String? key) => _tavilyApiKey = key;

  /// 三级查找 Tavily API Key：运行时注入 → Hive → 永久记忆
  String? _resolveApiKey(String? callArg) {
    if (callArg != null && callArg.isNotEmpty) return callArg;
    if (_tavilyApiKey != null && _tavilyApiKey!.isNotEmpty) return _tavilyApiKey;
    final hive = StorageManager.getSearchApiKey('tavily');
    if (hive != null && hive.isNotEmpty) return hive;
    final mem = _memoryManager?.searchApiKeyFromMemory('tavily');
    if (mem != null && mem.isNotEmpty) {
      debugPrint('🔑 [WebSearch] 从记忆中找到 Tavily API key');
      return mem;
    }
    return null;
  }

  @override
  String get id => 'web_search';

  @override
  String get name => '网络搜索';

  @override
  String get description =>
      '使用 Tavily 搜索互联网，获取实时信息。\n'
      '需要 Tavily API Key（tvly-xxx 格式），免费注册：https://tavily.com\n'
      '直接告诉鹅宝"我的 Tavily key 是 tvly-xxx"，鹅宝会记住。';

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
      name: 'max_results',
      description: '返回结果数量，默认 5，最多 10',
      type: 'int',
      required: false,
      defaultValue: 5,
    ),
    const SkillParam(
      name: 'search_depth',
      description: '搜索深度: basic(快速，默认) 或 advanced(深度，消耗更多配额)',
      type: 'string',
      required: false,
      defaultValue: 'basic',
    ),
    const SkillParam(
      name: 'include_domains',
      description: '限制搜索域名，逗号分隔，如 "github.com,stackoverflow.com"',
      type: 'string',
      required: false,
    ),
    const SkillParam(
      name: 'exclude_domains',
      description: '排除搜索域名，逗号分隔',
      type: 'string',
      required: false,
    ),
    const SkillParam(
      name: 'api_key',
      description: 'Tavily API Key（tvly-xxx 格式）。也可直接告诉鹅宝 key，鹅宝会记住',
      type: 'string',
      required: false,
    ),
  ];

  @override
  Future<SkillResult> execute(Map<String, dynamic> args, {void Function(String line)? onOutput}) async {
    final query = args['query'] as String? ?? '';
    if (query.trim().isEmpty) {
      return SkillResult.fail('请输入搜索关键词');
    }

    final apiKey = _resolveApiKey(args['api_key'] as String?);
    if (apiKey == null || apiKey.isEmpty) {
      return SkillResult.fail(
        '❌ 使用 web_search 需要 Tavily API Key\n\n'
        '💬 **最简单的方式**：直接在对话框告诉鹅宝：\n'
        '   "我的 Tavily key 是 tvly-xxxxxxxxxx"\n'
        '   鹅宝会自动记住，下次不用再说 🧠\n\n'
        '📝 **免费注册**：https://tavily.com（1000次/月免费）',
      );
    }

    final maxResults = ((args['max_results'] as int?) ?? 5).clamp(1, 10);
    final searchDepth = args['search_depth'] as String? ?? 'basic';
    final includeDomains = _parseDomains(args['include_domains']);
    final excludeDomains = _parseDomains(args['exclude_domains']);

    try {
      debugPrint('🔍 Tavily 搜索: $query');
      final response = await _dio.post(
        _tavilyUrl,
        options: Options(headers: {
          'Authorization': 'Bearer $apiKey',
          'Content-Type': 'application/json',
        }),
        data: {
          'query': query,
          'search_depth': searchDepth,
          'max_results': maxResults,
          'include_answer': true,
          if (includeDomains != null) 'include_domains': includeDomains,
          if (excludeDomains != null) 'exclude_domains': excludeDomains,
        },
      );

      if (response.statusCode != 200) {
        return SkillResult.fail('搜索失败: HTTP ${response.statusCode}');
      }

      return _formatResults(safeMap(response.data));
    } on DioException catch (e) {
      return _handleError(e);
    } catch (e) {
      debugPrint('🔍 搜索异常: $e');
      return SkillResult.fail('搜索异常: $e');
    }
  }

  SkillResult _formatResults(Map<String, dynamic> data) {
    final buffer = StringBuffer();

    final answer = data['answer'] as String?;
    if (answer != null && answer.isNotEmpty) {
      buffer.writeln('## 📝 答案摘要');
      buffer.writeln(answer);
      buffer.writeln();
    }

    final results = data['results'] as List?;
    if (results != null && results.isNotEmpty) {
      buffer.writeln('## 🔍 搜索结果 (${results.length} 条)');
      buffer.writeln();
      for (int i = 0; i < results.length; i++) {
        final r = safeMap(results[i]);
        final title = r['title'] as String? ?? '无标题';
        final url = r['url'] as String? ?? '';
        final content = r['content'] as String? ?? '';
        final score = r['score'] as num?;

        buffer.writeln('### ${i + 1}. $title');
        if (score != null) buffer.writeln('📊 相关度: ${(score * 100).toStringAsFixed(0)}%');
        if (url.isNotEmpty) buffer.writeln('🔗 $url');
        if (content.isNotEmpty) {
          buffer.writeln();
          buffer.writeln(content.length > 300 ? '${content.substring(0, 300)}...' : content);
        }
        buffer.writeln();
      }
    } else {
      buffer.writeln('未找到相关结果');
    }

    return SkillResult.ok(buffer.toString());
  }

  SkillResult _handleError(DioException e) {
    if (e.type == DioExceptionType.connectionTimeout ||
        e.type == DioExceptionType.sendTimeout ||
        e.type == DioExceptionType.receiveTimeout) {
      return SkillResult.fail('网络超时，请稍后重试');
    }
    final code = e.response?.statusCode;
    if (code == 401) {
      return SkillResult.fail(
        '❌ Tavily API Key 无效（401）\n'
        '请检查 key 是否正确，或重新告诉鹅宝新的 key。',
      );
    }
    if (code == 403) {
      return SkillResult.fail(
        '❌ Tavily 返回 403\n'
        '请检查 API Key 是否正确，或访问 https://tavily.com 确认账号状态。',
      );
    }
    if (code == 429) {
      return SkillResult.fail('❌ Tavily 配额已用完（429），请稍后重试或升级套餐。');
    }
    return SkillResult.fail('❌ Tavily 搜索失败（HTTP $code）：${e.message}');
  }

  List<String>? _parseDomains(dynamic value) {
    if (value == null) return null;
    if (value is List) return value.map((e) => e.toString()).toList();
    if (value is String) {
      if (value.trim().isEmpty) return null;
      return value.split(',').map((d) => d.trim()).where((d) => d.isNotEmpty).toList();
    }
    return null;
  }
}
