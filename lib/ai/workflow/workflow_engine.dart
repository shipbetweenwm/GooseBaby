/// 确定性工作流引擎（模块 2）
///
/// 将 AgentLoop 中的自由工具调用序列升级为结构化 DAG 工作流。
///
/// 核心能力：
/// 1. WorkflowNode: DAG 节点（7 种类型）
/// 2. WorkflowEngine: 拓扑排序执行 + 并行批次 + 重试策略
/// 3. WorkflowBuilder: 流式构建工作流 DAG
/// 4. WorkflowTemplates: 预定义常用工作流模板
///
/// 与 StructuredPlanner 的协作：
/// - Planner 生成 ExecutionPlan（逻辑计划）
/// - WorkflowEngine 执行 Workflow（物理执行）
/// - ExecutionPlan 的每个 Step 可映射为 WorkflowNode
library;
import 'dart:async';
import 'package:flutter/foundation.dart';
import '../config/agent_config.dart';

// ═══════════════════════════════════════════
// 工作流节点类型
// ═══════════════════════════════════════════

/// 工作流节点类型
enum NodeType {
  /// LLM 调用节点
  llmCall,

  /// 工具调用节点
  toolCall,

  /// 条件分支节点
  decision,

  /// 并行执行组
  parallel,

  /// 人工审批节点
  humanReview,

  /// 子工作流节点
  subWorkflow,

  /// 数据转换节点
  transform,
}

/// 工作流节点状态
enum NodeStatus {
  pending,
  running,
  completed,
  failed,
  skipped,
  cancelled,
}

// ═══════════════════════════════════════════
// 工作流节点
// ═══════════════════════════════════════════

/// 重试策略
class RetryPolicy {
  final int maxRetries;
  final Duration initialDelay;
  final double backoffMultiplier;
  final Duration maxDelay;

  const RetryPolicy({
    this.maxRetries = 2,
    this.initialDelay = const Duration(seconds: 1),
    this.backoffMultiplier = 2.0,
    this.maxDelay = const Duration(seconds: 30),
  });

  /// 不重试
  static const none = RetryPolicy(maxRetries: 0);

  /// 计算第 n 次重试的延迟
  Duration getDelay(int attempt) {
    final delay = initialDelay * (backoffMultiplier * attempt);
    return delay > maxDelay ? maxDelay : delay;
  }
}

/// 工作流节点定义
class WorkflowNode {
  final String id;
  final String name;
  final NodeType type;
  final List<String> dependsOn;
  final Map<String, dynamic> config;
  final RetryPolicy retryPolicy;
  final Duration? timeout;
  final String? condition; // 用于 decision 节点

  /// 节点执行逻辑（由外部注入）
  final Future<NodeResult> Function(
      WorkflowNode node, Map<String, dynamic> context)? executor;

  /// 运行时状态
  NodeStatus status = NodeStatus.pending;
  NodeResult? result;
  int retryCount = 0;
  DateTime? startTime;
  DateTime? endTime;

  WorkflowNode({
    required this.id,
    required this.name,
    required this.type,
    this.dependsOn = const [],
    this.config = const {},
    this.retryPolicy = const RetryPolicy(),
    this.timeout,
    this.condition,
    this.executor,
  });

  /// 执行时长
  Duration? get duration =>
      startTime != null && endTime != null
          ? endTime!.difference(startTime!)
          : null;

  @override
  String toString() => 'WorkflowNode($id: $name [$status])';
}

/// 节点执行结果
class NodeResult {
  final bool isSuccess;
  final dynamic output;
  final String? error;
  final Map<String, dynamic> metadata;

  const NodeResult({
    required this.isSuccess,
    this.output,
    this.error,
    this.metadata = const {},
  });

  factory NodeResult.success(dynamic output,
          {Map<String, dynamic> metadata = const {}}) =>
      NodeResult(isSuccess: true, output: output, metadata: metadata);

  factory NodeResult.failure(String error,
          {Map<String, dynamic> metadata = const {}}) =>
      NodeResult(isSuccess: false, error: error, metadata: metadata);
}

// ═══════════════════════════════════════════
// 工作流定义
// ═══════════════════════════════════════════

/// 工作流定义
class Workflow {
  final String id;
  final String name;
  final String? description;
  final List<WorkflowNode> nodes;
  final Map<String, dynamic> globalContext;
  final DateTime createdAt;

  Workflow({
    required this.id,
    required this.name,
    this.description,
    required this.nodes,
    this.globalContext = const {},
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  /// 获取入口节点（无依赖的节点）
  List<WorkflowNode> get entryNodes =>
      nodes.where((n) => n.dependsOn.isEmpty).toList();

  /// 获取节点 by ID
  WorkflowNode? getNode(String id) {
    try {
      return nodes.firstWhere((n) => n.id == id);
    } catch (_) {
      return null;
    }
  }

  /// 进度（0.0 ~ 1.0）
  double get progress {
    if (nodes.isEmpty) return 1.0;
    final completed = nodes
        .where((n) =>
            n.status == NodeStatus.completed ||
            n.status == NodeStatus.skipped)
        .length;
    return completed / nodes.length;
  }

  /// 是否全部完成
  bool get isComplete => nodes.every((n) =>
      n.status == NodeStatus.completed ||
      n.status == NodeStatus.skipped ||
      n.status == NodeStatus.cancelled);

  /// 是否有失败节点
  bool get hasFailed => nodes.any((n) => n.status == NodeStatus.failed);
}

/// 工作流执行报告
class WorkflowReport {
  final String workflowId;
  final String workflowName;
  final bool isSuccess;
  final Duration totalDuration;
  final int totalNodes;
  final int completedNodes;
  final int failedNodes;
  final int skippedNodes;
  final List<String> errors;
  final Map<String, NodeResult> nodeResults;

  const WorkflowReport({
    required this.workflowId,
    required this.workflowName,
    required this.isSuccess,
    required this.totalDuration,
    required this.totalNodes,
    required this.completedNodes,
    required this.failedNodes,
    required this.skippedNodes,
    required this.errors,
    required this.nodeResults,
  });

  @override
  String toString() =>
      'WorkflowReport($workflowName: ${isSuccess ? "✅" : "❌"} '
      '$completedNodes/$totalNodes completed, '
      '${totalDuration.inSeconds}s)';
}

// ═══════════════════════════════════════════
// 工作流引擎
// ═══════════════════════════════════════════

/// 工作流执行引擎
///
/// 核心执行策略：
/// 1. 拓扑排序，确保依赖关系正确
/// 2. 同一批次的节点并行执行
/// 3. 失败节点按 RetryPolicy 重试
/// 4. Decision 节点根据条件选择分支
class WorkflowEngine {
  /// 执行回调
  final void Function(WorkflowNode node, NodeStatus status)? onNodeStatusChange;

  /// 默认节点执行器（当节点无自定义 executor 时使用）
  final Future<NodeResult> Function(
      WorkflowNode node, Map<String, dynamic> context)? defaultExecutor;

  WorkflowEngine({
    this.onNodeStatusChange,
    this.defaultExecutor,
  });

  /// 执行工作流
  Future<WorkflowReport> execute(Workflow workflow) async {
    final stopwatch = Stopwatch()..start();
    final context = Map<String, dynamic>.from(workflow.globalContext);
    final nodeResults = <String, NodeResult>{};
    final errors = <String>[];

    debugPrint('🔄 [Workflow] 开始执行: ${workflow.name} '
        '(${workflow.nodes.length} 个节点)');

    // 循环执行，直到所有节点都处理完毕
    var iteration = 0;
    final maxIterations = workflow.nodes.length * 3; // 防止死循环

    while (!workflow.isComplete && iteration < maxIterations) {
      iteration++;

      // 1. 找到当前可执行的节点批次
      final executableBatch = _getExecutableBatch(workflow);
      if (executableBatch.isEmpty) {
        // 检查是否有阻塞（所有未完成节点的依赖都未满足）
        final pendingNodes =
            workflow.nodes.where((n) => n.status == NodeStatus.pending);
        if (pendingNodes.isNotEmpty) {
          debugPrint('⚠️ [Workflow] 检测到阻塞，跳过被阻塞的节点');
          for (final node in pendingNodes) {
            _updateNodeStatus(node, NodeStatus.skipped);
          }
        }
        break;
      }

      // 2. 并行执行这一批次
      debugPrint('🔄 [Workflow] 批次 $iteration: '
          '${executableBatch.map((n) => n.name).join(", ")}');

      final futures = executableBatch.map((node) async {
        return await _executeNode(node, context, workflow);
      });

      final batchResults = await Future.wait(futures);

      // 3. 处理结果
      for (var i = 0; i < executableBatch.length; i++) {
        final node = executableBatch[i];
        final result = batchResults[i];
        nodeResults[node.id] = result;

        // 将结果放入上下文供后续节点使用
        context['result_${node.id}'] = result.output;
        context['status_${node.id}'] = result.isSuccess;

        if (!result.isSuccess) {
          errors.add('${node.name}: ${result.error}');
        }
      }
    }

    stopwatch.stop();

    final report = WorkflowReport(
      workflowId: workflow.id,
      workflowName: workflow.name,
      isSuccess: !workflow.hasFailed,
      totalDuration: stopwatch.elapsed,
      totalNodes: workflow.nodes.length,
      completedNodes:
          workflow.nodes.where((n) => n.status == NodeStatus.completed).length,
      failedNodes:
          workflow.nodes.where((n) => n.status == NodeStatus.failed).length,
      skippedNodes:
          workflow.nodes.where((n) => n.status == NodeStatus.skipped).length,
      errors: errors,
      nodeResults: nodeResults,
    );

    debugPrint('🔄 [Workflow] 执行完成: $report');
    return report;
  }

  /// 获取当前可执行的节点批次
  List<WorkflowNode> _getExecutableBatch(Workflow workflow) {
    return workflow.nodes.where((node) {
      if (node.status != NodeStatus.pending) return false;

      // 检查所有依赖是否已完成
      return node.dependsOn.every((depId) {
        final depNode = workflow.getNode(depId);
        if (depNode == null) return true; // 依赖不存在视为已满足
        return depNode.status == NodeStatus.completed ||
            depNode.status == NodeStatus.skipped;
      });
    }).toList();
  }

  /// 执行单个节点（含重试）
  Future<NodeResult> _executeNode(
    WorkflowNode node,
    Map<String, dynamic> context,
    Workflow workflow,
  ) async {
    _updateNodeStatus(node, NodeStatus.running);
    node.startTime = DateTime.now();

    // Decision 节点特殊处理
    if (node.type == NodeType.decision) {
      return _executeDecisionNode(node, context, workflow);
    }

    // 普通节点执行（含重试）
    NodeResult? lastResult;
    for (var attempt = 0; attempt <= node.retryPolicy.maxRetries; attempt++) {
      if (attempt > 0) {
        final delay = node.retryPolicy.getDelay(attempt);
        debugPrint('🔄 [Workflow] ${node.name} 第 $attempt 次重试 '
            '(延迟 ${delay.inMilliseconds}ms)');
        await Future.delayed(delay);
        node.retryCount = attempt;
      }

      try {
        final executor = node.executor ?? defaultExecutor;
        if (executor == null) {
          lastResult = NodeResult.failure('节点无执行器');
          break;
        }

        // 超时控制
        final timeoutDuration =
            node.timeout ?? Duration(seconds: AgentConfig().toolTimeoutSeconds);

        lastResult = await executor(node, context).timeout(
          timeoutDuration,
          onTimeout: () =>
              NodeResult.failure('执行超时 (${timeoutDuration.inSeconds}s)'),
        );

        if (lastResult.isSuccess) break;
      } catch (e) {
        lastResult = NodeResult.failure(e.toString());
      }
    }

    node.endTime = DateTime.now();
    node.result = lastResult;

    if (lastResult?.isSuccess == true) {
      _updateNodeStatus(node, NodeStatus.completed);
    } else {
      _updateNodeStatus(node, NodeStatus.failed);
    }

    return lastResult ?? NodeResult.failure('未知错误');
  }

  /// 执行条件分支节点
  Future<NodeResult> _executeDecisionNode(
    WorkflowNode node,
    Map<String, dynamic> context,
    Workflow workflow,
  ) async {
    final condition = node.condition ?? '';
    bool conditionMet = false;

    // 简单条件评估：检查上下文中的值
    if (condition.startsWith('context.')) {
      final key = condition.substring('context.'.length);
      conditionMet = context[key] == true;
    } else if (condition.startsWith('status_')) {
      conditionMet = context[condition] == true;
    } else {
      // 默认使用上一步的执行结果
      conditionMet = context[condition] as bool? ?? true;
    }

    node.endTime = DateTime.now();
    node.result = NodeResult.success(conditionMet);
    _updateNodeStatus(node, NodeStatus.completed);

    // 将条件结果放入上下文
    context['decision_${node.id}'] = conditionMet;

    return NodeResult.success(conditionMet, metadata: {
      'condition': condition,
      'result': conditionMet,
    });
  }

  /// 更新节点状态
  void _updateNodeStatus(WorkflowNode node, NodeStatus status) {
    node.status = status;
    onNodeStatusChange?.call(node, status);
  }
}

// ═══════════════════════════════════════════
// 工作流构建器
// ═══════════════════════════════════════════

/// 工作流构建器（流式 API）
class WorkflowBuilder {
  final String _id;
  final String _name;
  String? _description;
  final List<WorkflowNode> _nodes = [];
  final Map<String, dynamic> _globalContext = {};

  WorkflowBuilder(this._id, this._name);

  /// 设置描述
  WorkflowBuilder describe(String description) {
    _description = description;
    return this;
  }

  /// 设置全局上下文
  WorkflowBuilder withContext(Map<String, dynamic> context) {
    _globalContext.addAll(context);
    return this;
  }

  /// 添加工具调用节点
  WorkflowBuilder addToolCall({
    required String id,
    required String name,
    List<String> dependsOn = const [],
    Map<String, dynamic> config = const {},
    RetryPolicy retryPolicy = const RetryPolicy(),
    Duration? timeout,
    Future<NodeResult> Function(
            WorkflowNode node, Map<String, dynamic> context)?
        executor,
  }) {
    _nodes.add(WorkflowNode(
      id: id,
      name: name,
      type: NodeType.toolCall,
      dependsOn: dependsOn,
      config: config,
      retryPolicy: retryPolicy,
      timeout: timeout,
      executor: executor,
    ));
    return this;
  }

  /// 添加 LLM 调用节点
  WorkflowBuilder addLLMCall({
    required String id,
    required String name,
    List<String> dependsOn = const [],
    Map<String, dynamic> config = const {},
    Future<NodeResult> Function(
            WorkflowNode node, Map<String, dynamic> context)?
        executor,
  }) {
    _nodes.add(WorkflowNode(
      id: id,
      name: name,
      type: NodeType.llmCall,
      dependsOn: dependsOn,
      config: config,
      executor: executor,
    ));
    return this;
  }

  /// 添加条件分支节点
  WorkflowBuilder addDecision({
    required String id,
    required String name,
    required String condition,
    List<String> dependsOn = const [],
  }) {
    _nodes.add(WorkflowNode(
      id: id,
      name: name,
      type: NodeType.decision,
      dependsOn: dependsOn,
      condition: condition,
    ));
    return this;
  }

  /// 添加数据转换节点
  WorkflowBuilder addTransform({
    required String id,
    required String name,
    List<String> dependsOn = const [],
    Future<NodeResult> Function(
            WorkflowNode node, Map<String, dynamic> context)?
        executor,
  }) {
    _nodes.add(WorkflowNode(
      id: id,
      name: name,
      type: NodeType.transform,
      dependsOn: dependsOn,
      executor: executor,
    ));
    return this;
  }

  /// 构建工作流
  Workflow build() {
    // 验证节点依赖
    final nodeIds = _nodes.map((n) => n.id).toSet();
    for (final node in _nodes) {
      for (final dep in node.dependsOn) {
        if (!nodeIds.contains(dep)) {
          debugPrint('⚠️ [WorkflowBuilder] 节点 ${node.id} 依赖不存在的节点 $dep');
        }
      }
    }

    return Workflow(
      id: _id,
      name: _name,
      description: _description,
      nodes: _nodes,
      globalContext: _globalContext,
    );
  }
}

// ═══════════════════════════════════════════
// 预定义工作流模板
// ═══════════════════════════════════════════

/// 常用工作流模板
class WorkflowTemplates {
  /// 文件修改工作流：读取 → 分析 → 修改 → 验证
  static Workflow fileModification({
    required String filePath,
    required String modification,
    Future<NodeResult> Function(
            WorkflowNode node, Map<String, dynamic> context)?
        toolExecutor,
  }) {
    return WorkflowBuilder(
      'wf_file_mod_${DateTime.now().millisecondsSinceEpoch}',
      '文件修改: $filePath',
    )
        .describe('读取、分析、修改、验证文件')
        .withContext({
          'filePath': filePath,
          'modification': modification,
        })
        .addToolCall(
          id: 'read',
          name: '读取文件',
          config: {'tool': 'read_file', 'args': {'filePath': filePath}},
          executor: toolExecutor,
        )
        .addLLMCall(
          id: 'analyze',
          name: '分析修改方案',
          dependsOn: ['read'],
          config: {'prompt': '分析如何修改: $modification'},
          executor: toolExecutor,
        )
        .addToolCall(
          id: 'modify',
          name: '执行修改',
          dependsOn: ['analyze'],
          config: {
            'tool': 'replace_in_file',
            'args': {'filePath': filePath},
          },
          retryPolicy: const RetryPolicy(maxRetries: 1),
          executor: toolExecutor,
        )
        .addToolCall(
          id: 'verify',
          name: '验证修改',
          dependsOn: ['modify'],
          config: {'tool': 'read_file', 'args': {'filePath': filePath}},
          executor: toolExecutor,
        )
        .build();
  }

  /// 搜索-分析-行动工作流
  static Workflow searchAnalyzeAct({
    required String searchQuery,
    Future<NodeResult> Function(
            WorkflowNode node, Map<String, dynamic> context)?
        toolExecutor,
  }) {
    return WorkflowBuilder(
      'wf_search_analyze_${DateTime.now().millisecondsSinceEpoch}',
      '搜索分析: $searchQuery',
    )
        .describe('搜索代码库、分析结果、执行操作')
        .withContext({'searchQuery': searchQuery})
        .addToolCall(
          id: 'search',
          name: '搜索代码库',
          config: {
            'tool': 'codebase_search',
            'args': {'query': searchQuery},
          },
          executor: toolExecutor,
        )
        .addLLMCall(
          id: 'analyze',
          name: '分析搜索结果',
          dependsOn: ['search'],
          executor: toolExecutor,
        )
        .addDecision(
          id: 'decide',
          name: '判断是否需要进一步操作',
          dependsOn: ['analyze'],
          condition: 'status_analyze',
        )
        .addToolCall(
          id: 'act',
          name: '执行操作',
          dependsOn: ['decide'],
          executor: toolExecutor,
        )
        .build();
  }

  /// 多文件重构工作流
  static Workflow multiFileRefactor({
    required List<String> filePaths,
    required String refactorDescription,
    Future<NodeResult> Function(
            WorkflowNode node, Map<String, dynamic> context)?
        toolExecutor,
  }) {
    final builder = WorkflowBuilder(
      'wf_refactor_${DateTime.now().millisecondsSinceEpoch}',
      '多文件重构',
    )
        .describe(refactorDescription)
        .withContext({
          'files': filePaths,
          'description': refactorDescription,
        })
        .addLLMCall(
          id: 'plan',
          name: '生成重构计划',
          config: {
            'prompt': '生成重构计划: $refactorDescription\n文件: ${filePaths.join(", ")}',
          },
          executor: toolExecutor,
        );

    // 为每个文件创建 读取 → 修改 节点
    final readIds = <String>[];
    for (var i = 0; i < filePaths.length; i++) {
      final readId = 'read_$i';
      final modifyId = 'modify_$i';
      readIds.add(readId);

      builder.addToolCall(
        id: readId,
        name: '读取 ${filePaths[i]}',
        dependsOn: ['plan'],
        config: {'tool': 'read_file', 'args': {'filePath': filePaths[i]}},
        executor: toolExecutor,
      );

      builder.addToolCall(
        id: modifyId,
        name: '修改 ${filePaths[i]}',
        dependsOn: [readId],
        config: {
          'tool': 'replace_in_file',
          'args': {'filePath': filePaths[i]},
        },
        retryPolicy: const RetryPolicy(maxRetries: 1),
        executor: toolExecutor,
      );
    }

    // 添加最终验证节点
    builder.addLLMCall(
      id: 'verify',
      name: '验证重构结果',
      dependsOn: List.generate(filePaths.length, (i) => 'modify_$i'),
      executor: toolExecutor,
    );

    return builder.build();
  }
}
