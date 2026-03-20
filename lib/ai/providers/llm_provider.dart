import '../../models/models.dart';

/// LLM 提供者抽象接口
/// 所有大模型适配器必须实现此接口
abstract class LLMProvider {
  /// 提供者名称
  String get name;

  /// 提供者显示名
  String get displayName;

  /// 支持的模型列表
  List<String> get supportedModels;

  /// 同步对话
  Future<String> chat(
    List<Map<String, dynamic>> messages, {
    LLMConfig? config,
    List<Map<String, dynamic>>? tools,
  });

  /// 流式对话
  Stream<String> chatStream(
    List<Map<String, dynamic>> messages, {
    LLMConfig? config,
    List<Map<String, dynamic>>? tools,
  });

  /// 检测是否可用
  Future<bool> isAvailable(LLMConfig config);
}
