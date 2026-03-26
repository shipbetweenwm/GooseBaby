import 'dart:async';
import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import '../../models/models.dart';
import '../agent/agent_types.dart';
import 'llm_provider.dart';

/// 通义千问（Qwen）大模型适配器
/// 使用 OpenAI 兼容接口 (DashScope)
class QwenProvider extends LLMProvider {
  static const _defaultBaseUrl = 'https://dashscope.aliyuncs.com/compatible-mode/v1';
  final Dio _dio = Dio();

  /// 规范化 baseUrl：去掉末尾斜杠，确保格式统一
  String _fixBaseUrl(String? baseUrl) {
    if (baseUrl == null || baseUrl.isEmpty) return _defaultBaseUrl;
    var url = baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl;
    return url;
  }

  @override
  String get name => 'qwen';

  @override
  String get displayName => '通义千问';

  @override
  List<String> get supportedModels => [
    'qwen-turbo',
    'qwen-plus',
    'qwen-max',
    'qwen-max-longcontext',
    'qwen-long',
  ];

  /// 根据模型名返回最大输出 token 数
  /// 来源: https://help.aliyun.com/zh/model-studio/models
  static int _getMaxOutputTokens(String model) {
    final m = model.toLowerCase();
    // Qwen3.5 系列（最新，最高 65536）
    if (m.contains('qwen3.5') || m.contains('qwen3-5')) return 65536;
    // Qwen3 开源版大模型
    if (m.contains('qwen3-235b') || m.contains('qwen3-30b') || m.contains('qwen3-32b')) return 16384;
    if (m.contains('qwen3-coder')) return 65536;
    // Qwen3.5-Plus
    if (m.contains('plus') && (m.contains('2025-07') || m.contains('2025-08') || m.contains('2025-09'))) return 32768;
    // qwen-plus 较新版本
    if (m.contains('plus')) return 16384;
    // qwen-max 新版
    if (m.contains('max')) return 8192;
    // qwen-long
    if (m.contains('long')) return 32768;
    // qwen-turbo
    if (m.contains('turbo')) return 16384;
    // 默认保守值
    return 16384;
  }

  @override
  Future<AgentResponse> chat(
    List<Map<String, dynamic>> messages, {
    LLMConfig? config,
    List<Map<String, dynamic>>? tools,
  }) async {
    final cfg = config ?? const LLMConfig(provider: 'qwen', model: 'qwen-turbo');
    final modelMaxTokens = _getMaxOutputTokens(cfg.model);
    final maxTokens = cfg.maxTokens.clamp(1, modelMaxTokens);
    final baseUrl = _fixBaseUrl(cfg.baseUrl);
    final url = '$baseUrl/chat/completions';

    // ── 千问消息格式验证与修复 ──
    // 千问严格要求：assistant(tool_calls) 后必须紧跟对应的 tool 消息
    final validatedMessages = _validateAndFixMessages(messages);

    final body = <String, dynamic>{
      'model': cfg.model,
      'messages': validatedMessages,
      'temperature': cfg.temperature,
      'max_tokens': maxTokens,
      'stream': false,
    };

    // 联网搜索
    if (cfg.enableWebSearch) {
      body['enable_search'] = true;
    }

    // 深度思考（与 tools 互斥：思考会挤占 max_tokens 导致 tool_calls 无法生成）
    if (cfg.enableDeepThink && (tools == null || tools.isEmpty)) {
      body['enable_thinking'] = true;
    }

    if (tools != null && tools.isNotEmpty) {
      body['tools'] = tools;
    }

    try {
      final response = await _dio.post(
        url,
        data: jsonEncode(body),
        options: Options(
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer ${cfg.apiKey}',
          },
          validateStatus: (status) => status != null && status < 500,
        ),
      );

      if (response.statusCode != 200) {
        throw Exception('千问 API 错误 [${response.statusCode}]: ${response.data}');
      }

      final data = response.data;
      final choice = data['choices'][0];
      final message = choice['message'];
      final finishReason = parseStopReason(choice['finish_reason'] as String?);

      // 检查是否有 tool_calls
      if (message['tool_calls'] != null) {
        final toolCalls = (message['tool_calls'] as List)
            .map((tc) => ToolCall.fromJson(tc as Map<String, dynamic>))
            .toList();
        return AgentResponse.tools(toolCalls);
      }

      return AgentResponse.text(message['content'] as String? ?? '', reason: finishReason);
    } on DioException catch (e) {
      debugPrint('❌ 千问 DioException: ${e.response?.statusCode}, body: ${e.response?.data}');
      rethrow;
    }
  }

  @override
  Stream<String> chatStream(
    List<Map<String, dynamic>> messages, {
    LLMConfig? config,
    List<Map<String, dynamic>>? tools,
  }) async* {
    final cfg = config ?? const LLMConfig(provider: 'qwen', model: 'qwen-turbo');
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

    // 联网搜索
    if (cfg.enableWebSearch) {
      body['enable_search'] = true;
    }

    // 深度思考（与 tools 互斥：思考会挤占 max_tokens 导致 tool_calls 无法生成）
    if (cfg.enableDeepThink && (tools == null || tools.isEmpty)) {
      body['enable_thinking'] = true;
    }

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
          } catch (_) {
            // 跳过解析错误
          }
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
          provider: 'qwen',
          model: config.model,
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

  /// 验证并修复消息序列，确保符合千问 API 要求：
  /// 1. 每个带 tool_calls 的 assistant 消息后必须紧跟对应的 tool 消息
  /// 2. tool 消息的 tool_call_id 必须和前面 assistant 的 tool_calls id 匹配
  /// 3. 不能出现孤立的 tool_calls（没有 tool 响应）
  List<Map<String, dynamic>> _validateAndFixMessages(
      List<Map<String, dynamic>> messages) {
    final result = <Map<String, dynamic>>[];

    for (int i = 0; i < messages.length; i++) {
      final msg = Map<String, dynamic>.from(messages[i]);
      final role = msg['role'] as String?;

      if (role == 'assistant' && msg['tool_calls'] != null) {
        final toolCalls = msg['tool_calls'] as List<dynamic>;
        if (toolCalls.isEmpty) {
          // tool_calls 为空列表，移除它
          msg.remove('tool_calls');
          result.add(msg);
          continue;
        }

        // 收集这个 assistant 消息中所有的 tool_call_id
        final expectedIds = <String>{};
        for (final tc in toolCalls) {
          final id = (tc as Map<String, dynamic>)['id'] as String?;
          if (id != null) expectedIds.add(id);
        }

        // 检查后续消息是否有对应的 tool 响应
        final foundIds = <String>{};
        int j = i + 1;
        while (j < messages.length && messages[j]['role'] == 'tool') {
          final tcId = messages[j]['tool_call_id'] as String?;
          if (tcId != null) foundIds.add(tcId);
          j++;
        }

        // 检查是否所有 tool_call_id 都有对应响应
        final missingIds = expectedIds.difference(foundIds);
        if (missingIds.isNotEmpty) {
          debugPrint('⚠️ 千问消息修复: message[$i] 有 ${expectedIds.length} 个 tool_call，'
              '但缺少 ${missingIds.length} 个 tool 响应: $missingIds');

          if (foundIds.isEmpty) {
            // 完全没有 tool 响应 → 降级为普通 assistant 消息
            debugPrint('⚠️ → 降级为普通 assistant 消息（移除 tool_calls）');
            msg.remove('tool_calls');
            // 确保有 content
            if (msg['content'] == null) {
              msg['content'] = '';
            }
          } else {
            // 部分缺失 → 只保留有响应的 tool_calls
            debugPrint('⚠️ → 移除缺少响应的 tool_calls');
            final fixedToolCalls = toolCalls.where((tc) {
              final id = (tc as Map<String, dynamic>)['id'] as String?;
              return id != null && foundIds.contains(id);
            }).toList();
            msg['tool_calls'] = fixedToolCalls;
          }
        }

        result.add(msg);
      } else {
        result.add(msg);
      }
    }

    return result;
  }
}
