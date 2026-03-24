import 'dart:async';
import 'dart:convert';
import 'package:dio/dio.dart';
import '../../models/models.dart';
import '../agent/agent_types.dart';
import 'llm_provider.dart';

/// Claude (Anthropic) 大模型适配器
class ClaudeProvider implements LLMProvider {
  static const _defaultBaseUrl = 'https://api.anthropic.com';
  final Dio _dio = Dio();

  /// 规范化 baseUrl：去掉末尾斜杠，确保格式统一
  String _fixBaseUrl(String? baseUrl) {
    if (baseUrl == null || baseUrl.isEmpty) return _defaultBaseUrl;
    var url = baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl;
    return url;
  }

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
  Future<AgentResponse> chat(
    List<Map<String, dynamic>> messages, {
    LLMConfig? config,
    List<Map<String, dynamic>>? tools,
  }) async {
    final cfg = config ?? const LLMConfig(provider: 'claude', model: 'claude-sonnet-4-20250514');
    final baseUrl = _fixBaseUrl(cfg.baseUrl);
    final url = '$baseUrl/v1/messages';

    // Claude 需要把 system 消息单独提取，并转换消息格式
    String? systemMsg;
    final chatMessages = <Map<String, dynamic>>[];
    for (int i = 0; i < messages.length; i++) {
      final msg = messages[i];
      if (msg['role'] == 'system') {
        // 累积所有 system 消息
        final sysContent = msg['content'] as String? ?? '';
        systemMsg = systemMsg != null ? '$systemMsg\n\n$sysContent' : sysContent;
      } else if (msg['role'] == 'tool') {
        // OpenAI 格式的 role:tool → Claude 的 tool_result 格式
        // 需要关联到前一个 assistant 消息的 tool_use block
        final toolCallId = msg['tool_call_id'] as String? ?? '';
        final content = msg['content'] as String? ?? '';
        chatMessages.add({
          'role': 'user',
          'content': [
            {
              'type': 'tool_result',
              'tool_use_id': toolCallId,
              'content': content,
            }
          ],
        });
      } else if (msg['role'] == 'assistant') {
        // 转换 OpenAI 格式的 assistant 消息（含 tool_calls）为 Claude 格式
        final toolCalls = msg['tool_calls'] as List<dynamic>?;
        final textContent = msg['content'] as String?;

        if (toolCalls != null && toolCalls.isNotEmpty) {
          // 有 tool_calls → 转换为 Claude 的 tool_use blocks
          final blocks = <Map<String, dynamic>>[];
          if (textContent != null && textContent.isNotEmpty) {
            blocks.add({'type': 'text', 'text': textContent});
          }
          for (final tc in toolCalls) {
            final func = tc['function'] as Map<String, dynamic>?;
            if (func != null) {
              // 从 id 中提取 Claude 原始 id（如果有的话）
              String claudeId = tc['id'] as String? ?? '';
              if (claudeId.startsWith('claude_')) {
                claudeId = claudeId.substring(7);
              }
              blocks.add({
                'type': 'tool_use',
                'id': claudeId.isNotEmpty ? claudeId : 'toolu_${DateTime.now().microsecondsSinceEpoch}',
                'name': func['name'],
                'input': jsonDecode(func['arguments'] as String? ?? '{}'),
              });
            }
          }
          chatMessages.add({'role': 'assistant', 'content': blocks});
        } else {
          // 纯文本消息
          chatMessages.add({'role': 'assistant', 'content': textContent ?? ''});
        }
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
    final stopReason = parseStopReason(data['stop_reason'] as String?);

    // 检查 tool_use
    final toolUseBlocks = content.where((b) => b['type'] == 'tool_use').toList();
    if (toolUseBlocks.isNotEmpty) {
      final toolCalls = toolUseBlocks.map((block) {
        return ToolCall(
          id: 'claude_${block['id'] ?? DateTime.now().microsecondsSinceEpoch}',
          name: block['name'] as String? ?? '',
          arguments: (block['input'] as Map<String, dynamic>?) ?? {},
        );
      }).toList();
      return AgentResponse.tools(toolCalls);
    }

    // 文本内容
    final textBlocks = content.where((b) => b['type'] == 'text');
    return AgentResponse.text(
      textBlocks.map((b) => b['text']).join(''),
      reason: stopReason,
    );
  }

  @override
  Stream<String> chatStream(
    List<Map<String, dynamic>> messages, {
    LLMConfig? config,
    List<Map<String, dynamic>>? tools,
  }) async* {
    final cfg = config ?? const LLMConfig(provider: 'claude', model: 'claude-sonnet-4-20250514');
    final baseUrl = _fixBaseUrl(cfg.baseUrl);
    final url = '$baseUrl/v1/messages';

    String? systemMsg;
    final chatMessages = <Map<String, dynamic>>[];
    for (int i = 0; i < messages.length; i++) {
      final msg = messages[i];
      if (msg['role'] == 'system') {
        final sysContent = msg['content'] as String? ?? '';
        systemMsg = systemMsg != null ? '$systemMsg\n\n$sysContent' : sysContent;
      } else if (msg['role'] == 'tool') {
        final toolCallId = msg['tool_call_id'] as String? ?? '';
        final content = msg['content'] as String? ?? '';
        chatMessages.add({
          'role': 'user',
          'content': [
            {
              'type': 'tool_result',
              'tool_use_id': toolCallId,
              'content': content,
            }
          ],
        });
      } else if (msg['role'] == 'assistant') {
        final toolCalls = msg['tool_calls'] as List<dynamic>?;
        final textContent = msg['content'] as String?;
        if (toolCalls != null && toolCalls.isNotEmpty) {
          final blocks = <Map<String, dynamic>>[];
          if (textContent != null && textContent.isNotEmpty) {
            blocks.add({'type': 'text', 'text': textContent});
          }
          for (final tc in toolCalls) {
            final func = tc['function'] as Map<String, dynamic>?;
            if (func != null) {
              String claudeId = tc['id'] as String? ?? '';
              if (claudeId.startsWith('claude_')) {
                claudeId = claudeId.substring(7);
              }
              blocks.add({
                'type': 'tool_use',
                'id': claudeId.isNotEmpty ? claudeId : 'toolu_${DateTime.now().microsecondsSinceEpoch}',
                'name': func['name'],
                'input': jsonDecode(func['arguments'] as String? ?? '{}'),
              });
            }
          }
          chatMessages.add({'role': 'assistant', 'content': blocks});
        } else {
          chatMessages.add({'role': 'assistant', 'content': textContent ?? ''});
        }
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

    // 深度思考
    if (cfg.enableDeepThink) {
      body['thinking'] = {
        'type': 'enabled',
        'budget_tokens': 10000,
      };
      body['max_tokens'] = (cfg.maxTokens < 10000) ? 16000 : cfg.maxTokens;
    }

    // 合并 tools（联网搜索 + Function Calling），避免后者覆盖前者
    final allTools = <Map<String, dynamic>>[];
    if (cfg.enableWebSearch) {
      allTools.add({
        'type': 'web_search_20250305',
        'name': 'web_search',
        'max_uses': 5,
      });
    }
    if (tools != null && tools.isNotEmpty) {
      for (final t in tools) {
        final func = t['function'] as Map<String, dynamic>;
        allTools.add({
          'name': func['name'],
          'description': func['description'],
          'input_schema': func['parameters'],
        });
      }
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
