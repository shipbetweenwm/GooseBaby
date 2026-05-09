/// 会话级状态机
///
/// 跟踪多轮对话的执行阶段，确保流程有序推进：
/// idle → routing → planning → executing → evaluating → completed
///
/// 核心能力：
/// 1. 状态跟踪：记录当前阶段、耗时、转换历史
/// 2. 状态守卫：非法转换会被拒绝
/// 3. 事件回调：状态变化时通知外部
/// 4. 回滚支持：支持从 executing 回退到 planning（重新规划）
import 'package:flutter/foundation.dart';

/// 会话状态
enum SessionState {
  /// 空闲，等待用户输入
  idle,

  /// 路由中，判断走哪条处理路径
  routing,

  /// 规划中，LLM 正在分解任务
  planning,

  /// 执行中，正在运行工具
  executing,

  /// 评估中，正在评估步骤结果
  evaluating,

  /// 已完成，输出最终结果
  completed,

  /// 失败，需要重试或重新规划
  failed,
}

/// 状态转换事件
class StateTransition {
  final SessionState from;
  final SessionState to;
  final DateTime timestamp;
  final String? reason;

  const StateTransition({
    required this.from,
    required this.to,
    required this.timestamp,
    this.reason,
  });
}

/// 会话状态机
class SessionStateMachine {
  SessionState _currentState = SessionState.idle;
  final List<StateTransition> _history = [];
  DateTime? _stateEnteredAt;
  String? _currentPlanId;

  /// 状态变化回调
  final void Function(SessionState from, SessionState to)? onStateChange;

  SessionStateMachine({this.onStateChange});

  /// 当前状态
  SessionState get currentState => _currentState;

  /// 状态历史
  List<StateTransition> get history => List.unmodifiable(_history);

  /// 当前状态持续时间
  Duration get currentDuration => _stateEnteredAt != null
      ? DateTime.now().difference(_stateEnteredAt!)
      : Duration.zero;

  /// 当前计划 ID
  String? get currentPlanId => _currentPlanId;

  /// 是否处于活跃状态（非 idle / completed）
  bool get isActive =>
      _currentState != SessionState.idle &&
      _currentState != SessionState.completed;

  /// 是否可以接受新输入
  bool get canAcceptInput =>
      _currentState == SessionState.idle ||
      _currentState == SessionState.completed ||
      _currentState == SessionState.failed;

  /// 合法状态转换表
  static const Map<SessionState, Set<SessionState>> _transitions = {
    SessionState.idle: {SessionState.routing},
    SessionState.routing: {
      SessionState.planning,
      SessionState.executing,
      SessionState.completed,
      SessionState.failed,
    },
    SessionState.planning: {
      SessionState.executing,
      SessionState.failed,
      SessionState.idle, // 用户取消规划
    },
    SessionState.executing: {
      SessionState.evaluating,
      SessionState.planning, // 需要重新规划
      SessionState.completed,
      SessionState.failed,
      SessionState.idle, // 用户取消执行
    },
    SessionState.evaluating: {
      SessionState.executing, // 继续执行下一步
      SessionState.planning, // 评估失败，重新规划
      SessionState.completed,
      SessionState.failed,
    },
    SessionState.completed: {SessionState.idle, SessionState.routing},
    SessionState.failed: {
      SessionState.planning, // 重新规划
      SessionState.idle, // 放弃
      SessionState.routing, // 重新路由
    },
  };

  /// 尝试转换状态
  /// 返回 true 表示转换成功
  bool transition(SessionState target, {String? reason}) {
    final allowed = _transitions[_currentState];
    if (allowed == null || !allowed.contains(target)) {
      debugPrint('⚠️ [StateMachine] 非法状态转换: $_currentState → $target'
          '${reason != null ? " ($reason)" : ""}');
      return false;
    }

    final from = _currentState;
    _history.add(StateTransition(
      from: from,
      to: target,
      timestamp: DateTime.now(),
      reason: reason,
    ));

    debugPrint('🔄 [StateMachine] $from → $target'
        '${reason != null ? " ($reason)" : ""}'
        ' [${_history.length}]');

    _currentState = target;
    _stateEnteredAt = DateTime.now();

    onStateChange?.call(from, target);
    return true;
  }

  /// 强制重置到 idle（用于用户取消等场景）
  void reset({String? reason}) {
    if (_currentState != SessionState.idle) {
      _history.add(StateTransition(
        from: _currentState,
        to: SessionState.idle,
        timestamp: DateTime.now(),
        reason: reason ?? '重置',
      ));
      _currentState = SessionState.idle;
      _stateEnteredAt = DateTime.now();
      _currentPlanId = null;
      onStateChange?.call(_currentState, SessionState.idle);
    }
  }

  /// 设置当前计划 ID
  void setPlanId(String planId) {
    _currentPlanId = planId;
  }

  /// 获取状态摘要（用于 System Prompt 注入）
  String get stateSummary {
    switch (_currentState) {
      case SessionState.idle:
        return '等待用户指令';
      case SessionState.routing:
        return '正在分析用户意图...';
      case SessionState.planning:
        return '正在制定执行计划...';
      case SessionState.executing:
        return '正在执行任务（计划: ${_currentPlanId ?? "无"}）...';
      case SessionState.evaluating:
        return '正在评估执行结果...';
      case SessionState.completed:
        return '任务已完成';
      case SessionState.failed:
        return '任务执行失败，等待用户指示';
    }
  }

  /// 生成状态历史摘要（用于调试或注入上下文）
  String get historySummary {
    if (_history.isEmpty) return '无状态转换记录';

    final buffer = StringBuffer();
    buffer.writeln('会话状态历史:');
    for (var i = 0; i < _history.length; i++) {
      final t = _history[i];
      final reason = t.reason != null ? ' (${t.reason})' : '';
      buffer.writeln(
          '  ${i + 1}. ${t.from.name} → ${t.to.name}$reason '
          '@ ${t.timestamp.toIso8601String()}');
    }
    return buffer.toString();
  }
}
