import 'dart:async';
import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import '../../models/models.dart';
import '../../utils/http_client.dart';
import '../../utils/type_utils.dart';
import '../agent/agent_types.dart';
import 'llm_provider.dart';

/// 腾讯混元大模型适配器
/// 使用 OpenAI 兼容接口（更简单、更稳定）
class HunyuanProvider extends LLMProvider {
  static const _defaultBaseUrl = 'https://api.hunyuan.cloud.tencent.com/v1';
  final Dio _dio = createRetryDio(receiveTimeout: const Duration(seconds: 120));

  /// 修正旧版URL或无效URL，确保使用新的OpenAI兼容端点
  String _fixBaseUrl(String? baseUrl) {
    if (baseUrl == null || baseUrl.isEmpty) return _defaultBaseUrl;
    // 旧版腾讯云API地址，自动替换为新的OpenAI兼容端点
    if (baseUrl.contains('hunyuan.tencentcloudapi.com')) {
      return _defaultBaseUrl;
    }
    // 去掉末尾斜杠
    return baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl;
  }

  @override
  String get name => 'hunyuan';

  @override
  String get displayName => '腾讯混元';

  @override
  List<String> get supportedModels => [
    'hunyuan-lite',
    'hunyuan-standard',
    'hunyuan-standard-256K',
    'hunyuan-pro',
    'hunyuan-turbo',
    'hunyuan-turbo-latest',
    'hunyuan-turbos-latest',
    'hunyuan-large',
  ];

  /// 根据模型名返回最大输出 token 数
  /// 来源: 腾讯云混元官方文档
  static int _getMaxOutputTokens(String model) {
    final m = model.toLowerCase();
    // hunyuan-t1 旗舰推理模型（32K 输出）
    if (m.contains('hunyuan-t1') || (m.contains('t1') && !m.contains('vision'))) return 32768;
    // hunyuan-a13b MoE 均衡模型（16K 输出）
    if (m.contains('a13b')) return 16384;
    // hunyuan-large（32K 输出）
    if (m.contains('large')) return 32768;
    // hunyuan-turbos 快速思考（16K 输出）
    if (m.contains('turbos')) return 16384;
    // hunyuan-turbo（16K 输出）
    if (m.contains('turbo')) return 16384;
    // hunyuan-standard-256k（16K 输出，但支持超长上下文输入）
    if (m.contains('standard')) return 16384;
    // hunyuan-lite 轻量版（4K 输出）
    return 4096;
  }

  @override
  Future<AgentResponse> chat(
    List<Map<String, dynamic>> messages, {
    LLMConfig? config,
    List<Map<String, dynamic>>? tools,
    CancelToken? cancelToken,
  }) async {
    final cfg = config ?? const LLMConfig(provider: 'hunyuan', model: 'hunyuan-turbo');
    final modelMaxTokens = _getMaxOutputTokens(cfg.model);
    final maxTokens = cfg.maxTokens.clamp(1, modelMaxTokens);
    final baseUrl = _fixBaseUrl(cfg.baseUrl);
    final url = '$baseUrl/chat/completions';

    final body = <String, dynamic>{
      'model': cfg.model,
      'messages': messages,
      'temperature': cfg.temperature,
      'max_tokens': maxTokens,
      'stream': false,
    };

    // 联网搜索（混元 OpenAI 兼容接口通过 tools 传入）
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
      throw Exception('混元 API 错误: ${data['error']['message']}');
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

    throw Exception('混元 API 返回数据异常');
  }

  @override
  Stream<String> chatStream(
    List<Map<String, dynamic>> messages, {
    LLMConfig? config,
    List<Map<String, dynamic>>? tools,
  }) async* {
    final cfg = config ?? const LLMConfig(provider: 'hunyuan', model: 'hunyuan-turbo');
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

    // 联网搜索（混元 OpenAI 兼容接口通过 tools 传入）
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

    final response = await _dio.post(
      url,
      data: body,
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
  Future<String> chatWithVision({
    required String base64Image,
    required String mimeType,
    required String prompt,
    required LLMConfig config,
  }) async {
    final baseUrl = _fixBaseUrl(config.baseUrl);
    final url = '$baseUrl/chat/completions';

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
        throw Exception('混元视觉模型 API 错误 [${response.statusCode}]: ${response.data}');
      }

      final data = response.data;
      if (data['error'] != null) {
        throw Exception('混元视觉模型错误: ${data['error']['message']}');
      }

      return data['choices'][0]['message']['content'] as String? ?? '';
    } on DioException catch (e) {
      debugPrint('❌ 混元视觉模型 DioException: ${e.response?.statusCode}, body: ${e.response?.data}');
      rethrow;
    }
  }

  @override
  Future<bool> isAvailable(LLMConfig config) async {
    if (config.apiKey.isEmpty) return false;
    try {
      await chat(
        [{'role': 'user', 'content': 'hi'}],
        config: LLMConfig(
          provider: 'hunyuan',
          model: 'hunyuan-lite',
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

