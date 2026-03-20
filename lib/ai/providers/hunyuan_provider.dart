import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import '../../models/models.dart';
import 'llm_provider.dart';

/// 腾讯混元大模型适配器
/// 使用腾讯云 API 签名认证
class HunyuanProvider implements LLMProvider {
  final Dio _dio = Dio();

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
    'hunyuan-large',
  ];

  /// 生成腾讯云 API v3 签名
  Map<String, String> _generateSignature(
    String secretId,
    String secretKey,
    String payload,
  ) {
    final now = DateTime.now().toUtc();
    final timestamp = (now.millisecondsSinceEpoch ~/ 1000).toString();
    final dateStr = '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';

    const service = 'hunyuan';
    const host = 'hunyuan.tencentcloudapi.com';
    const action = 'ChatCompletions';
    const version = '2023-09-01';
    const algorithm = 'TC3-HMAC-SHA256';

    // Step 1: 拼接规范请求串
    final hashedPayload = sha256.convert(utf8.encode(payload)).toString();
    final canonicalRequest = [
      'POST',
      '/',
      '',
      'content-type:application/json',
      'host:$host',
      '',
      'content-type;host',
      hashedPayload,
    ].join('\n');

    // Step 2: 拼接待签名字符串
    final credentialScope = '$dateStr/$service/tc3_request';
    final hashedCanonicalRequest = sha256.convert(utf8.encode(canonicalRequest)).toString();
    final stringToSign = [
      algorithm,
      timestamp,
      credentialScope,
      hashedCanonicalRequest,
    ].join('\n');

    // Step 3: 计算签名
    List<int> _hmacSha256(List<int> key, String msg) {
      final hmac = Hmac(sha256, key);
      return hmac.convert(utf8.encode(msg)).bytes;
    }

    final secretDate = _hmacSha256(utf8.encode('TC3$secretKey'), dateStr);
    final secretService = _hmacSha256(secretDate, service);
    final secretSigning = _hmacSha256(secretService, 'tc3_request');
    final signatureHmac = Hmac(sha256, secretSigning);
    final signature = signatureHmac.convert(utf8.encode(stringToSign)).toString();

    // Step 4: 拼接 Authorization
    final authorization = '$algorithm Credential=$secretId/$credentialScope, '
        'SignedHeaders=content-type;host, Signature=$signature';

    return {
      'Content-Type': 'application/json',
      'Host': host,
      'X-TC-Action': action,
      'X-TC-Version': version,
      'X-TC-Timestamp': timestamp,
      'Authorization': authorization,
    };
  }

  @override
  Future<String> chat(
    List<Map<String, dynamic>> messages, {
    LLMConfig? config,
    List<Map<String, dynamic>>? tools,
  }) async {
    final cfg = config ?? const LLMConfig(provider: 'hunyuan', model: 'hunyuan-turbo');
    const url = 'https://hunyuan.tencentcloudapi.com';

    final body = <String, dynamic>{
      'Model': cfg.model,
      'Messages': messages.map((m) =>
        {'Role': m['role'], 'Content': m['content']}
      ).toList(),
      'Temperature': cfg.temperature,
      'TopP': 0.9,
    };

    if (tools != null && tools.isNotEmpty) {
      body['Tools'] = tools;
    }

    final payload = jsonEncode(body);
    final headers = _generateSignature(cfg.apiKey, cfg.secretKey ?? '', payload);

    final response = await _dio.post(
      url,
      data: payload,
      options: Options(headers: headers),
    );

    final data = response.data;
    final responseData = data['Response'];

    if (responseData?['Error'] != null) {
      throw Exception('混元 API 错误: ${responseData['Error']['Message']}');
    }

    final choices = responseData['Choices'];
    if (choices != null && choices.isNotEmpty) {
      final message = choices[0]['Message'];
      if (message['ToolCalls'] != null) {
        return jsonEncode(message);
      }
      return message['Content'] as String;
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
    const url = 'https://hunyuan.tencentcloudapi.com';

    final body = <String, dynamic>{
      'Model': cfg.model,
      'Messages': messages.map((m) =>
        {'Role': m['role'], 'Content': m['content']}
      ).toList(),
      'Temperature': cfg.temperature,
      'TopP': 0.9,
      'Stream': true,
    };

    if (tools != null && tools.isNotEmpty) {
      body['Tools'] = tools;
    }

    final payload = jsonEncode(body);
    final headers = _generateSignature(cfg.apiKey, cfg.secretKey ?? '', payload);

    final response = await _dio.post(
      url,
      data: payload,
      options: Options(
        headers: headers,
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
            final delta = data['Choices']?[0]?['Delta']?['Content'];
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
    if (config.apiKey.isEmpty || (config.secretKey ?? '').isEmpty) return false;
    try {
      await chat(
        [{'role': 'user', 'content': 'hi'}],
        config: LLMConfig(
          provider: 'hunyuan',
          model: 'hunyuan-lite',
          apiKey: config.apiKey,
          secretKey: config.secretKey,
          maxTokens: 10,
        ),
      );
      return true;
    } catch (_) {
      return false;
    }
  }
}
