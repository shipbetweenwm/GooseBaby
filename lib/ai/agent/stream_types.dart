/// 流式响应类型定义
/// 用于 AgentLoop 的 yield 流式输出

/// 流式响应事件基类
abstract class StreamEvent {
  const StreamEvent();
}

/// 文本增量事件
class TextDeltaEvent extends StreamEvent {
  final String delta;
  
  const TextDeltaEvent(this.delta);
  
  @override
  String toString() => 'TextDelta("$delta")';
}

/// 工具调用开始事件
class ToolCallStartEvent extends StreamEvent {
  final int index;
  final String toolName;
  final String toolCallId;
  
  const ToolCallStartEvent({
    required this.index,
    required this.toolName,
    required this.toolCallId,
  });
  
  @override
  String toString() => 'ToolCallStart($index, $toolName)';
}

/// 工具调用参数增量事件
class ToolCallDeltaEvent extends StreamEvent {
  final int index;
  final String argsDelta;
  
  const ToolCallDeltaEvent({
    required this.index,
    required this.argsDelta,
  });
  
  @override
  String toString() => 'ToolCallDelta($index, "${argsDelta.length} chars")';
}

/// 工具调用完成事件
class ToolCallCompleteEvent extends StreamEvent {
  final int index;
  final String toolName;
  final String toolCallId;
  final String arguments;
  
  const ToolCallCompleteEvent({
    required this.index,
    required this.toolName,
    required this.toolCallId,
    required this.arguments,
  });
  
  @override
  String toString() => 'ToolCallComplete($index, $toolName)';
}

/// 流式响应结束事件
class StreamEndEvent extends StreamEvent {
  /// 停止原因
  final String? finishReason;
  
  /// 当前轮次的 token 使用统计
  final TokenUsage? usage;
  
  const StreamEndEvent({
    this.finishReason,
    this.usage,
  });
  
  @override
  String toString() => 'StreamEnd(reason: $finishReason)';
}

/// 错误事件
class StreamErrorEvent extends StreamEvent {
  final String message;
  final String? code;
  
  const StreamErrorEvent({
    required this.message,
    this.code,
  });
  
  @override
  String toString() => 'StreamError($code: $message)';
}

/// Token 使用统计
class TokenUsage {
  final int promptTokens;
  final int completionTokens;
  final int totalTokens;
  
  const TokenUsage({
    required this.promptTokens,
    required this.completionTokens,
    required this.totalTokens,
  });
  
  factory TokenUsage.empty() => const TokenUsage(
    promptTokens: 0,
    completionTokens: 0,
    totalTokens: 0,
  );
  
  Map<String, dynamic> toJson() => {
    'prompt_tokens': promptTokens,
    'completion_tokens': completionTokens,
    'total_tokens': totalTokens,
  };
}

/// 思考内容增量事件（用于深度思考模型）
class ThinkingDeltaEvent extends StreamEvent {
  final String delta;
  
  const ThinkingDeltaEvent(this.delta);
  
  @override
  String toString() => 'ThinkingDelta("${delta.length} chars")';
}

/// 流式响应聚合器
/// 将流式事件聚合成完整响应
class StreamAggregator {
  final StringBuffer _textBuffer = StringBuffer();
  final StringBuffer _thinkingBuffer = StringBuffer();
  final List<ToolCallBuilder> _toolBuilders = [];
  TokenUsage? _usage;
  String? _finishReason;
  
  /// 处理事件
  void addEvent(StreamEvent event) {
    switch (event) {
      case TextDeltaEvent e:
        _textBuffer.write(e.delta);
      case ThinkingDeltaEvent e:
        _thinkingBuffer.write(e.delta);
      case ToolCallStartEvent e:
        while (_toolBuilders.length <= e.index) {
          _toolBuilders.add(ToolCallBuilder());
        }
        _toolBuilders[e.index]
          ..toolCallId = e.toolCallId
          ..toolName = e.toolName;
      case ToolCallDeltaEvent e:
        while (_toolBuilders.length <= e.index) {
          _toolBuilders.add(ToolCallBuilder());
        }
        _toolBuilders[e.index].argsBuffer.write(e.argsDelta);
      case ToolCallCompleteEvent e:
        while (_toolBuilders.length <= e.index) {
          _toolBuilders.add(ToolCallBuilder());
        }
        _toolBuilders[e.index]
          ..toolCallId = e.toolCallId
          ..toolName = e.toolName
          ..argsBuffer = StringBuffer(e.arguments);
      case StreamEndEvent e:
        _finishReason = e.finishReason;
        _usage = e.usage;
      case StreamErrorEvent _:
        // 错误事件不处理，由调用方处理
        break;
    }
  }
  
  /// 获取完整文本
  String get text => _textBuffer.toString();
  
  /// 获取完整思考内容
  String get thinking => _thinkingBuffer.toString();
  
  /// 获取工具调用列表
  List<BuiltToolCall> get toolCalls {
    return _toolBuilders
        .map((b) => b.build())
        .where((tc) => tc != null)
        .cast<BuiltToolCall>()
        .toList();
  }
  
  /// 获取 token 使用统计
  TokenUsage? get usage => _usage;
  
  /// 获取停止原因
  String? get finishReason => _finishReason;
  
  /// 是否有工具调用
  bool get hasToolCalls => _toolBuilders.any((b) => b.toolName.isNotEmpty);
  
  /// 是否有思考内容
  bool get hasThinking => _thinkingBuffer.isNotEmpty;
}

/// 工具调用构建器
class ToolCallBuilder {
  String toolCallId = '';
  String toolName = '';
  StringBuffer argsBuffer = StringBuffer();
  
  BuiltToolCall? build() {
    if (toolName.isEmpty) return null;
    return BuiltToolCall(
      toolCallId: toolCallId,
      toolName: toolName,
      arguments: argsBuffer.toString(),
    );
  }
}

/// 构建完成的工具调用
class BuiltToolCall {
  final String toolCallId;
  final String toolName;
  final String arguments;
  
  const BuiltToolCall({
    required this.toolCallId,
    required this.toolName,
    required this.arguments,
  });
  
  Map<String, dynamic> toJson() => {
    'id': toolCallId,
    'type': 'function',
    'function': {
      'name': toolName,
      'arguments': arguments,
    },
  };
}
