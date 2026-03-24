/// 智能体核心类型定义
/// 参考 Claude Code 的设计：结构化响应 + 工具调用 + 停止原因

import 'dart:convert';

/// 取消令牌 — 用于从外部中断 AgentLoop
class CancellationToken {
  bool _isCancelled = false;

  bool get isCancelled => _isCancelled;

  void cancel() => _isCancelled = true;

  /// 如果已取消，抛出 [CancelledException]
  void throwIfCancelled() {
    if (_isCancelled) throw CancelledException();
  }
}

/// 用户主动取消会话时抛出的异常
class CancelledException implements Exception {
  @override
  String toString() => 'CancelledException: 用户取消了当前会话';
}

/// 智能体响应（结构化，替代之前 JSON 字符串 hack）
///
/// 之前 Provider 返回 String，通过 `startsWith('{') && contains('tool_calls')` 判断是否为工具调用。
/// 现在直接返回结构化类型，消除字符串解析。
class AgentResponse {
  /// 文本内容（LLM 的纯文本回复）
  final String text;

  /// 工具调用列表（LLM 请求执行的工具）
  final List<ToolCall> toolCalls;

  /// 停止原因
  final AgentStopReason stopReason;

  AgentResponse({
    required this.text,
    required this.toolCalls,
    required this.stopReason,
  });

  /// 便捷构造：通过 tools 命名参数创建（兼容 providers 的调用方式）
  factory AgentResponse.tools(List<ToolCall> toolCalls) =>
      AgentResponse(text: '', toolCalls: toolCalls, stopReason: AgentStopReason.toolCalls);

  /// 便捷构造：纯文本回复
  factory AgentResponse.text(String text, {AgentStopReason reason = AgentStopReason.stop}) =>
      AgentResponse(text: text, toolCalls: const [], stopReason: reason);

  bool get hasToolCalls => toolCalls.isNotEmpty;

  @override
  String toString() => 'AgentResponse(stop: $stopReason, text: ${text.length}chars, tools: ${toolCalls.length})';
}

/// 单个工具调用
class ToolCall {
  final String id;
  final String name;
  final Map<String, dynamic> arguments;

  ToolCall({required this.id, required this.name, required this.arguments});

  /// 从 OpenAI 格式的 tool_call 解析
  factory ToolCall.fromJson(Map<String, dynamic> json) {
    final function = json['function'] as Map<String, dynamic>? ?? {};
    return ToolCall(
      id: json['id'] as String? ?? '',
      name: function['name'] as String? ?? '',
      arguments: (function['arguments'] is String)
          ? (jsonDecode(function['arguments'] as String) as Map<String, dynamic>)
          : (function['arguments'] as Map<String, dynamic>? ?? {}),
    );
  }

  @override
  String toString() => 'ToolCall($name, id=$id)';

  /// 用于循环检测的签名
  String get signature => '$name:${jsonEncode(arguments)}';
}

/// 停止原因
enum AgentStopReason {
  /// LLM 正常结束（纯文本回复）
  stop,

  /// LLM 请求执行工具（有 tool_calls）
  toolCalls,

  /// 输出被截断（max_tokens 用尽）
  length,

  /// 内容过滤
  contentFilter,
}

/// 工具执行结果
class ToolResult {
  final String toolCallId;
  final String content;
  final bool isError;

  /// 附加数据（如写入的文件路径/大小等）
  final Map<String, dynamic>? data;

  ToolResult({required this.toolCallId, required this.content, this.isError = false, this.data});
}

/// Agent 循环的最终结果
class AgentLoopResult {
  /// LLM 的最终文本回复
  final String text;

  /// 完整的工具调用 API 消息序列（用于多轮会话持久化）
  final List<Map<String, dynamic>> apiMessages;

  /// 调用过的技能名
  final List<String> skillNames;

  /// shell_exec 生成的输出文件
  final List<Map<String, dynamic>> outputFiles;

  /// 工具调用步骤（用于 UI 显示）
  final List<ToolStep> steps;

  AgentLoopResult({
    required this.text,
    required this.apiMessages,
    required this.skillNames,
    required this.outputFiles,
    required this.steps,
  });
}

/// 工具调用步骤（UI 展示用）
class ToolStep {
  final String title;
  String content;
  bool isLoading;
  final bool isSkip;
  bool isFailed;
  final DateTime timestamp;

  ToolStep({
    required this.title,
    required this.content,
    this.isLoading = false,
    this.isSkip = false,
    this.isFailed = false,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();
}

/// 解析 API 的 finish_reason 为 AgentStopReason
AgentStopReason parseStopReason(String? reason) {
  switch (reason) {
    case 'tool_calls':
    case 'function_call':
      return AgentStopReason.toolCalls;
    case 'length':
    case 'max_tokens':
      return AgentStopReason.length;
    case 'content_filter':
      return AgentStopReason.contentFilter;
    default:
      return AgentStopReason.stop;
  }
}
