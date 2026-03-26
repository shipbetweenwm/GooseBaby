import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'type_utils.dart';

/// HTTP 客户端封装
class HttpClient {
  static HttpClient? _instance;
  late final Dio _dio;

  HttpClient._() {
    _dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 30),
      receiveTimeout: const Duration(seconds: 60),
      sendTimeout: const Duration(seconds: 30),
      headers: {
        'User-Agent': 'GooseBaby/1.0',
      },
    ));

    // 添加拦截器
    _dio.interceptors.add(InterceptorsWrapper(
      onRequest: (options, handler) {
        debugPrint('🌐 HTTP ${options.method} ${options.uri}');
        handler.next(options);
      },
      onResponse: (response, handler) {
        debugPrint('🌐 HTTP ${response.statusCode} ${response.requestOptions.uri}');
        handler.next(response);
      },
      onError: (error, handler) {
        debugPrint('🌐 HTTP ERROR: ${error.message}');
        handler.next(error);
      },
    ));
  }

  static HttpClient get instance {
    _instance ??= HttpClient._();
    return _instance!;
  }

  Dio get dio => _dio;

  /// GET 请求
  Future<Response> get(
    String url, {
    Map<String, dynamic>? queryParameters,
    Map<String, String>? headers,
  }) async {
    return _dio.get(
      url,
      queryParameters: queryParameters,
      options: headers != null ? Options(headers: headers) : null,
    );
  }

  /// POST 请求
  Future<Response> post(
    String url, {
    dynamic data,
    Map<String, String>? headers,
  }) async {
    return _dio.post(
      url,
      data: data,
      options: headers != null ? Options(headers: headers) : null,
    );
  }

  /// POST JSON 请求
  Future<Map<String, dynamic>> postJson(
    String url, {
    required Map<String, dynamic> body,
    Map<String, String>? headers,
  }) async {
    final response = await _dio.post(
      url,
      data: body,
      options: Options(
        headers: {
          'Content-Type': 'application/json',
          ...?headers,
        },
      ),
    );

    if (response.data is Map) {
      return safeMap(response.data);
    }
    return {'data': response.data};
  }
}
