/// ExecutionPlan → Workflow 转换适配器
///
/// 桥接 StructuredPlanner 和 WorkflowEngine：
/// - Planner 生成 ExecutionPlan（逻辑计划，含 DAG 依赖）
/// - PlanWorkflowAdapter 将 ExecutionPlan 转换为 Workflow（物理执行 DAG）
/// - WorkflowEngine 执行 Workflow
///
/// 关键转换逻辑：
/// 1. EnhancedPlanStep → WorkflowNode（toolCall / llmCall / decision 类型）
/// 2. dependsOn 映射为 WorkflowNode.dependsOn
/// 3. postAssertions 映射为 Decision 节点（条件分支）
/// 4. RetryPolicy 根据 canRetry / maxRetries / criticality 生成
import 'package:flutter/foundation.dart';
import '../agent/planner.dart';
import 'workflow_engine.dart';

/// ExecutionPlan → Workflow 转换适配器
class PlanWorkflowAdapter {
  /// 工具执行回调（由外部注入，实际执行工具调用）
  final Future<NodeResult> Function(
      WorkflowNode node, Map<String, dynamic> context)? toolExecutor;

  PlanWorkflowAdapter({this.toolExecutor});

  /// 将 ExecutionPlan 转换为 Workflow
  Workflow convert(ExecutionPlan plan) {
    final builder = WorkflowBuilder(
      plan.id,
      '执行计划: ${plan.steps.first.description.length > 30 ? '${plan.steps.first.description.substring(0, 30)}...' : plan.steps.first.description}',
    )
        .describe(plan.successCriteria ?? '按步骤执行计划')
        .withContext({
      'planId': plan.id,
      'successCriteria': plan.successCriteria ?? '',
    });

    // 将每个 EnhancedPlanStep 转换为 WorkflowNode
    for (final step in plan.steps) {
      final nodeType = _inferNodeType(step);
      final retryPolicy = _buildRetryPolicy(step);

      switch (nodeType) {
        case NodeType.toolCall:
          builder.addToolCall(
            id: step.id,
            name: step.description,
            dependsOn: step.dependsOn,
            config: {
              'tool': step.toolName,
              'parametersHint': step.parametersHint,
              'expectedOutput': step.expectedOutput,
              'criticality': step.criticality,
            },
            retryPolicy: retryPolicy,
            executor: toolExecutor,
          );
          break;

        case NodeType.llmCall:
          builder.addLLMCall(
            id: step.id,
            name: step.description,
            dependsOn: step.dependsOn,
            config: {
              'prompt': step.description,
              'expectedOutput': step.expectedOutput,
            },
            executor: toolExecutor,
          );
          break;

        case NodeType.decision:
          // 带有 postAssertions 的步骤 → 在步骤后插入 Decision 节点
          builder.addToolCall(
            id: step.id,
            name: step.description,
            dependsOn: step.dependsOn,
            config: {
              'tool': step.toolName,
              'parametersHint': step.parametersHint,
            },
            retryPolicy: retryPolicy,
            executor: toolExecutor,
          );

          // 断言检查作为 Decision 节点
          if (step.postAssertions.isNotEmpty) {
            final assertionDesc = step.postAssertions
                .map((a) => a.description)
                .join('; ');
            builder.addDecision(
              id: '${step.id}_assert',
              name: '断言检查: $assertionDesc',
              dependsOn: [step.id],
              condition: 'status_${step.id}',
            );
          }
          break;

        default:
          // 其他类型作为工具调用处理
          builder.addToolCall(
            id: step.id,
            name: step.description,
            dependsOn: step.dependsOn,
            config: {
              'tool': step.toolName,
              'parametersHint': step.parametersHint,
            },
            retryPolicy: retryPolicy,
            executor: toolExecutor,
          );
      }
    }

    final workflow = builder.build();

    // 将 ExecutionPlan 的完成步骤状态同步到 Workflow 节点
    for (final entry in plan.completedSteps.entries) {
      final node = workflow.getNode(entry.key);
      if (node != null && entry.value.isSuccess) {
        node.status = NodeStatus.completed;
      }
    }

    debugPrint('🔄 [PlanWorkflowAdapter] 转换完成: '
        '${plan.steps.length} 步骤 → ${workflow.nodes.length} 节点');
    return workflow;
  }

  /// 推断步骤的节点类型
  NodeType _inferNodeType(EnhancedPlanStep step) {
    // 有 postAssertions 的步骤需要 Decision 节点
    if (step.postAssertions.isNotEmpty) {
      return NodeType.decision;
    }

    // 无工具名的步骤为 LLM 调用（纯思考/分析）
    if (step.toolName == null || step.toolName!.isEmpty) {
      return NodeType.llmCall;
    }

    return NodeType.toolCall;
  }

  /// 根据 PlanStep 属性构建重试策略
  RetryPolicy _buildRetryPolicy(EnhancedPlanStep step) {
    if (!step.canRetry) {
      return RetryPolicy.none;
    }

    // criticality 影响重试策略
    switch (step.criticality) {
      case 'high':
        // 高优先级：快速重试，次数少
        return RetryPolicy(
          maxRetries: step.maxRetries,
          initialDelay: const Duration(seconds: 1),
          backoffMultiplier: 1.5,
          maxDelay: const Duration(seconds: 10),
        );
      case 'low':
        // 低优先级：可以多试几次
        return RetryPolicy(
          maxRetries: step.maxRetries + 1,
          initialDelay: const Duration(seconds: 2),
          backoffMultiplier: 2.0,
          maxDelay: const Duration(seconds: 30),
        );
      default:
        // 中等：默认策略
        return RetryPolicy(
          maxRetries: step.maxRetries,
        );
    }
  }
}
