/// 错误恢复与状态回滚（模块 7）
///
/// 提供三层错误恢复能力：
/// 1. 状态快照与回滚 — 在关键步骤前创建检查点，失败时可回退
/// 2. 渐进式降级策略 — 缩小范围 → 切换工具 → 简化参数 → 报告失败
/// 3. 补偿事务 — 记录已执行操作，支持反向操作撤销
///
/// 与现有 FailureLessonHook 的协作：
/// - FailureLessonHook: 失败后学习经验，下次避免
/// - RecoveryManager: 失败后立即尝试恢复，当次就解决
import 'package:flutter/foundation.dart';
import 'agent_types.dart';
import 'agent_hooks.dart';
import '../config/agent_config.dart';

// ═══════════════════════════════════════════
// 状态快照
// ═══════════════════════════════════════════

/// 状态快照（检查点）
class StateSnapshot {
  final String id;
  final DateTime timestamp;
  final int messageCount;
  final List<Map<String, dynamic>> messagesSnapshot;
  final Map<String, dynamic> metadata;
  final String? description;

  StateSnapshot({
    required this.id,
    required this.timestamp,
    required this.messageCount,
    required this.messagesSnapshot,
    this.metadata = const {},
    this.description,
  });

  @override
  String toString() =>
      'Snapshot($id, msgs=$messageCount, ${description ?? ""})';
}

// ═══════════════════════════════════════════
// 降级策略接口
// ═══════════════════════════════════════════

/// 降级策略接口
abstract class DegradationStrategy {
  String get name;
  String get description;

  /// 判断是否适用于该工具调用
  bool isApplicable(ToolCall call, String error);

  /// 修改工具调用（降级处理）
  ToolCall modify(ToolCall original);
}

/// 策略 1：缩小操作范围
class ReduceScopeStrategy extends DegradationStrategy {
  @override
  String get name => '缩小范围';

  @override
  String get description => '缩小搜索范围或操作目标';

  @override
  bool isApplicable(ToolCall call, String error) {
    // 适用于搜索类和文件操作类工具
    return ['codebase_search', 'search_content', 'search_file', 'list_dir']
        .contains(call.name);
  }

  @override
  ToolCall modify(ToolCall original) {
    final args = Map<String, dynamic>.from(original.arguments);

    // 缩小搜索范围到当前目录
    if (args.containsKey('path')) {
      args['path'] = '.';
    }

    // 减少结果数量
    if (args.containsKey('limit')) {
      final currentLimit = args['limit'] as int? ?? 10;
      args['limit'] = (currentLimit ~/ 2).clamp(1, currentLimit);
    }

    return ToolCall(id: original.id, name: original.name, arguments: args);
  }
}

/// 策略 2：切换替代工具
class FallbackToolStrategy extends DegradationStrategy {
  /// 工具降级映射
  static const _fallbackMap = <String, String>{
    'codebase_search': 'search_content',
    'search_content': 'search_file',
    'execute_command': 'read_file',
  };

  @override
  String get name => '替代工具';

  @override
  String get description => '切换到功能相近的替代工具';

  @override
  bool isApplicable(ToolCall call, String error) {
    return _fallbackMap.containsKey(call.name);
  }

  @override
  ToolCall modify(ToolCall original) {
    final fallback = _fallbackMap[original.name];
    if (fallback != null) {
      return ToolCall(
        id: original.id,
        name: fallback,
        arguments: Map<String, dynamic>.from(original.arguments),
      );
    }
    return original;
  }
}

/// 策略 3：简化参数
class SimplifyParamsStrategy extends DegradationStrategy {
  @override
  String get name => '简化参数';

  @override
  String get description => '移除可选参数，使用最简配置';

  @override
  bool isApplicable(ToolCall call, String error) {
    // 适用于参数较多的工具
    return call.arguments.length > 2;
  }

  @override
  ToolCall modify(ToolCall original) {
    final args = Map<String, dynamic>.from(original.arguments);

    // 保留必要参数（name/path/query/command），移除其他
    final essentialKeys = {'name', 'path', 'query', 'command', 'content',
        'filePath', 'pattern', 'text'};
    args.removeWhere((key, _) => !essentialKeys.contains(key));

    return ToolCall(id: original.id, name: original.name, arguments: args);
  }
}

/// 策略 4：带重试间隔的重试
class RetryWithBackoffStrategy extends DegradationStrategy {
  final int maxRetries;
  final Duration initialDelay;
  final double backoffMultiplier;
  int _currentAttempt = 0;

  RetryWithBackoffStrategy({
    this.maxRetries = 3,
    this.initialDelay = const Duration(seconds: 1),
    this.backoffMultiplier = 2.0,
  });

  @override
  String get name => '退避重试';

  @override
  String get description => '指数退避重试';

  @override
  bool isApplicable(ToolCall call, String error) {
    // 适用于网络相关错误或临时性错误
    return error.contains('timeout') ||
        error.contains('429') ||
        error.contains('503') ||
        error.contains('connection') ||
        _currentAttempt < maxRetries;
  }

  @override
  ToolCall modify(ToolCall original) {
    _currentAttempt++;
    // 不修改参数，只是标记需要延迟
    return original;
  }

  Duration get currentDelay {
    final multiplier = backoffMultiplier * _currentAttempt;
    return Duration(
        milliseconds: (initialDelay.inMilliseconds * multiplier).round());
  }

  void reset() => _currentAttempt = 0;
}

// ═══════════════════════════════════════════
// 补偿事务记录
// ═══════════════════════════════════════════

/// 已执行操作记录（用于回滚）
class ExecutedAction {
  final String stepId;
  final ToolCall toolCall;
  final ToolResult result;
  final DateTime timestamp;

  /// 反向操作（用于撤销）
  final ToolCall? compensatingAction;

  ExecutedAction({
    required this.stepId,
    required this.toolCall,
    required this.result,
    required this.timestamp,
    this.compensatingAction,
  });
}

// ═══════════════════════════════════════════
// 恢复管理器
// ═══════════════════════════════════════════

/// 错误恢复管理器
class RecoveryManager {
  final List<StateSnapshot> _snapshots = [];
  final List<ExecutedAction> _executedActions = [];
  final List<DegradationStrategy> _defaultStrategies;

  RecoveryManager({
    List<DegradationStrategy>? strategies,
  }) : _defaultStrategies = strategies ??
            [
              RetryWithBackoffStrategy(),
              ReduceScopeStrategy(),
              SimplifyParamsStrategy(),
              FallbackToolStrategy(),
            ];

  // ─── 快照管理 ───

  /// 创建状态快照（在关键步骤前调用）
  StateSnapshot createSnapshot({
    required List<Map<String, dynamic>> messages,
    Map<String, dynamic>? metadata,
    String? description,
  }) {
    final config = AgentConfig();
    final snapshot = StateSnapshot(
      id: 'snap_${DateTime.now().millisecondsSinceEpoch}',
      timestamp: DateTime.now(),
      messageCount: messages.length,
      messagesSnapshot: messages.map((m) => Map<String, dynamic>.from(m)).toList(),
      metadata: metadata ?? {},
      description: description,
    );

    _snapshots.add(snapshot);

    // 控制快照数量
    while (_snapshots.length > config.maxSnapshots) {
      _snapshots.removeAt(0);
    }

    debugPrint('📸 [Recovery] 创建快照: ${snapshot.id} ($description)');
    return snapshot;
  }

  /// 回滚到指定快照
  List<Map<String, dynamic>> rollbackTo(StateSnapshot snapshot) {
    debugPrint('⏪ [Recovery] 回滚到快照: ${snapshot.id}');
    return snapshot.messagesSnapshot
        .map((m) => Map<String, dynamic>.from(m))
        .toList();
  }

  /// 回滚到最近的快照
  List<Map<String, dynamic>>? rollbackToLatest() {
    if (_snapshots.isEmpty) return null;
    return rollbackTo(_snapshots.last);
  }

  /// 获取所有快照
  List<StateSnapshot> get snapshots => List.unmodifiable(_snapshots);

  // ─── 操作记录 ───

  /// 记录已执行的操作
  void recordAction(
    String stepId,
    ToolCall call,
    ToolResult result, {
    ToolCall? compensatingAction,
  }) {
    _executedActions.add(ExecutedAction(
      stepId: stepId,
      toolCall: call,
      result: result,
      timestamp: DateTime.now(),
      compensatingAction: compensatingAction,
    ));
  }

  /// 获取已执行操作
  List<ExecutedAction> get executedActions =>
      List.unmodifiable(_executedActions);

  // ─── 降级执行 ───

  /// 使用渐进式降级策略执行工具调用
  ///
  /// 策略链：重试 → 缩小范围 → 简化参数 → 替代工具 → 报告失败
  Future<ToolResult> executeWithDegradation(
    ToolCall call,
    Future<ToolResult> Function(ToolCall) executor, {
    List<DegradationStrategy>? strategies,
    String? lastError,
  }) async {
    final effectiveStrategies = strategies ?? _defaultStrategies;
    final config = AgentConfig();

    // 首先尝试正常执行
    try {
      final result = await executor(call);
      if (!result.isError) return result;
      lastError = result.content;
    } catch (e) {
      lastError = e.toString();
    }

    // 逐个尝试降级策略
    var attempts = 0;
    for (final strategy in effectiveStrategies) {
      if (attempts >= config.maxDegradationAttempts) break;

      if (!strategy.isApplicable(call, lastError ?? '')) continue;

      try {
        final modifiedCall = strategy.modify(call);
        debugPrint(
            '⚠️ [Recovery] 降级策略 ${strategy.name}: '
            '${call.name} → ${modifiedCall.name}');

        // 如果是退避重试策略，等待
        if (strategy is RetryWithBackoffStrategy) {
          await Future.delayed(strategy.currentDelay);
        }

        final result = await executor(modifiedCall);
        if (!result.isError) {
          debugPrint('✅ [Recovery] 降级策略 ${strategy.name} 成功');
          return result;
        }
        lastError = result.content;
      } catch (e) {
        debugPrint('⚠️ [Recovery] 降级策略 ${strategy.name} 失败: $e');
        lastError = e.toString();
      }

      attempts++;
    }

    // 所有策略都失败
    debugPrint('❌ [Recovery] 所有恢复策略已耗尽');
    return ToolResult(
      toolCallId: call.id,
      content: '所有恢复策略已耗尽。最后错误: ${lastError ?? "unknown"}',
      isError: true,
    );
  }

  /// 清理状态
  void reset() {
    _snapshots.clear();
    _executedActions.clear();
    for (final strategy in _defaultStrategies) {
      if (strategy is RetryWithBackoffStrategy) {
        strategy.reset();
      }
    }
  }
}

// ═══════════════════════════════════════════
// RecoveryHook — 将恢复管理器集成为 Hook
// ═══════════════════════════════════════════

/// 将恢复管理器集成为 AgentHook
///
/// 职责：
/// - onLoopStart: 重置恢复管理器
/// - beforeToolCall: 关键工具调用前自动创建快照
/// - onToolError: 记录错误，判断是否需要降级
/// - onLoopEnd: 清理状态
class RecoveryHook extends BaseHook {
  final RecoveryManager _recovery;

  /// 需要在调用前创建快照的工具（写操作）
  static const _snapshotTriggerTools = {
    'write_file',
    'replace_in_file',
    'shell_exec',
    'execute_command',
    'batch_file',
    'delete_file',
  };

  RecoveryHook([RecoveryManager? recovery])
      : _recovery = recovery ?? RecoveryManager(),
        super(
          id: 'recovery',
          name: '错误恢复',
          description: '状态快照 + 渐进式降级 + 补偿事务',
          priority: 50, // 中等优先级
        );

  @override
  Future<void> onLoopStart(AgentLoopContext context) async {
    _recovery.reset();
  }

  @override
  Future<HookResult?> beforeToolCall(
      ToolCall call, AgentLoopContext context) async {
    // 对写操作工具自动创建快照
    if (_snapshotTriggerTools.contains(call.name)) {
      // 注意：这里无法直接访问 messages，快照需要在 AgentLoop 层面配合
      debugPrint('📸 [Recovery] 写操作前标记快照: ${call.name}');
      context.customData['_needsSnapshot'] = true;
    }
    return null;
  }

  @override
  Future<void> afterToolCall(
      ToolCall call, ToolResult result, AgentLoopContext context) async {
    // 记录已执行的操作（用于补偿事务）
    _recovery.recordAction(
      'turn_${context.currentTurn}',
      call,
      result,
      compensatingAction: _generateCompensatingAction(call, result),
    );
  }

  @override
  Future<void> onToolError(
      ToolCall call, dynamic error, AgentLoopContext context) async {
    debugPrint('🔧 [Recovery] 工具 ${call.name} 出错，记录恢复上下文');
    context.customData['_lastError'] = error.toString();
    context.customData['_lastFailedTool'] = call.name;
  }

  @override
  Future<void> onLoopEnd(AgentLoopResult result) async {
    final actionsCount = _recovery.executedActions.length;
    final snapshotsCount = _recovery.snapshots.length;
    debugPrint(
        '📊 [Recovery] 会话统计: $actionsCount 个操作, $snapshotsCount 个快照');
  }

  /// 生成补偿操作（简单启发式）
  ToolCall? _generateCompensatingAction(ToolCall call, ToolResult result) {
    if (result.isError) return null;

    // write_file → delete_file (或恢复原始内容)
    if (call.name == 'write_file') {
      final path = call.arguments['path'] as String?;
      if (path != null) {
        return ToolCall(
          id: '${call.id}_compensate',
          name: 'delete_file',
          arguments: {'target_file': path},
        );
      }
    }

    return null;
  }

  /// 获取恢复管理器
  RecoveryManager get recovery => _recovery;
}
