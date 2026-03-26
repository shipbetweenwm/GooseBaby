import 'dart:async';
import 'dart:convert';
import 'package:dio/dio.dart';
import '../../models/models.dart';
import '../../utils/type_utils.dart';
import '../agent/agent_types.dart';
import 'llm_provider.dart';

/// OpenAI GPT 大模型适配器
class OpenAIProvider extends LLMProvider {
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
          .map((tc) => ToolCall.fromJson(safeMap(tc)))
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
  Stream<StreamEvent> chatStreamWithTools(
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

    // 深度思考模型支持
    if (cfg.enableDeepThink && (tools == null || tools.isEmpty)) {
      body['reasoning_effort'] = 'high';
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

    // 用于追踪工具调用
    final toolCallBuilders = <int, _ToolCallBuilder>{};

    await for (final chunk in stream) {
      buffer += utf8.decode(chunk);
      final lines = buffer.split('\n');
      buffer = lines.last;

      for (int i = 0; i < lines.length - 1; i++) {
        final line = lines[i].trim();
        if (line.isEmpty) continue;
        
        if (line.startsWith('data: ')) {
          final jsonStr = line.substring(6);
          if (jsonStr == '[DONE]') {
            // 发送工具调用完成事件
            for (final entry in toolCallBuilders.entries) {
              final builder = entry.value;
              yield ToolCallCompleteEvent(
                index: entry.key,
                toolName: builder.name,
                toolCallId: builder.id,
                arguments: builder.args.toString(),
              );
            }
            yield const StreamEndEvent();
            return;
          }
          
          try {
            final data = jsonDecode(jsonStr);
            final choice = data['choices']?[0];
            if (choice == null) continue;
            
            final delta = choice['delta'] is Map ? safeMap(choice['delta']) : null;
            final finishReason = choice['finish_reason'] as String?;
            
            // 处理文本增量
            if (delta?['content'] != null) {
              final content = delta!['content'] as String;
              if (content.isNotEmpty) {
                yield TextDeltaEvent(content);
              }
            }
            
            // 处理思考内容增量（o1 等推理模型）
            if (delta?['reasoning_content'] != null) {
              final reasoning = delta!['reasoning_content'] as String;
              if (reasoning.isNotEmpty) {
                yield ThinkingDeltaEvent(reasoning);
              }
            }
            
            // 处理工具调用增量
            if (delta?['tool_calls'] != null) {
              final toolCalls = delta!['tool_calls'] as List;
              
              for (final tc in toolCalls) {
                if (tc is! Map<String, dynamic>) continue;
                
                final index = tc['index'] as int? ?? 0;
                final func = tc['function'] is Map ? safeMap(tc['function']) : null;
                
                // 工具调用开始
                if (tc['id'] != null) {
                  toolCallBuilders[index] = _ToolCallBuilder(
                    id: tc['id'] as String,
                    name: func?['name'] as String? ?? '',
                  );
                  
                  if (func?['name'] != null) {
                    yield ToolCallStartEvent(
                      index: index,
                      toolName: func!['name'] as String,
                      toolCallId: tc['id'] as String,
                    );
                  }
                }
                
                // 工具调用参数增量
                if (func?['arguments'] != null) {
                  final args = func!['arguments'] as String;
                  if (args.isNotEmpty) {
                    toolCallBuilders[index]?.args.write(args);
                    yield ToolCallDeltaEvent(index: index, argsDelta: args);
                  }
                }
              }
            }
            
            // 流结束
            if (finishReason != null) {
              // 发送工具调用完成事件
              for (final entry in toolCallBuilders.entries) {
                final builder = entry.value;
                yield ToolCallCompleteEvent(
                  index: entry.key,
                  toolName: builder.name,
                  toolCallId: builder.id,
                  arguments: builder.args.toString(),
                );
              }
              
              yield StreamEndEvent(finishReason: finishReason);
              return;
            }
          } catch (e) {
            yield StreamErrorEvent(message: e.toString());
          }
        }
      }
    }
    
    // 如果流正常结束但没有收到 [DONE]
    for (final entry in toolCallBuilders.entries) {
      final builder = entry.value;
      yield ToolCallCompleteEvent(
        index: entry.key,
        toolName: builder.name,
        toolCallId: builder.id,
        arguments: builder.args.toString(),
      );
    }
    yield const StreamEndEvent();
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
  
  @override
  int countTokens(String text) {
    // OpenAI 模型使用 tiktoken，这里用简化估算
    // 英文约 4 字符 = 1 token，中文约 1.5 字符 = 1 token
    int count = 0;
    for (int i = 0; i < text.length; i++) {
      final code = text.codeUnitAt(i);
      // 中文字符范围
      if (code >= 0x4e00 && code <= 0x9fff) {
        count += 1;
      } else {
        count += 1;
      }
    }
    return (count / 4).ceil();
  }
}

/// 工具调用构建器
class _ToolCallBuilder {
  final String id;
  final String name;
  final StringBuffer args = StringBuffer();
  
  _ToolCallBuilder({required this.id, required this.name});
}
