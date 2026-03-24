import '../../models/models.dart';
import '../agent/agent_types.dart';

/// LLM 提供者抽象接口
/// 所有大模型适配器必须实现此接口
abstract class LLMProvider {
  /// 提供者名称
  String get name;

  /// 提供者显示名
  String get displayName;

  /// 支持的模型列表
  List<String> get supportedModels;

  /// 同步对话，返回结构化响应
  ///
  /// 之前返回 String，通过 startsWith('{') 判断是否为 tool_calls。
  /// 现在直接返回 AgentResponse，调用方无需字符串解析。
  Future<AgentResponse> chat(
    List<Map<String, dynamic>> messages, {
    LLMConfig? config,
    List<Map<String, dynamic>>? tools,
  });

  /// 流式对话（仅用于纯文本回复的流式展示，不处理 tool_calls）
  Stream<String> chatStream(
    List<Map<String, dynamic>> messages, {
    LLMConfig? config,
    List<Map<String, dynamic>>? tools,
  });

  /// 检测是否可用
  Future<bool> isAvailable(LLMConfig config);
}
