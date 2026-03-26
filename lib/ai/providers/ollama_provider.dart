import 'dart:async';
import 'dart:convert';
import 'package:dio/dio.dart';
import '../../models/models.dart';
import '../agent/agent_types.dart';
import 'llm_provider.dart';

/// Ollama 本地大模型适配器
/// 支持运行本地千问、Llama 等开源模型
class OllamaProvider extends LLMProvider {
  static const _defaultBaseUrl = 'http://localhost:11434';
  final Dio _dio = Dio();

  /// 规范化 baseUrl：去掉末尾斜杠，确保格式统一
  String _fixBaseUrl(String? baseUrl) {
    if (baseUrl == null || baseUrl.isEmpty) return _defaultBaseUrl;
    var url = baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl;
    return url;
  }

  @override
  String get name => 'ollama';

  @override
  String get displayName => 'Ollama (本地)';

  @override
  List<String> get supportedModels => [
    'qwen2.5:7b',
    'qwen2.5:14b',
    'llama3.1:8b',
    'llama3.1:70b',
    'gemma2:9b',
    'mistral:7b',
    'phi3:mini',
  ];

  @override
  Future<AgentResponse> chat(
    List<Map<String, dynamic>> messages, {
    LLMConfig? config,
    List<Map<String, dynamic>>? tools,
  }) async {
    final cfg = config ?? const LLMConfig(provider: 'ollama', model: 'qwen2.5:7b');
    final baseUrl = _fixBaseUrl(cfg.baseUrl);
    // 使用 OpenAI 兼容接口
    final url = '$baseUrl/v1/chat/completions';

    final body = <String, dynamic>{
      'model': cfg.model,
      'messages': messages,
      'temperature': cfg.temperature,
      'stream': false,
    };

    if (tools != null && tools.isNotEmpty) {
      body['tools'] = tools;
    }

    final response = await _dio.post(
      url,
      data: jsonEncode(body),
      options: Options(
        headers: {'Content-Type': 'application/json'},
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
    final cfg = config ?? const LLMConfig(provider: 'ollama', model: 'qwen2.5:7b');
    final baseUrl = _fixBaseUrl(cfg.baseUrl);
    final url = '$baseUrl/v1/chat/completions';

    final body = <String, dynamic>{
      'model': cfg.model,
      'messages': messages,
      'temperature': cfg.temperature,
      'max_tokens': cfg.maxTokens,
      'stream': true,
    };

    // 联网搜索
    if (cfg.enableWebSearch) {
      body['tools'] = [
        {'type': 'web_search'},
        if (tools != null)
          ...tools,
      ];
    } else if (tools != null && tools.isNotEmpty) {
      body['tools'] = tools;
    }

    final response = await _dio.post(
      url,
      data: jsonEncode(body),
      options: Options(
        headers: {'Content-Type': 'application/json'},
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
    try {
      final url = '${_fixBaseUrl(config.baseUrl)}/api/tags';
      final response = await _dio.get(url);
      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }
}
