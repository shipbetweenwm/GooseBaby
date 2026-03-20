import 'dart:async';
import 'dart:convert';
import 'package:dio/dio.dart';
import '../../models/models.dart';
import 'llm_provider.dart';

/// Ollama 本地大模型适配器
/// 支持运行本地千问、Llama 等开源模型
class OllamaProvider implements LLMProvider {
  final Dio _dio = Dio();

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

  String _getBaseUrl(LLMConfig? config) {
    return config?.baseUrl ?? 'http://localhost:11434';
  }

  @override
  Future<String> chat(
    List<Map<String, dynamic>> messages, {
    LLMConfig? config,
    List<Map<String, dynamic>>? tools,
  }) async {
    final cfg = config ?? const LLMConfig(provider: 'ollama', model: 'qwen2.5:7b');
    // 使用 OpenAI 兼容接口
    final url = '${_getBaseUrl(cfg)}/v1/chat/completions';

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
    if (choice['message']['tool_calls'] != null) {
      return jsonEncode(choice['message']);
    }
    return choice['message']['content'] as String;
  }

  @override
  Stream<String> chatStream(
    List<Map<String, dynamic>> messages, {
    LLMConfig? config,
    List<Map<String, dynamic>>? tools,
  }) async* {
    final cfg = config ?? const LLMConfig(provider: 'ollama', model: 'qwen2.5:7b');
    final url = '${_getBaseUrl(cfg)}/v1/chat/completions';

    final body = <String, dynamic>{
      'model': cfg.model,
      'messages': messages,
      'temperature': cfg.temperature,
      'stream': true,
    };

    if (tools != null && tools.isNotEmpty) {
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
      final url = '${_getBaseUrl(config)}/api/tags';
      final response = await _dio.get(url);
      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }
}
