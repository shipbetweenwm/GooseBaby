import 'dart:async';
import 'dart:convert';
import 'package:dio/dio.dart';
import '../../models/models.dart';
import '../agent/agent_types.dart';
import 'llm_provider.dart';

/// OpenAI GPT 大模型适配器
class OpenAIProvider implements LLMProvider {
  static const _defaultBaseUrl = 'https://api.openai.com/v1';
  final Dio _dio = Dio();

  /// 规范化 baseUrl：去掉末尾斜杠，确保格式统一
  String _fixBaseUrl(String? baseUrl) {
    if (baseUrl == null || baseUrl.isEmpty) return _defaultBaseUrl;
    var url = baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl;
    return url;
  }

  @override
  String get name => 'openai';

  @override
  String get displayName => 'OpenAI';

  @override
  List<String> get supportedModels => [
    'gpt-4o',
    'gpt-4o-mini',
    'gpt-4-turbo',
    'gpt-3.5-turbo',
  ];

  @override
  Future<AgentResponse> chat(
    List<Map<String, dynamic>> messages, {
    LLMConfig? config,
    List<Map<String, dynamic>>? tools,
  }) async {
    final cfg = config ?? const LLMConfig(provider: 'openai', model: 'gpt-4o-mini');
    final baseUrl = _fixBaseUrl(cfg.baseUrl);
    final url = '$baseUrl/chat/completions';

    final body = <String, dynamic>{
      'model': cfg.model,
      'messages': messages,
      'temperature': cfg.temperature,
      'max_tokens': cfg.maxTokens,
    };

    if (tools != null && tools.isNotEmpty) {
      body['tools'] = tools;
    }

    final response = await _dio.post(
      url,
      data: jsonEncode(body),
      options: Options(
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer ${cfg.apiKey}',
        },
      ),
    );

    final choice = response.data['choices'][0];
    final message = choice['message'];
    final finishReason = parseStopReason(choice['finish_reason'] as String?);

    if (message['tool_calls'] != null) {
      final toolCalls = (message['tool_calls'] as List)
          .map((tc) => ToolCall.fromJson(tc as Map<String, dynamic>))
          .toList();
      return AgentResponse.tools(toolCalls);
    }
    return AgentResponse.text(message['content'] as String? ?? '', reason: finishReason);
  }

  @override
  Stream<String> chatStream(
    List<Map<String, dynamic>> messages, {
    LLMConfig? config,
    List<Map<String, dynamic>>? tools,
  }) async* {
    final cfg = config ?? const LLMConfig(provider: 'openai', model: 'gpt-4o-mini');
    final baseUrl = _fixBaseUrl(cfg.baseUrl);
    final url = '$baseUrl/chat/completions';

    final body = <String, dynamic>{
      'model': cfg.model,
      'messages': messages,
      'temperature': cfg.temperature,
      'max_tokens': cfg.maxTokens,
      'stream': true,
    };

    // 深度思考（与 tools 互斥：reasoning 会挤占 max_tokens）
    if (cfg.enableDeepThink && (tools == null || tools.isEmpty)) {
      body['reasoning_effort'] = 'high';
    }

    // 合并 tools
    final allTools = <Map<String, dynamic>>[];
    if (cfg.enableWebSearch) {
      allTools.add({
        'type': 'web_search',
        'web_search': {},
      });
    }
    if (tools != null && tools.isNotEmpty) {
      allTools.addAll(tools.cast<Map<String, dynamic>>());
    }
    if (allTools.isNotEmpty) {
      body['tools'] = allTools;
    }

    final response = await _dio.post(
      url,
      data: jsonEncode(body),
      options: Options(
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer ${cfg.apiKey}',
        },
        responseType: ResponseType.stream,
      ),
    );

    final stream = response.data.stream as Stream<List<int>>;
    String buffer = '';

    await for (final chunk in stream) {
      buffer += utf8.decode(chunk);
      final lines = buffer.split('\n');
      buffer = lines.last;

      for (int i = 0; i < lines.length - 1; i++) {
        final line = lines[i].trim();
        if (line.startsWith('data: ')) {
          final jsonStr = line.substring(6);
          if (jsonStr == '[DONE]') return;
          try {
            final data = jsonDecode(jsonStr);
            final delta = data['choices']?[0]?['delta']?['content'];
            if (delta != null && delta is String && delta.isNotEmpty) {
              yield delta;
            }
          } catch (_) {}
        }
      }
    }
  }

  @override
  Future<bool> isAvailable(LLMConfig config) async {
    if (config.apiKey.isEmpty) return false;
    try {
      await chat(
        [{'role': 'user', 'content': 'hi'}],
        config: LLMConfig(
          provider: 'openai', model: config.model,
          apiKey: config.apiKey, baseUrl: config.baseUrl,
          maxTokens: 10,
        ),
      );
      return true;
    } catch (_) {
      return false;
    }
  }
}
