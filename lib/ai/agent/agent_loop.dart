import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import '../../models/models.dart';
import 'agent_types.dart';
import 'agent_hooks.dart';
import 'agent_mode.dart';
import 'sub_agent_types.dart';
import '../providers/llm_provider.dart';
import '../config/agent_config.dart';
import '../guardrails/guardrails.dart';
import '../observability/tracer.dart';
import 'planner.dart';
import 'recovery.dart';
import 'tool_selector.dart';
import 'query_router.dart';
import 'session_state_machine.dart';
import '../workflow/workflow_engine.dart';
import '../workflow/plan_workflow_adapter.dart';

/// Claude Code 风格的 Agent 循环
///
/// 核心设计：
/// 1. 发送消息 → 接收响应 → 如果有 tool_calls → 执行工具 → 追加结果 → 重复
/// 2. 直到 LLM 返回纯文本（stop）或达到最大轮数
/// 3. 无可变状态，纯函数式循环
/// 4. 通过回调报告进度（UI 更新由调用方处理）
/// 5. 支持 Hook 系统，在生命周期的各个阶段注入自定义逻辑
/// 6. 支持三种执行模式：Craft（立即执行）、Plan（先计划后执行）、Ask（只回答不操作）
class AgentLoop {
  /// 运行 Agent 循环
  ///
  /// [provider] LLM 提供者
  /// [config] 模型配置
  /// [messages] 完整的消息列表（包含 system prompt + 对话历史）
  /// [tools] 可用工具定义
  /// [executeTool] 工具执行回调（由调用方实现具体的工具执行逻辑）
  /// [maxTurns] 最大工具调用轮数（默认 30）
  /// [onStepUpdate] 步骤更新回调（UI 实时显示）
  /// [onToolFailure] 工具失败+修复回调（失败后成功修复时触发，包含解决方案）
  /// [cancellationToken] 取消令牌，外部可通过 token.cancel() 中断循环
  /// [hooks] Hook 列表，在生命周期的各个阶段执行
  /// [subAgentContext] 子 Agent 上下文（如果是子 Agent 执行）
  /// [userRequest] 用户原始请求（用于 Hook 上下文）
  /// [mode] 执行模式：craft（立即执行）、plan（先计划后执行）、ask（只回答不操作）
  /// [onPlanGenerated] 计划生成回调（Plan 模式下触发）
  static Future<AgentLoopResult> run({
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
    /// 截图分析回调：将截图 base64 + mimeType + 屏幕元信息 发给视觉模型，返回屏幕描述
    /// 返回 null 则不做视觉分析
    /// [screenInfo] 包含逻辑分辨率 width/height 和缩放因子 scaleFactor，
    /// 视觉模型需要根据此信息报告逻辑坐标（与鼠标点击坐标系一致）
    Future<String?> Function(String base64Image, String mimeType, Map<String, dynamic> screenInfo)? analyzeScreenshot,
    /// 是否将截图作为多模态图片直接嵌入对话消息（供主模型直接看图）
    /// 为 true 时，截图会作为 image_url 类型的 user 消息注入到 workingMessages 中，
    /// 主模型可以直接看到截图并据此决策，无需通过视觉模型间接获取文字描述。
    /// 启用此选项时，主模型必须是多模态模型（如 qwen-vl-max、gpt-4o 等）。
    bool embedScreenshotImages = false,
    /// 截图滑动窗口大小（记忆压缩/上下文窗口管理）
    /// 在发送给 LLM 前，只保留最近 [maxScreenshotsInContext] 张截图，
    /// 更早的截图消息会被替换为压缩后的文字摘要，大幅降低 token 消耗。
    /// 默认 4 张（约 2 轮 screenshot + confirm_screenshot），设为 0 表示不限制。
    int maxScreenshotsInContext = 4,
    // ===== 新增参数（全部可选，向后兼容）=====
    /// 结构化规划器（Module 1），注入后 Plan 模式将使用结构化 DAG 规划
    StructuredPlanner? planner,
    /// 步骤评估器（Module 1），与 planner 配合进行每步评估
    StepEvaluator? evaluator,
    /// 防护系统（Module 3），注入后自动创建 GuardrailHook 替代 SecurityHook
    GuardrailsSystem? guardrails,
    /// 追踪器（Module 4），注入后自动创建 ObservabilityHook
    Tracer? tracer,
    /// 恢复管理器（Module 7），注入后自动创建 RecoveryHook
    RecoveryManager? recovery,
    /// 工具选择器（Module 5），注入后在每轮开始前进行工具排序和建议注入
    ToolSelector? toolSelector,
    /// 问答路由器，注入后自动根据用户意图选择最优模式
    QueryRouter? queryRouter,
    /// 会话状态机，注入后跟踪多轮对话的执行阶段
    SessionStateMachine? stateMachine,
    /// 工作流引擎，注入后 Plan 模式可走 Workflow DAG 执行路径
    WorkflowEngine? workflowEngine,
  }) async {
    // 使用配置中心的默认值
    final agentConfig = AgentConfig();
    final effectiveMaxTurns = maxTurns ?? agentConfig.maxTurns;

    // 创建 Hook 管理器
    final hookManager = HookManager();

    // 自动注入内置 Hook（如果提供了对应的模块实例）
    if (guardrails != null) {
      hookManager.register(GuardrailHook(guardrails));
    }
    if (tracer != null) {
      hookManager.register(ObservabilityHook(tracer: tracer));
    }
    if (recovery != null) {
      hookManager.register(RecoveryHook(recovery));
    }

    // 注册用户自定义 Hook
    if (hooks != null) {
      for (final hook in hooks) {
        hookManager.register(hook);
      }
    }
    
    // 创建 Agent 循环上下文
    final context = AgentLoopContext(
      maxTurns: effectiveMaxTurns,
      subAgentContext: subAgentContext,
      userRequest: userRequest ?? _extractUserRequest(messages),
    );
    
    // ── 问答路由：自动选择最优模式 ──
    AgentMode effectiveMode = mode;
    if (queryRouter != null && mode != AgentMode.cua && mode != AgentMode.team) {
      final routeResult = queryRouter.route(userRequest ?? '', userSpecifiedMode: mode);
      debugPrint('🧭 [Agent] 路由结果: ${routeResult.recommendedMode.displayName}'
          ' (置信度: ${(routeResult.confidence * 100).toStringAsFixed(0)}%,'
          ' 原因: ${routeResult.reason})');
      // 只有在置信度足够高且与用户指定不同时才覆盖
      if (routeResult.confidence >= 0.8 && routeResult.recommendedMode != mode) {
        effectiveMode = routeResult.recommendedMode;
        debugPrint('🧭 [Agent] 模式自动调整: ${mode.displayName} → ${effectiveMode.displayName}');
      }
    }

    // ── 状态机：初始化会话状态 ──
    stateMachine?.transition(SessionState.routing, reason: '开始路由');
    if (effectiveMode == AgentMode.plan) {
      stateMachine?.transition(SessionState.planning, reason: '进入规划阶段');
    } else if (effectiveMode == AgentMode.craft || effectiveMode == AgentMode.cua) {
      stateMachine?.transition(SessionState.executing, reason: '进入执行阶段');
    }

    // 触发循环开始 Hooks
    await hookManager.triggerLoopStart(context);
    final allApiMessages = <Map<String, dynamic>>[];
    final skillNames = <String>[];
    final outputFiles = <Map<String, dynamic>>[];
    final steps = <ToolStep>[];

    // 从 messages 中分离 system prompt（不发送给 LLM 重复）
    final systemMessage = messages.firstWhere(
      (m) => m['role'] == 'system',
      orElse: () => {'role': 'system', 'content': ''},
    );

    // 工作副本（会在循环中追加消息）
    final workingMessages = List<Map<String, dynamic>>.from(messages);

    // ── 循环防护（从 AgentConfig 读取阈值） ──
    final maxDuplicateRounds = agentConfig.maxDuplicateRounds;
    final maxStagnantRounds = agentConfig.maxStagnantRounds;
    final maxFailedCalls = agentConfig.maxFailedCalls;
    final recentSignatures = <String>[];
    final recentResultLengths = <int>[];
    final recentFailedToolNames = <String>[];

    // CUA 模式：连续纯文本轮数跟踪（用于防止 LLM "偷懒"）
    int cuaPlainTextRounds = 0;
    // CUA 模式：任务完成标记（当 cua_observe 返回 screenStatus=Done 或 cua_step 返回 done=true 时设置）
    bool cuaTaskDone = false;
    // CUA 模式：任务进度追踪
    String cuaTaskProgress = ''; // 当前步骤描述
    int cuaCompletionPercentage = 0; // 完成百分比
    // CUA 模式：任务解析完成标记（第一轮必须先 think 完成任务解析）
    bool cuaTaskParsed = false;

    // ── 重试跟踪（用于触发 beforeRetry 钩子） ──
    final lastFailedTools = <String, ToolCall>{}; // 工具名 → 最后失败的调用
    final retryCountMap = <String, int>{}; // 工具名 → 重试次数

    for (var turn = 0; turn < effectiveMaxTurns; turn++) {
      // ── 每轮开始前检查取消 ──
      cancellationToken?.throwIfCancelled();

      // ── ToolSelector：每轮开始前进行工具排序和过滤 ──
      List<Map<String, dynamic>> effectiveTools = tools;
      if (toolSelector != null) {
        try {
          final selectionResult = await toolSelector.selectTools(
            userQuery: userRequest ?? '',
            allTools: tools,
          );
          if (selectionResult.rankedTools.isNotEmpty &&
              selectionResult.rankedTools.length < tools.length) {
            effectiveTools = selectionResult.rankedTools;
            debugPrint('🎯 [Agent] ToolSelector: '
                '${tools.length} → ${effectiveTools.length} 工具'
                ' (类型: ${selectionResult.detectedTaskType.name},'
                ' 过滤: ${selectionResult.filteredOut.length})');
          }
          // 注入工具使用建议到 System Prompt
          if (selectionResult.suggestions.isNotEmpty) {
            final sysMsgIdx = workingMessages.indexWhere((m) => m['role'] == 'system');
            if (sysMsgIdx >= 0) {
              final existingContent = workingMessages[sysMsgIdx]['content'] as String? ?? '';
              if (!existingContent.contains(selectionResult.suggestions)) {
                workingMessages[sysMsgIdx] = {
                  ...workingMessages[sysMsgIdx],
                  'content': '$existingContent\n\n${selectionResult.suggestions}',
                };
              }
            }
          }
        } catch (e) {
          debugPrint('⚠️ [Agent] ToolSelector 失败，使用全部工具: $e');
        }
      }
      
      // ── 截图滑动窗口（优化3：记忆压缩/上下文窗口管理） ──
      // 在发送给 LLM 前，压缩超出窗口大小的旧截图，降低 token 消耗
      if (maxScreenshotsInContext > 0 && embedScreenshotImages) {
        _applyScreenshotSlidingWindow(workingMessages, maxScreenshotsInContext);
      }

      debugPrint('🔄 [Agent 第${turn + 1}轮] 发送 ${workingMessages.length} 条消息, tools=${tools.length}, model=${config.model}');

      // ── 调用 LLM（支持即时取消，使用 ToolSelector 过滤后的工具列表） ──
      final response = await _chat(
        provider, workingMessages,
        config: config,
        tools: effectiveTools,
        cancellationToken: cancellationToken,
      );

      debugPrint('🔄 [Agent 第${turn + 1}轮] LLM返回: stopReason=${response.stopReason}, hasToolCalls=${response.hasToolCalls}, toolCount=${response.toolCalls.length}, textLen=${response.text.length}');
      
      // ── LLM 返回后再检查取消（等待期间用户可能已点停止） ──
      cancellationToken?.throwIfCancelled();

      // ── 检查是否需要执行工具 ──
      if (!response.hasToolCalls) {
        // ── Plan 模式：即使没有工具调用，也要先规划 ──
        if (effectiveMode == AgentMode.plan) {
          if (planner != null) {
            // 结构化规划
            debugPrint('📋 [Agent] Plan 模式（纯文本响应，结构化规划器）');
            try {
              final planRequest = PlanRequest(
                userQuery: userRequest ?? '',
                availableTools: tools,
              );
              final executionPlan = await planner.plan(planRequest);
              final planId = executionPlan.id;
              final pendingPlan = PendingPlan(
                id: planId,
                userRequest: userRequest ?? '',
                title: '执行计划',
                steps: executionPlan.steps.asMap().entries.map((entry) {
                  final step = entry.value;
                  return PlanStep(
                    id: step.id,
                    order: entry.key + 1,
                    description: step.description,
                    toolName: step.toolName,
                    dependsOn: step.dependsOn,
                    criticality: step.criticality,
                    canRetry: step.canRetry,
                    maxRetries: step.maxRetries,
                    expectedOutput: step.expectedOutput,
                  );
                }).toList(),
                successCriteria: executionPlan.successCriteria,
                estimatedTokens: executionPlan.estimatedTokens,
                estimatedDuration: executionPlan.estimatedDuration,
              );
              onPlanGenerated?.call(pendingPlan);
              
              final planText = _formatStructuredPlanAsText(pendingPlan);
              final result = AgentLoopResult(
                text: planText,
                apiMessages: allApiMessages,
                skillNames: [],
                outputFiles: [],
                steps: steps,
                pendingPlan: pendingPlan,
              );
              await hookManager.triggerLoopEnd(result);
              return result;
            } catch (e) {
              debugPrint('⚠️ [Agent] 结构化规划失败，降级: $e');
            }
          }
          
          // 降级路径
          debugPrint('📋 [Agent] Plan 模式（纯文本响应），进行任务规划');
          final plan = _buildPlanFromTextResponse(response.text, userRequest ?? '');
          onPlanGenerated?.call(plan);
          
          final planText = _formatPlanAsText(plan);
          final result = AgentLoopResult(
            text: planText,
            apiMessages: allApiMessages,
            skillNames: [],
            outputFiles: [],
            steps: steps,
            pendingPlan: plan,
          );
          await hookManager.triggerLoopEnd(result);
          return result;
        }

        // ── CUA 模式：不允许纯文本退出，强制要求继续操作 ──
        // 但如果任务已完成（cuaTaskDone=true），允许 LLM 正常退出输出总结
        if (effectiveMode == AgentMode.cua) {
          if (cuaTaskDone) {
            // 任务已完成，允许 LLM 输出总结并退出
            debugPrint('✅ [Agent] CUA 任务已完成（screenStatus=Done），允许纯文本退出');
          } else {
            cuaPlainTextRounds++;
            if (cuaPlainTextRounds <= 3) {
              // 追加 LLM 的纯文本到历史（让它知道自己的回复已被"看到"）
              workingMessages.add({
                'role': 'assistant',
                'content': response.text.isEmpty ? null : response.text,
              });
              // 注入强制提醒
              final reminder = cuaPlainTextRounds == 1
                  ? '【系统强制提醒】你处于 CUA 操作模式，不能只输出文字回复。'
                      '你必须通过 cua(action=...) 工具执行实际桌面操作。'
                      '请先调用 cua(action="cua_observe") 观察屏幕状态，然后根据结果执行操作。'
                      '⛔ 注意：所有 mouse_click 必须先 find_element 定位，否则会被系统拦截拒绝执行！'
                  : '【系统第${cuaPlainTextRounds}次提醒】CUA 模式下必须调用 cua 工具操作！'
                      '不要输出文字描述，先调用 cua(action="cua_observe") 观察屏幕，再执行操作。'
                      '⛔ mouse_click 坐标必须来自 find_element，否则会被拦截！';
              debugPrint('⚠️ [Agent] CUA 模式 LLM 返回纯文本 (第${cuaPlainTextRounds}次)，注入强制提醒');
              workingMessages.add({'role': 'user', 'content': reminder});
              continue; // 不退出循环，继续下一轮
            }
            // 超过 3 次纯文本，允许退出
            debugPrint('⚠️ [Agent] CUA 模式连续 $cuaPlainTextRounds 轮纯文本，允许退出');
          }
        }
        
        // LLM 返回纯文本 → 循环结束
        final text = response.text;
        debugPrint('🔄 [Agent] LLM 返回纯文本 (${text.length} 字符)，循环结束');
        stateMachine?.transition(SessionState.completed, reason: 'LLM 返回最终文本');

        // 检查截断
        if (response.stopReason == AgentStopReason.length) {
          debugPrint('⚠️ [Agent] 输出被截断（max_tokens 用尽）');
        }
        
        // ── 触发 LLM 响应后 Hook ──
        await hookManager.triggerAfterLLMResponse(response);

        final result = AgentLoopResult(
          text: text,
          apiMessages: allApiMessages,
          skillNames: skillNames,
          outputFiles: outputFiles,
          steps: steps,
        );
        
        // ── 触发循环结束 Hooks ──
        await hookManager.triggerLoopEnd(result);
        
        return result;
      }

      // 有 tool_calls → 重置 CUA 纯文本计数
      if (effectiveMode == AgentMode.cua) {
        cuaPlainTextRounds = 0;

        // ── CUA 第一轮必须先任务解析 ──
        if (turn == 0 && !cuaTaskParsed) {
          // 检查是否包含 think
          final hasThink = response.toolCalls.any((tc) => tc.name == 'think');
          if (!hasThink) {
            // 第一轮没有 think，强制要求先任务解析
            debugPrint('⚠️ [Agent] CUA 第一轮未包含 think，强制要求任务解析');

            // 追加 LLM 的响应到历史
            workingMessages.add({
              'role': 'assistant',
              'content': response.text.isEmpty ? null : response.text,
              'tool_calls': response.toolCalls.map((tc) => {
                'id': tc.id,
                'type': 'function',
                'function': {
                  'name': tc.name,
                  'arguments': jsonEncode(tc.arguments),
                },
              }).toList(),
            });

            // 注入强制提醒
            workingMessages.add({
              'role': 'user',
              'content': '【系统强制要求】这是 CUA 操作模式的第一轮，你必须先调用 think 工具完成任务解析。\n\n'
                  '请按照任务解析模板完成深度思考：\n'
                  '1. 用户意图分析\n'
                  '2. 歧义识别与处理\n'
                  '3. 边界条件考虑\n'
                  '4. 验证方法定义\n'
                  '5. 步骤拆解（每步都要有验证方法）\n\n'
                  '⛔ 禁止跳过任务解析直接操作！',
            });
            continue; // 不执行工具，继续下一轮
          } else {
            // 有 think，标记任务解析已完成
            cuaTaskParsed = true;
            debugPrint('✅ [Agent] CUA 任务解析已完成');
          }
        }
      }
      
      // ── 触发 LLM 响应后 Hook ──
      await hookManager.triggerAfterLLMResponse(response);
      
      // ── 检查执行模式 ──
      if (effectiveMode == AgentMode.ask) {
        // Ask 模式：只允许执行只读工具，拒绝写操作工具
        final readOnlyTools = {
          'think', 'save_memory', 'web_search', 'search',
          'read_file', 'activate_skill', 'list_dir',
          'search_file', 'search_content',
        };
        
        final writeTools = response.toolCalls
            .where((tc) => !readOnlyTools.contains(tc.name))
            .map((tc) => tc.name)
            .toSet();
        
        if (writeTools.isNotEmpty) {
          // 有写操作工具，拒绝执行
          debugPrint('💬 [Agent] Ask 模式，拒绝写操作: ${writeTools.join(', ')}');
          final result = AgentLoopResult(
            text: '【Ask 模式】我只提供信息和建议，不执行实际操作。\n\n'
                '你想执行的操作涉及写操作: ${writeTools.join(', ')}\n\n'
                '如需执行操作，请切换到 **Craft 模式**（立即执行）或 **Plan 模式**（先规划后执行）。',
            apiMessages: allApiMessages,
            skillNames: [],
            outputFiles: [],
            steps: steps,
          );
          await hookManager.triggerLoopEnd(result);
          return result;
        }
        
        // 只有只读工具，继续执行（搜索、思考、读取等）
        debugPrint('💬 [Agent] Ask 模式，执行只读工具: ${response.toolCalls.map((tc) => tc.name).join(', ')}');
      }
      
      if (effectiveMode == AgentMode.plan) {
        // Plan 模式：优先使用 StructuredPlanner（DAG 规划），降级使用简单 JSON 规划
        if (planner != null) {
          // ── 结构化规划（P0 升级）──
          debugPrint('📋 [Agent] Plan 模式（结构化 DAG 规划器）');
          stateMachine?.transition(SessionState.planning, reason: '结构化规划');
          
          try {
            final planRequest = PlanRequest(
              userQuery: userRequest ?? '',
              availableTools: tools,
              context: {
                'initial_tool_calls': response.toolCalls.map((tc) => tc.name).toList(),
              },
            );
            
            final executionPlan = await planner.plan(planRequest);
            
            // 将 ExecutionPlan 转换为 PendingPlan（UI 层数据结构）
            final planId = executionPlan.id;
            final pendingPlan = PendingPlan(
              id: planId,
              userRequest: userRequest ?? '',
              title: '执行计划',
              steps: executionPlan.steps.asMap().entries.map((entry) {
                final step = entry.value;
                return PlanStep(
                  id: step.id,
                  order: entry.key + 1,
                  description: step.description,
                  toolName: step.toolName,
                  dependsOn: step.dependsOn,
                  criticality: step.criticality,
                  canRetry: step.canRetry,
                  maxRetries: step.maxRetries,
                  expectedOutput: step.expectedOutput,
                );
              }).toList(),
              successCriteria: executionPlan.successCriteria,
              estimatedTokens: executionPlan.estimatedTokens,
              estimatedDuration: executionPlan.estimatedDuration,
            );
            
            onPlanGenerated?.call(pendingPlan);
            
            // ── Workflow 执行路径（可选）──
            // 如果提供了 WorkflowEngine，将 ExecutionPlan 转为 Workflow 执行
            if (workflowEngine != null) {
              try {
                stateMachine?.setPlanId(planId);
                stateMachine?.transition(SessionState.executing, reason: 'Workflow DAG 执行');
                final adapter = PlanWorkflowAdapter();
                final workflow = adapter.convert(executionPlan);
                final report = await workflowEngine.execute(workflow);
                
                debugPrint('📋 [Agent] Workflow 执行完成: ${report.isSuccess ? "✅" : "❌"}'
                    ' (${report.completedNodes}/${report.totalNodes} 节点完成)');
                stateMachine?.transition(SessionState.completed, reason: 'Workflow 执行完成');
                
                final planText = _formatStructuredPlanAsText(pendingPlan);
                final wfSummary = '\n\n---\n**执行报告**: ${report.completedNodes}/${report.totalNodes} 步骤完成'
                    '${report.failedNodes > 0 ? "，${report.failedNodes} 步失败" : ""}'
                    '，耗时 ${report.totalDuration.inSeconds}s';
                final result = AgentLoopResult(
                  text: '$planText$wfSummary',
                  apiMessages: allApiMessages,
                  skillNames: [],
                  outputFiles: [],
                  steps: steps,
                  pendingPlan: pendingPlan,
                );
                await hookManager.triggerLoopEnd(result);
                return result;
              } catch (e) {
                debugPrint('⚠️ [Agent] Workflow 执行失败，降级为普通计划展示: $e');
                stateMachine?.transition(SessionState.planning, reason: 'Workflow 失败，降级');
              }
            }
            
            final planText = _formatStructuredPlanAsText(pendingPlan);
            final result = AgentLoopResult(
              text: planText,
              apiMessages: allApiMessages,
              skillNames: [],
              outputFiles: [],
              steps: steps,
              pendingPlan: pendingPlan,
            );
            await hookManager.triggerLoopEnd(result);
            return result;
          } catch (e) {
            debugPrint('⚠️ [Agent] 结构化规划失败，降级到简单规划: $e');
            // 降级到旧逻辑
          }
        }
        
        // ── 简单规划（旧逻辑/降级路径）──
        debugPrint('📋 [Agent] Plan 模式，引导 LLM 思考并拆分任务');
        
        // 注入规划提示，引导 LLM 进行任务分析和拆分
        final planningPrompt = _buildPlanningPrompt(userRequest ?? '', response.toolCalls);
        workingMessages.add({
          'role': 'user',
          'content': planningPrompt,
        });
        
        // 让 LLM 思考并生成计划
        final planResponse = await _chat(
          provider, workingMessages,
          config: config,
          tools: [], // Plan 模式下不返回工具调用，只返回纯文本计划
          cancellationToken: cancellationToken,
        );
        
        // 从 LLM 的规划响应中提取任务步骤
        final plan = _parsePlanFromResponse(planResponse.text, userRequest ?? '');
        onPlanGenerated?.call(plan);
        
        final planText = _formatPlanAsText(plan);
        final result = AgentLoopResult(
          text: planText,
          apiMessages: allApiMessages,
          skillNames: [],
          outputFiles: [],
          steps: steps,
          pendingPlan: plan,
        );
        await hookManager.triggerLoopEnd(result);
        return result;
      }

      // ── 循环防护：重复调用检测 ──
      final signature = response.toolCalls.map((tc) => tc.signature).join('|');
      recentSignatures.add(signature);
      if (recentSignatures.length > maxDuplicateRounds) recentSignatures.removeAt(0);
      if (recentSignatures.length >= maxDuplicateRounds &&
          recentSignatures.toSet().length == 1) {
        debugPrint('⚠️ [Agent] 连续 $maxDuplicateRounds 轮 tool_calls 相同，强制停止');
        _addStep(steps, '⚠️ 循环检测', '连续重复调用已终止', onStepUpdate);
        workingMessages.add({
          'role': 'user',
          'content': '【系统提示】检测到你连续多轮调用完全相同的工具，请停止重复，直接基于已有结果回复。',
        });
        try {
          final stopResp = await _chat(provider, workingMessages, config: config, cancellationToken: cancellationToken);
          final result = AgentLoopResult(
            text: stopResp.text,
            apiMessages: allApiMessages,
            skillNames: skillNames,
            outputFiles: outputFiles,
            steps: steps,
          );
          await hookManager.triggerLoopEnd(result);
          return result;
        } catch (_) {
          final result = AgentLoopResult(
            text: '嘎...鹅宝陷入了重复调用的死循环，已自动终止~ 🦢',
            apiMessages: allApiMessages,
            skillNames: skillNames,
            outputFiles: outputFiles,
            steps: steps,
          );
          await hookManager.triggerLoopEnd(result);
          return result;
        }
      }

      // ── 构造 assistant 消息（含 tool_calls）并追加到历史 ──
      final assistantMsg = {
        'role': 'assistant',
        'content': response.text.isEmpty ? null : response.text,
        'tool_calls': response.toolCalls.map((tc) => {
          'id': tc.id,
          'type': 'function',
          'function': {
            'name': tc.name,
            'arguments': jsonEncode(tc.arguments),
          },
        }).toList(),
      };
      workingMessages.add(assistantMsg);
      allApiMessages.add(Map<String, dynamic>.from(assistantMsg));

      // ── 逐个执行工具 ──
      int roundResultLength = 0;
      // 缓冲 hook 注入的 user 消息，避免插入在 assistant(tool_calls) 和 tool 之间
      // 所有 tool 响应添加完之后再统一追加
      final deferredHookMessages = <Map<String, dynamic>>[];
      for (final toolCall in response.toolCalls) {
        // ── 取消检查（每个工具执行前） ──
        cancellationToken?.throwIfCancelled();
        
        // ── 更新上下文 ──
        context.currentTurn = turn + 1;
        context.recordToolCall(toolCall);

        debugPrint('🔧 [Agent] 执行工具: ${toolCall.name}(${toolCall.arguments})');
        
        // ── 检查是否为真正重试（工具之前失败过 且 参数签名相同） ──
        // 参数不同视为"正常调整"，不触发反思
        final lastFailed = lastFailedTools[toolCall.name];
        final isExactRetry = lastFailed != null && lastFailed.signature == toolCall.signature;
        final isRetry = lastFailedTools.containsKey(toolCall.name);
        
        if (isRetry) {
          if (isExactRetry) {
            // 参数完全相同 → 真正的重试，触发 beforeRetry 反思
            final retryCount = retryCountMap[toolCall.name] ?? 0;
            debugPrint('🔄 [Agent] 检测到真正重试（相同参数）: ${toolCall.name}, 第${retryCount + 1}次');
            
            // ── 触发 beforeRetry Hooks ──
            final retryHookResult = await hookManager.triggerBeforeRetry(
              toolCall, 
              retryCount + 1, 
              context,
            );
            
            if (retryHookResult != null) {
              if (retryHookResult.shouldBlock) {
                debugPrint('🪝 [Hook] 阻止重试: ${toolCall.name}');
                _addStep(steps, '⚠️ Hook 阻止重试', retryHookResult.userMessage ?? '重试被阻止', onStepUpdate);
                // 被阻止的 tool_call 需要一个空响应，否则 API 会报错
                workingMessages.add({'role': 'tool', 'tool_call_id': toolCall.id, 'content': '工具调用被阻止'});
                continue;
              }
              if (retryHookResult.shouldInject && retryHookResult.injectedMessage != null) {
                // 缓冲反思消息（不直接插入 workingMessages，避免打断 tool_calls → tool 连续性）
                deferredHookMessages.add({
                  'role': 'user',
                  'content': retryHookResult.injectedMessage!,
                });
              }
              // ── 自动应用替代方案的参数修改 ──
              if (retryHookResult.modifiedArgs != null) {
                debugPrint('🪝 [Hook] 自动修改工具参数: ${toolCall.name}');
                toolCall.arguments.addAll(retryHookResult.modifiedArgs!);
              }
            }
            
            // 更新重试计数
            retryCountMap[toolCall.name] = retryCount + 1;
          } else {
            // 参数不同 → 正常调整，不触发反思，仅清除记录
            debugPrint('🔧 [Agent] 检测到参数调整（非重试）: ${toolCall.name}');
          }
          // 清除失败记录（这次调用后会有新结果）
          lastFailedTools.remove(toolCall.name);
        }

        // ── 触发 beforeToolCall Hooks ──
        final hookResult = await hookManager.triggerBeforeToolCall(toolCall, context);
        if (hookResult != null) {
          if (hookResult.shouldBlock) {
            // 阻止执行
            debugPrint('🪝 [Hook] 阻止工具调用: ${toolCall.name}');
            _addStep(steps, '⚠️ Hook 阻止', hookResult.userMessage ?? '工具调用被阻止', onStepUpdate);
            // 被阻止的 tool_call 需要一个空响应
            workingMessages.add({'role': 'tool', 'tool_call_id': toolCall.id, 'content': '工具调用被阻止'});
            continue;
          }
          if (hookResult.shouldInject && hookResult.injectedMessage != null) {
            // 缓冲注入消息
            deferredHookMessages.add({
              'role': 'user',
              'content': hookResult.injectedMessage!,
            });
          }
          if (hookResult.shouldSkip) {
            // 跳过当前工具
            debugPrint('🪝 [Hook] 跳过工具: ${toolCall.name}');
            // 跳过的 tool_call 也需要一个空响应
            workingMessages.add({'role': 'tool', 'tool_call_id': toolCall.id, 'content': '工具调用被跳过'});
            continue;
          }
          // ── 自动应用 Hook 建议的参数修改 ──
          if (hookResult.modifiedArgs != null) {
            debugPrint('🪝 [Hook] beforeToolCall 修改工具参数: ${toolCall.name}');
            toolCall.arguments.addAll(hookResult.modifiedArgs!);
          }
        }

        // 根据工具类型构建步骤标题
        String stepTitle;
        String stepDesc;
        if (toolCall.name == 'think') {
          // CUA 模式下 think 表示"决策 & 下一步规划"阶段
          stepTitle = effectiveMode == AgentMode.cua ? '② 🧠 决策 & 规划' : '🧠 思考';
          stepDesc = toolCall.arguments['thought'] as String? ?? '';
        } else if (toolCall.name == 'save_memory') {
          stepTitle = '💾 保存记忆';
          stepDesc = (toolCall.arguments['content'] as String? ?? '').length > 50
              ? '${(toolCall.arguments['content'] as String).substring(0, 50)}...'
              : (toolCall.arguments['content'] as String? ?? '');
        } else if (toolCall.name == 'activate_skill') {
          stepTitle = '📋 ${toolCall.arguments['name'] ?? ''}';
          stepDesc = '正在加载技能说明...';
        } else if (toolCall.name == 'write_file') {
          stepTitle = '📝 写入文件';
          stepDesc = toolCall.arguments['path'] as String? ?? '';
        } else if (toolCall.name == 'read_file') {
          stepTitle = '📂 读取文件';
          stepDesc = toolCall.arguments['path'] as String? ?? '';
        } else if (toolCall.name == 'cua') {
          final action = toolCall.arguments['action'] as String? ?? '';
          final cuaDescMap = {
            'screenshot': '📸 截图',
            'cua_observe': '① 👁️ 观察屏幕',
            'cua_step': '🔄 自动循环（观察→决策→执行）',
            'cua_plan': '📋 任务规划',
            'find_element': '③ 🔍 定位元素',
            'mouse_click': '③ ⚡ 点击',
            'mouse_move': '③ ⚡ 移动',
            'mouse_scroll': '③ ⚡ 滚动',
            'mouse_drag': '③ ⚡ 拖拽',
            'key_type': '③ ⚡ 输入',
            'key_combo': '③ ⚡ 快捷键',
            'open_app': '③ 🚀 打开应用',
            'wait': '③ ⏳ 等待加载',
          };
          stepTitle = cuaDescMap[action] ?? '🖥️ CUA';
          if (action == 'screenshot') {
            stepDesc = '获取当前屏幕状态...';
          } else if (action.startsWith('mouse')) {
            final x = toolCall.arguments['x'];
            final y = toolCall.arguments['y'];
            stepDesc = '($x, $y)';
          } else if (action == 'key_type') {
            final text = toolCall.arguments['text'] as String? ?? '';
            stepDesc = text.length > 50 ? '${text.substring(0, 50)}...' : text;
          } else if (action == 'key_combo') {
            stepDesc = toolCall.arguments['keys'] as String? ?? '';
          } else if (action == 'open_app') {
            stepDesc = toolCall.arguments['app_name'] as String? ?? '';
          } else if (action == 'find_element') {
            final query = toolCall.arguments['query'] as String? ?? '';
            stepDesc = '查找: $query';
          } else if (action == 'cua_observe') {
            stepDesc = '分析屏幕内容，识别关键元素...';
          } else if (action == 'cua_step') {
            final goal = toolCall.arguments['task_goal'] as String? ?? '';
            stepDesc = goal.isNotEmpty ? goal : '自动执行下一步操作...';
          } else if (action == 'cua_plan') {
            final goal = toolCall.arguments['task_goal'] as String? ?? '';
            stepDesc = goal.isNotEmpty ? '规划: $goal' : '生成任务执行计划...';
          } else {
            stepDesc = action;
          }
        } else {
          stepTitle = '⚙️ ${toolCall.name}';
          final cmd = toolCall.arguments['command'] as String? ?? '';
          final script = toolCall.arguments['script'] as String? ?? '';
          stepDesc = cmd.isNotEmpty ? cmd : script;
        }

        final step = ToolStep(title: stepTitle, content: stepDesc, isLoading: true);
        steps.add(step);
        onStepUpdate?.call(step);

        // 构造实时输出回调：每收到一行输出就追加到 step.content 并通知 UI
        final outputBuffer = StringBuffer();
        void Function(String)? onOutput;
        if (onStepUpdate != null) {
          onOutput = (String line) {
            if (outputBuffer.isNotEmpty) outputBuffer.write('\n');
            outputBuffer.write(line);
            step.content = '$stepDesc\n${outputBuffer.toString()}';
            onStepUpdate(step);
          };
        }

        // 执行工具（由调用方决定具体实现）
        final result = await executeTool(toolCall, onOutput: onOutput);
        roundResultLength += result.content.length;

        // 收集输出文件（从 ToolResult.data 提取）
        if (!result.isError && result.data != null) {
          // shell_exec: 多文件列表
          final multiFiles = result.data!['_outputFiles'] as List?;
          if (multiFiles != null) {
            for (final f in multiFiles) {
              outputFiles.add(Map<String, dynamic>.from(f as Map));
            }
          } else {
            // write_file: 单文件
            final filePath = result.data!['filePath'] as String?;
            final fileSize = result.data!['fileSize'] as int?;
            if (filePath != null) {
              outputFiles.add({
                'path': filePath,
                'name': filePath.split(RegExp(r'[\\/]')).last,
                'size': fileSize ?? 0,
              });
            }
          }
        }

        // 追加工具结果消息
        var toolContent = result.content;

        // ── CUA 截图处理 ──
        // 支持两种模式：
        // 1. embedScreenshotImages=true：将截图直接作为图片嵌入对话（主模型直接看图）
        // 2. embedScreenshotImages=false：调用视觉模型分析截图，返回文字描述追加到 tool 结果
        // 两种模式都同时处理 screenshot 和 confirm_screenshot
        final imageType = result.data?['imageType'];
        final isScreenshot = !result.isError &&
            (imageType == 'screenshot' || imageType == 'confirm_screenshot');

        if (isScreenshot) {
          final b64 = result.data!['base64'] as String?;
          final mime = result.data!['mimeType'] as String? ?? 'image/jpeg';

          if (embedScreenshotImages && b64 != null && b64.isNotEmpty) {
            // ── 模式 1：直接嵌入图片到对话（主模型多模态） ──
            // 截图作为 image_url 类型的 user 消息注入，主模型可以直接看到
            step.content = '$stepDesc\n📸 已嵌入截图到对话';
            step.isLoading = false;
            onStepUpdate?.call(step);
          } else if (analyzeScreenshot != null && b64 != null && b64.isNotEmpty) {
            // ── 模式 2：调用视觉模型分析截图，返回文字描述 ──
            // 注意：CUA 模式下 analyzeScreenshot 为 null，不会执行此分支
            // CUA 模式的视觉分析在 cua_observe 中完成
            step.content = '$stepDesc\n🔍 正在分析截图...';
            step.isLoading = true;
            onStepUpdate?.call(step);

            // 提取屏幕元信息，传给视觉分析
            final screenInfo = <String, dynamic>{
              'width': result.data!['width'] ?? 1920,
              'height': result.data!['height'] ?? 1080,
            };

            try {
              debugPrint('🔍 开始视觉分析: ${b64.length} 字符 base64');
              final analysis = await analyzeScreenshot(b64, mime, screenInfo);
              if (analysis != null && analysis.isNotEmpty) {
                debugPrint('🔍 视觉分析结果: ${analysis.length} 字符');
                toolContent = '$toolContent\n\n📊 屏幕分析:\n$analysis';
              } else {
                debugPrint('⚠️ 视觉分析返回 null/空 — 可能是视觉模型未配置或调用失败');
              }
            } catch (e) {
              debugPrint('⚠️ 视觉分析失败: $e');
            }
          }
          // CUA 模式下 analyzeScreenshot 为 null，直接跳过（视觉分析在 cua_observe 中完成）
        }

        final toolMsg = {
          'role': 'tool',
          'tool_call_id': toolCall.id,
          'content': toolContent,
        };
        workingMessages.add(toolMsg);
        allApiMessages.add(Map<String, dynamic>.from(toolMsg));

        // ── CUA 模式：think 工具执行后标记任务解析完成 ──
        if (effectiveMode == AgentMode.cua && toolCall.name == 'think') {
          cuaTaskParsed = true;
          debugPrint('✅ [Agent] CUA 任务解析已完成（think 工具已执行）');
        }

        // ── 多模态截图嵌入：将截图作为图片直接注入对话 ──
        if (embedScreenshotImages && isScreenshot) {
          final b64 = result.data!['base64'] as String?;
          final mime = result.data!['mimeType'] as String? ?? 'image/jpeg';
          if (b64 != null && b64.isNotEmpty) {
            final frontmostApp = result.data!['frontmostApp'] as String? ?? '';
            final somCount = result.data!['somMarkerCount'] as int? ?? 0;
            // 构建截图上下文提示：告诉模型前台 app 名称、SOM 标记数量
            final appHint = frontmostApp.isNotEmpty
                ? '前台应用: $frontmostApp' : '';
            final somHint = somCount > 0
                ? '图上已用编号圆圈标记了 $somCount 个可交互元素' : '';
            final contextHint = [appHint, somHint]
                .where((s) => s.isNotEmpty).join('，');

            final imageHint = imageType == 'confirm_screenshot'
                ? '这是操作后的屏幕截图，请确认操作结果。${contextHint.isNotEmpty ? '($contextHint)' : ''}'
                : '这是当前屏幕截图（坐标已归一化到 0~1000，左上角 (0,0)，右下角 (1000,1000)）。${contextHint.isNotEmpty ? '$contextHint。' : ''}如果前台应用不是你要操作的，请先调用 open_app 切换。';
            final imageMsg = {
              'role': 'user',
              'content': [
                {'type': 'text', 'text': imageHint},
                {
                  'type': 'image_url',
                  'image_url': {'url': 'data:$mime;base64,$b64'},
                },
              ],
            };
            workingMessages.add(imageMsg);
            debugPrint('📸 已将 ${imageType ?? 'screenshot'} 嵌入对话消息（${b64.length} 字符 base64）');
          }
        }

        // ── CUA 任务完成信号检测 ──
        // 完成信号区分：
        // 【强信号 - 整个任务完成】：
        //   - data['done'] = true（cua_step 明确返回完成）
        //   - data['screenStatus'] = 'Done'（VLM 判定整个屏幕状态为完成，全局视角）
        // 【弱信号 - 子任务完成】：
        //   - data['suggestion']['action'] = 'done'（VLM 建议下一步是完成，子任务视角）
        //   - ⚠️ 这只代表当前步骤完成，不代表整个任务完成，不触发 cuaTaskDone
        if (effectiveMode == AgentMode.cua && toolCall.name == 'cua' && !result.isError && result.data != null) {
          final data = result.data!;
          final screenStatus = data['screenStatus'] as String?;
          final isDone = data['done'] as bool?;

          // ── 任务进度追踪 ──
          final taskProgress = data['taskProgress'] as Map<String, dynamic>?;
          if (taskProgress != null) {
            cuaTaskProgress = taskProgress['currentStep'] as String? ?? '';
            cuaCompletionPercentage = taskProgress['completionPercentage'] as int? ?? 0;
            debugPrint('📊 [Agent] CUA 任务进度: $cuaTaskProgress (${cuaCompletionPercentage}%)');
          }

          // 只检测强信号
          final isTaskDone = screenStatus?.toLowerCase() == 'done' || isDone == true;

          if (isTaskDone) {
            cuaTaskDone = true;
            debugPrint('🎯 [Agent] CUA 任务完成（强信号）: screenStatus=$screenStatus, done=$isDone');
          } else {
            // 检查弱信号，打印提示
            final suggestion = data['suggestion'] as Map<String, dynamic>?;
            final suggestionAction = suggestion?['action'] as String?;
            if (suggestionAction?.toLowerCase() == 'done') {
              debugPrint('ℹ️ [Agent] VLM 建议 action=done（子任务完成），但 screenStatus=$screenStatus，继续执行');
            }
          }
        }

        // 记录技能名
        if (toolCall.name != 'think' && toolCall.name != 'save_memory') {
          skillNames.add(toolCall.name);
        }

        // 更新步骤状态（UI 展示用，已在可折叠面板中，不截断）
        if (toolCall.name == 'think') {
          step.content = stepDesc;
        } else if (!result.isError
            && (result.data?['imageType'] == 'screenshot'
                || result.data?['imageType'] == 'confirm_screenshot')) {
          // CUA 截图/确认截图：用特殊标记嵌入图片路径（UI 端从路径加载图片渲染）
          final imgPath = result.data!['filePath'] as String? ?? '';
          final imgTag = imgPath.isNotEmpty ? '\n\n__IMG__:$imgPath' : '';
          step.content = '$stepDesc\n${result.content}$imgTag';
        } else {
          step.content = result.isError
              ? '$stepDesc\n❌ ${result.content}'
              : '$stepDesc\n${result.content}';
        }
        step.isLoading = false;
        step.isFailed = result.isError;
        onStepUpdate?.call(step);
        
        // ── StepEvaluator：评估工具执行结果 ──
        if (evaluator != null) {
          try {
            final evalStep = EnhancedPlanStep(
              id: toolCall.id,
              description: stepDesc,
              toolName: toolCall.name,
              criticality: 'medium',
              canRetry: true,
              maxRetries: 2,
            );
            final evaluation = await evaluator.evaluate(evalStep, result);
            if (!evaluation.allPassed) {
              debugPrint('📋 [Agent] 评估结果: ${evaluation.decision.name}'
                  ' (问题: ${evaluation.issues.map((i) => i.message).join("; ")})');

              switch (evaluation.decision) {
                case EvalDecision.proceedWithWarning:
                  // 继续但注入警告
                  deferredHookMessages.add({
                    'role': 'user',
                    'content': '【评估警告】${evaluation.issues.where((i) => i.severity == "warning").map((i) => i.message).join("; ")}'
                        '${evaluation.issues.where((i) => i.suggestion != null).map((i) => i.suggestion).where((s) => s != null).isNotEmpty ? "。建议: ${evaluation.issues.where((i) => i.suggestion != null).map((i) => i.suggestion).whereType<String>().join("; ")}" : ""}',
                  });
                  stateMachine?.transition(SessionState.evaluating, reason: '评估发现警告');
                  stateMachine?.transition(SessionState.executing, reason: '继续执行');
                  break;

                case EvalDecision.skipStep:
                  debugPrint('⏭️ [Agent] 评估决策: 跳过当前步骤 ${toolCall.name}');
                  step.content = '$stepDesc\n⏭️ 已跳过: ${evaluation.issues.first.message}';
                  step.isLoading = false;
                  onStepUpdate?.call(step);
                  continue;

                case EvalDecision.replan:
                  debugPrint('🔄 [Agent] 评估决策: 需要重新规划');
                  stateMachine?.transition(SessionState.evaluating, reason: '评估失败');
                  stateMachine?.transition(SessionState.planning, reason: '重新规划');
                  // 注入重新规划提示
                  deferredHookMessages.add({
                    'role': 'user',
                    'content': '【评估决策】当前方法不可行: ${evaluation.issues.first.message}。'
                        '请停止当前操作，重新思考并采用完全不同的方法。',
                  });
                  break;

                case EvalDecision.rollbackAndRetry:
                case EvalDecision.retry:
                  if (evalStep.canRetry && evalStep.maxRetries > 0) {
                    debugPrint('🔄 [Agent] 评估决策: 重试 ${toolCall.name}');
                    stateMachine?.transition(SessionState.evaluating, reason: '需要重试');
                    stateMachine?.transition(SessionState.executing, reason: '重试执行');
                  }
                  break;

                case EvalDecision.rollbackAndAbort:
                  debugPrint('🛑 [Agent] 评估决策: 终止执行');
                  stateMachine?.transition(SessionState.failed, reason: '评估判定必须终止');
                  final abortResult = AgentLoopResult(
                    text: '任务执行中止：${evaluation.issues.first.message}',
                    apiMessages: allApiMessages,
                    skillNames: skillNames,
                    outputFiles: outputFiles,
                    steps: steps,
                  );
                  await hookManager.triggerLoopEnd(abortResult);
                  return abortResult;

                case EvalDecision.proceed:
                  // 正常继续
                  break;
              }
            }
          } catch (e) {
            debugPrint('⚠️ [Agent] StepEvaluator 执行失败: $e');
          }
        }

        // ── 触发 afterToolCall Hooks ──
        await hookManager.triggerAfterToolCall(toolCall, result, context);
        
        // ── 如果工具执行出错，触发 onToolError Hooks ──
        if (result.isError) {
          await hookManager.triggerToolError(toolCall, result.content, context);
          
          // ── 记录失败的工具调用（用于下一轮检测重试） ──
          lastFailedTools[toolCall.name] = toolCall;
          
          // ── 记录到连续失败检测列表（AgentLoop 级安全网） ──
          if (toolCall.name != 'think' && toolCall.name != 'save_memory') {
            recentFailedToolNames.add(toolCall.name);
            if (recentFailedToolNames.length > maxFailedCalls * 2) {
              recentFailedToolNames.removeRange(0, recentFailedToolNames.length - maxFailedCalls);
            }
          }
        } else {
          // 成功后清除重试计数
          retryCountMap.remove(toolCall.name);
        }
      }

      // ── 追加缓冲的 hook 注入消息（在所有 tool 响应之后，避免打断 tool_calls 连续性） ──
      for (final hookMsg in deferredHookMessages) {
        workingMessages.add(hookMsg);
      }
      deferredHookMessages.clear();

      // ── CUA 模式防护：只思考不操作时强制提醒（任务完成除外） ──
      if (effectiveMode == AgentMode.cua) {
        if (cuaTaskDone) {
          // 任务已完成，注入完成提示引导 LLM 输出总结
          debugPrint('🎯 [Agent] CUA 任务已完成，注入完成提示');
          workingMessages.add({
            'role': 'user',
            'content': '【系统提示】cua_observe 已确认任务目标达成（screenStatus=Done）。'
                '请直接输出简短的任务完成总结，不要再调用任何工具。',
          });
        } else {
          final hasCua = response.toolCalls.any((tc) => tc.name == 'cua');
          if (!hasCua) {
            debugPrint('⚠️ [Agent] CUA 模式本轮只有 think，无 cua 操作 → 注入强制提醒');
            workingMessages.add({
              'role': 'user',
              'content': '【系统强制提醒】你处于 CUA 模式，必须通过 cua(action=...) 工具执行实际操作。'
                  '思考（think）只是决策阶段，不能代替操作。请调用 cua(action="cua_observe") 观察屏幕，然后执行操作。'
                  '⛔ 需要点击时必须先 find_element 定位，再 mouse_click（坐标不匹配会被系统拦截）。',
            });
          }
        }
      }

      // ── 循环防护：同类工具连续失败检测 ──
      if (recentFailedToolNames.length >= maxFailedCalls) {
        final lastN = recentFailedToolNames.sublist(recentFailedToolNames.length - maxFailedCalls);
        if (lastN.toSet().length == 1) {
          final toolName = lastN.first;
          debugPrint('⚠️ [Agent] 连续 $maxFailedCalls 次 $toolName 失败，强制停止');
          _addStep(steps, '⚠️ 失败检测', '$toolName 连续失败 $maxFailedCalls 次，已终止', onStepUpdate);
          workingMessages.add({
            'role': 'user',
            'content': '【系统提示】$toolName 已经连续失败了 $maxFailedCalls 次。请停止重试，换一种完全不同的方法来完成任务，或者直接告诉用户当前方法不可行。',
          });
          try {
            final stopResp = await _chat(provider, workingMessages, config: config, cancellationToken: cancellationToken);
            final result = AgentLoopResult(
              text: stopResp.text,
              apiMessages: allApiMessages,
              skillNames: skillNames,
              outputFiles: outputFiles,
              steps: steps,
            );
            await hookManager.triggerLoopEnd(result);
            return result;
          } catch (_) {
            final result = AgentLoopResult(
              text: '嘎...鹅宝的某个技能连续失败了 $maxFailedCalls 次，已自动终止~ 🦢',
              apiMessages: allApiMessages,
              skillNames: skillNames,
              outputFiles: outputFiles,
              steps: steps,
            );
            await hookManager.triggerLoopEnd(result);
            return result;
          }
        }
      }

      // ── 循环防护：无进展检测（CUA 模式跳过，因为 CUA 操作结果长度天然相近） ──
      final isCuaMode = effectiveMode == AgentMode.cua;
      if (!isCuaMode) {
      recentResultLengths.add(roundResultLength);
      if (recentResultLengths.length > maxStagnantRounds) recentResultLengths.removeAt(0);
      if (recentResultLengths.length >= maxStagnantRounds) {
        final avg = recentResultLengths.reduce((a, b) => a + b) / recentResultLengths.length;
        final variance = recentResultLengths.map((l) => (l - avg) * (l - avg)).reduce((a, b) => a + b) / recentResultLengths.length;
        if (variance < 100) {
          debugPrint('⚠️ [Agent] 连续 ${recentResultLengths.length} 轮结果停滞，强制停止');
          _addStep(steps, '⚠️ 无进展检测', '工具调用连续多轮无变化，已终止', onStepUpdate);
          workingMessages.add({
            'role': 'user',
            'content': '【系统提示】工具调用连续多轮没有产生新进展，请停止调用工具，直接回复用户。',
          });
          try {
            final stopResp = await _chat(provider, workingMessages, config: config, cancellationToken: cancellationToken);
            final result = AgentLoopResult(
              text: stopResp.text,
              apiMessages: allApiMessages,
              skillNames: skillNames,
              outputFiles: outputFiles,
              steps: steps,
            );
            await hookManager.triggerLoopEnd(result);
            return result;
          } catch (_) {
            final result = AgentLoopResult(
              text: '嘎...鹅宝的工具调用陷入停滞，已自动终止~ 🦢',
              apiMessages: allApiMessages,
              skillNames: skillNames,
              outputFiles: outputFiles,
              steps: steps,
            );
            await hookManager.triggerLoopEnd(result);
            return result;
          }
        }
      }
      } // end if (!isCuaMode) — 无进展检测

      debugPrint('🔧 [Agent 第${turn + 1}轮结束] 共执行 ${response.toolCalls.length} 个工具，结果 ${roundResultLength} 字符');
    }

    // ── 达到最大轮数 ──
    debugPrint('⚠️ [Agent] 达到最大轮数 $maxTurns，请求最终总结');
    _addStep(steps, '⚠️ 轮数限制', '已达 $maxTurns 轮，请求最终总结', onStepUpdate);
    workingMessages.add({
      'role': 'user',
      'content': '【系统提示】已达到最大工具调用轮数 ($maxTurns)。请停止调用工具，直接基于已有结果给出最终回复。',
    });

    try {
      final finalResp = await _chat(provider, workingMessages, config: config, cancellationToken: cancellationToken);
      final result = AgentLoopResult(
        text: finalResp.text,
        apiMessages: allApiMessages,
        skillNames: skillNames,
        outputFiles: outputFiles,
        steps: steps,
      );
      
      // ── 触发循环结束 Hooks ──
      await hookManager.triggerLoopEnd(result);
      
      return result;
    } catch (_) {
      final result = AgentLoopResult(
        text: '嘎...鹅宝调用了太多次技能，脑子转晕了~ 🦢',
        apiMessages: allApiMessages,
        skillNames: skillNames,
        outputFiles: outputFiles,
        steps: steps,
      );
      
      // ── 触发循环结束 Hooks ──
      await hookManager.triggerLoopEnd(result);
      
      return result;
    }
  }
  
  /// 从消息列表中提取用户原始请求
  static String _extractUserRequest(List<Map<String, dynamic>> messages) {
    // 找到最后一条用户消息
    for (int i = messages.length - 1; i >= 0; i--) {
      if (messages[i]['role'] == 'user') {
        final content = messages[i]['content'];
        if (content is String && content.isNotEmpty) {
          return content.length > 200 
              ? '${content.substring(0, 200)}...'
              : content;
        }
      }
    }
    return '';
  }

  /// 包装 provider.chat 调用，自动处理 CancellationToken、Dio 取消和 429 重试
  static int _chatCallCount = 0;
  static DateTime? _lastChatTime;
  static const _maxRetries = 3;

  static Future<AgentResponse> _chat(
    LLMProvider provider,
    List<Map<String, dynamic>> messages, {
    LLMConfig? config,
    List<Map<String, dynamic>>? tools,
    CancellationToken? cancellationToken,
  }) async {
    // 轮间间隔：防止连续请求触发 429
    if (_lastChatTime != null && _chatCallCount > 0) {
      final elapsed = DateTime.now().difference(_lastChatTime!);
      if (elapsed.inMilliseconds < 1000) {
        final wait = 1000 - elapsed.inMilliseconds;
        await Future.delayed(Duration(milliseconds: wait));
      }
    }
    _chatCallCount++;
    _lastChatTime = DateTime.now();

    final dioToken = cancellationToken?.newDioCancelToken();

    for (int attempt = 0; attempt <= _maxRetries; attempt++) {
      try {
        return await provider.chat(
          messages,
          config: config,
          tools: tools,
          cancelToken: dioToken,
        );
      } on DioException catch (e) {
        if (e.type == DioExceptionType.cancel) throw CancelledException();

        final statusCode = e.response?.statusCode;
        // 打印 4xx/5xx 错误详情，便于排查参数问题
        if (statusCode != null && statusCode >= 400) {
          debugPrint('❌ [Agent] LLM API 错误 [$statusCode]: ${e.response?.data}');
        }
        if (statusCode == 429 && attempt < _maxRetries) {
          // 读取 Retry-After 头，否则指数退避（2s, 4s, 8s）
          final retryAfter = e.response?.headers.value('retry-after');
          final waitSeconds = (retryAfter != null && int.tryParse(retryAfter) != null)
              ? int.parse(retryAfter)
              : (2 << attempt); // 2, 4, 8
          debugPrint('⏳ [Agent] 429 限流，${attempt + 1}/$_maxRetries 次重试，等待 ${waitSeconds}s...');
          await Future.delayed(Duration(seconds: waitSeconds));
          continue;
        }
        rethrow;
      }
    }
    throw Exception('超过最大重试次数');
  }

  static void _addStep(List<ToolStep> steps, String title, String content, void Function(ToolStep)? onStepUpdate) {
    final step = ToolStep(title: title, content: content);
    steps.add(step);
    onStepUpdate?.call(step);
  }

  /// 从工具调用列表生成执行计划
  static PendingPlan _generatePlan(List<ToolCall> toolCalls, String userRequest) {
    final planId = DateTime.now().millisecondsSinceEpoch.toString();
    final steps = <PlanStep>[];
    
    for (int i = 0; i < toolCalls.length; i++) {
      final call = toolCalls[i];
      steps.add(PlanStep(
        id: '${planId}_$i',
        order: i + 1,
        description: _describeToolCall(call),
        toolName: call.name,
        toolArgs: call.arguments,
      ));
    }
    
    return PendingPlan(
      id: planId,
      userRequest: userRequest,
      title: '执行计划',
      steps: steps,
    );
  }
  
  /// 描述工具调用（用于计划展示）
  static String _describeToolCall(ToolCall call) {
    final args = call.arguments;
    
    switch (call.name) {
      case 'write_file':
        final path = args['path'] as String? ?? '';
        return '写入文件: $path';
      case 'read_file':
        final path = args['path'] as String? ?? '';
        return '读取文件: $path';
      case 'shell_exec':
        final cmd = args['command'] as String? ?? '';
        return '执行命令: ${cmd.length > 50 ? '${cmd.substring(0, 50)}...' : cmd}';
      case 'batch_file':
        final action = args['action'] as String? ?? '';
        return '批量文件操作: $action';
      case 'web_search':
        final query = args['query'] as String? ?? '';
        return '网络搜索: $query';
      case 'web_interact':
        final action = args['action'] as String? ?? '';
        return 'Web 操作: $action';
      case 'save_memory':
        return '保存记忆';
      case 'think':
        return '思考规划';
      default:
        return '执行 ${call.name}';
    }
  }
  
  /// 将计划格式化为文本
  static String _formatPlanAsText(PendingPlan plan) {
    final buffer = StringBuffer();
    buffer.writeln('📋 **执行计划**');
    buffer.writeln();
    buffer.writeln('**目标**: ${plan.userRequest}');
    buffer.writeln();
    buffer.writeln('**步骤**:');
    
    for (final step in plan.steps) {
      final status = step.isExecuted 
          ? '✅' 
          : step.isSkipped 
              ? '⏭️' 
              : '⬜';
      buffer.writeln('$status ${step.order}. ${step.description}');
    }
    
    buffer.writeln();
    buffer.writeln('---');
    buffer.writeln('💡 **确认执行请回复「确认」或「执行」，取消请回复「取消」**');
    
    return buffer.toString();
  }

  /// 将结构化 DAG 计划格式化为文本（展示依赖关系和额外信息）
  static String _formatStructuredPlanAsText(PendingPlan plan) {
    final buffer = StringBuffer();
    buffer.writeln('📋 **结构化执行计划**');
    buffer.writeln();
    buffer.writeln('**目标**: ${plan.userRequest}');
    if (plan.successCriteria != null) {
      buffer.writeln('**成功条件**: ${plan.successCriteria}');
    }
    if (plan.estimatedTokens > 0) {
      buffer.writeln('**预估消耗**: ~${plan.estimatedTokens} tokens, ~${plan.estimatedDuration.inSeconds}s');
    }
    buffer.writeln();
    buffer.writeln('**步骤**:');
    
    for (final step in plan.steps) {
      final status = step.isExecuted 
          ? '✅' 
          : step.isSkipped 
              ? '⏭️' 
              : '⬜';
      final depInfo = step.dependsOn.isNotEmpty
          ? ' (依赖: ${step.dependsOn.join(", ")})'
          : '';
      final critInfo = step.criticality != 'medium'
          ? ' [${step.criticality}]'
          : '';
      buffer.writeln('$status ${step.order}. ${step.description}$depInfo$critInfo');
    }
    
    buffer.writeln();
    buffer.writeln('---');
    buffer.writeln('💡 **确认执行请回复「确认」或「执行」，取消请回复「取消」**');
    
    return buffer.toString();
  }
  
  /// 构建规划提示，引导 LLM 拆解任务（参考 Team 的 JSON 拆解机制）
  static String _buildPlanningPrompt(String userRequest, List<ToolCall> initialToolCalls) {
    final toolsInfo = initialToolCalls.isEmpty
        ? ''
        : '\n可用工具参考：\n${initialToolCalls.map((tc) => '- ${tc.name}').toSet().join('\n')}\n';

    return '''请将以下用户需求分解为可执行的子任务步骤。

用户需求：
$userRequest
$toolsInfo
请以 JSON 数组格式输出任务分解结果，每个元素包含：
- task: 步骤描述（简洁明确，一句话说清楚要做什么）
- tool: 可能用到的工具名（可选，没有则为 null）

分解原则：
1. 每个步骤应该是一个明确、可独立执行的动作
2. 步骤之间按执行顺序排列
3. 步骤粒度适中（3-8个步骤为宜），不要太细也不要太粗
4. 对于知识类/分析类任务，步骤应该是信息收集→分析→输出的逻辑
5. 对于操作类任务，步骤应该对应具体的文件操作或命令执行

示例1（操作类）：
[
  {"task": "读取当前项目的配置文件，了解项目结构", "tool": "read_file"},
  {"task": "创建新的工具函数文件 utils.dart", "tool": "write_file"},
  {"task": "在主文件中导入并集成新工具函数", "tool": "write_file"},
  {"task": "运行测试验证功能正常", "tool": "shell_exec"}
]

示例2（分析类）：
[
  {"task": "梳理当前宏观经济核心指标（GDP、CPI、就业）", "tool": null},
  {"task": "分析产业结构变化和新兴产业发展趋势", "tool": null},
  {"task": "评估政策环境和外部风险因素", "tool": null},
  {"task": "综合分析并输出结构化报告", "tool": null}
]

只输出 JSON 数组，不要其他内容。''';
  }

  /// 从 LLM 规划响应中解析出结构化计划（优先 JSON，回退文本）
  static PendingPlan _parsePlanFromResponse(String responseText, String userRequest) {
    final planId = DateTime.now().millisecondsSinceEpoch.toString();
    final steps = <PlanStep>[];

    // 优先尝试解析 JSON 数组
    final jsonMatch = RegExp(r'\[[\s\S]*\]').firstMatch(responseText);
    if (jsonMatch != null) {
      try {
        final tasks = jsonDecode(jsonMatch.group(0)!) as List;
        for (int i = 0; i < tasks.length; i++) {
          final taskData = tasks[i] as Map<String, dynamic>;
          final task = taskData['task'] as String? ?? '';
          if (task.isEmpty) continue;

          steps.add(PlanStep(
            id: '${planId}_${i + 1}',
            order: i + 1,
            description: task,
            toolName: taskData['tool'] as String?,
          ));
        }
      } catch (e) {
        debugPrint('⚠️ [Plan] JSON 解析失败: $e');
      }
    }

    // JSON 解析失败时回退：匹配 "**步骤N**:" 格式
    if (steps.isEmpty) {
      final stepPattern = RegExp(r'\*\*步骤(\d+)\*\*[：:]\s*(.+?)(?=\n\*\*|###|$)', multiLine: true);
      int stepOrder = 1;
      for (final match in stepPattern.allMatches(responseText)) {
        var name = match.group(2)?.trim() ?? '';
        if (name.contains('|')) {
          name = name.split('\n').firstWhere((l) => !l.contains('|'), orElse: () => '');
        }
        if (name.isEmpty || name.length > 100) continue;
        steps.add(PlanStep(id: '${planId}_$stepOrder', order: stepOrder++, description: name));
      }
    }

    // 仍然没有步骤，创建默认
    if (steps.isEmpty) {
      steps.add(PlanStep(
        id: '${planId}_1',
        order: 1,
        description: userRequest.length > 80 ? '${userRequest.substring(0, 80)}...' : userRequest,
      ));
    }

    return PendingPlan(id: planId, userRequest: userRequest, title: '执行计划', steps: steps);
  }

  /// 从纯文本响应构建计划（无工具调用时使用）
  static PendingPlan _buildPlanFromTextResponse(String responseText, String userRequest) {
    return _parsePlanFromResponse(responseText, userRequest);
  }

  // ═══════════════════════════════════════════
  // 截图滑动窗口（优化3：记忆压缩/上下文窗口管理）
  // ═══════════════════════════════════════════

  /// 截图滑动窗口：保留最近 N 张截图，旧截图压缩为带上下文的文字摘要
  ///
  /// CUA 模式下每张截图约 100-300KB（JPEG 85%），base64 后约 130-400KB。
  /// 多轮操作后对话会迅速膨胀（maxTurns=30，每轮 2 张截图 = 60 张截图）。
  /// 此方法在每轮 LLM 调用前执行，将超出窗口的旧截图替换为摘要文本。
  /// 改进：保留截图前后的操作上下文（tool call + tool result），让模型知道
  /// 之前做了什么操作、得到了什么结果，而不只是丢弃视觉信息。
  static void _applyScreenshotSlidingWindow(
    List<Map<String, dynamic>> messages,
    int maxScreenshots,
  ) {
    // 找出所有包含截图的 user 消息（image_url 类型）
    final screenshotIndices = <int>[];
    for (var i = 0; i < messages.length; i++) {
      final msg = messages[i];
      if (msg['role'] != 'user') continue;
      final content = msg['content'];
      if (content is! List) continue;

      final hasImage = content.any((item) =>
          item is Map && item['type'] == 'image_url');
      if (hasImage) {
        screenshotIndices.add(i);
      }
    }

    if (screenshotIndices.length <= maxScreenshots) return;

    // 需要压缩的截图数量
    final toCompressCount = screenshotIndices.length - maxScreenshots;

    for (var i = 0; i < toCompressCount; i++) {
      final msgIdx = screenshotIndices[i];
      final msg = messages[msgIdx];
      final content = msg['content'] as List;

      // 提取截图文本提示（"这是操作后的屏幕截图" 等）
      final imageHint = content
          .where((item) => item is Map && item['type'] == 'text')
          .map((item) => (item as Map)['text'] as String? ?? '')
          .join(' ')
          .trim();

      // 提取上下文：查找截图前后的 tool 消息来获取操作信息
      final context = _extractScreenshotContext(messages, msgIdx);

      // 构建压缩后的摘要，包含操作上下文
      final summaryBuffer = StringBuffer();
      if (context.isNotEmpty) {
        summaryBuffer.write('[📷 早期截图已压缩] ');
        summaryBuffer.write(context);
      } else if (imageHint.isNotEmpty) {
        summaryBuffer.write('[📷 早期截图已压缩] $imageHint');
      } else {
        summaryBuffer.write('[📷 早期截图已压缩以节省 token，仅保留最近 $maxScreenshots 张截图上下文]');
      }

      messages[msgIdx] = {
        'role': 'user',
        'content': summaryBuffer.toString(),
      };
    }

    if (toCompressCount > 0) {
      debugPrint('📷 截图滑动窗口: 压缩了 $toCompressCount 张旧截图，保留最近 $maxScreenshots 张');
    }
  }

  /// 提取截图消息附近的操作上下文
  ///
  /// 查找截图前后的 tool call 和 tool result，生成简要操作摘要。
  /// 例如: "点击(500,300) → 成功; 输入'hello' → 成功"
  static String _extractScreenshotContext(List<Map<String, dynamic>> messages, int screenshotIdx) {
    final parts = <String>[];

    // 向前查找最近的 tool call（assistant 消息含 tool_calls）
    for (var i = screenshotIdx - 1; i >= 0 && i >= screenshotIdx - 4; i--) {
      final msg = messages[i];
      if (msg['role'] == 'assistant' && msg['tool_calls'] != null) {
        final toolCalls = msg['tool_calls'] as List;
        for (final tc in toolCalls) {
          final func = tc['function'] as Map<String, dynamic>?;
          if (func == null) continue;
          final name = func['name'] as String? ?? '';
          final argsStr = func['arguments'] as String? ?? '{}';

          // 只提取 CUA 操作上下文
          if (name == 'cua') {
            try {
              final args = jsonDecode(argsStr) as Map<String, dynamic>;
              final action = args['action'] as String? ?? '';
              if (action == 'screenshot') continue; // 跳过截图操作本身
              final desc = _briefCuaAction(action, args);
              if (desc.isNotEmpty) parts.add(desc);
            } catch (_) {}
          }
        }
        break; // 只查最近一个 assistant 消息
      }
    }

    // 向后查找最近的 tool result
    for (var i = screenshotIdx + 1; i < messages.length && i <= screenshotIdx + 4; i++) {
      final msg = messages[i];
      if (msg['role'] == 'tool') {
        final content = msg['content'] as String? ?? '';
        if (content.length > 200) {
          // 提取第一行作为结果摘要
          final firstLine = content.split('\n').first;
          parts.add('结果: ${firstLine.length > 80 ? '${firstLine.substring(0, 80)}...' : firstLine}');
        } else if (content.isNotEmpty) {
          parts.add('结果: $content');
        }
        break;
      }
    }

    return parts.isEmpty ? '' : parts.join(' → ');
  }

  /// 生成 CUA 操作的简要描述
  static String _briefCuaAction(String action, Map<String, dynamic> args) {
    switch (action) {
      case 'mouse_click':
        final x = args['x'];
        final y = args['y'];
        final btn = args['button'] ?? 'left';
        return '点击($x,$y) $btn';
      case 'key_type':
        final text = args['text'] as String? ?? '';
        return '输入"${text.length > 20 ? '${text.substring(0, 20)}...' : text}"';
      case 'key_combo':
        return '快捷键 ${args['keys'] ?? ''}';
      case 'mouse_scroll':
        return '滚动(${args['scroll_x']}, ${args['scroll_y']})';
      case 'mouse_drag':
        return '拖拽(${args['x']},${args['y']})→(${args['target_x']},${args['target_y']})';
      case 'open_app':
        return '打开${args['app_name'] ?? ''}';
      case 'find_element':
        return '查找元素: ${args['query'] ?? ''}';
      default:
        return action;
    }
  }
}
