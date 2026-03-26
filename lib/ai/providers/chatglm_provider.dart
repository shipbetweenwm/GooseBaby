import 'dart:async';
import 'dart:convert';
import 'package:dio/dio.dart';
import '../../models/models.dart';
import '../../utils/type_utils.dart';
import '../agent/agent_types.dart';
import 'llm_provider.dart';

/// 智谱 ChatGLM 大模型适配器
/// 使用 OpenAI 兼容接口，直接用 API Key 认证
class ChatGLMProvider extends LLMProvider {
  static const _defaultBaseUrl = 'https://open.bigmodel.cn/api/paas/v4';
  final Dio _dio = Dio();

  String _fixBaseUrl(String? baseUrl) {
    if (baseUrl == null || baseUrl.isEmpty) return _defaultBaseUrl;
    return baseUrl.endsWith('/')
        ? baseUrl.substring(0, baseUrl.length - 1)
        : baseUrl;
  }

  @override
  String get name => 'chatglm';

  @override
  String get displayName => '智谱ChatGLM';

  @override
  List<String> get supportedModels => [
    'glm-4-plus',
    'glm-4-0520',
    'glm-4',
    'glm-4-air',
    'glm-4-airx',
    'glm-4-long',
    'glm-4-flashx',
    'glm-4-flash',
    'glm-3-turbo',
    'glm-5',
    'glm-5.0-turbo',
  ];

  /// 根据模型名返回最大输出 token 数
  static int _getMaxOutputTokens(String model) {
    final m = model.toLowerCase();
    if (m.contains('glm-4-plus')) return 4096;
    if (m.contains('glm-4-0520')) return 4096;
    if (m.contains('glm-4-airx')) return 4096;
    if (m.contains('glm-4-air')) return 4096;
    if (m.contains('glm-4-flashx')) return 4096;
    if (m.contains('glm-4-flash')) return 4096;
    if (m.contains('glm-4-long')) return 4096;
    if (m.contains('glm-4')) return 4096;
    if (m.contains('glm-3-turbo')) return 4096;
    return 4096;
  }

  @override
  Future<AgentResponse> chat(
    List<Map<String, dynamic>> messages, {
    LLMConfig? config,
    List<Map<String, dynamic>>? tools,
  }) async {
    final cfg = config ?? const LLMConfig(provider: 'chatglm', model: 'glm-4-flash');
    final modelMaxTokens = _getMaxOutputTokens(cfg.model);
    final maxTokens = cfg.maxTokens.clamp(1, modelMaxTokens);
    final baseUrl = _fixBaseUrl(cfg.baseUrl);
    final url = '$baseUrl/chat/completions';

    final body = <String, dynamic>{
      'model': cfg.model,
      'messages': messages,
      'temperature': cfg.temperature,
      'max_tokens': maxTokens,
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

    final data = response.data;

    if (data['error'] != null) {
      throw Exception('ChatGLM API 错误: ${data['error']['message']}');
    }

    final choices = data['choices'];
    if (choices != null && choices.isNotEmpty) {
      final message = choices[0]['message'];
      final finishReason = parseStopReason(choices[0]['finish_reason'] as String?);
      if (message['tool_calls'] != null) {
        final toolCalls = (message['tool_calls'] as List)
            .map((tc) => ToolCall.fromJson(safeMap(tc)))
            .toList();
        return AgentResponse.tools(toolCalls);
      }
      return AgentResponse.text(message['content'] as String? ?? '', reason: finishReason);
    }

    throw Exception('ChatGLM API 返回数据异常');
  }

  @override
  Stream<String> chatStream(
    List<Map<String, dynamic>> messages, {
    LLMConfig? config,
    List<Map<String, dynamic>>? tools,
  }) async* {
    final cfg = config ?? const LLMConfig(provider: 'chatglm', model: 'glm-4-flash');
    final modelMaxTokens = _getMaxOutputTokens(cfg.model);
    final maxTokens = cfg.maxTokens.clamp(1, modelMaxTokens);
    final baseUrl = _fixBaseUrl(cfg.baseUrl);
    final url = '$baseUrl/chat/completions';

    final body = <String, dynamic>{
      'model': cfg.model,
      'messages': messages,
      'temperature': cfg.temperature,
      'max_tokens': maxTokens,
      'stream': true,
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
          provider: 'chatglm',
          model: 'glm-4-flash',
          apiKey: config.apiKey,
          baseUrl: config.baseUrl,
          maxTokens: 10,
        ),
      );
      return true;
    } catch (_) {
      return false;
    }
  }
}
