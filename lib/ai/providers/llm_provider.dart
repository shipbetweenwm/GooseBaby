import 'package:dio/dio.dart';
import '../../models/models.dart';
import '../agent/agent_types.dart';
import '../agent/stream_types.dart';

export '../agent/stream_types.dart';

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
  /// [cancelToken] 可选的 Dio CancelToken，用于即时中断 HTTP 请求
  Future<AgentResponse> chat(
    List<Map<String, dynamic>> messages, {
    LLMConfig? config,
    List<Map<String, dynamic>>? tools,
    CancelToken? cancelToken,
  });

  /// 流式对话（仅用于纯文本回复的流式展示，不处理 tool_calls）
  Stream<String> chatStream(
    List<Map<String, dynamic>> messages, {
    LLMConfig? config,
    List<Map<String, dynamic>>? tools,
  });

  /// 流式对话（支持工具调用）
  ///
  /// 与 chatStream 不同，此方法会：
  /// 1. 流式输出文本增量
  /// 2. 流式输出工具调用参数（让 UI 可以实时显示）
  /// 3. 返回完整的工具调用信息
  ///
  /// 返回 Stream<StreamEvent>，包含：
  /// - TextDeltaEvent: 文本增量
  /// - ThinkingDeltaEvent: 思考内容增量（深度思考模型）
  /// - ToolCallStartEvent: 工具调用开始
  /// - ToolCallDeltaEvent: 工具调用参数增量
  /// - ToolCallCompleteEvent: 工具调用完成
  /// - StreamEndEvent: 流结束
  /// - StreamErrorEvent: 错误
  ///
  /// 默认实现：回退到同步 chat 并包装为流
  /// 子类可以覆盖此方法提供真正的流式支持
  Stream<StreamEvent> chatStreamWithTools(
    List<Map<String, dynamic>> messages, {
    LLMConfig? config,
    List<Map<String, dynamic>>? tools,
  }) async* {
    // 默认实现：回退到同步 chat
    yield const StreamErrorEvent(
      message: '此 Provider 不支持流式工具调用',
      code: 'NOT_SUPPORTED',
    );
  }

  /// 检测是否可用
  Future<bool> isAvailable(LLMConfig config);

  /// 视觉分析：发送一张图片 + 提示词，返回文本描述
  /// 用于 CUA 截图分析等场景
  /// [base64Image] 图片的 base64 编码（不含 data:xxx;base64, 前缀）
  /// [mimeType] 图片 MIME 类型（如 image/jpeg）
  /// [prompt] 提示词
  /// [config] 视觉模型配置（model 字段应指向视觉模型）
  Future<String> chatWithVision({
    required String base64Image,
    required String mimeType,
    required String prompt,
    required LLMConfig config,
  }) async {
    // 默认实现：不支持视觉分析的 provider 抛异常
    throw UnsupportedError('${name} 不支持视觉分析');
  }

  /// Token 计数（估算）
  /// 用于上下文管理，避免超出模型上下文窗口
  int countTokens(String text) {
    // 默认实现：简单估算（英文约 4 字符 = 1 token，中文约 1.5 字符 = 1 token）
    int count = 0;
    for (int i = 0; i < text.length; i++) {
      final char = text[i];
      // 中文字符
      if (char.codeUnitAt(0) >= 0x4e00 && char.codeUnitAt(0) <= 0x9fff) {
        count += 1;
      } else {
        count += 1;
      }
    }
    // 除以 3 作为粗略估算
    return (count / 3).ceil();
  }

  /// 计算消息列表的 token 数
  int countMessagesTokens(List<Map<String, dynamic>> messages) {
    int total = 0;
    for (final msg in messages) {
      // 每条消息有约 4 token 的格式开销
      total += 4;
      final content = msg['content'];
      if (content is String) {
        total += countTokens(content);
      } else if (content is List) {
        for (final part in content) {
          if (part is Map && part['text'] is String) {
            total += countTokens(part['text'] as String);
          }
        }
      }
      // 工具调用参数
      if (msg['tool_calls'] is List) {
        for (final tc in msg['tool_calls'] as List) {
          if (tc is Map) {
            final func = tc['function'];
            if (func is Map) {
              total += countTokens(func['name']?.toString() ?? '');
              total += countTokens(func['arguments']?.toString() ?? '');
            }
          }
        }
      }
    }
    return total;
  }
}
