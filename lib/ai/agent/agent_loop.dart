import 'dart:convert';
import 'package:flutter/foundation.dart';
import '../../models/models.dart';
import 'agent_types.dart';
import 'agent_hooks.dart';
import 'agent_mode.dart';
import 'sub_agent_types.dart';
import '../providers/llm_provider.dart';

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
    int maxTurns = 30,
    void Function(ToolStep step)? onStepUpdate,
    void Function(String failedTool, String summary, String error, String solution)? onToolFailure,
    CancellationToken? cancellationToken,
    List<AgentHook>? hooks,
    SubAgentContext? subAgentContext,
    String? userRequest,
    AgentMode mode = AgentMode.craft,
    void Function(PendingPlan plan)? onPlanGenerated,
  }) async {
    // 创建 Hook 管理器
    final hookManager = HookManager();
    if (hooks != null) {
      for (final hook in hooks) {
        hookManager.register(hook);
      }
    }
    
    // 创建 Agent 循环上下文
    final context = AgentLoopContext(
      maxTurns: maxTurns,
      subAgentContext: subAgentContext,
      userRequest: userRequest ?? _extractUserRequest(messages),
    );
    
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

    // ── 循环防护 ──
    const maxDuplicateRounds = 3;
    const maxStagnantRounds = 4;
    const maxFailedCalls = 3;
    final recentSignatures = <String>[];
    final recentResultLengths = <int>[];
    final recentFailedToolNames = <String>[];

    // ── 重试跟踪（用于触发 beforeRetry 钩子） ──
    final lastFailedTools = <String, ToolCall>{}; // 工具名 → 最后失败的调用
    final retryCountMap = <String, int>{}; // 工具名 → 重试次数

    for (var turn = 0; turn < maxTurns; turn++) {
      debugPrint('🔄 [Agent 第${turn + 1}轮] 发送 ${workingMessages.length} 条消息');

      // ── 调用 LLM ──
      final response = await provider.chat(
        workingMessages,
        config: config,
        tools: tools,
      );

      // ── 检查是否需要执行工具 ──
      if (!response.hasToolCalls) {
        // LLM 返回纯文本 → 循环结束
        final text = response.text;
        debugPrint('🔄 [Agent] LLM 返回纯文本 (${text.length} 字符)，循环结束');

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
      
      // ── 触发 LLM 响应后 Hook ──
      await hookManager.triggerAfterLLMResponse(response);
      
      // ── 检查执行模式 ──
      if (mode == AgentMode.ask) {
        // Ask 模式：不执行工具，直接返回响应
        debugPrint('💬 [Agent] Ask 模式，跳过工具执行');
        final toolNames = response.toolCalls.map((tc) => tc.name).join(', ');
        final result = AgentLoopResult(
          text: '【Ask 模式】我只提供信息和建议，不执行实际操作。\n\n'
              '你想执行的操作涉及以下工具: $toolNames\n\n'
              '如需执行操作，请切换到 **Craft 模式**（立即执行）或 **Plan 模式**（先规划后执行）。',
          apiMessages: allApiMessages,
          skillNames: [],
          outputFiles: [],
          steps: steps,
        );
        await hookManager.triggerLoopEnd(result);
        return result;
      }
      
      if (mode == AgentMode.plan) {
        // Plan 模式：先让 LLM 思考并拆分任务，再生成计划
        debugPrint('📋 [Agent] Plan 模式，引导 LLM 思考并拆分任务');
        
        // 注入规划提示，引导 LLM 进行任务分析和拆分
        final planningPrompt = _buildPlanningPrompt(userRequest ?? '', response.toolCalls);
        workingMessages.add({
          'role': 'user',
          'content': planningPrompt,
        });
        
        // 让 LLM 思考并生成计划
        final planResponse = await provider.chat(
          workingMessages,
          config: config,
          tools: [], // Plan 模式下不返回工具调用，只返回纯文本计划
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
          final stopResp = await provider.chat(workingMessages, config: config);
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
                continue;
              }
              if (retryHookResult.shouldInject && retryHookResult.injectedMessage != null) {
                // 注入反思消息
                workingMessages.add({
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
            continue;
          }
          if (hookResult.shouldInject && hookResult.injectedMessage != null) {
            // 注入消息
            workingMessages.add({
              'role': 'user',
              'content': hookResult.injectedMessage!,
            });
          }
          if (hookResult.shouldSkip) {
            // 跳过当前工具
            debugPrint('🪝 [Hook] 跳过工具: ${toolCall.name}');
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
          stepTitle = '🧠 思考';
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
        } else {
          stepTitle = '⚙️ 执行';
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
        final toolMsg = {
          'role': 'tool',
          'tool_call_id': toolCall.id,
          'content': result.content,
        };
        workingMessages.add(toolMsg);
        allApiMessages.add(Map<String, dynamic>.from(toolMsg));

        // 记录技能名
        if (toolCall.name != 'think' && toolCall.name != 'save_memory') {
          skillNames.add(toolCall.name);
        }

        // 更新步骤状态（UI 展示用，已在可折叠面板中，不截断）
        if (toolCall.name == 'think') {
          step.content = stepDesc;
        } else {
          step.content = result.isError
              ? '$stepDesc\n❌ ${result.content}'
              : '$stepDesc\n${result.content}';
        }
        step.isLoading = false;
        step.isFailed = result.isError;
        onStepUpdate?.call(step);
        
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
            final stopResp = await provider.chat(workingMessages, config: config);
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

      // ── 循环防护：无进展检测 ──
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
            final stopResp = await provider.chat(workingMessages, config: config);
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
      final finalResp = await provider.chat(workingMessages, config: config);
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
  
  /// 构建规划提示，引导 LLM 思考并拆分任务
  static String _buildPlanningPrompt(String userRequest, List<ToolCall> initialToolCalls) {
    final initialToolsDesc = initialToolCalls.isEmpty 
        ? '（暂无初步判断）'
        : initialToolCalls.map((tc) => '- ${tc.name}(${tc.arguments})').join('\n');
    
    return '''
【规划模式】请在执行前先进行任务分析和规划。

## 用户请求
$userRequest

## 初步工具调用判断
$initialToolsDesc

## 请按以下格式输出计划

### 任务分析
- 分析用户的核心需求是什么
- 识别任务的复杂度和潜在风险
- 判断是否需要分步骤执行

### 执行计划
按步骤列出具体的执行计划，每步格式：
**步骤N**: [步骤名称]
- 操作：[具体要做什么]
- 工具：[要使用的工具名]
- 预期结果：[这一步完成后会得到什么]

### 风险提示（可选）
- 列出可能的失败点和备选方案

---
请务必认真分析后再输出计划，确保计划完整、可执行。
''';
  }
  
  /// 从 LLM 规划响应中解析出结构化计划
  static PendingPlan _parsePlanFromResponse(String responseText, String userRequest) {
    final planId = DateTime.now().millisecondsSinceEpoch.toString();
    final steps = <PlanStep>[];
    
    // 解析步骤：匹配 "**步骤N**:" 或 "步骤N:" 或 "N." 格式
    final stepPattern = RegExp(
      r'\*\*步骤(\d+)\*\*[：:]\s*(.+?)(?=\n-|\n\*\*|$)'
      r'|步骤(\d+)[：:]\s*(.+?)(?=\n-|\n\*\*|$)'
      r'|(\d+)\.\s*(.+?)(?=\n|$)',
      multiLine: true,
    );
    
    int stepOrder = 1;
    
    // 尝试按步骤格式解析
    for (final match in stepPattern.allMatches(responseText)) {
      final stepName = match.group(2) ?? match.group(4) ?? match.group(6) ?? '';
      if (stepName.trim().isEmpty) continue;
      
      // 提取工具名（如果有）
      String? toolName;
      final toolMatch = RegExp(r'工具[：:]\s*(\w+)').firstMatch(responseText.substring(match.start));
      if (toolMatch != null) {
        toolName = toolMatch.group(1);
      }
      
      steps.add(PlanStep(
        id: '${planId}_$stepOrder',
        order: stepOrder,
        description: stepName.trim(),
        toolName: toolName,
      ));
      stepOrder++;
    }
    
    // 如果没有解析到步骤，按行分割生成简单计划
    if (steps.isEmpty) {
      final lines = responseText.split('\n')
          .where((l) => l.trim().isNotEmpty && !l.startsWith('#') && !l.startsWith('---'))
          .take(10);
      
      for (final line in lines) {
        // 去除 markdown 标记
        final cleanLine = line.replaceAll(RegExp(r'[\*\-]'), '').trim();
        if (cleanLine.isEmpty) continue;
        
        steps.add(PlanStep(
          id: '${planId}_$stepOrder',
          order: stepOrder,
          description: cleanLine,
        ));
        stepOrder++;
      }
    }
    
    // 如果仍然没有步骤，创建一个默认步骤
    if (steps.isEmpty) {
      steps.add(PlanStep(
        id: '${planId}_1',
        order: 1,
        description: '执行用户请求: ${userRequest.length > 50 ? userRequest.substring(0, 50) + "..." : userRequest}',
      ));
    }
    
    return PendingPlan(
      id: planId,
      userRequest: userRequest,
      title: '执行计划',
      steps: steps,
    );
  }
}
