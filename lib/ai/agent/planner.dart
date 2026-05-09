/// 结构化 Planner + Evaluator（模块 1）
///
/// 将 LLM 的自由规划输出约束为结构化的 DAG 执行计划，
/// 并在每步执行后进行评估，可触发回滚/重试/跳过/重新规划。
///
/// 与当前 Plan 模式的关键区别：
/// 1. 输出是结构化的 ExecutionPlan（不是自然语言）
/// 2. 每个步骤有前置条件和预期输出 Schema
/// 3. 步骤间有显式的依赖关系（DAG）
/// 4. 计划生成后经过验证器校验
/// 5. 每步执行后由 StepEvaluator 主动评估
import 'dart:convert';
import 'package:flutter/foundation.dart';
import '../providers/llm_provider.dart';
import '../../models/models.dart';
import 'agent_types.dart';

// ═══════════════════════════════════════════
// 规划请求
// ═══════════════════════════════════════════

/// 规划请求
class PlanRequest {
  final String userQuery;
  final List<Map<String, dynamic>> availableTools;
  final Map<String, dynamic>? context;

  const PlanRequest({
    required this.userQuery,
    required this.availableTools,
    this.context,
  });
}

// ═══════════════════════════════════════════
// 任务分解结果
// ═══════════════════════════════════════════

/// 子任务定义
class SubTask {
  final String id;
  final String description;
  final String? toolName;
  final Map<String, dynamic> parametersHint;
  final List<String> dependsOn;
  final String? expectedOutput;
  final String criticality; // high / medium / low
  final bool canRetry;

  const SubTask({
    required this.id,
    required this.description,
    this.toolName,
    this.parametersHint = const {},
    this.dependsOn = const [],
    this.expectedOutput,
    this.criticality = 'medium',
    this.canRetry = true,
  });

  factory SubTask.fromJson(Map<String, dynamic> json) {
    return SubTask(
      id: json['id'] as String? ?? '',
      description: json['description'] as String? ?? json['task'] as String? ?? '',
      toolName: json['tool'] as String?,
      parametersHint: json['parameters_hint'] as Map<String, dynamic>? ?? {},
      dependsOn: (json['depends_on'] as List?)?.cast<String>() ?? [],
      expectedOutput: json['expected_output'] as String?,
      criticality: json['criticality'] as String? ?? 'medium',
      canRetry: json['can_retry'] as bool? ?? true,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'description': description,
        if (toolName != null) 'tool': toolName,
        'parameters_hint': parametersHint,
        'depends_on': dependsOn,
        if (expectedOutput != null) 'expected_output': expectedOutput,
        'criticality': criticality,
        'can_retry': canRetry,
      };
}

/// 任务分解结果
class TaskDecomposition {
  final List<SubTask> subtasks;
  final String? successCriteria;

  const TaskDecomposition({
    required this.subtasks,
    this.successCriteria,
  });

  factory TaskDecomposition.fromJson(Map<String, dynamic> json) {
    final subtasksJson = json['subtasks'] as List? ?? [];
    return TaskDecomposition(
      subtasks: subtasksJson
          .map((s) => SubTask.fromJson(s as Map<String, dynamic>))
          .toList(),
      successCriteria: json['success_criteria'] as String?,
    );
  }
}

// ═══════════════════════════════════════════
// 回滚计划
// ═══════════════════════════════════════════

/// 回滚计划
class RollbackPlan {
  final List<RollbackAction> actions;

  const RollbackPlan({this.actions = const []});

  bool get isEmpty => actions.isEmpty;
}

/// 回滚动作
class RollbackAction {
  final String stepId;
  final String description;
  final String? toolName;
  final Map<String, dynamic>? args;

  const RollbackAction({
    required this.stepId,
    required this.description,
    this.toolName,
    this.args,
  });
}

// ═══════════════════════════════════════════
// 增强版 PlanStep
// ═══════════════════════════════════════════

/// 前置条件
class Precondition {
  final String description;
  final bool Function(Map<String, dynamic> context) check;

  const Precondition({required this.description, required this.check});
}

/// 后置断言
class PostAssertion {
  final String description;
  final String severity; // critical / warning / info
  final String? fixSuggestion;
  final bool Function(ToolResult result) check;

  const PostAssertion({
    required this.description,
    required this.check,
    this.severity = 'warning',
    this.fixSuggestion,
  });

  /// 执行断言检查
  AssertionResult evaluate(ToolResult result) {
    final passed = check(result);
    return AssertionResult(passed: passed, message: description);
  }
}

/// 断言结果
class AssertionResult {
  final bool passed;
  final String message;

  const AssertionResult({required this.passed, required this.message});
}

/// 增强版 PlanStep（可用于 StructuredPlanner）
class EnhancedPlanStep {
  final String id;
  final String description;
  final String? toolName;
  final Map<String, dynamic> parametersHint;
  final List<String> dependsOn;
  final String? expectedOutput;
  final String criticality; // high/medium/low
  final bool canRetry;
  final int maxRetries;
  final List<Precondition> preconditions;
  final List<PostAssertion> postAssertions;

  EnhancedPlanStep({
    required this.id,
    required this.description,
    this.toolName,
    this.parametersHint = const {},
    this.dependsOn = const [],
    this.expectedOutput,
    this.criticality = 'medium',
    this.canRetry = true,
    this.maxRetries = 2,
    this.preconditions = const [],
    this.postAssertions = const [],
  });

  /// 从 SubTask 创建
  factory EnhancedPlanStep.fromSubTask(SubTask task) {
    return EnhancedPlanStep(
      id: task.id,
      description: task.description,
      toolName: task.toolName,
      parametersHint: task.parametersHint,
      dependsOn: task.dependsOn,
      expectedOutput: task.expectedOutput,
      criticality: task.criticality,
      canRetry: task.canRetry,
    );
  }
}

// ═══════════════════════════════════════════
// 步骤执行结果
// ═══════════════════════════════════════════

/// 步骤执行结果
class StepResult {
  final String stepId;
  final bool isSuccess;
  final ToolResult? toolResult;
  final String? error;
  final Duration duration;

  const StepResult({
    required this.stepId,
    required this.isSuccess,
    this.toolResult,
    this.error,
    this.duration = Duration.zero,
  });
}

// ═══════════════════════════════════════════
// 执行计划
// ═══════════════════════════════════════════

/// 结构化执行计划
class ExecutionPlan {
  final String id;
  final List<EnhancedPlanStep> steps;
  final int estimatedTokens;
  final Duration estimatedDuration;
  final RollbackPlan rollbackStrategy;
  final String? successCriteria;

  /// 当前执行到哪一步
  int currentStepIndex = 0;

  /// 已完成步骤的结果
  final Map<String, StepResult> completedSteps = {};

  ExecutionPlan({
    required this.id,
    required this.steps,
    this.estimatedTokens = 0,
    this.estimatedDuration = Duration.zero,
    this.rollbackStrategy = const RollbackPlan(),
    this.successCriteria,
  });

  /// 是否还有待执行的步骤
  bool get hasNextSteps => getNextExecutableSteps().isNotEmpty;

  /// 获取下一批可并行执行的步骤
  List<EnhancedPlanStep> getNextExecutableSteps() {
    return steps.where((step) {
      if (completedSteps.containsKey(step.id)) return false;
      return step.dependsOn.every((dep) =>
          completedSteps.containsKey(dep) &&
          completedSteps[dep]!.isSuccess);
    }).toList();
  }

  /// 标记步骤完成
  void markCompleted(String stepId, StepResult result) {
    completedSteps[stepId] = result;
  }

  /// 获取进度（0.0 ~ 1.0）
  double get progress {
    if (steps.isEmpty) return 1.0;
    return completedSteps.length / steps.length;
  }

  /// 所有步骤是否都已成功完成
  bool get isFullyCompleted =>
      completedSteps.length == steps.length &&
      completedSteps.values.every((r) => r.isSuccess);
}

// ═══════════════════════════════════════════
// 结构化规划器
// ═══════════════════════════════════════════

/// 结构化规划器
class StructuredPlanner {
  final LLMProvider _provider;
  final LLMConfig _config;

  StructuredPlanner({
    required LLMProvider provider,
    required LLMConfig config,
  })  : _provider = provider,
        _config = config;

  /// 生成结构化执行计划
  Future<ExecutionPlan> plan(PlanRequest request) async {
    // 1. 任务分解：将用户请求分解为子任务
    final decomposition = await _decompose(request);

    // 2. 依赖分析：验证和修正依赖关系
    _validateDependencies(decomposition);

    // 3. 构建计划
    final steps = decomposition.subtasks.map((task) {
      return EnhancedPlanStep.fromSubTask(task);
    }).toList();

    // 4. 估算资源消耗
    final estimatedTokens = _estimateTokenCost(steps);

    return ExecutionPlan(
      id: 'plan_${DateTime.now().millisecondsSinceEpoch}',
      steps: steps,
      estimatedTokens: estimatedTokens,
      estimatedDuration: Duration(seconds: steps.length * 10),
      successCriteria: decomposition.successCriteria,
    );
  }

  /// 重新规划（在评估失败后调用）
  Future<ExecutionPlan> replan(
    ExecutionPlan currentPlan,
    EnhancedPlanStep failedStep,
    StepResult failedResult,
  ) async {
    // 构建重新规划请求，包含失败上下文
    final remainingSteps = currentPlan.steps
        .where((s) => !currentPlan.completedSteps.containsKey(s.id))
        .map((s) => s.description)
        .join('\n');

    final replanRequest = PlanRequest(
      userQuery: '重新规划未完成的步骤：\n$remainingSteps\n\n'
          '原因：步骤 "${failedStep.description}" 失败：${failedResult.error}',
      availableTools: [],
      context: {
        'completed_steps': currentPlan.completedSteps.keys.toList(),
        'failed_step': failedStep.id,
        'failure_reason': failedResult.error,
      },
    );

    return await plan(replanRequest);
  }

  /// 任务分解 — 使用 LLM 进行 Chain-of-Thought 分解
  Future<TaskDecomposition> _decompose(PlanRequest request) async {
    final toolNames = request.availableTools
        .map((t) => (t['function'] as Map?)?['name'] ?? '')
        .where((name) => name.isNotEmpty)
        .join(', ');

    final decompositionPrompt = '''
分析以下任务，将其分解为可独立执行的子任务。

任务：${request.userQuery}
${toolNames.isNotEmpty ? '可用工具：$toolNames' : ''}

请输出 JSON 格式：
{
  "subtasks": [
    {
      "id": "step_1",
      "description": "子任务描述",
      "tool": "推荐工具名或null",
      "depends_on": [],
      "expected_output": "预期输出描述",
      "criticality": "high|medium|low",
      "can_retry": true
    }
  ],
  "success_criteria": "整体成功的判断条件"
}

分解原则：
1. 每个步骤是一个明确、可独立执行的动作
2. 步骤之间按执行顺序排列，有依赖关系的注明 depends_on
3. 步骤粒度适中（3-8 个步骤为宜）
4. criticality: high 表示失败必须停止，medium 可重试，low 可跳过

只输出 JSON，不要其他内容。''';

    final messages = <Map<String, dynamic>>[
      {'role': 'user', 'content': decompositionPrompt},
    ];

    try {
      final response = await _provider.chat(messages, config: _config);
      return _parseDecomposition(response.text);
    } catch (e) {
      debugPrint('⚠️ [Planner] 任务分解失败: $e');
      // 降级：创建单步计划
      return TaskDecomposition(
        subtasks: [
          SubTask(
            id: 'step_1',
            description: request.userQuery,
            criticality: 'medium',
          ),
        ],
        successCriteria: '用户请求被处理',
      );
    }
  }

  /// 解析 LLM 返回的分解结果
  TaskDecomposition _parseDecomposition(String responseText) {
    // 提取 JSON
    final jsonMatch = RegExp(r'\{[\s\S]*\}').firstMatch(responseText);
    if (jsonMatch == null) {
      throw FormatException('无法从 LLM 响应中提取 JSON');
    }

    try {
      final json = jsonDecode(jsonMatch.group(0)!) as Map<String, dynamic>;
      return TaskDecomposition.fromJson(json);
    } catch (e) {
      // 尝试数组格式
      final arrayMatch = RegExp(r'\[[\s\S]*\]').firstMatch(responseText);
      if (arrayMatch != null) {
        try {
          final array = jsonDecode(arrayMatch.group(0)!) as List;
          return TaskDecomposition(
            subtasks: array.asMap().entries.map((e) {
              final data = e.value as Map<String, dynamic>;
              data['id'] ??= 'step_${e.key + 1}';
              return SubTask.fromJson(data);
            }).toList(),
          );
        } catch (_) {}
      }
      rethrow;
    }
  }

  /// 验证依赖关系（检测循环依赖等）
  void _validateDependencies(TaskDecomposition decomposition) {
    final ids = decomposition.subtasks.map((s) => s.id).toSet();
    for (final task in decomposition.subtasks) {
      for (final dep in task.dependsOn) {
        if (!ids.contains(dep)) {
          debugPrint(
              '⚠️ [Planner] 步骤 ${task.id} 依赖不存在的步骤 $dep，已忽略');
        }
      }
    }
    // TODO: 循环依赖检测
  }

  /// 估算 Token 消耗
  int _estimateTokenCost(List<EnhancedPlanStep> steps) {
    // 简单估算：每个步骤约 500 tokens（LLM 调用 + 工具结果）
    return steps.length * 500;
  }
}

// ═══════════════════════════════════════════
// 步骤评估器
// ═══════════════════════════════════════════

/// 评估问题
class EvalIssue {
  final String severity; // critical / warning / info
  final String message;
  final String? suggestion;

  const EvalIssue({
    required this.severity,
    required this.message,
    this.suggestion,
  });
}

/// 评估决策
enum EvalDecision {
  /// 继续下一步
  proceed,

  /// 继续但记录警告
  proceedWithWarning,

  /// 重试当前步骤
  retry,

  /// 回滚后重试
  rollbackAndRetry,

  /// 回滚并终止
  rollbackAndAbort,

  /// 跳过当前步骤
  skipStep,

  /// 触发重新规划
  replan,
}

/// 步骤评估结果
class StepEvaluation {
  final List<EvalIssue> issues = [];
  EvalDecision decision = EvalDecision.proceed;
  bool needsSemanticEval = false;

  void addIssue(EvalIssue issue) {
    issues.add(issue);
  }

  bool get allPassed => issues.isEmpty;

  bool get hasCriticalIssue =>
      issues.any((i) => i.severity == 'critical');

  bool get hasWarning =>
      issues.any((i) => i.severity == 'warning');

  /// 合并语义评估结果
  void mergeSemanticResult(Map<String, dynamic> semanticResult) {
    final passed = semanticResult['passed'] as bool? ?? true;
    if (!passed) {
      addIssue(EvalIssue(
        severity: semanticResult['severity'] as String? ?? 'warning',
        message: semanticResult['reason'] as String? ?? '语义评估不通过',
        suggestion: semanticResult['suggestion'] as String?,
      ));
    }
  }
}

/// 步骤评估器
///
/// 与当前 ReflectionHook 的区别：
/// - ReflectionHook 是事后被动反思
/// - Evaluator 是每步执行后主动评估，可触发回滚/重试/跳过
class StepEvaluator {
  /// 评估单步执行结果
  Future<StepEvaluation> evaluate(
      EnhancedPlanStep step, ToolResult result) async {
    final evaluation = StepEvaluation();

    // 1. 基础检查：工具是否执行成功
    if (result.isError) {
      evaluation.addIssue(EvalIssue(
        severity: step.criticality == 'low' ? 'warning' : 'critical',
        message: '工具执行失败: ${result.content}',
        suggestion: step.canRetry ? '建议重试' : '建议跳过或终止',
      ));
    }

    // 2. 确定性断言检查（不耗 LLM token）
    for (final assertion in step.postAssertions) {
      final assertResult = assertion.evaluate(result);
      if (!assertResult.passed) {
        evaluation.addIssue(EvalIssue(
          severity: assertion.severity,
          message: assertResult.message,
          suggestion: assertion.fixSuggestion,
        ));
      }
    }

    // 3. 输出非空检查
    if (!result.isError && result.content.trim().isEmpty) {
      evaluation.addIssue(EvalIssue(
        severity: 'warning',
        message: '工具返回空结果',
        suggestion: '检查工具参数是否正确',
      ));
    }

    // 4. 生成决策
    evaluation.decision = _makeDecision(evaluation, step);
    return evaluation;
  }

  /// 生成评估决策
  EvalDecision _makeDecision(
      StepEvaluation eval, EnhancedPlanStep step) {
    if (eval.allPassed) return EvalDecision.proceed;

    if (eval.hasCriticalIssue) {
      if (step.canRetry) return EvalDecision.retry;
      if (step.criticality == 'low') return EvalDecision.skipStep;
      return EvalDecision.rollbackAndAbort;
    }

    if (eval.hasWarning) return EvalDecision.proceedWithWarning;

    return EvalDecision.proceed;
  }
}
