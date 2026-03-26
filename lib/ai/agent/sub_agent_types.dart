/// Sub-Agent 和 Agent Teams 类型定义
/// 
/// Sub-Agent: 主 Agent spawn 的子智能体，拥有独立的上下文窗口和工具集
/// Agent Teams: 多个 Agent 协作完成复杂任务

import 'agent_types.dart';

/// 子 Agent 配置
class SubAgentConfig {
  /// 子 Agent 唯一 ID
  final String id;
  
  /// 任务描述
  final String task;
  
  /// 允许使用的工具列表（为空则继承父 Agent）
  final List<String>? allowedTools;
  
  /// 最大轮数
  final int maxTurns;
  
  /// 是否需要结果摘要
  final bool needSummary;
  
  /// 传递给子 Agent 的上下文信息
  final String? context;
  
  /// 子 Agent 的角色描述（可选）
  final String? role;
  
  const SubAgentConfig({
    required this.id,
    required this.task,
    this.allowedTools,
    this.maxTurns = 10,
    this.needSummary = true,
    this.context,
    this.role,
  });
  
  Map<String, dynamic> toJson() => {
    'id': id,
    'task': task,
    'allowedTools': allowedTools,
    'maxTurns': maxTurns,
    'needSummary': needSummary,
    'context': context,
    'role': role,
  };
}

/// 子 Agent 执行结果
class SubAgentResult {
  /// 子 Agent ID
  final String id;
  
  /// 是否成功完成
  final bool success;
  
  /// 结果内容
  final String result;
  
  /// 消耗的轮数
  final int turnsUsed;
  
  /// 执行步骤
  final List<ToolStep> steps;
  
  /// 结果摘要（如果配置了 needSummary）
  final String? summary;
  
  /// 错误信息（如果失败）
  final String? error;
  
  const SubAgentResult({
    required this.id,
    required this.success,
    required this.result,
    required this.turnsUsed,
    required this.steps,
    this.summary,
    this.error,
  });
  
  Map<String, dynamic> toJson() => {
    'id': id,
    'success': success,
    'result': result,
    'turnsUsed': turnsUsed,
    'stepsCount': steps.length,
    'summary': summary,
    'error': error,
  };
}

/// Agent Teams 协作配置
class AgentTeamConfig {
  /// 团队唯一标识
  final String teamId;
  
  /// 团队名称
  final String teamName;
  
  /// 团队成员
  final List<TeamAgent> agents;
  
  /// 最大并发数
  final int maxConcurrency;
  
  /// 协作模式
  final TeamCollaborationMode mode;
  
  const AgentTeamConfig({
    required this.teamId,
    required this.teamName,
    required this.agents,
    this.maxConcurrency = 3,
    this.mode = TeamCollaborationMode.sequential,
  });
}

/// 团队协作模式
enum TeamCollaborationMode {
  /// 顺序执行：按顺序依次执行
  sequential,
  
  /// 并行执行：多个 Agent 同时执行独立任务
  parallel,
  
  /// 层级协作：主 Agent 分配任务，子 Agent 执行并汇报
  hierarchical,
  
  /// 投票决策：多个 Agent 提出方案，投票决定
  voting,
}

/// 团队成员 Agent 定义
class TeamAgent {
  /// Agent 唯一标识
  final String id;
  
  /// 显示名称
  final String name;
  
  /// 角色描述
  final String role;
  
  /// 系统提示词
  final String systemPrompt;
  
  /// 允许使用的工具列表
  final List<String> allowedTools;
  
  /// 优先级（数值越小越先执行）
  final int priority;
  
  const TeamAgent({
    required this.id,
    required this.name,
    required this.role,
    required this.systemPrompt,
    this.allowedTools = const [],
    this.priority = 100,
  });
  
  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'role': role,
    'systemPrompt': systemPrompt,
    'allowedTools': allowedTools,
    'priority': priority,
  };
  
  factory TeamAgent.fromJson(Map<String, dynamic> json) => TeamAgent(
    id: json['id'] as String,
    name: json['name'] as String,
    role: json['role'] as String,
    systemPrompt: json['systemPrompt'] as String,
    allowedTools: (json['allowedTools'] as List<dynamic>?)?.cast<String>() ?? [],
    priority: json['priority'] as int? ?? 100,
  );
}

/// 共享任务队列
class SharedTaskQueue {
  final List<TeamTask> pending = [];
  final List<TeamTask> inProgress = [];
  final List<TeamTask> completed = [];
  
  void add(TeamTask task) => pending.add(task);
  
  TeamTask? pop() => pending.isEmpty ? null : pending.removeAt(0);
  
  void markInProgress(TeamTask task) {
    pending.remove(task);
    inProgress.add(task);
  }
  
  void markCompleted(TeamTask task, String result) {
    inProgress.remove(task);
    task.result = result;
    task.completedAt = DateTime.now();
    completed.add(task);
  }
  
  void markFailed(TeamTask task, String error) {
    inProgress.remove(task);
    task.error = error;
    completed.add(task);
  }
  
  int get totalTasks => pending.length + inProgress.length + completed.length;
  int get completedCount => completed.length;
  int get pendingCount => pending.length;
  int get inProgressCount => inProgress.length;
}

/// 任务执行模式
enum TaskExecutionMode {
  /// 自动：根据依赖关系自动判断串行或并行
  auto,
  
  /// 串行：必须等待前序任务完成
  sequential,
  
  /// 并行：可与其他并行任务同时执行
  parallel,
}

/// 任务状态
enum TaskStatus {
  pending,
  waiting,    // 等待依赖完成
  ready,      // 准备执行
  running,
  completed,
  failed,
}

/// 团队任务
class TeamTask {
  /// 任务 ID
  final String id;
  
  /// 任务描述
  final String description;
  
  /// 分配给的 Agent ID（可选）
  String? assignedTo;
  
  /// 执行结果
  String? result;
  
  /// 错误信息
  String? error;
  
  /// 创建时间
  final DateTime createdAt;
  
  /// 开始时间
  DateTime? startedAt;
  
  /// 完成时间
  DateTime? completedAt;
  
  /// 依赖的任务 ID 列表
  final List<String> dependencies;
  
  /// 执行模式
  final TaskExecutionMode executionMode;
  
  /// 任务状态
  TaskStatus status;
  
  /// 任务组 ID（同组任务按组模式执行）
  String? groupId;
  
  /// 优先级（数值越小越优先）
  final int priority;
  
  /// 预估执行时间（秒）
  final int? estimatedDuration;
  
  /// 重试次数
  int retryCount = 0;
  
  /// 最大重试次数
  final int maxRetries;
  
  TeamTask({
    required this.id,
    required this.description,
    this.assignedTo,
    this.dependencies = const [],
    this.executionMode = TaskExecutionMode.auto,
    this.status = TaskStatus.pending,
    this.groupId,
    this.priority = 100,
    this.estimatedDuration,
    this.maxRetries = 2,
  }) : createdAt = DateTime.now();
  
  bool get isCompleted => status == TaskStatus.completed;
  bool get isFailed => status == TaskStatus.failed;
  bool get isRunning => status == TaskStatus.running;
  bool get canRetry => retryCount < maxRetries;
  
  /// 检查依赖是否全部完成
  bool canExecute(Set<String> completedTaskIds) {
    return dependencies.every((dep) => completedTaskIds.contains(dep));
  }
  
  /// 标记为运行中
  void start() {
    status = TaskStatus.running;
    startedAt = DateTime.now();
  }
  
  /// 标记为完成
  void complete(String result) {
    this.result = result;
    status = TaskStatus.completed;
    completedAt = DateTime.now();
  }
  
  /// 标记为失败
  void fail(String error) {
    this.error = error;
    status = TaskStatus.failed;
    completedAt = DateTime.now();
  }
  
  /// 重置任务状态（用于重试）
  void reset() {
    status = TaskStatus.pending;
    retryCount++;
    result = null;
    error = null;
    startedAt = null;
    completedAt = null;
  }
  
  Map<String, dynamic> toJson() => {
    'id': id,
    'description': description,
    'assignedTo': assignedTo,
    'result': result,
    'error': error,
    'createdAt': createdAt.toIso8601String(),
    'startedAt': startedAt?.toIso8601String(),
    'completedAt': completedAt?.toIso8601String(),
    'dependencies': dependencies,
    'executionMode': executionMode.name,
    'status': status.name,
    'groupId': groupId,
    'priority': priority,
    'retryCount': retryCount,
  };
  
  /// 复制并修改
  TeamTask copyWith({
    String? id,
    String? description,
    String? assignedTo,
    List<String>? dependencies,
    TaskExecutionMode? executionMode,
    TaskStatus? status,
    String? groupId,
    int? priority,
  }) {
    return TeamTask(
      id: id ?? this.id,
      description: description ?? this.description,
      assignedTo: assignedTo ?? this.assignedTo,
      dependencies: dependencies ?? this.dependencies,
      executionMode: executionMode ?? this.executionMode,
      status: status ?? this.status,
      groupId: groupId ?? this.groupId,
      priority: priority ?? this.priority,
      estimatedDuration: estimatedDuration,
      maxRetries: maxRetries,
    );
  }
}

/// 任务编排计划
class TaskOrchestrationPlan {
  /// 所有任务
  final List<TeamTask> tasks;
  
  /// 执行阶段（每个阶段包含可并行执行的任务）
  final List<List<TeamTask>> stages;
  
  /// 最大并行度
  final int maxParallelism;
  
  /// 预估总时间（秒）
  final int estimatedTotalTime;
  
  TaskOrchestrationPlan({
    required this.tasks,
    required this.stages,
    this.maxParallelism = 3,
    this.estimatedTotalTime = 0,
  });
  
  /// 获取下一阶段可执行的任务
  List<TeamTask> getNextExecutableTasks(Set<String> completedTaskIds, int currentRunningCount) {
    final result = <TeamTask>[];
    
    for (final task in tasks) {
      if (task.status == TaskStatus.pending && 
          task.canExecute(completedTaskIds)) {
        if (task.executionMode == TaskExecutionMode.parallel) {
          // 并行任务，只要不超过并发限制就加入
          if (currentRunningCount + result.length < maxParallelism) {
            result.add(task);
          }
        } else {
          // 串行或自动模式，一次只加一个
          if (result.isEmpty || result.every((t) => t.executionMode == TaskExecutionMode.sequential)) {
            result.add(task);
          }
        }
      }
    }
    
    return result;
  }
  
  /// 获取执行进度
  double get progress {
    if (tasks.isEmpty) return 1.0;
    final completed = tasks.where((t) => t.isCompleted).length;
    return completed / tasks.length;
  }
  
  Map<String, dynamic> toJson() => {
    'tasks': tasks.map((t) => t.toJson()).toList(),
    'stages': stages.map((stage) => stage.map((t) => t.id).toList()).toList(),
    'maxParallelism': maxParallelism,
    'estimatedTotalTime': estimatedTotalTime,
    'progress': progress,
  };
}

/// Sub-Agent 执行上下文
class SubAgentContext {
  /// 父 Agent ID
  final String parentAgentId;
  
  /// 嵌套深度（0 表示顶层 Agent）
  final int depth;
  
  /// 最大允许嵌套深度
  static const int maxDepth = 3;
  
  /// 工具调用计数
  int toolCallCount = 0;
  
  /// 最大工具调用次数
  final int maxToolCalls;
  
  SubAgentContext({
    required this.parentAgentId,
    this.depth = 0,
    this.maxToolCalls = 50,
  });
  
  /// 检查是否可以创建更深层级的 Sub-Agent
  bool get canSpawnSubAgent => depth < maxDepth;
  
  /// 创建子级上下文
  SubAgentContext spawnChild(String newParentId) {
    return SubAgentContext(
      parentAgentId: newParentId,
      depth: depth + 1,
      maxToolCalls: maxToolCalls,
    );
  }
}

/// 团队消息类型
enum TeamMessageType {
  /// 广播消息 - 发送给所有人
  broadcast,
  
  /// 定向消息 - 发送给特定 Agent
  direct,
  
  /// 任务结果 - 任务完成后的结果报告
  taskResult,
  
  /// 状态更新 - Agent 状态变化通知
  statusUpdate,
}

/// 团队消息
class TeamMessage {
  /// 消息 ID
  final String id;
  
  /// 发送者 Agent ID
  final String fromAgentId;
  
  /// 发送者名称
  final String fromAgentName;
  
  /// 消息类型
  final TeamMessageType type;
  
  /// 接收者 Agent ID 列表（广播时为空，定向时指定）
  final List<String> toAgentIds;
  
  /// 消息内容
  final String content;
  
  /// 发送时间
  final DateTime timestamp;
  
  /// 关联的任务 ID（可选）
  final String? taskId;
  
  TeamMessage({
    required this.id,
    required this.fromAgentId,
    required this.fromAgentName,
    required this.type,
    required this.toAgentIds,
    required this.content,
    String? taskId,
    DateTime? timestamp,
  }) : taskId = taskId,
       timestamp = timestamp ?? DateTime.now();
  
  /// 是否为广播消息
  bool get isBroadcast => type == TeamMessageType.broadcast || toAgentIds.isEmpty;
  
  /// 格式化显示内容（带 @ 提及）
  String get formattedContent {
    if (isBroadcast) {
      return '@所有人 $content';
    } else if (toAgentIds.isNotEmpty) {
      return '@${toAgentIds.join(' @')} $content';
    }
    return content;
  }
  
  Map<String, dynamic> toJson() => {
    'id': id,
    'fromAgentId': fromAgentId,
    'fromAgentName': fromAgentName,
    'type': type.name,
    'toAgentIds': toAgentIds,
    'content': content,
    'timestamp': timestamp.toIso8601String(),
    'taskId': taskId,
  };
  
  factory TeamMessage.fromJson(Map<String, dynamic> json) {
    return TeamMessage(
      id: json['id'] as String,
      fromAgentId: json['fromAgentId'] as String,
      fromAgentName: json['fromAgentName'] as String,
      type: TeamMessageType.values.byName(json['type'] as String),
      toAgentIds: (json['toAgentIds'] as List?)?.cast<String>() ?? [],
      content: json['content'] as String,
      taskId: json['taskId'] as String?,
      timestamp: json['timestamp'] != null 
          ? DateTime.parse(json['timestamp'] as String) 
          : null,
    );
  }
}

/// 团队消息板（共享消息存储）
class TeamMessageBoard {
  /// 所有消息
  final List<TeamMessage> messages = [];
  
  /// 添加消息
  void add(TeamMessage message) {
    messages.add(message);
  }
  
  /// 获取某个 Agent 收到的所有消息
  List<TeamMessage> getMessagesForAgent(String agentId) {
    return messages.where((m) => 
      m.isBroadcast || m.toAgentIds.contains(agentId)
    ).toList();
  }
  
  /// 获取某个 Agent 发送的所有消息
  List<TeamMessage> getMessagesFromAgent(String agentId) {
    return messages.where((m) => m.fromAgentId == agentId).toList();
  }
  
  /// 获取未读消息（某个时间点之后的）
  List<TeamMessage> getUnreadMessages(String agentId, DateTime after) {
    return getMessagesForAgent(agentId)
        .where((m) => m.timestamp.isAfter(after))
        .toList();
  }
  
  /// 清空消息板
  void clear() {
    messages.clear();
  }
  
  Map<String, dynamic> toJson() => {
    'messages': messages.map((m) => m.toJson()).toList(),
  };
}
