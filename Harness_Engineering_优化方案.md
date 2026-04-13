# 🏗️ 鹅宝 Harness Engineering 智能体优化方案

## 一、Harness Engineering 是什么？

**Harness Engineering（驾驭工程）** 是相对于 Vibe Coding（氛围编程）提出的概念，核心理念是：

> **不是让 AI 随意发挥，而是为 AI 搭建精确的"缰绳"和"轨道"，让 AI 在确定性框架内高效执行。**

| 维度 | Vibe Coding（当前） | Harness Engineering（目标） |
|------|---------------------|---------------------------|
| 规划 | LLM 自由规划 | 结构化 Planner + 验证门控 |
| 执行 | 单循环试错 | DAG 工作流 + 确定性编排 |
| 评估 | 事后反思 | 实时评估器 + 自动回滚 |
| 防护 | 硬编码规则拦截 | 分层 Guardrails 系统 |
| 可观测 | debugPrint | 结构化 Tracing + Metrics |
| 记忆 | 关键词搜索 | RAG + 向量检索 + 知识图谱 |
| 测试 | 无系统化测试 | Eval 框架 + 回归测试集 |

---

## 二、当前架构诊断（差距分析）

### 2.1 当前架构优势 ✅

```
┌─────────────────────────────────────────────────┐
│              当前架构已具备的能力                    │
├─────────────────────────────────────────────────┤
│ ✅ Hook 系统 — 完整的生命周期钩子接口               │
│ ✅ 多模式执行 — Craft/Plan/Ask/Team/CUA           │
│ ✅ 失败经验学习 — FailureLessonHook 自动检索        │
│ ✅ 反思机制 — ReflectionHook 含 LLM 调用           │
│ ✅ 安全防护 — SecurityHook 危险命令拦截             │
│ ✅ 循环检测 — LoopDetectionHook 防死循环            │
│ ✅ 记忆系统 — 长期/短期记忆 + 衰减淘汰              │
│ ✅ 多 Agent 协作 — 子 Agent 和团队模式              │
│ ✅ 上下文管理 — Token 预算 + 消息修剪               │
│ ✅ 工具学习 — ToolLearner 案例学习                  │
│ ✅ 任务感知提示词 — TaskAwarePromptInjector          │
└─────────────────────────────────────────────────┘
```

### 2.2 关键差距 ❌

| # | 差距 | 当前状态 | 影响 |
|---|------|---------|------|
| G1 | **无结构化 Planner** | Plan 模式只是让 LLM 生成文本计划 | 计划不可验证、不可分步执行 |
| G2 | **无独立 Evaluator** | 反思 Hook 是事后单次分析 | 无法实时评估步骤质量 |
| G3 | **无确定性工作流引擎** | AgentLoop 是单一 while 循环 | 无法编排复杂的分支/并行/条件流 |
| G4 | **Guardrails 不系统化** | SecurityHook 只做命令字符串匹配 | 缺少输入/输出验证、成本控制、语义安全 |
| G5 | **可观测性为零** | 全靠 `debugPrint` | 无法追踪/复现/分析执行链路 |
| G6 | **记忆检索不够智能** | 简单关键词 + 词袋向量 | 语义理解弱、无知识图谱关联 |
| G7 | **工具选择缺乏策略** | LLM 自行决定调用什么工具 | 可能选错工具、遗漏最优工具 |
| G8 | **无 Eval 框架** | 完全依赖人工验证 | 无法量化改进、无回归保障 |
| G9 | **错误恢复不够健壮** | 简单重试 + 失败经验注入 | 无状态回滚、无补偿事务 |
| G10 | **配置硬编码** | 阈值散落在代码各处 | 无法动态调参、A/B 测试 |

---

## 三、分层优化架构（目标架构）

```
┌───────────────────────────────────────────────────────────────┐
│                      🎯 Orchestration Layer                    │
│  ┌──────────┐  ┌───────────┐  ┌───────────┐  ┌────────────┐  │
│  │ Planner  │→ │ Evaluator │→ │ Executor  │→ │ Reconciler │  │
│  │(规划器)   │  │(评估器)    │  │(执行器)    │  │(协调器)     │  │
│  └──────────┘  └───────────┘  └───────────┘  └────────────┘  │
├───────────────────────────────────────────────────────────────┤
│                      🛡️ Guardrails Layer                       │
│  ┌──────────┐  ┌───────────┐  ┌───────────┐  ┌────────────┐  │
│  │  Input   │  │  Output   │  │   Cost    │  │  Semantic  │  │
│  │ Validator│  │ Validator │  │ Controller│  │  Safety    │  │
│  └──────────┘  └───────────┘  └───────────┘  └────────────┘  │
├───────────────────────────────────────────────────────────────┤
│                      📊 Observability Layer                    │
│  ┌──────────┐  ┌───────────┐  ┌───────────┐  ┌────────────┐  │
│  │  Tracer  │  │  Metrics  │  │  Logger   │  │  Profiler  │  │
│  └──────────┘  └───────────┘  └───────────┘  └────────────┘  │
├───────────────────────────────────────────────────────────────┤
│                      🧠 Intelligence Layer                     │
│  ┌──────────┐  ┌───────────┐  ┌───────────┐  ┌────────────┐  │
│  │ RAG      │  │ Knowledge │  │  Tool     │  │  Context   │  │
│  │ Memory   │  │ Graph     │  │ Selector  │  │  Window    │  │
│  └──────────┘  └───────────┘  └───────────┘  └────────────┘  │
├───────────────────────────────────────────────────────────────┤
│                      ⚙️ Foundation Layer                       │
│  ┌──────────┐  ┌───────────┐  ┌───────────┐  ┌────────────┐  │
│  │  Hook    │  │  Agent    │  │   LLM     │  │   Config   │  │
│  │ System   │  │  Loop     │  │  Router   │  │  Manager   │  │
│  └──────────┘  └───────────┘  └───────────┘  └────────────┘  │
└───────────────────────────────────────────────────────────────┘
```

---

## 四、具体优化方案（10 个模块）

---

### 🔧 优化 1：结构化 Planner-Executor-Evaluator 三层架构

**现状问题：** Plan 模式只是让 LLM 生成自然语言计划，存储为 `PendingPlan`，不具备：
- 计划的结构化验证
- 步骤间的依赖分析
- 执行与评估的分离

**目标：** 实现 Plan → Execute → Evaluate 的三阶段闭环

#### 新增文件：`lib/ai/agent/planner.dart`

```dart
/// 结构化规划器
/// 
/// 将 LLM 的自由规划输出约束为结构化的 DAG 执行计划
class StructuredPlanner {
  final LLMProvider _provider;
  final LLMConfig _config;
  final ToolSelector _toolSelector;
  
  /// 生成结构化执行计划
  /// 
  /// 与当前 Plan 模式的关键区别：
  /// 1. 输出是结构化的 ExecutionPlan（不是自然语言）
  /// 2. 每个步骤有前置条件和预期输出 Schema
  /// 3. 步骤间有显式的依赖关系（DAG）
  /// 4. 计划生成后经过验证器校验
  Future<ExecutionPlan> plan(PlanRequest request) async {
    // 1. 任务分解：将用户请求分解为子任务
    final decomposition = await _decompose(request);
    
    // 2. 工具映射：为每个子任务选择最优工具
    final toolMapping = await _toolSelector.selectTools(decomposition);
    
    // 3. 依赖分析：构建步骤间的 DAG
    final dag = _buildDependencyGraph(decomposition, toolMapping);
    
    // 4. 计划验证：检查可行性、循环依赖、资源冲突
    final validation = _validatePlan(dag);
    if (!validation.isValid) {
      // 自动修复或返回错误
      return _repairPlan(dag, validation.errors);
    }
    
    return ExecutionPlan(
      id: _generatePlanId(),
      steps: dag.topologicalSort(),
      estimatedTokens: _estimateTokenCost(dag),
      estimatedDuration: _estimateDuration(dag),
      rollbackStrategy: _generateRollbackPlan(dag),
    );
  }
  
  /// 任务分解 — 使用 LLM 进行 Chain-of-Thought 分解
  Future<TaskDecomposition> _decompose(PlanRequest request) async {
    final decompositionPrompt = '''
分析以下任务，将其分解为可独立执行的子任务：

任务：${request.userQuery}
可用工具：${request.availableTools.map((t) => t['function']['name']).join(', ')}

请输出 JSON 格式：
{
  "subtasks": [
    {
      "id": "step_1",
      "description": "子任务描述",
      "tool": "推荐工具名",
      "parameters_hint": {"key": "预期参数"},
      "depends_on": [],  // 依赖的前置步骤 id
      "expected_output": "预期输出描述",
      "criticality": "high|medium|low",  // 失败影响程度
      "can_retry": true  // 是否可重试
    }
  ],
  "success_criteria": "整体成功的判断条件"
}''';
    
    final response = await _provider.chat(/* ... */);
    return TaskDecomposition.fromJson(json.decode(response));
  }
}

/// 结构化执行计划
class ExecutionPlan {
  final String id;
  final List<PlanStep> steps;
  final int estimatedTokens;
  final Duration estimatedDuration;
  final RollbackPlan rollbackStrategy;
  
  /// 当前执行到哪一步
  int currentStepIndex = 0;
  
  /// 已完成步骤的结果
  final Map<String, StepResult> completedSteps = {};
  
  /// 获取下一批可并行执行的步骤
  List<PlanStep> getNextExecutableSteps() {
    return steps.where((step) {
      if (completedSteps.containsKey(step.id)) return false;
      return step.dependsOn.every((dep) => 
        completedSteps.containsKey(dep) && 
        completedSteps[dep]!.isSuccess
      );
    }).toList();
  }
}

/// 增强版 PlanStep（替代当前的 PlanStep）
class PlanStep {
  final String id;
  final String description;
  final String toolName;
  final Map<String, dynamic> parametersHint;
  final List<String> dependsOn;
  final String expectedOutput;
  final String criticality; // high/medium/low
  final bool canRetry;
  final int maxRetries;
  
  /// 前置条件检查（确定性的，不依赖 LLM）
  final List<Precondition> preconditions;
  
  /// 后置断言（验证步骤输出是否符合预期）
  final List<PostAssertion> postAssertions;
}
```

#### 新增文件：`lib/ai/agent/evaluator.dart`

```dart
/// 步骤评估器
/// 
/// 与当前 ReflectionHook 的区别：
/// - ReflectionHook 是事后被动反思
/// - Evaluator 是每步执行后主动评估，可触发回滚/重试/跳过
class StepEvaluator {
  final LLMProvider _provider;
  
  /// 评估单步执行结果
  Future<StepEvaluation> evaluate(PlanStep step, ToolResult result) async {
    final evaluation = StepEvaluation();
    
    // 1. 确定性断言检查（不耗 LLM token）
    for (final assertion in step.postAssertions) {
      final assertResult = assertion.check(result);
      if (!assertResult.passed) {
        evaluation.addIssue(EvalIssue(
          severity: assertion.severity,
          message: assertResult.message,
          suggestion: assertion.fixSuggestion,
        ));
      }
    }
    
    // 2. 仅当确定性检查不确定时，才用 LLM 做语义评估
    if (evaluation.needsSemanticEval) {
      final semanticResult = await _semanticEvaluate(step, result);
      evaluation.mergeSemanticResult(semanticResult);
    }
    
    // 3. 生成决策
    evaluation.decision = _makeDecision(evaluation, step);
    return evaluation;
  }
  
  EvalDecision _makeDecision(StepEvaluation eval, PlanStep step) {
    if (eval.allPassed) return EvalDecision.proceed;
    if (eval.hasCriticalIssue) {
      if (step.canRetry) return EvalDecision.retry;
      return EvalDecision.rollbackAndAbort;
    }
    if (eval.hasWarning) return EvalDecision.proceedWithWarning;
    return EvalDecision.proceed;
  }
}

enum EvalDecision {
  proceed,            // 继续下一步
  proceedWithWarning, // 继续但记录警告
  retry,              // 重试当前步骤
  rollbackAndRetry,   // 回滚后重试
  rollbackAndAbort,   // 回滚并终止
  skipStep,           // 跳过当前步骤
  replan,             // 触发重新规划
}
```

#### 改造文件：`lib/ai/agent/agent_loop.dart`

```dart
// 在 AgentLoop.run() 中集成三层架构
static Future<AgentLoopResult> run({
  // ... 现有参数保留 ...
  StructuredPlanner? planner,  // 新增
  StepEvaluator? evaluator,    // 新增
}) async {
  
  // 当 mode == AgentMode.plan 时，走结构化规划路径
  if (mode == AgentMode.plan && planner != null) {
    final plan = await planner.plan(PlanRequest(
      userQuery: userRequest ?? '',
      availableTools: tools,
      context: context,
    ));
    
    // 逐步执行 + 逐步评估
    while (plan.hasNextSteps) {
      final nextSteps = plan.getNextExecutableSteps();
      
      for (final step in nextSteps) {
        // 执行
        final result = await executeTool(
          ToolCall(name: step.toolName, arguments: step.parametersHint),
        );
        
        // 评估
        if (evaluator != null) {
          final eval = await evaluator.evaluate(step, result);
          switch (eval.decision) {
            case EvalDecision.retry:
              // 重试逻辑
              break;
            case EvalDecision.rollbackAndAbort:
              // 回滚逻辑
              await _rollback(plan, step);
              return AgentLoopResult(/* ... */);
            case EvalDecision.replan:
              // 重新规划
              plan = await planner.replan(plan, step, result);
              break;
            default:
              plan.markCompleted(step.id, result);
          }
        }
      }
    }
  }
  
  // 原有的 while 循环保留为 Craft 模式的执行路径
  // ...
}
```

---

### 🔧 优化 2：确定性工作流引擎

**现状问题：** `AgentLoop` 是一个扁平的 while 循环，无法表达分支、并行、条件跳转等复杂流程。

**目标：** 引入轻量级 DAG 工作流引擎，让关键流程走"铁轨"而非"草地"。

#### 新增文件：`lib/ai/workflow/workflow_engine.dart`

```dart
/// 工作流节点类型
enum NodeType {
  llmCall,      // LLM 调用
  toolCall,     // 工具调用
  decision,     // 条件分支（确定性）
  parallel,     // 并行分支
  humanReview,  // 人类审核
  subWorkflow,  // 子工作流
}

/// 工作流节点
class WorkflowNode {
  final String id;
  final String name;
  final NodeType type;
  final Map<String, dynamic> config;
  final List<String> dependsOn;
  
  /// 条件边 — 根据输出决定走哪个分支
  final Map<String, String>? conditionalEdges; // condition -> nextNodeId
  
  /// 超时设置
  final Duration? timeout;
  
  /// 重试策略
  final RetryPolicy? retryPolicy;
}

/// 工作流引擎
/// 
/// 与 AgentLoop 的协作方式：
/// - 简单任务：AgentLoop 直接执行（Craft 模式）
/// - 复杂任务：WorkflowEngine 编排，AgentLoop 作为节点执行器
class WorkflowEngine {
  final Map<String, WorkflowNode> _nodes;
  final Tracer _tracer;
  
  /// 执行工作流
  Future<WorkflowResult> execute(WorkflowDefinition workflow) async {
    final executionId = _generateExecutionId();
    final span = _tracer.startSpan('workflow.execute', attributes: {
      'workflow.id': workflow.id,
      'workflow.name': workflow.name,
    });
    
    try {
      // 拓扑排序确定执行顺序
      final executionOrder = workflow.topologicalSort();
      final results = <String, NodeResult>{};
      
      for (final batch in executionOrder) {
        // 同一 batch 内的节点可以并行执行
        if (batch.length == 1) {
          results[batch.first.id] = await _executeNode(batch.first, results);
        } else {
          // 并行执行
          final futures = batch.map((node) => _executeNode(node, results));
          final batchResults = await Future.wait(futures);
          for (var i = 0; i < batch.length; i++) {
            results[batch[i].id] = batchResults[i];
          }
        }
      }
      
      return WorkflowResult.success(results);
    } catch (e) {
      span.setError(e);
      return WorkflowResult.failure(e.toString());
    } finally {
      span.end();
    }
  }
  
  /// 执行单个节点
  Future<NodeResult> _executeNode(
    WorkflowNode node, 
    Map<String, NodeResult> previousResults,
  ) async {
    switch (node.type) {
      case NodeType.decision:
        // 确定性分支 — 不需要 LLM 介入
        final condition = _evaluateCondition(node.config, previousResults);
        return NodeResult.decision(condition);
        
      case NodeType.parallel:
        // 并行执行子节点
        final subNodes = node.config['children'] as List<WorkflowNode>;
        final results = await Future.wait(
          subNodes.map((n) => _executeNode(n, previousResults)),
        );
        return NodeResult.parallel(results);
        
      case NodeType.toolCall:
        // 工具调用 — 带重试和超时
        return _executeWithRetry(node, previousResults);
        
      case NodeType.llmCall:
        // LLM 调用 — 可以嵌入 AgentLoop
        return _executeLLMNode(node, previousResults);
        
      default:
        throw UnimplementedError('Node type: ${node.type}');
    }
  }
}

/// 重试策略
class RetryPolicy {
  final int maxRetries;
  final Duration initialDelay;
  final double backoffMultiplier;
  final List<Type> retryableErrors;
  
  const RetryPolicy({
    this.maxRetries = 3,
    this.initialDelay = const Duration(seconds: 1),
    this.backoffMultiplier = 2.0,
    this.retryableErrors = const [],
  });
  
  Duration getDelay(int attempt) {
    return initialDelay * (backoffMultiplier * attempt);
  }
}
```

#### 预定义工作流模板

```dart
/// 常见任务的预定义工作流
class WorkflowTemplates {
  /// 文件操作工作流：读 → 修改 → 验证 → 写入
  static WorkflowDefinition fileModification() => WorkflowDefinition(
    nodes: [
      WorkflowNode(id: 'read', type: NodeType.toolCall, config: {'tool': 'read_file'}),
      WorkflowNode(id: 'analyze', type: NodeType.llmCall, dependsOn: ['read']),
      WorkflowNode(id: 'modify', type: NodeType.llmCall, dependsOn: ['analyze']),
      WorkflowNode(id: 'validate', type: NodeType.decision, dependsOn: ['modify'],
        config: {'condition': 'output.hasChanges && output.passesLint'}),
      WorkflowNode(id: 'write', type: NodeType.toolCall, dependsOn: ['validate'],
        config: {'tool': 'write_file'}),
      WorkflowNode(id: 'verify', type: NodeType.toolCall, dependsOn: ['write'],
        config: {'tool': 'read_file'}), // 验证写入结果
    ],
  );
  
  /// 搜索-分析-行动工作流
  static WorkflowDefinition searchAnalyzeAct() => WorkflowDefinition(
    nodes: [
      WorkflowNode(id: 'search', type: NodeType.parallel, config: {
        'children': ['codebase_search', 'grep_search', 'file_search'],
      }),
      WorkflowNode(id: 'aggregate', type: NodeType.llmCall, dependsOn: ['search']),
      WorkflowNode(id: 'decide', type: NodeType.decision, dependsOn: ['aggregate']),
      WorkflowNode(id: 'act', type: NodeType.toolCall, dependsOn: ['decide']),
    ],
  );
}
```

---

### 🔧 优化 3：系统化 Guardrails 分层防护

**现状问题：** `SecurityHook` 仅做字符串匹配拦截（`rm -rf /`, `format C:`），缺少：
- 输入验证（LLM 输出的工具参数是否合法）
- 输出验证（工具返回结果是否安全）
- 成本控制（Token/API 消费上限）
- 语义安全（防止 Prompt Injection）

#### 新增文件：`lib/ai/guardrails/guardrails.dart`

```dart
/// 分层 Guardrails 系统
/// 
/// 四层防护架构：
/// L1: 输入验证 — 在工具调用前验证参数合法性
/// L2: 执行防护 — 运行时的安全边界
/// L3: 输出验证 — 确保输出不含敏感信息
/// L4: 成本控制 — Token/调用次数/时间预算
class GuardrailsSystem {
  final List<InputGuardrail> inputGuardrails;
  final List<ExecutionGuardrail> executionGuardrails;
  final List<OutputGuardrail> outputGuardrails;
  final CostController costController;
  
  /// 输入验证管道
  Future<GuardrailResult> validateInput(ToolCall call) async {
    for (final guardrail in inputGuardrails) {
      final result = await guardrail.validate(call);
      if (result.isBlocked) return result;
    }
    return GuardrailResult.passed();
  }
  
  /// 输出验证管道
  Future<GuardrailResult> validateOutput(ToolResult result) async {
    for (final guardrail in outputGuardrails) {
      final gResult = await guardrail.validate(result);
      if (gResult.isBlocked) return gResult;
    }
    return GuardrailResult.passed();
  }
}

/// L1: 输入参数验证
abstract class InputGuardrail {
  Future<GuardrailResult> validate(ToolCall call);
}

/// 文件路径安全验证
class FilePathGuardrail extends InputGuardrail {
  final List<String> allowedPaths;  // 白名单
  final List<String> blockedPaths;  // 黑名单
  
  @override
  Future<GuardrailResult> validate(ToolCall call) async {
    final path = call.arguments['path'] ?? call.arguments['filePath'];
    if (path == null) return GuardrailResult.passed();
    
    // 路径穿越检查
    if (path.contains('..') || path.contains('~')) {
      return GuardrailResult.blocked('路径穿越攻击：$path');
    }
    
    // 系统关键路径保护
    final criticalPaths = ['/etc', '/usr/bin', '/System', '/Windows/System32'];
    for (final cp in criticalPaths) {
      if (path.startsWith(cp)) {
        return GuardrailResult.blocked('禁止访问系统路径：$path');
      }
    }
    
    return GuardrailResult.passed();
  }
}

/// 参数类型与范围验证
class ParameterSchemaGuardrail extends InputGuardrail {
  final Map<String, Map<String, dynamic>> toolSchemas; // 工具参数 Schema
  
  @override
  Future<GuardrailResult> validate(ToolCall call) async {
    final schema = toolSchemas[call.name];
    if (schema == null) return GuardrailResult.passed();
    
    // JSON Schema 验证
    final errors = _validateAgainstSchema(call.arguments, schema);
    if (errors.isNotEmpty) {
      return GuardrailResult.blocked(
        '参数校验失败：${errors.join(", ")}',
        canAutoFix: true,
        fixSuggestion: _suggestFix(call, errors),
      );
    }
    return GuardrailResult.passed();
  }
}

/// L3: 输出内容安全过滤
class OutputSanitizer extends OutputGuardrail {
  @override
  Future<GuardrailResult> validate(ToolResult result) async {
    // 检查是否泄露敏感信息
    final sensitivePatterns = [
      RegExp(r'(?:api[_-]?key|token|secret|password)\s*[:=]\s*\S+', caseSensitive: false),
      RegExp(r'\b[A-Za-z0-9+/]{40,}\b'), // 长 base64 串可能是密钥
    ];
    
    for (final pattern in sensitivePatterns) {
      if (pattern.hasMatch(result.output)) {
        return GuardrailResult.sanitized(
          _redactSensitiveInfo(result.output, pattern),
          '已自动脱敏输出中的敏感信息',
        );
      }
    }
    return GuardrailResult.passed();
  }
}

/// L4: 成本控制器
class CostController {
  final int maxTokensPerSession;
  final int maxToolCallsPerSession;
  final int maxLLMCallsPerSession;
  final Duration maxSessionDuration;
  
  int _totalTokens = 0;
  int _totalToolCalls = 0;
  int _totalLLMCalls = 0;
  DateTime? _sessionStart;
  
  /// 检查是否超出预算
  CostCheckResult checkBudget() {
    if (_totalTokens >= maxTokensPerSession) {
      return CostCheckResult.exceeded('Token 预算已耗尽 ($_totalTokens/$maxTokensPerSession)');
    }
    if (_totalToolCalls >= maxToolCallsPerSession) {
      return CostCheckResult.exceeded('工具调用次数已达上限');
    }
    final elapsed = DateTime.now().difference(_sessionStart ?? DateTime.now());
    if (elapsed >= maxSessionDuration) {
      return CostCheckResult.exceeded('会话时间已超限');
    }
    return CostCheckResult.ok(
      remainingTokens: maxTokensPerSession - _totalTokens,
      remainingCalls: maxToolCallsPerSession - _totalToolCalls,
    );
  }
  
  void recordUsage({int tokens = 0, bool isToolCall = false, bool isLLMCall = false}) {
    _totalTokens += tokens;
    if (isToolCall) _totalToolCalls++;
    if (isLLMCall) _totalLLMCalls++;
  }
}
```

#### 改造：`SecurityHook` → `GuardrailHook`

```dart
/// 将当前的 SecurityHook 升级为 GuardrailHook
/// 作为 Guardrails 系统的 Hook 桥接层
class GuardrailHook extends BaseHook {
  final GuardrailsSystem _guardrails;
  
  @override
  Future<HookResult?> beforeToolCall(ToolCall call, AgentLoopContext context) async {
    // 1. 成本预检
    final costCheck = _guardrails.costController.checkBudget();
    if (costCheck.isExceeded) {
      return HookResult.block('⚠️ ${costCheck.message}');
    }
    
    // 2. 输入验证管道
    final inputResult = await _guardrails.validateInput(call);
    if (inputResult.isBlocked) {
      if (inputResult.canAutoFix) {
        // 自动修复参数
        return HookResult.modifyAndProceed(inputResult.fixSuggestion!);
      }
      return HookResult.block('🛡️ ${inputResult.reason}');
    }
    
    return null; // 通过
  }
  
  @override
  Future<void> afterToolCall(ToolCall call, ToolResult result, AgentLoopContext context) async {
    // 输出验证
    final outputResult = await _guardrails.validateOutput(result);
    if (outputResult.isSanitized) {
      // 修改输出（脱敏）
      result.output = outputResult.sanitizedOutput!;
    }
    
    // 记录成本
    _guardrails.costController.recordUsage(isToolCall: true);
  }
}
```

---

### 🔧 优化 4：结构化可观测性系统

**现状问题：** 全靠 `debugPrint`，无法：
- 追踪完整的执行链路
- 统计工具调用耗时/成功率
- 复现和调试问题
- 量化优化效果

#### 新增文件：`lib/ai/observability/tracer.dart`

```dart
/// 结构化 Trace 系统
/// 
/// 遵循 OpenTelemetry 语义规范的简化实现
/// 每次 AgentLoop 执行产生一个 Trace，包含多个 Span
class Tracer {
  static final Tracer _instance = Tracer._();
  factory Tracer() => _instance;
  Tracer._();
  
  final List<TraceExporter> _exporters = [];
  
  /// 开始一个新的 Span
  Span startSpan(String name, {
    Span? parent,
    Map<String, dynamic>? attributes,
  }) {
    return Span(
      traceId: parent?.traceId ?? _generateTraceId(),
      spanId: _generateSpanId(),
      parentSpanId: parent?.spanId,
      name: name,
      startTime: DateTime.now(),
      attributes: attributes ?? {},
    );
  }
  
  /// 导出完整 Trace
  Future<void> export(Trace trace) async {
    for (final exporter in _exporters) {
      await exporter.export(trace);
    }
  }
}

/// Span 表示一个操作的时间段
class Span {
  final String traceId;
  final String spanId;
  final String? parentSpanId;
  final String name;
  final DateTime startTime;
  DateTime? endTime;
  final Map<String, dynamic> attributes;
  SpanStatus status = SpanStatus.ok;
  String? errorMessage;
  final List<SpanEvent> events = [];
  
  Duration get duration => (endTime ?? DateTime.now()).difference(startTime);
  
  void addEvent(String name, {Map<String, dynamic>? attributes}) {
    events.add(SpanEvent(name: name, timestamp: DateTime.now(), attributes: attributes));
  }
  
  void setError(dynamic error) {
    status = SpanStatus.error;
    errorMessage = error.toString();
  }
  
  void end() {
    endTime = DateTime.now();
  }
}

/// Metrics 收集器
class MetricsCollector {
  static final MetricsCollector _instance = MetricsCollector._();
  factory MetricsCollector() => _instance;
  MetricsCollector._();
  
  // ---- Agent Loop Metrics ----
  final _loopDurations = <Duration>[];
  final _turnsPerLoop = <int>[];
  final _tokensPerLoop = <int>[];
  
  // ---- Tool Metrics ----
  final Map<String, _ToolMetrics> _toolMetrics = {};
  
  // ---- LLM Metrics ----
  int _totalLLMCalls = 0;
  int _totalInputTokens = 0;
  int _totalOutputTokens = 0;
  final _llmLatencies = <Duration>[];
  
  /// 记录工具调用
  void recordToolCall(String toolName, Duration duration, bool success) {
    _toolMetrics.putIfAbsent(toolName, () => _ToolMetrics());
    _toolMetrics[toolName]!.record(duration, success);
  }
  
  /// 记录 LLM 调用
  void recordLLMCall(Duration latency, int inputTokens, int outputTokens) {
    _totalLLMCalls++;
    _totalInputTokens += inputTokens;
    _totalOutputTokens += outputTokens;
    _llmLatencies.add(latency);
  }
  
  /// 生成统计报告
  Map<String, dynamic> generateReport() {
    return {
      'agent_loops': {
        'total': _loopDurations.length,
        'avg_duration_ms': _average(_loopDurations.map((d) => d.inMilliseconds)),
        'avg_turns': _average(_turnsPerLoop.map((t) => t)),
        'avg_tokens': _average(_tokensPerLoop.map((t) => t)),
      },
      'tools': _toolMetrics.map((name, m) => MapEntry(name, {
        'total_calls': m.totalCalls,
        'success_rate': m.successRate,
        'avg_latency_ms': m.avgLatency.inMilliseconds,
        'p95_latency_ms': m.p95Latency.inMilliseconds,
      })),
      'llm': {
        'total_calls': _totalLLMCalls,
        'total_input_tokens': _totalInputTokens,
        'total_output_tokens': _totalOutputTokens,
        'avg_latency_ms': _average(_llmLatencies.map((d) => d.inMilliseconds)),
      },
    };
  }
}
```

#### 改造 `AgentLoop` — 注入 Tracing

```dart
// agent_loop.dart 中增加 Tracing 支持
static Future<AgentLoopResult> run({
  // ... 现有参数 ...
  Tracer? tracer,  // 新增
}) async {
  final rootSpan = tracer?.startSpan('agent_loop.run', attributes: {
    'agent.mode': mode.name,
    'agent.max_turns': maxTurns,
    'agent.user_request': userRequest ?? '',
  });
  
  try {
    // ... 现有循环逻辑 ...
    
    // 在每个工具调用前后打 Span
    for (final toolCall in toolCalls) {
      final toolSpan = tracer?.startSpan('tool.${toolCall.name}', 
        parent: rootSpan,
        attributes: {
          'tool.name': toolCall.name,
          'tool.arguments': json.encode(toolCall.arguments),
        },
      );
      
      try {
        final result = await executeTool(toolCall);
        toolSpan?.attributes['tool.success'] = result.isSuccess;
        toolSpan?.attributes['tool.output_length'] = result.output.length;
      } catch (e) {
        toolSpan?.setError(e);
        rethrow;
      } finally {
        toolSpan?.end();
        MetricsCollector().recordToolCall(
          toolCall.name, 
          toolSpan?.duration ?? Duration.zero,
          toolSpan?.status == SpanStatus.ok,
        );
      }
    }
    
    rootSpan?.attributes['agent.total_turns'] = currentTurn;
    return result;
  } finally {
    rootSpan?.end();
    if (rootSpan != null) {
      await tracer?.export(Trace(rootSpan: rootSpan));
    }
  }
}
```

#### 新增 Hook：`ObservabilityHook`

```dart
/// 将可观测性集成为 Hook（对现有代码侵入最小）
class ObservabilityHook extends BaseHook {
  final Tracer _tracer;
  final MetricsCollector _metrics;
  Span? _currentLoopSpan;
  final Map<String, Span> _activeToolSpans = {};
  
  ObservabilityHook()
      : _tracer = Tracer(),
        _metrics = MetricsCollector(),
        super(id: 'observability', name: '可观测性', description: '结构化追踪', priority: 1);
  
  @override
  Future<void> onLoopStart(AgentLoopContext context) async {
    _currentLoopSpan = _tracer.startSpan('agent_loop', attributes: {
      'mode': context.mode.name,
      'user_request': context.userRequest ?? '',
    });
  }
  
  @override
  Future<HookResult?> beforeToolCall(ToolCall call, AgentLoopContext context) async {
    _activeToolSpans[call.id] = _tracer.startSpan(
      'tool.${call.name}',
      parent: _currentLoopSpan,
    );
    return null;
  }
  
  @override
  Future<void> afterToolCall(ToolCall call, ToolResult result, AgentLoopContext context) async {
    final span = _activeToolSpans.remove(call.id);
    span?.attributes['success'] = result.isSuccess;
    span?.end();
    _metrics.recordToolCall(call.name, span?.duration ?? Duration.zero, result.isSuccess);
  }
  
  @override
  Future<void> onLoopEnd(AgentLoopResult result) async {
    _currentLoopSpan?.end();
    // 可以导出到文件、上报到服务端
    debugPrint('📊 Trace: ${_currentLoopSpan?.traceId}, Duration: ${_currentLoopSpan?.duration}');
  }
}
```

---

### 🔧 优化 5：智能工具选择策略

**现状问题：** `TaskAwarePromptInjector` 只做粗粒度的提示词注入，工具选择完全由 LLM 自行决定。

#### 新增文件：`lib/ai/agent/tool_selector.dart`

```dart
/// 智能工具选择器
/// 
/// 基于任务类型 + 历史成功率 + 工具能力匹配，
/// 为 LLM 提供工具排序建议和使用策略
class ToolSelector {
  final ToolLearner _learner;
  final MetricsCollector _metrics;
  
  /// 为任务选择最优工具集
  /// 
  /// 不是替代 LLM 选择工具，而是：
  /// 1. 过滤掉明显不适用的工具（减少 token）
  /// 2. 对工具按推荐度排序
  /// 3. 在 System Prompt 中注入使用建议
  Future<ToolSelectionResult> selectTools({
    required String userQuery,
    required List<Map<String, dynamic>> allTools,
    required TaskType taskType,
  }) async {
    final scoredTools = <ScoredTool>[];
    
    for (final tool in allTools) {
      final toolName = tool['function']['name'] as String;
      final score = _calculateToolScore(toolName, taskType);
      scoredTools.add(ScoredTool(tool: tool, score: score, reason: ''));
    }
    
    // 按分数排序
    scoredTools.sort((a, b) => b.score.compareTo(a.score));
    
    // 构建使用建议
    final suggestions = _generateUsageSuggestions(scoredTools, taskType);
    
    return ToolSelectionResult(
      rankedTools: scoredTools.map((s) => s.tool).toList(),
      suggestions: suggestions,
      filteredOut: scoredTools.where((s) => s.score < 0.1).map((s) => s.tool).toList(),
    );
  }
  
  double _calculateToolScore(String toolName, TaskType taskType) {
    double score = 0.0;
    
    // 1. 任务类型匹配度（确定性规则）
    score += _taskToolAffinity[taskType]?[toolName] ?? 0.0;
    
    // 2. 历史成功率（从 ToolLearner 获取）
    final successRate = _learner.getSuccessRate(toolName);
    score += successRate * 0.3;
    
    // 3. 调用延迟评分（从 Metrics 获取）
    final avgLatency = _metrics.getAvgLatency(toolName);
    if (avgLatency != null && avgLatency.inSeconds < 5) {
      score += 0.1; // 低延迟加分
    }
    
    return score;
  }
  
  /// 任务类型-工具亲和度矩阵
  static const Map<TaskType, Map<String, double>> _taskToolAffinity = {
    TaskType.fileEdit: {
      'read_file': 0.9,
      'write_file': 0.8,
      'replace_in_file': 0.85,
      'search_content': 0.7,
    },
    TaskType.search: {
      'codebase_search': 0.9,
      'search_content': 0.85,
      'search_file': 0.8,
      'read_file': 0.3,
    },
    TaskType.shell: {
      'execute_command': 0.9,
      'read_file': 0.3,
    },
    // ... 更多映射
  };
}
```

---

### 🔧 优化 6：记忆系统升级（RAG + 知识图谱）

**现状问题：**
- `VectorMemory` 使用简单词袋模型，语义理解能力弱
- 记忆检索以关键词为主，向量搜索为 fallback
- 无记忆间的关联关系（知识图谱）

#### 改造文件：`lib/ai/memory/vector_memory.dart`

```dart
/// 升级向量记忆 — 使用 LLM Embedding 替代词袋模型
class EnhancedVectorMemory {
  /// 混合检索策略
  Future<List<MemoryEntry>> hybridSearch(String query, {int topK = 5}) async {
    // 1. 稀疏检索（BM25/关键词）— 快速召回
    final sparseResults = await _sparseSearch(query, topK: topK * 2);
    
    // 2. 稠密检索（向量相似度）— 语义理解
    final denseResults = await _denseSearch(query, topK: topK * 2);
    
    // 3. 融合排序（Reciprocal Rank Fusion）
    final fusedResults = _reciprocalRankFusion(sparseResults, denseResults);
    
    // 4. 重排序（可选，用 LLM 做精排）
    if (fusedResults.length > topK) {
      return _rerank(query, fusedResults, topK: topK);
    }
    
    return fusedResults.take(topK).toList();
  }
  
  /// Reciprocal Rank Fusion
  List<MemoryEntry> _reciprocalRankFusion(
    List<MemoryEntry> listA, 
    List<MemoryEntry> listB,
    {int k = 60}
  ) {
    final scores = <String, double>{};
    
    for (var i = 0; i < listA.length; i++) {
      scores[listA[i].id] = (scores[listA[i].id] ?? 0) + 1 / (k + i + 1);
    }
    for (var i = 0; i < listB.length; i++) {
      scores[listB[i].id] = (scores[listB[i].id] ?? 0) + 1 / (k + i + 1);
    }
    
    final allEntries = {...listA, ...listB}.toList();
    allEntries.sort((a, b) => (scores[b.id] ?? 0).compareTo(scores[a.id] ?? 0));
    return allEntries;
  }
}
```

#### 新增文件：`lib/ai/memory/knowledge_graph.dart`

```dart
/// 轻量级知识图谱
/// 
/// 用于建立记忆之间的关联关系，支持图遍历式检索
class KnowledgeGraph {
  final Map<String, KGNode> _nodes = {};
  final List<KGEdge> _edges = [];
  
  /// 添加实体和关系
  void addTriple(String subject, String predicate, String object) {
    _nodes.putIfAbsent(subject, () => KGNode(id: subject));
    _nodes.putIfAbsent(object, () => KGNode(id: object));
    _edges.add(KGEdge(from: subject, relation: predicate, to: object));
  }
  
  /// 从对话中自动提取知识三元组
  Future<List<Triple>> extractFromConversation(String conversation) async {
    // 使用 LLM 提取实体和关系
    final prompt = '''
从以下对话中提取知识三元组（主语-谓语-宾语）：
$conversation

格式：[{"s": "主语", "p": "谓语", "o": "宾语"}]
只提取事实性知识，不提取情感或意见。
''';
    // ... LLM 调用 ...
  }
  
  /// 图遍历搜索 — 找到与查询相关的知识子图
  List<KGNode> traverseFrom(String entityId, {int maxDepth = 2}) {
    final visited = <String>{};
    final result = <KGNode>[];
    _dfs(entityId, 0, maxDepth, visited, result);
    return result;
  }
}
```

---

### 🔧 优化 7：错误恢复与状态回滚

**现状问题：** 当前只有简单重试和失败经验注入，缺乏：
- 状态快照与回滚
- 补偿事务
- 渐进式降级

#### 新增文件：`lib/ai/agent/recovery.dart`

```dart
/// 错误恢复管理器
class RecoveryManager {
  final List<StateSnapshot> _snapshots = [];
  
  /// 创建状态快照（在关键步骤前调用）
  StateSnapshot createSnapshot(AgentLoopContext context) {
    final snapshot = StateSnapshot(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      timestamp: DateTime.now(),
      messageCount: context.messages.length,
      messagesSnapshot: List.from(context.messages), // 深拷贝消息
      completedSteps: Map.from(context.completedSteps),
      metadata: Map.from(context.metadata),
    );
    _snapshots.add(snapshot);
    return snapshot;
  }
  
  /// 回滚到指定快照
  void rollbackTo(StateSnapshot snapshot, AgentLoopContext context) {
    context.messages.clear();
    context.messages.addAll(snapshot.messagesSnapshot);
    context.completedSteps.clear();
    context.completedSteps.addAll(snapshot.completedSteps);
  }
  
  /// 渐进式降级策略
  Future<ToolResult> executeWithDegradation(
    ToolCall call,
    Future<ToolResult> Function(ToolCall) executor,
    List<DegradationStrategy> strategies,
  ) async {
    // 策略链：重试 → 参数调整 → 替代工具 → 人工介入
    for (final strategy in strategies) {
      try {
        final modifiedCall = strategy.modify(call);
        return await executor(modifiedCall);
      } catch (e) {
        debugPrint('⚠️ 降级策略 ${strategy.name} 失败: $e');
        continue;
      }
    }
    
    // 所有策略都失败
    return ToolResult(isSuccess: false, output: '所有恢复策略已耗尽');
  }
}

/// 降级策略接口
abstract class DegradationStrategy {
  String get name;
  ToolCall modify(ToolCall original);
}

/// 策略1：减小操作范围
class ReduceScopeStrategy extends DegradationStrategy {
  @override
  String get name => '缩小范围';
  
  @override
  ToolCall modify(ToolCall original) {
    // 例如：search 范围从全局缩小到当前目录
    final args = Map<String, dynamic>.from(original.arguments);
    if (args.containsKey('path')) {
      args['path'] = '.'; // 缩小到当前目录
    }
    return ToolCall(name: original.name, arguments: args);
  }
}

/// 策略2：切换替代工具
class FallbackToolStrategy extends DegradationStrategy {
  final Map<String, String> _fallbackMap = {
    'codebase_search': 'search_content',
    'search_content': 'search_file',
    'execute_command': 'read_file',
  };
  
  @override
  String get name => '替代工具';
  
  @override
  ToolCall modify(ToolCall original) {
    final fallback = _fallbackMap[original.name];
    if (fallback != null) {
      return ToolCall(name: fallback, arguments: original.arguments);
    }
    return original;
  }
}
```

---

### 🔧 优化 8：动态配置管理

**现状问题：** 关键阈值散落在代码各处（`maxTurns = 30`, `maxConsecutiveFailures = 3`, `reflectionThreshold = 2` 等），无法动态调整。

#### 新增文件：`lib/ai/config/agent_config.dart`

```dart
/// 动态配置中心
/// 
/// 所有 Agent 行为参数集中管理，支持：
/// 1. 运行时热更新
/// 2. 按用户/任务类型差异化配置
/// 3. A/B 测试
class AgentConfig {
  static final AgentConfig _instance = AgentConfig._();
  factory AgentConfig() => _instance;
  AgentConfig._();
  
  // ==== Agent Loop 配置 ====
  int get maxTurns => _get('agent.maxTurns', 30);
  int get maxTokensPerSession => _get('agent.maxTokensPerSession', 100000);
  Duration get toolTimeout => Duration(seconds: _get('agent.toolTimeoutSeconds', 30));
  
  // ==== Hook 配置 ====
  int get maxConsecutiveFailures => _get('hook.maxConsecutiveFailures', 3);
  int get reflectionThreshold => _get('hook.reflectionThreshold', 2);
  bool get enableReflection => _get('hook.enableReflection', true);
  bool get enableToolLearning => _get('hook.enableToolLearning', true);
  
  // ==== 记忆配置 ====
  int get maxMemoryEntries => _get('memory.maxEntries', 200);
  double get memoryDecayRate => _get('memory.decayRate', 0.1);
  int get memorySearchTopK => _get('memory.searchTopK', 5);
  
  // ==== Guardrails 配置 ====
  bool get enableCostControl => _get('guardrails.enableCostControl', true);
  int get maxToolCallsPerSession => _get('guardrails.maxToolCallsPerSession', 100);
  bool get enableOutputSanitize => _get('guardrails.enableOutputSanitize', true);
  
  // ==== Prompt 配置 ====
  String get defaultPromptLevel => _get('prompt.defaultLevel', 'standard');
  int get maxSystemPromptTokens => _get('prompt.maxSystemTokens', 8000);
  
  // ==== 配置存储 ====
  final Map<String, dynamic> _overrides = {};
  
  T _get<T>(String key, T defaultValue) {
    return _overrides[key] as T? ?? defaultValue;
  }
  
  void override(String key, dynamic value) {
    _overrides[key] = value;
  }
  
  /// 从 JSON 加载配置
  void loadFromJson(Map<String, dynamic> json) {
    _overrides.clear();
    _flattenJson(json, '', _overrides);
  }
  
  void _flattenJson(Map<String, dynamic> json, String prefix, Map<String, dynamic> result) {
    for (final entry in json.entries) {
      final key = prefix.isEmpty ? entry.key : '$prefix.${entry.key}';
      if (entry.value is Map<String, dynamic>) {
        _flattenJson(entry.value, key, result);
      } else {
        result[key] = entry.value;
      }
    }
  }
}
```

---

### 🔧 优化 9：Eval 评估框架

**现状问题：** 完全依赖人工验证，无法量化改进效果。

#### 新增文件：`lib/ai/eval/eval_framework.dart`

```dart
/// Agent 评估框架
/// 
/// 提供自动化的质量评估，用于：
/// 1. 回归测试 — 代码改动后确保不退化
/// 2. A/B 测试 — 对比不同策略的效果
/// 3. 持续优化 — 量化每次改进的收益
class EvalFramework {
  /// 运行评估套件
  Future<EvalReport> runSuite(EvalSuite suite) async {
    final results = <EvalCaseResult>[];
    
    for (final testCase in suite.cases) {
      final result = await _runCase(testCase);
      results.add(result);
    }
    
    return EvalReport(
      suiteName: suite.name,
      results: results,
      overallScore: _calculateOverallScore(results),
      timestamp: DateTime.now(),
    );
  }
  
  Future<EvalCaseResult> _runCase(EvalCase testCase) async {
    final stopwatch = Stopwatch()..start();
    
    try {
      // 执行 Agent
      final agentResult = await AgentLoop.run(
        // ... 配置 ...
        userRequest: testCase.input,
      );
      
      stopwatch.stop();
      
      // 评估结果
      final scores = <String, double>{};
      
      // 维度 1: 任务完成度
      scores['completion'] = await _evaluateCompletion(
        testCase.expectedOutput, agentResult,
      );
      
      // 维度 2: 效率（工具调用次数/Token 使用量）
      scores['efficiency'] = _evaluateEfficiency(
        agentResult.totalTurns, 
        testCase.expectedMaxTurns,
      );
      
      // 维度 3: 安全性（是否触发 Guardrails）
      scores['safety'] = agentResult.guardrailViolations == 0 ? 1.0 : 0.0;
      
      // 维度 4: 延迟
      scores['latency'] = _evaluateLatency(
        stopwatch.elapsed, testCase.expectedMaxDuration,
      );
      
      return EvalCaseResult(
        caseId: testCase.id,
        scores: scores,
        overallScore: scores.values.reduce((a, b) => a + b) / scores.length,
        duration: stopwatch.elapsed,
        passed: scores.values.every((s) => s >= testCase.passThreshold),
      );
    } catch (e) {
      return EvalCaseResult(
        caseId: testCase.id,
        scores: {'completion': 0, 'efficiency': 0, 'safety': 0, 'latency': 0},
        overallScore: 0,
        error: e.toString(),
        passed: false,
      );
    }
  }
}

/// 评估用例
class EvalCase {
  final String id;
  final String name;
  final String input;          // 用户输入
  final String expectedOutput; // 预期输出（或判断标准）
  final int expectedMaxTurns;  // 预期最大轮数
  final Duration expectedMaxDuration;
  final double passThreshold;  // 通过分数线
  
  const EvalCase({
    required this.id,
    required this.name,
    required this.input,
    required this.expectedOutput,
    this.expectedMaxTurns = 10,
    this.expectedMaxDuration = const Duration(minutes: 2),
    this.passThreshold = 0.7,
  });
}

/// 预定义评估套件
class EvalSuites {
  /// 基础能力评估
  static EvalSuite basicCapabilities() => EvalSuite(
    name: '基础能力',
    cases: [
      EvalCase(
        id: 'basic_chat',
        name: '简单对话',
        input: '你好，今天天气怎么样？',
        expectedOutput: '包含问候和天气相关回应',
        expectedMaxTurns: 1,
      ),
      EvalCase(
        id: 'tool_usage',
        name: '工具使用',
        input: '帮我查看当前目录有哪些文件',
        expectedOutput: '正确使用 list_dir 或 ls 命令并返回文件列表',
        expectedMaxTurns: 3,
      ),
      EvalCase(
        id: 'error_recovery',
        name: '错误恢复',
        input: '帮我读取 /nonexistent/file.txt',
        expectedOutput: '优雅地处理文件不存在的错误',
        expectedMaxTurns: 3,
      ),
    ],
  );
  
  /// 复杂任务评估
  static EvalSuite complexTasks() => EvalSuite(
    name: '复杂任务',
    cases: [
      EvalCase(
        id: 'multi_step',
        name: '多步骤文件操作',
        input: '在当前目录创建一个 hello.dart 文件，写入 Hello World 程序',
        expectedOutput: '成功创建文件并包含正确的 Dart 代码',
        expectedMaxTurns: 5,
      ),
    ],
  );
}
```

---

### 🔧 优化 10：增强 AgentLoop — 集成所有优化

**最终改造方案：** 对 `agent_loop.dart` 的改造采用**最小侵入**策略，通过 Hook + 依赖注入的方式接入新能力。

```dart
/// 改造后的 AgentLoop.run() 签名
static Future<AgentLoopResult> run({
  // ===== 原有参数（全部保留）=====
  required LLMProvider provider,
  required LLMConfig config,
  required List<Map<String, dynamic>> messages,
  required List<Map<String, dynamic>> tools,
  required Future<ToolResult> Function(ToolCall call, {void Function(String line)? onOutput}) executeTool,
  int? maxTurns,  // 改为可选，默认从 AgentConfig 读取
  void Function(ToolStep step)? onStepUpdate,
  void Function(String failedTool, String summary, String error, String solution)? onToolFailure,
  CancellationToken? cancellationToken,
  List<AgentHook>? hooks,
  SubAgentContext? subAgentContext,
  String? userRequest,
  AgentMode mode = AgentMode.craft,
  void Function(PendingPlan plan)? onPlanGenerated,
  Future<String?> Function(String, String, Map<String, dynamic>)? analyzeScreenshot,
  bool embedScreenshotImages = false,
  int maxScreenshotsInContext = 4,
  
  // ===== 新增参数（全部可选，向后兼容）=====
  StructuredPlanner? planner,     // 结构化规划器
  StepEvaluator? evaluator,       // 步骤评估器
  GuardrailsSystem? guardrails,   // 防护系统
  Tracer? tracer,                 // 追踪器
  RecoveryManager? recovery,      // 恢复管理器
  ToolSelector? toolSelector,     // 工具选择器
}) async {
  // 使用配置中心的默认值
  final effectiveMaxTurns = maxTurns ?? AgentConfig().maxTurns;
  
  // 自动注入内置 Hook（如果未手动提供）
  final effectiveHooks = [
    ...?hooks,
    if (guardrails != null) GuardrailHook(guardrails),
    if (tracer != null) ObservabilityHook(tracer),
  ];
  
  // ... 原有逻辑保持不变 ...
}
```

---

## 五、实施路线图（优先级排序）

```
Phase 1 — 基础强化（1-2 周）           影响: 🔥🔥🔥  难度: ⭐⭐
├── ✅ 优化 8: 动态配置管理              → 解耦硬编码
├── ✅ 优化 4: 可观测性 Hook             → 即插即用，不改主循环
└── ✅ 优化 3: Guardrails 输入验证       → 增强安全防护

Phase 2 — 核心升级（2-3 周）           影响: 🔥🔥🔥🔥  难度: ⭐⭐⭐
├── ✅ 优化 1: Planner-Evaluator        → 结构化规划与评估
├── ✅ 优化 7: 错误恢复与回滚            → 提升鲁棒性
└── ✅ 优化 5: 工具选择策略              → 减少无效调用

Phase 3 — 智能进化（3-4 周）           影响: 🔥🔥🔥🔥🔥  难度: ⭐⭐⭐⭐
├── ✅ 优化 6: RAG 混合检索              → 提升记忆质量
├── ✅ 优化 2: 工作流引擎               → 支持复杂编排
└── ✅ 优化 9: Eval 框架                → 量化改进效果

Phase 4 — 持续优化（持续）
└── 基于 Eval 数据持续调参优化
```

---

## 六、改造原则

| 原则 | 说明 |
|------|------|
| **向后兼容** | 所有新参数可选，不传等于现有行为 |
| **最小侵入** | 优先通过 Hook + DI 接入，避免大改 AgentLoop |
| **渐进式** | 每个优化可独立部署和验证 |
| **可度量** | 每个优化都有对应的 Eval 指标 |
| **Hook 优先** | 新能力尽量包装为 Hook，利用现有生命周期系统 |

---

## 七、预期收益

| 指标 | 当前估计 | 优化后目标 | 提升 |
|------|---------|-----------|------|
| 任务完成率 | ~70% | 90%+ | +20% |
| 平均工具调用次数 | ~8 次/任务 | ~5 次/任务 | -37% |
| 错误恢复成功率 | ~30% | 70%+ | +40% |
| Token 使用效率 | 基准 | 降低 30% | +30% |
| 执行链路可追踪 | 0% | 100% | +100% |
| 安全事件漏检率 | 未知 | <5% | - |
| 回归测试覆盖 | 0% | 80%+ | +80% |

---

## 八、关键文件变更清单

| 文件 | 操作 | 说明 |
|------|------|------|
| `lib/ai/agent/planner.dart` | **新增** | 结构化规划器 |
| `lib/ai/agent/evaluator.dart` | **新增** | 步骤评估器 |
| `lib/ai/agent/tool_selector.dart` | **新增** | 智能工具选择器 |
| `lib/ai/agent/recovery.dart` | **新增** | 错误恢复管理器 |
| `lib/ai/workflow/workflow_engine.dart` | **新增** | 工作流引擎 |
| `lib/ai/guardrails/guardrails.dart` | **新增** | 分层防护系统 |
| `lib/ai/observability/tracer.dart` | **新增** | 可观测性系统 |
| `lib/ai/memory/knowledge_graph.dart` | **新增** | 知识图谱 |
| `lib/ai/config/agent_config.dart` | **新增** | 动态配置中心 |
| `lib/ai/eval/eval_framework.dart` | **新增** | 评估框架 |
| `lib/ai/agent/agent_loop.dart` | **改造** | 接入新参数（向后兼容） |
| `lib/ai/agent/agent_hooks.dart` | **改造** | 新增 ObservabilityHook |
| `lib/ai/agent/security_hook.dart` | **改造** | 升级为 GuardrailHook |
| `lib/ai/memory/vector_memory.dart` | **改造** | 混合检索升级 |
| `lib/core/tool_learner.dart` | **改造** | 接入 ToolSelector + 修复 import |

---

> 💡 **一句话总结：** 从「让 LLM 自由发挥的 while 循环」进化为「Plan → Execute → Evaluate 的确定性管道 + 分层防护 + 全链路可观测」，这就是 Harness Engineering 的核心跃迁。
