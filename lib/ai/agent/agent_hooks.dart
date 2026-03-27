/// Agent HOOK 系统
/// 
/// 提供在 Agent 执行生命周期的各个阶段注入自定义逻辑的能力。
/// 内置 Hook 包括：
/// - 失败经验自动检索 Hook
/// - 工具执行监控 Hook
/// - 性能统计 Hook

import 'agent_types.dart';
import 'sub_agent_types.dart';

/// Agent Hook 接口
abstract class AgentHook {
  /// Hook 唯一标识
  String get id;
  
  /// Hook 名称（显示用）
  String get name;
  
  /// Hook 描述
  String get description;
  
  /// Hook 优先级（数值越小越先执行）
  int get priority => 100;
  
  /// 是否启用
  bool get enabled => true;
  
  /// 循环开始前调用
  /// [context] Agent 执行上下文
  Future<void> onLoopStart(AgentLoopContext context) async {}
  
  /// 循环结束时调用
  /// [result] Agent 执行结果
  Future<void> onLoopEnd(AgentLoopResult result) async {}
  
  /// 工具调用前调用
  /// [call] 即将执行的工具调用
  /// 返回 HookResult 可注入消息或阻止调用
  Future<HookResult?> beforeToolCall(ToolCall call, AgentLoopContext context) async => null;
  
  /// 工具调用后调用
  /// [call] 已执行的工具调用
  /// [result] 工具执行结果
  Future<void> afterToolCall(ToolCall call, ToolResult result, AgentLoopContext context) async {}
  
  /// 工具调用出错时调用
  /// [call] 出错的工具调用
  /// [error] 错误信息
  Future<void> onToolError(ToolCall call, dynamic error, AgentLoopContext context) async {}
  
  /// 重试前调用
  /// [call] 即将重试的工具调用
  /// [retryCount] 当前重试次数
  /// 返回 HookResult 可注入消息或阻止重试
  Future<HookResult?> beforeRetry(ToolCall call, int retryCount, AgentLoopContext context) async => null;
  
  /// 子 Agent 启动前调用
  /// [config] 子 Agent 配置
  Future<void> onSubAgentStart(SubAgentConfig config) async {}
  
  /// 子 Agent 完成后调用
  /// [result] 子 Agent 执行结果
  Future<void> onSubAgentComplete(SubAgentResult result) async {}
  
  /// LLM 请求前调用（可用于注入额外消息）
  /// [messages] 当前的消息列表
  /// 返回要注入的额外消息列表
  Future<List<Map<String, dynamic>>?> beforeLLMRequest(List<Map<String, dynamic>> messages) async => null;
  
  /// LLM 响应后调用
  /// [response] LLM 的响应
  Future<void> afterLLMResponse(AgentResponse response) async {}
}

/// Hook 执行结果
class HookResult {
  /// 是否应该阻止后续执行
  final bool shouldBlock;
  
  /// 是否应该注入消息到上下文
  final bool shouldInject;
  
  /// 要注入的消息内容
  final String? injectedMessage;
  
  /// 要显示给用户的消息
  final String? userMessage;
  
  /// 是否跳过当前工具调用
  final bool shouldSkip;
  
  /// 修改后的工具参数（用于修正参数）
  final Map<String, dynamic>? modifiedArgs;
  
  const HookResult({
    this.shouldBlock = false,
    this.shouldInject = false,
    this.injectedMessage,
    this.userMessage,
    this.shouldSkip = false,
    this.modifiedArgs,
  });
  
  /// 创建注入消息的结果
  factory HookResult.inject(String message, {String? userMessage}) {
    return HookResult(
      shouldInject: true,
      injectedMessage: message,
      userMessage: userMessage,
    );
  }
  
  /// 创建阻止执行的结果
  factory HookResult.block(String reason) {
    return HookResult(
      shouldBlock: true,
      userMessage: reason,
    );
  }
  
  /// 创建跳过当前工具的结果
  factory HookResult.skip(String reason) {
    return HookResult(
      shouldSkip: true,
      userMessage: reason,
    );
  }
  
  /// 创建修改参数的结果
  factory HookResult.modifyArgs(Map<String, dynamic> newArgs, {String? reason}) {
    return HookResult(
      modifiedArgs: newArgs,
      userMessage: reason,
    );
  }
  
  /// 空结果（继续正常执行）
  static const HookResult empty = HookResult();
}

/// Agent 循环上下文
class AgentLoopContext {
  /// 会话 ID
  final String sessionId;
  
  /// 当前轮次
  int currentTurn;
  
  /// 最大轮次
  final int maxTurns;
  
  /// 已执行的工具调用列表
  final List<ToolCall> executedToolCalls;
  
  /// 失败的工具调用列表
  final List<FailedToolCall> failedToolCalls;
  
  /// 子 Agent 上下文（如果是子 Agent）
  final SubAgentContext? subAgentContext;
  
  /// 用户原始请求
  final String userRequest;
  
  /// 自定义数据存储（Hook 可用于存储临时状态）
  final Map<String, dynamic> customData;
  
  AgentLoopContext({
    String? sessionId,
    this.currentTurn = 0,
    this.maxTurns = 30,
    required this.userRequest,
    this.subAgentContext,
  })  : sessionId = sessionId ?? _generateSessionId(),
        executedToolCalls = [],
        failedToolCalls = [],
        customData = {};
  
  static String _generateSessionId() {
    return 'session_${DateTime.now().millisecondsSinceEpoch}';
  }
  
  /// 是否为子 Agent
  bool get isSubAgent => subAgentContext != null;
  
  /// 记录工具调用
  void recordToolCall(ToolCall call) {
    executedToolCalls.add(call);
  }
  
  /// 记录失败的工具调用
  void recordFailedToolCall(ToolCall call, String error) {
    failedToolCalls.add(FailedToolCall(call: call, error: error, timestamp: DateTime.now()));
  }
  
  /// 获取特定工具的失败次数
  int getFailureCount(String toolName) {
    return failedToolCalls.where((f) => f.call.name == toolName).length;
  }
}

/// 失败的工具调用记录
class FailedToolCall {
  final ToolCall call;
  final String error;
  final DateTime timestamp;
  
  const FailedToolCall({
    required this.call,
    required this.error,
    required this.timestamp,
  });
}

/// Hook 管理器
class HookManager {
  final List<AgentHook> _hooks = [];
  
  List<AgentHook> get hooks => List.unmodifiable(_hooks);
  
  /// 注册 Hook
  void register(AgentHook hook) {
    _hooks.add(hook);
    _hooks.sort((a, b) => a.priority.compareTo(b.priority));
  }
  
  /// 注销 Hook
  void unregister(String hookId) {
    _hooks.removeWhere((h) => h.id == hookId);
  }
  
  /// 获取 Hook
  AgentHook? getHook(String hookId) {
    try {
      return _hooks.firstWhere((h) => h.id == hookId);
    } catch (_) {
      return null;
    }
  }
  
  /// 启用/禁用 Hook
  void setEnabled(String hookId, bool enabled) {
    final hook = getHook(hookId);
    if (hook != null && hook is ToggleableHook) {
      (hook as ToggleableHook).enabled = enabled;
    }
  }
  
  /// 执行循环开始 Hooks
  Future<void> triggerLoopStart(AgentLoopContext context) async {
    for (final hook in _hooks.where((h) => h.enabled)) {
      try {
        await hook.onLoopStart(context);
      } catch (e) {
        // Hook 执行失败不影响主流程
        print('[Hook ${hook.id}] onLoopStart error: $e');
      }
    }
  }
  
  /// 执行循环结束 Hooks
  Future<void> triggerLoopEnd(AgentLoopResult result) async {
    for (final hook in _hooks.where((h) => h.enabled)) {
      try {
        await hook.onLoopEnd(result);
      } catch (e) {
        print('[Hook ${hook.id}] onLoopEnd error: $e');
      }
    }
  }
  
  /// 执行工具调用前 Hooks
  /// block 立即返回，inject 消息会合并，所有 Hook 都有机会执行
  Future<HookResult?> triggerBeforeToolCall(ToolCall call, AgentLoopContext context) async {
    final injectedMessages = <String>[];
    String? userMessage;
    bool shouldSkip = false;
    Map<String, dynamic>? modifiedArgs;
    
    for (final hook in _hooks.where((h) => h.enabled)) {
      try {
        final result = await hook.beforeToolCall(call, context);
        if (result == null) continue;
        
        // block 最高优先级，立刻返回
        if (result.shouldBlock) return result;
        
        // skip 记录但继续收集
        if (result.shouldSkip) {
          shouldSkip = true;
          userMessage ??= result.userMessage;
        }
        
        // inject 消息合并
        if (result.shouldInject && result.injectedMessage != null) {
          injectedMessages.add(result.injectedMessage!);
          userMessage ??= result.userMessage;
        }
        
        // modifyArgs 后者覆盖前者
        if (result.modifiedArgs != null) {
          modifiedArgs = result.modifiedArgs;
          userMessage ??= result.userMessage;
        }
      } catch (e) {
        print('[Hook ${hook.id}] beforeToolCall error: $e');
      }
    }
    
    // 如果有 skip
    if (shouldSkip) {
      return HookResult(shouldSkip: true, userMessage: userMessage);
    }
    
    // 合并所有 inject 消息
    if (injectedMessages.isNotEmpty) {
      return HookResult(
        shouldInject: true,
        injectedMessage: injectedMessages.join('\n\n'),
        userMessage: userMessage,
        modifiedArgs: modifiedArgs,
      );
    }
    
    // 仅有 modifyArgs
    if (modifiedArgs != null) {
      return HookResult(modifiedArgs: modifiedArgs, userMessage: userMessage);
    }
    
    return null;
  }
  
  /// 执行工具调用后 Hooks
  Future<void> triggerAfterToolCall(ToolCall call, ToolResult result, AgentLoopContext context) async {
    for (final hook in _hooks.where((h) => h.enabled)) {
      try {
        await hook.afterToolCall(call, result, context);
      } catch (e) {
        print('[Hook ${hook.id}] afterToolCall error: $e');
      }
    }
  }
  
  /// 执行工具错误 Hooks
  Future<void> triggerToolError(ToolCall call, dynamic error, AgentLoopContext context) async {
    for (final hook in _hooks.where((h) => h.enabled)) {
      try {
        await hook.onToolError(call, error, context);
      } catch (e) {
        print('[Hook ${hook.id}] onToolError error: $e');
      }
    }
  }
  
  /// 执行重试前 Hooks
  Future<HookResult?> triggerBeforeRetry(ToolCall call, int retryCount, AgentLoopContext context) async {
    for (final hook in _hooks.where((h) => h.enabled)) {
      try {
        final result = await hook.beforeRetry(call, retryCount, context);
        if (result != null) return result;
      } catch (e) {
        print('[Hook ${hook.id}] beforeRetry error: $e');
      }
    }
    return null;
  }
  
  /// 执行子 Agent 启动 Hooks
  Future<void> triggerSubAgentStart(SubAgentConfig config) async {
    for (final hook in _hooks.where((h) => h.enabled)) {
      try {
        await hook.onSubAgentStart(config);
      } catch (e) {
        print('[Hook ${hook.id}] onSubAgentStart error: $e');
      }
    }
  }
  
  /// 执行子 Agent 完成 Hooks
  Future<void> triggerSubAgentComplete(SubAgentResult result) async {
    for (final hook in _hooks.where((h) => h.enabled)) {
      try {
        await hook.onSubAgentComplete(result);
      } catch (e) {
        print('[Hook ${hook.id}] onSubAgentComplete error: $e');
      }
    }
  }
  
  /// 执行 LLM 请求前 Hooks
  Future<List<Map<String, dynamic>>?> triggerBeforeLLMRequest(List<Map<String, dynamic>> messages) async {
    final allInjected = <Map<String, dynamic>>[];
    for (final hook in _hooks.where((h) => h.enabled)) {
      try {
        final injected = await hook.beforeLLMRequest(messages);
        if (injected != null && injected.isNotEmpty) {
          allInjected.addAll(injected);
        }
      } catch (e) {
        print('[Hook ${hook.id}] beforeLLMRequest error: $e');
      }
    }
    return allInjected.isEmpty ? null : allInjected;
  }
  
  /// 执行 LLM 响应后 Hooks
  Future<void> triggerAfterLLMResponse(AgentResponse response) async {
    for (final hook in _hooks.where((h) => h.enabled)) {
      try {
        await hook.afterLLMResponse(response);
      } catch (e) {
        print('[Hook ${hook.id}] afterLLMResponse error: $e');
      }
    }
  }
  
  /// 清空所有 Hooks
  void clear() {
    _hooks.clear();
  }
}

/// 可切换状态的 Hook Mixin
mixin ToggleableHook implements AgentHook {
  bool _hookEnabled = true;
  
  @override
  bool get enabled => _hookEnabled;
  
  set enabled(bool value) {
    _hookEnabled = value;
  }
}

/// 基础 Hook 实现类
abstract class BaseHook with ToggleableHook {
  @override
  final String id;
  
  @override
  final String name;
  
  @override
  final String description;
  
  @override
  final int priority;
  
  BaseHook({
    required this.id,
    required this.name,
    required this.description,
    this.priority = 100,
  });
  
  // 提供默认的空实现
  @override
  Future<void> onLoopStart(AgentLoopContext context) async {}
  
  @override
  Future<void> onLoopEnd(AgentLoopResult result) async {}
  
  @override
  Future<HookResult?> beforeToolCall(ToolCall call, AgentLoopContext context) async => null;
  
  @override
  Future<void> afterToolCall(ToolCall call, ToolResult result, AgentLoopContext context) async {}
  
  @override
  Future<void> onToolError(ToolCall call, dynamic error, AgentLoopContext context) async {}
  
  @override
  Future<HookResult?> beforeRetry(ToolCall call, int retryCount, AgentLoopContext context) async => null;
  
  @override
  Future<void> onSubAgentStart(SubAgentConfig config) async {}
  
  @override
  Future<void> onSubAgentComplete(SubAgentResult result) async {}
  
  @override
  Future<List<Map<String, dynamic>>?> beforeLLMRequest(List<Map<String, dynamic>> messages) async => null;
  
  @override
  Future<void> afterLLMResponse(AgentResponse response) async {}
}

/// 性能统计 Hook
class PerformanceStatsHook extends BaseHook {
  DateTime? _loopStartTime;
  final Map<String, _ToolStats> _toolStats = {};
  
  /// 每个工具调用的开始时间（key: toolCall.id）
  final Map<String, DateTime> _toolStartTimes = {};
  
  PerformanceStatsHook()
      : super(
          id: 'performance_stats',
          name: '性能统计',
          description: '统计 Agent 执行性能数据',
          priority: 1000, // 低优先级，最后执行
        );
  
  @override
  Future<void> onLoopStart(AgentLoopContext context) async {
    _loopStartTime = DateTime.now();
    _toolStats.clear();
    _toolStartTimes.clear();
  }
  
  @override
  Future<void> onLoopEnd(AgentLoopResult result) async {
    if (_loopStartTime == null) return;
    
    final totalDuration = DateTime.now().difference(_loopStartTime!);
    final stats = getStats();
    
    print('[PerformanceStats] 总耗时: ${totalDuration.inMilliseconds}ms');
    print('[PerformanceStats] 工具调用次数: ${stats['totalToolCalls']}');
    print('[PerformanceStats] 失败次数: ${stats['failedCalls']}');
    
    for (final entry in _toolStats.entries) {
      final avg = entry.value.count > 0
          ? entry.value.totalDurationMs / entry.value.count
          : 0;
      print('[PerformanceStats] ${entry.key}: ${entry.value.count}次, 平均 ${avg.toStringAsFixed(0)}ms, 失败 ${entry.value.failures}次');
    }
  }
  
  @override
  Future<HookResult?> beforeToolCall(ToolCall call, AgentLoopContext context) async {
    // 记录工具调用开始时间
    _toolStartTimes[call.id] = DateTime.now();
    return null;
  }
  
  @override
  Future<void> afterToolCall(ToolCall call, ToolResult result, AgentLoopContext context) async {
    final stats = _toolStats.putIfAbsent(call.name, () => _ToolStats());
    stats.count++;
    if (result.isError) stats.failures++;
    
    // 计算实际耗时
    final startTime = _toolStartTimes.remove(call.id);
    if (startTime != null) {
      final durationMs = DateTime.now().difference(startTime).inMilliseconds;
      stats.totalDurationMs += durationMs;
    }
  }
  
  Map<String, dynamic> getStats() {
    int totalCalls = 0;
    int failedCalls = 0;
    int totalDurationMs = 0;
    for (final stats in _toolStats.values) {
      totalCalls += stats.count;
      failedCalls += stats.failures;
      totalDurationMs += stats.totalDurationMs;
    }
    return {
      'totalToolCalls': totalCalls,
      'failedCalls': failedCalls,
      'totalDurationMs': totalDurationMs,
      'toolBreakdown': _toolStats.map((k, v) => MapEntry(k, {
        'count': v.count,
        'failures': v.failures,
        'avgDurationMs': v.count > 0 ? (v.totalDurationMs / v.count).round() : 0,
      })),
    };
  }
}

class _ToolStats {
  int count = 0;
  int failures = 0;
  int totalDurationMs = 0;
}
