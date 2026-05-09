/// Agent 执行模式
/// 
/// 控制鹅宝如何响应用户请求：
/// - Craft: 立即执行，直接修改文件、运行命令
/// - Plan: 先制定计划，等用户确认后再执行
/// - Ask: 只回答问题，不执行任何操作
/// - Team: 多 Agent 协作模式，创建团队协作完成复杂任务
/// - CUA: Computer Use Agent，使用多模态模型操控电脑
enum AgentMode {
  /// Ask 模式（只回答，不操作）
  /// 只提供信息和建议，不修改文件或执行命令
  /// 适合：咨询问题、获取建议、学习知识
  ask,
  
  /// Craft 模式（你说话，我直接做）
  /// 立即执行任务，直接修改文件、运行命令
  /// 适合：明确知道要做什么，希望快速完成任务
  craft,
  
  /// Plan 模式（先思考，再执行）
  /// 分析需求，制定计划，等用户确认后再执行
  /// 适合：复杂任务，需要规划步骤
  plan,
  
  /// Team 模式（多 Agent 协作）
  /// 创建多个专业 Agent 组成团队，协作完成复杂任务
  /// 适合：需要多角色协作、并行处理、专业分工的场景
  team,

  /// CUA 模式（Computer Use Agent）
  /// 使用多模态模型作为主模型，通过截图感知屏幕，操控鼠标键盘
  /// 截图直接嵌入对话供主模型看图，无需额外视觉分析步骤
  cua,
}

/// Agent 模式扩展方法
extension AgentModeExtension on AgentMode {
  /// 模式显示名称
  String get displayName {
    switch (this) {
      case AgentMode.craft:
        return 'Craft';
      case AgentMode.plan:
        return 'Plan';
      case AgentMode.ask:
        return 'Ask';
      case AgentMode.team:
        return 'Team';
      case AgentMode.cua:
        return 'CUA';
    }
  }
  
  /// 模式描述
  String get description {
    switch (this) {
      case AgentMode.craft:
        return '你说话，我直接做';
      case AgentMode.plan:
        return '先思考，再执行';
      case AgentMode.ask:
        return '只回答，不操作';
      case AgentMode.team:
        return '多 Agent 协作';
      case AgentMode.cua:
        return '操控电脑';
    }
  }
  
  /// 模式图标
  String get icon {
    switch (this) {
      case AgentMode.craft:
        return '⚡';
      case AgentMode.plan:
        return '📋';
      case AgentMode.ask:
        return '💬';
      case AgentMode.team:
        return '👥';
      case AgentMode.cua:
        return '🖥️';
    }
  }
  
  /// 模式颜色（用于 UI 显示）
  String get colorHex {
    switch (this) {
      case AgentMode.craft:
        return '#4CAF50'; // 绿色 - 快速执行
      case AgentMode.plan:
        return '#2196F3'; // 蓝色 - 思考规划
      case AgentMode.ask:
        return '#9E9E9E'; // 灰色 - 轻量对话
      case AgentMode.team:
        return '#9C27B0'; // 紫色 - 团队协作
      case AgentMode.cua:
        return '#FF5722'; // 深橙色 - 电脑操控
    }
  }
  
  /// 是否允许执行工具
  bool get canExecuteTools {
    switch (this) {
      case AgentMode.craft:
        return true;
      case AgentMode.plan:
        return false; // 需要确认后才执行
      case AgentMode.ask:
        return false; // 不执行任何工具
      case AgentMode.team:
        return true; // Team 模式使用 spawn_agent_team 工具
      case AgentMode.cua:
        return true; // CUA 模式使用鼠标键盘操控
    }
  }
  
  /// 是否需要用户确认
  bool get requiresConfirmation {
    switch (this) {
      case AgentMode.craft:
        return false;
      case AgentMode.plan:
        return true;
      case AgentMode.ask:
        return false;
      case AgentMode.team:
        return false;
      case AgentMode.cua:
        return false;
    }
  }
  
  /// 从字符串解析
  static AgentMode? fromString(String value) {
    switch (value.toLowerCase()) {
      case 'craft':
        return AgentMode.craft;
      case 'plan':
        return AgentMode.plan;
      case 'ask':
        return AgentMode.ask;
      case 'team':
        return AgentMode.team;
      case 'cua':
        return AgentMode.cua;
      default:
        return null;
    }
  }
}

/// 计划步骤状态
enum PlanStepStatus {
  pending,   // 待执行
  running,   // 执行中
  completed, // 已完成
  failed,    // 失败
  skipped,   // 已跳过
}

/// 待确认的执行计划
class PendingPlan {
  /// 计划 ID
  final String id;
  
  /// 用户原始请求
  final String userRequest;
  
  /// 计划标题
  final String title;
  
  /// 计划步骤列表
  final List<PlanStep> steps;
  
  /// 创建时间
  final DateTime createdAt;
  
  /// 是否已被用户确认
  bool isConfirmed;
  
  /// 是否已被用户拒绝
  bool isRejected;

  /// 成功判定条件（来自 StructuredPlanner 的 successCriteria）
  final String? successCriteria;

  /// 预估 Token 消耗（来自 StructuredPlanner）
  final int estimatedTokens;

  /// 预估耗时（来自 StructuredPlanner）
  final Duration estimatedDuration;

  /// 步骤间共享的上下文（每步执行后更新，下一步可读取）
  final Map<String, dynamic> sharedContext = {};

  /// 重新规划次数（用于限制连续 replan）
  int replanCount = 0;

  /// 最大重新规划次数
  static const int maxReplanCount = 3;
  
  PendingPlan({
    required this.id,
    required this.userRequest,
    required this.title,
    required this.steps,
    DateTime? createdAt,
    this.isConfirmed = false,
    this.isRejected = false,
    this.successCriteria,
    this.estimatedTokens = 0,
    this.estimatedDuration = Duration.zero,
  }) : createdAt = createdAt ?? DateTime.now();
  
  /// 获取待执行的步骤
  List<PlanStep> get pendingSteps => steps.where((s) => s.status == PlanStepStatus.pending).toList();
  
  /// 是否所有步骤都已执行
  bool get isCompleted => steps.every((s) => 
      s.status == PlanStepStatus.completed || s.status == PlanStepStatus.skipped);
  
  /// 获取进度
  double get progress {
    if (steps.isEmpty) return 1.0;
    final completed = steps.where((s) => 
        s.status == PlanStepStatus.completed || s.status == PlanStepStatus.skipped).length;
    return completed / steps.length;
  }

  /// 获取下一批可执行的步骤（DAG 调度：所有依赖已完成的步骤）
  List<PlanStep> getNextExecutableSteps() {
    return steps.where((step) {
      if (step.status != PlanStepStatus.pending) return false;
      // 所有依赖都已成功完成
      return step.dependsOn.every((depId) {
        final dep = steps.where((s) => s.id == depId).firstOrNull;
        return dep != null && dep.status == PlanStepStatus.completed;
      });
    }).toList();
  }

  /// 是否还能继续重新规划
  bool get canReplan => replanCount < maxReplanCount;

  /// 获取已完成步骤的上下文摘要（用于传递给后续步骤）
  String getCompletedStepsContext() {
    final completed = steps.where((s) => s.status == PlanStepStatus.completed).toList();
    if (completed.isEmpty) return '';
    
    return completed.map((s) {
      final resultSummary = s.result != null
          ? (s.result!.length > 300 ? '${s.result!.substring(0, 300)}...' : s.result!)
          : '完成';
      return '✅ 步骤${s.order} [${s.description}]: $resultSummary';
    }).join('\n');
  }
}

/// 计划中的单个步骤
class PlanStep {
  /// 步骤 ID
  final String id;
  
  /// 步骤序号（1-based）
  final int order;
  
  /// 步骤描述
  final String description;
  
  /// 涉及的工具
  final String? toolName;
  
  /// 工具参数
  final Map<String, dynamic>? toolArgs;
  
  /// 步骤状态
  PlanStepStatus status;
  
  /// 执行结果
  String? result;
  
  /// 错误信息
  String? error;

  /// 依赖的步骤 ID 列表（DAG 依赖关系）
  final List<String> dependsOn;

  /// 步骤重要程度：high=失败必须停止, medium=可重试, low=可跳过
  final String criticality;

  /// 是否可重试
  final bool canRetry;

  /// 最大重试次数
  final int maxRetries;

  /// 当前重试次数
  int retryCount = 0;

  /// 预期输出描述（用于评估是否成功）
  final String? expectedOutput;

  /// 步骤执行时长
  Duration? executionDuration;
  
  PlanStep({
    required this.id,
    required this.order,
    required this.description,
    this.toolName,
    this.toolArgs,
    PlanStepStatus? status,
    this.result,
    this.error,
    this.dependsOn = const [],
    this.criticality = 'medium',
    this.canRetry = true,
    this.maxRetries = 2,
    this.expectedOutput,
  }) : status = status ?? PlanStepStatus.pending;
  
  /// 兼容旧代码
  bool get isExecuted => status == PlanStepStatus.completed;
  bool get isSkipped => status == PlanStepStatus.skipped;
  bool get isFailed => status == PlanStepStatus.failed;

  /// 是否还能重试
  bool get canRetryNow => canRetry && retryCount < maxRetries;

  /// 是否为低优先级（失败可跳过）
  bool get isLowPriority => criticality == 'low';

  /// 是否为高优先级（失败必须停止）
  bool get isHighPriority => criticality == 'high';
  
  /// 标记为运行中
  void start() => status = PlanStepStatus.running;
  
  /// 标记为完成
  void complete(String? result) {
    this.result = result;
    status = PlanStepStatus.completed;
  }
  
  /// 标记为失败
  void fail(String error) {
    this.error = error;
    status = PlanStepStatus.failed;
  }

  /// 标记为失败并增加重试计数
  void failWithRetry(String error) {
    this.error = error;
    retryCount++;
    status = PlanStepStatus.failed;
  }

  /// 重置为待执行（用于重试）
  void resetForRetry() {
    status = PlanStepStatus.pending;
    result = null;
    error = null;
  }
  
  /// 标记为跳过
  void skip() => status = PlanStepStatus.skipped;
  
  /// 转换为 ToolCall（如果包含工具信息）
  Map<String, dynamic>? toToolCall() {
    if (toolName == null || toolArgs == null) return null;
    return {
      'name': toolName,
      'arguments': toolArgs,
    };
  }
}
