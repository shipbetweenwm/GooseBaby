import 'dart:async';
import 'dart:convert';
import 'package:dio/dio.dart';
import '../../models/models.dart';
import 'llm_provider.dart';

/// Claude (Anthropic) 大模型适配器
class ClaudeProvider implements LLMProvider {
  final Dio _dio = Dio();

  @override
  String get name => 'claude';

  @override
  String get displayName => 'Claude';

  @override
  List<String> get supportedModels => [
    'claude-sonnet-4-20250514',
    'claude-3-5-sonnet-20241022',
    'claude-3-5-haiku-20241022',
    'claude-3-opus-20240229',
  ];

  @override
  Future<String> chat(
    List<Map<String, dynamic>> messages, {
    LLMConfig? config,
    List<Map<String, dynamic>>? tools,
  }) async {
    final cfg = config ?? const LLMConfig(provider: 'claude', model: 'claude-sonnet-4-20250514');
    final url = '${cfg.baseUrl ?? "https://api.anthropic.com"}/v1/messages';

    // Claude 需要把 system 消息单独提取
    String? systemMsg;
    final chatMessages = <Map<String, dynamic>>[];
    for (final msg in messages) {
      if (msg['role'] == 'system') {
        systemMsg = msg['content'] as String;
      } else {
        chatMessages.add(msg);
      }
    }

    final body = <String, dynamic>{
      'model': cfg.model,
      'messages': chatMessages,
      'max_tokens': cfg.maxTokens,
      'temperature': cfg.temperature,
    };

    if (systemMsg != null) {
      body['system'] = systemMsg;
    }

    if (tools != null && tools.isNotEmpty) {
      body['tools'] = tools.map((t) {
        final func = t['function'] as Map<String, dynamic>;
        return {
          'name': func['name'],
          'description': func['description'],
          'input_schema': func['parameters'],
        };
      }).toList();
    }

    final response = await _dio.post(
      url,
      data: jsonEncode(body),
      options: Options(
        headers: {
          'Content-Type': 'application/json',
          'x-api-key': cfg.apiKey,
          'anthropic-version': '2023-06-01',
        },
      ),
    );

    final data = response.data;
    final content = data['content'] as List;

    // 检查 tool_use
    for (final block in content) {
      if (block['type'] == 'tool_use') {
        return jsonEncode({
          'tool_calls': [
            {
              'function': {
                'name': block['name'],
                'arguments': jsonEncode(block['input']),
              },
            }
          ],
          'content': '',
        });
      }
    }

    // 文本内容
    final textBlocks = content.where((b) => b['type'] == 'text');
    return textBlocks.map((b) => b['text']).join('');
  }

  @override
  Stream<String> chatStream(
    List<Map<String, dynamic>> messages, {
    LLMConfig? config,
    List<Map<String, dynamic>>? tools,
  }) async* {
    final cfg = config ?? const LLMConfig(provider: 'claude', model: 'claude-sonnet-4-20250514');
    final url = '${cfg.baseUrl ?? "https://api.anthropic.com"}/v1/messages';

    String? systemMsg;
    final chatMessages = <Map<String, dynamic>>[];
    for (final msg in messages) {
      if (msg['role'] == 'system') {
        systemMsg = msg['content'] as String;
      } else {
        chatMessages.add(msg);
      }
    }

    final body = <String, dynamic>{
      'model': cfg.model,
      'messages': chatMessages,
      'max_tokens': cfg.maxTokens,
      'temperature': cfg.temperature,
      'stream': true,
    };

    if (systemMsg != null) body['system'] = systemMsg;

    final response = await _dio.post(
      url,
      data: jsonEncode(body),
      options: Options(
        headers: {
          'Content-Type': 'application/json',
          'x-api-key': cfg.apiKey,
          'anthropic-version': '2023-06-01',
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
          try {
            final data = jsonDecode(jsonStr);
            if (data['type'] == 'content_block_delta') {
              final text = data['delta']?['text'];
              if (text != null && text is String && text.isNotEmpty) {
                yield text;
              }
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
          provider: 'claude', model: config.model,
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
