import 'dart:async';
import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import '../../models/models.dart';
import '../../utils/http_client.dart';
import '../../utils/type_utils.dart';
import '../agent/agent_types.dart';
import 'llm_provider.dart';

/// 智谱 ChatGLM 大模型适配器
/// 使用 OpenAI 兼容接口，直接用 API Key 认证
class ChatGLMProvider extends LLMProvider {
  static const _defaultBaseUrl = 'https://open.bigmodel.cn/api/paas/v4';
  final Dio _dio = createRetryDio(receiveTimeout: const Duration(seconds: 120));

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
    'glm-5',
    'glm-5-turbo',
    'glm-4-plus',
    'glm-4-0520',
    'glm-4',
    'glm-4-air',
    'glm-4-airx',
    'glm-4-long',
    'glm-4-flashx',
    'glm-4-flash',
    'glm-3-turbo',
  ];

  /// 根据模型名返回最大输出 token 数
  /// 来源: https://docs.bigmodel.cn/cn/guide/models/text
  static int _getMaxOutputTokens(String model) {
    final m = model.toLowerCase();
    // GLM-5 系列：最大输出 128K
    if (m.startsWith('glm-5')) return 131072;
    // GLM-4-Plus / GLM-4-0520：8K
    if (m.contains('glm-4-plus') || m.contains('glm-4-0520')) return 8192;
    // GLM-4-Long：支持超长上下文，输出 4K
    if (m.contains('glm-4-long')) return 4096;
    // GLM-4-AirX / GLM-4-Air / GLM-4-FlashX / GLM-4-Flash
    if (m.contains('glm-4')) return 4096;
    // GLM-3-Turbo
    if (m.contains('glm-3-turbo')) return 4096;
    return 4096;
  }

  @override
  Future<AgentResponse> chat(
    List<Map<String, dynamic>> messages, {
    LLMConfig? config,
    List<Map<String, dynamic>>? tools,
    CancelToken? cancelToken,
  }) async {
    final cfg = config ?? const LLMConfig(provider: 'chatglm', model: 'glm-4-flash');
    final modelMaxTokens = _getMaxOutputTokens(cfg.model);
    final maxTokens = cfg.maxTokens.clamp(1, modelMaxTokens);
    final baseUrl = _fixBaseUrl(cfg.baseUrl);
    final url = '$baseUrl/chat/completions';

    // ── 消息格式清理 ──
    // ChatGLM 对消息格式有严格要求：
    // 1. assistant 带 tool_calls 时 content 可为 null，但某些模型不接受
    // 2. 必须确保 assistant(tool_calls) → tool 响应的配对
    // 3. 不支持 image_url 类型的多模态消息（纯文本模型）
    final cleanedMessages = _cleanMessages(messages);
    debugPrint('🤖 [ChatGLM] 发送 ${cleanedMessages.length} 条消息 (原始 ${messages.length}), model=${cfg.model}');

    final body = <String, dynamic>{
      'model': cfg.model,
      'messages': cleanedMessages,
      'temperature': cfg.temperature,
      'max_tokens': maxTokens,
    };

    // 合并 tools（联网搜索 + Function Calling）
    // 智谱 GLM-4 通过 tools 注入 web_search 工具实现联网
    final allTools = <Map<String, dynamic>>[];
    if (cfg.enableWebSearch) {
      allTools.add({
        'type': 'web_search',
        'web_search': {'enable': true},
      });
    }
    if (tools != null && tools.isNotEmpty) {
      allTools.addAll(tools.cast<Map<String, dynamic>>());
    }
    if (allTools.isNotEmpty) {
      body['tools'] = allTools;
    }

    // 深度思考（仅 GLM-5 系列支持，与 tools 互斥）
    if (cfg.enableDeepThink &&
        cfg.model.toLowerCase().startsWith('glm-5') &&
        (tools == null || tools.isEmpty)) {
      body['thinking'] = {'type': 'enabled'};
    }

    debugPrint('🤖 [ChatGLM] 请求体大小: ${jsonEncode(body).length} 字符, tools=${allTools.length}');

    final response = await _dio.post(
      url,
      data: jsonEncode(body),
      cancelToken: cancelToken,
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
        final rawToolCalls = message['tool_calls'] as List;
        // 过滤掉非 function 类型的 tool_calls（如 web_search 类型），
        // 这些由模型内部处理，客户端不需要执行
        final toolCalls = rawToolCalls
            .where((tc) {
              final type = safeMap(tc)['type'] as String?;
              // null 或 'function' 类型保留，其他类型（如 'web_search'）跳过
              return type == null || type == 'function';
            })
            .map((tc) => ToolCall.fromJson(safeMap(tc)))
            .where((tc) => tc.name.isNotEmpty) // 过滤掉解析失败的空名调用
            .toList();

        if (toolCalls.isNotEmpty) {
          debugPrint('🤖 [ChatGLM] 返回 ${toolCalls.length} 个 tool_calls, finish=$finishReason');
          return AgentResponse.tools(toolCalls);
        }

        // 只有 web_search 类型的 tool_calls → 当作纯文本响应处理
        debugPrint('🤖 [ChatGLM] 返回的 tool_calls 全部为内置工具（如 web_search），当作纯文本处理');
        return AgentResponse.text(message['content'] as String? ?? '', reason: finishReason);
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

    final cleanedMessages = _cleanMessages(messages);

    final body = <String, dynamic>{
      'model': cfg.model,
      'messages': cleanedMessages,
      'temperature': cfg.temperature,
      'max_tokens': maxTokens,
      'stream': true,
    };

    // 合并 tools（联网搜索 + Function Calling）
    final allTools = <Map<String, dynamic>>[];
    if (cfg.enableWebSearch) {
      allTools.add({
        'type': 'web_search',
        'web_search': {'enable': true},
      });
    }
    if (tools != null && tools.isNotEmpty) {
      allTools.addAll(tools.cast<Map<String, dynamic>>());
    }
    if (allTools.isNotEmpty) {
      body['tools'] = allTools;
    }

    // 深度思考（仅 GLM-5 系列支持，与 tools 互斥）
    if (cfg.enableDeepThink &&
        cfg.model.toLowerCase().startsWith('glm-5') &&
        (tools == null || tools.isEmpty)) {
      body['thinking'] = {'type': 'enabled'};
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

  @override
  Future<String> chatWithVision({
    required String base64Image,
    required String mimeType,
    required String prompt,
    required LLMConfig config,
  }) async {
    final baseUrl = _fixBaseUrl(config.baseUrl);
    final url = '$baseUrl/chat/completions';

    // GLM-4V 系列使用 OpenAI 兼容的多模态消息格式
    final messages = [
      {
        'role': 'user',
        'content': [
          {'type': 'text', 'text': prompt},
          {
            'type': 'image_url',
            'image_url': {
              'url': 'data:$mimeType;base64,$base64Image',
            },
          },
        ],
      },
    ];

    final body = <String, dynamic>{
      'model': config.model,
      'messages': messages,
      'max_tokens': 2048,
      'temperature': 0.3,
    };

    try {
      final response = await _dio.post(
        url,
        data: jsonEncode(body),
        options: Options(
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer ${config.apiKey}',
          },
          validateStatus: (status) => status != null && status < 500,
        ),
      );

      if (response.statusCode != 200) {
        throw Exception('GLM 视觉模型 API 错误 [${response.statusCode}]: ${response.data}');
      }

      final data = response.data;
      if (data['error'] != null) {
        throw Exception('GLM 视觉模型错误: ${data['error']['message']}');
      }

      return data['choices'][0]['message']['content'] as String? ?? '';
    } on DioException catch (e) {
      debugPrint('❌ GLM 视觉模型 DioException: ${e.response?.statusCode}, body: ${e.response?.data}');
      rethrow;
    }
  }

  /// 清理消息格式，确保符合 ChatGLM API 要求
  /// 1. assistant 带 tool_calls 时 content 为 null → 设为空字符串
  /// 2. 移除孤立消息（没有匹配的 tool 响应的 tool_calls）
  /// 3. 移除 content 中包含 image_url 的多模态消息（纯文本模型不支持）
  List<Map<String, dynamic>> _cleanMessages(List<Map<String, dynamic>> messages) {
    final result = <Map<String, dynamic>>[];
    final pendingToolIds = <String>[];

    for (final msg in messages) {
      final role = msg['role'] as String?;
      if (role == null) continue;

      final cleaned = Map<String, dynamic>.from(msg);

      if (role == 'assistant') {
        final toolCalls = cleaned['tool_calls'] as List<dynamic>?;
        if (toolCalls != null && toolCalls.isNotEmpty) {
          // 记录预期需要响应的 tool_call_id
          pendingToolIds.clear();
          for (final tc in toolCalls) {
            final id = safeMap(tc)['id'] as String?;
            if (id != null) pendingToolIds.add(id);
          }
          // assistant(tool_calls) 的 content 为 null 时改为空字符串
          if (cleaned['content'] == null) {
            cleaned['content'] = '';
          }
        } else {
          // 普通 assistant 消息，清除可能残留的空 tool_calls
          cleaned.remove('tool_calls');
        }
      } else if (role == 'tool') {
        final toolId = cleaned['tool_call_id'] as String?;
        if (toolId != null) {
          pendingToolIds.remove(toolId);
        } else {
          // 没有 tool_call_id 的 tool 消息 → 跳过
          debugPrint('⚠️ [ChatGLM] 跳过没有 tool_call_id 的 tool 消息');
          continue;
        }
      } else if (role == 'user') {
        // 检查是否包含多模态内容（image_url 类型）
        final content = cleaned['content'];
        if (content is List) {
          // 多模态消息 → 只保留文本部分
          final textParts = content
              .where((part) => safeMap(part)['type'] == 'text')
              .map((part) => safeMap(part)['text'] as String? ?? '')
              .join('\n');
          cleaned['content'] = textParts.isNotEmpty ? textParts : '（图片内容）';
          debugPrint('⚠️ [ChatGLM] 多模态消息已降级为纯文本（ChatGLM 纯文本模型不支持图片）');
        }
      }

      result.add(cleaned);
    }

    // 清理尾部可能残留的 assistant(tool_calls)（没有对应的 tool 响应）
    while (result.isNotEmpty) {
      final last = result.last;
      final role = last['role'] as String?;
      final tc = last['tool_calls'] as List<dynamic>?;
      if (role == 'assistant' && tc != null && tc.isNotEmpty) {
        debugPrint('⚠️ [ChatGLM] 移除尾部孤立的 assistant(tool_calls) 消息');
        result.removeLast();
      } else {
        break;
      }
    }

    return result;
  }
}
