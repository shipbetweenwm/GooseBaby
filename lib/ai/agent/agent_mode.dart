/// Agent 执行模式
/// 
/// 控制鹅宝如何响应用户请求：
/// - Craft: 立即执行，直接修改文件、运行命令
/// - Plan: 先制定计划，等用户确认后再执行
/// - Ask: 只回答问题，不执行任何操作
/// - Team: 多 Agent 协作模式，创建团队协作完成复杂任务
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
  
  PendingPlan({
    required this.id,
    required this.userRequest,
    required this.title,
    required this.steps,
    DateTime? createdAt,
    this.isConfirmed = false,
    this.isRejected = false,
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
  
  PlanStep({
    required this.id,
    required this.order,
    required this.description,
    this.toolName,
    this.toolArgs,
    PlanStepStatus? status,
    this.result,
    this.error,
  }) : status = status ?? PlanStepStatus.pending;
  
  /// 兼容旧代码
  bool get isExecuted => status == PlanStepStatus.completed;
  bool get isSkipped => status == PlanStepStatus.skipped;
  bool get isFailed => status == PlanStepStatus.failed;
  
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
