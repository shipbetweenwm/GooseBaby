// 类型安全工具函数
//
// 解决 Dart 中 jsonDecode / Hive 反序列化返回 _Map<dynamic, dynamic>
// 直接 as Map<String, dynamic> 导致运行时崩溃的问题。

/// 安全地将 dynamic 转换为 Map<String, dynamic>
/// 适用于 jsonDecode、Hive 反序列化、Dio JSON 响应等场景
Map<String, dynamic> safeMap(dynamic source) {
  if (source is Map<String, dynamic>) return source;
  if (source is Map) return Map<String, dynamic>.from(source);
  throw ArgumentError('Expected Map, got ${source.runtimeType}');
}
