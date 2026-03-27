/// Sub-Agent 技能
/// 
/// 允许主 Agent spawn 子 Agent 执行独立任务。
/// 子 Agent 拥有独立的上下文窗口和工具集，
/// 执行完毕后返回结果摘要给主 Agent。

import 'dart:convert';
import 'package:flutter/foundation.dart';
import '../../skills/skill_base.dart';
import '../../models/models.dart';
import 'agent_loop.dart';
import 'agent_types.dart';
import 'agent_hooks.dart';
import 'sub_agent_types.dart';
import '../providers/llm_provider.dart';

/// Sub-Agent 技能
class SubAgentSkill extends GooseSkill {
  /// LLM Provider 工厂函数
  LLMProvider Function()? providerFactory;
  
  /// 工具执行回调
  Future<ToolResult> Function(ToolCall)? executeToolCallback;
  
  /// 获取可用工具列表回调
  List<Map<String, dynamic>> Function()? getToolsCallback;
  
  /// Hook 管理器（可选，用于子 Agent 也使用 Hooks）
  HookManager? hookManager;
  
  SubAgentSkill({
    this.providerFactory,
    this.executeToolCallback,
    this.getToolsCallback,
    this.hookManager,
  });
  
  @override
  String get id => 'spawn_sub_agent';
  
  @override
  String get name => 'Spawn Sub-Agent';
  
  @override
  String get description => 
      '创建一个子智能体来执行独立的子任务。'
      '子智能体有独立的上下文窗口，执行完毕后返回结果摘要。'
      '适用于：(1) 复杂任务的分解执行 (2) 需要隔离上下文的探索性任务 (3) 可并行处理的独立子任务。'
      '注意：子智能体不能再次 spawn 子智能体（防止无限嵌套）。';
  
  @override
  String get icon => '🐣';
  
  @override
  String get category => 'Agent 能力';
  
  @override
  List<SkillParam> get params => [
    const SkillParam(
      name: 'task',
      description: '子智能体的任务描述（清晰说明要完成什么）',
      type: 'string',
      required: true,
    ),
    const SkillParam(
      name: 'allowed_tools',
      description: '子智能体允许使用的工具列表（JSON数组字符串，为空则继承父Agent但不包含spawn_sub_agent）',
      type: 'string',
      required: false,
    ),
    const SkillParam(
      name: 'max_turns',
      description: '子智能体最大执行轮数（默认10，最大20）',
      type: 'int',
      required: false,
      defaultValue: 10,
    ),
    const SkillParam(
      name: 'context',
      description: '传递给子智能体的额外上下文信息（可选）',
      type: 'string',
      required: false,
    ),
    const SkillParam(
      name: 'role',
      description: '子智能体的角色描述（可选，如"代码审查员"、"测试员"）',
      type: 'string',
      required: false,
    ),
  ];
  
  @override
  Future<SkillResult> execute(Map<String, dynamic> args, {void Function(String line)? onOutput}) async {
    final task = args['task'] as String? ?? '';
    if (task.isEmpty) {
      return SkillResult.fail('任务描述不能为空');
    }
    
    // 检查必要的回调
    if (providerFactory == null || executeToolCallback == null || getToolsCallback == null) {
      return SkillResult.fail('Sub-Agent 技能未正确初始化（缺少必要的回调）');
    }
    
    // 解析参数
    List<String>? allowedTools;
    final toolsJson = args['allowed_tools'] as String?;
    if (toolsJson != null && toolsJson.isNotEmpty) {
      try {
        final list = jsonDecode(toolsJson) as List;
        allowedTools = list.cast<String>();
      } catch (e) {
        debugPrint('🐣 [Sub-Agent] 解析 allowed_tools 失败: $e');
      }
    }
    
    final maxTurns = (args['max_turns'] as int? ?? 10).clamp(1, 20);
    final context = args['context'] as String? ?? '';
    final role = args['role'] as String?;
    
    // 生成子 Agent ID
    final subAgentId = 'sub_${DateTime.now().millisecondsSinceEpoch}';
    debugPrint('🐣 [Sub-Agent] 启动: $subAgentId');
    debugPrint('🐣 [Sub-Agent] 任务: $task');
    
    try {
      // 构建 Sub-Agent 配置
      final config = SubAgentConfig(
        id: subAgentId,
        task: task,
        allowedTools: allowedTools,
        maxTurns: maxTurns,
        context: context,
        role: role,
      );
      
      // 触发 Hook
      hookManager?.triggerSubAgentStart(config);
      
      // 执行子 Agent
      final result = await _runSubAgent(config);
      
      // 触发 Hook
      hookManager?.triggerSubAgentComplete(result);
      
      if (result.success) {
        debugPrint('🐣 [Sub-Agent] 完成: $subAgentId, 轮数: ${result.turnsUsed}');
        return SkillResult.ok(
          result.summary ?? result.result,
          data: result.toJson(),
        );
      } else {
        debugPrint('🐣 [Sub-Agent] 失败: $subAgentId, 错误: ${result.error}');
        return SkillResult.fail(result.error ?? '子智能体执行失败');
      }
    } catch (e, st) {
      debugPrint('🐣 [Sub-Agent] 异常: $subAgentId, $e\n$st');
      return SkillResult.fail('子智能体执行异常: $e');
    }
  }
  
  /// 运行子 Agent
  Future<SubAgentResult> _runSubAgent(SubAgentConfig config) async {
    try {
      // 构建子 Agent 的消息列表
      final subMessages = _buildSubAgentMessages(config);
      
      // 过滤可用工具
      final allTools = getToolsCallback!();
      final subTools = _filterTools(allTools, config.allowedTools);
      
      // 创建子 Agent 上下文
      final subContext = SubAgentContext(
        parentAgentId: config.id,
        depth: 1, // 子 Agent 深度为 1
      );
      
      // 运行子 Agent
      final loopResult = await AgentLoop.run(
        provider: providerFactory!(),
        config: LLMConfig(
          provider: '',  // 子 Agent 使用父 Agent 的 provider
          model: '',
        ),
        messages: subMessages,
        tools: subTools,
        executeTool: (call, {onOutput}) => executeToolCallback!(call),
        maxTurns: config.maxTurns,
        hooks: hookManager?.hooks,
        subAgentContext: subContext,
      );
      
      // 生成结果摘要
      String? summary;
      if (config.needSummary && loopResult.text.length > 500) {
        // 如果结果太长，生成摘要
        summary = await _summarizeResult(config.task, loopResult.text);
      } else {
        summary = loopResult.text;
      }
      
      return SubAgentResult(
        id: config.id,
        success: true,
        result: loopResult.text,
        turnsUsed: loopResult.steps.length,
        steps: loopResult.steps,
        summary: summary,
      );
    } catch (e) {
      return SubAgentResult(
        id: config.id,
        success: false,
        result: '',
        turnsUsed: 0,
        steps: [],
        error: e.toString(),
      );
    }
  }
  
  /// 构建子 Agent 的消息列表
  List<Map<String, dynamic>> _buildSubAgentMessages(SubAgentConfig config) {
    final roleDesc = config.role != null 
        ? '你是一个${config.role}，' 
        : '你是一个子智能体，';
    
    final contextSection = config.context != null && config.context!.isNotEmpty
        ? '## 额外上下文\n${config.context}\n'
        : '';
    
    final systemPrompt = '''$roleDesc负责完成主智能体分配的独立任务。

## 工作原则
1. 专注于完成分配给你的任务，不要偏离
2. 完成任务后直接报告结果，不要过多解释
3. 如果遇到无法解决的问题，清楚说明原因
4. 尽量在有限的工具调用内完成任务
5. 不要尝试调用 spawn_sub_agent 工具（不支持嵌套）

## 当前任务
${config.task}

$contextSection
''';
    
    return [
      {'role': 'system', 'content': systemPrompt},
      {'role': 'user', 'content': '请开始执行任务。完成后直接报告结果。'},
    ];
  }
  
  /// 根据允许列表过滤工具
  List<Map<String, dynamic>> _filterTools(
    List<Map<String, dynamic>> allTools,
    List<String>? allowedTools,
  ) {
    // 始终排除 spawn_sub_agent，防止无限嵌套
    if (allowedTools == null || allowedTools.isEmpty) {
      return allTools.where((t) {
        final name = (t['function'] as Map?)?['name'] as String?;
        return name != 'spawn_sub_agent';
      }).toList();
    }
    
    return allTools.where((t) {
      final name = (t['function'] as Map?)?['name'] as String?;
      return name != null && 
             allowedTools.contains(name) && 
             name != 'spawn_sub_agent';
    }).toList();
  }
  
  /// 生成结果摘要（如果结果太长）
  Future<String> _summarizeResult(String task, String result) async {
    // 简单截断策略：取前 500 字符
    // 如果需要更智能的摘要，可以调用 LLM
    if (result.length <= 500) return result;
    
    final truncated = result.substring(0, 500);
    return '$truncated...\n\n[结果已截断，完整内容共 ${result.length} 字符]';
  }
  
  /// 更新回调（用于运行时注入）
  void updateCallbacks({
    LLMProvider Function()? providerFactory,
    Future<ToolResult> Function(ToolCall)? executeToolCallback,
    List<Map<String, dynamic>> Function()? getToolsCallback,
    HookManager? hookManager,
  }) {
    // 使用 late 初始化模式，允许运行时注入
  }
}

/// Agent Teams 技能
/// 
/// 管理多个 Agent 协作执行任务
class AgentTeamsSkill extends GooseSkill {
  final SubAgentSkill _subAgentSkill;
  
  /// 消息回调（用于 UI 实时显示消息）
  void Function(TeamMessage message)? onMessage;
  
  AgentTeamsSkill(this._subAgentSkill, {this.onMessage});
  
  @override
  String get id => 'spawn_agent_team';
  
  @override
  String get name => 'Spawn Agent Team';
  
  @override
  String get description => 
      '创建一个 Agent 团队协作执行复杂任务。'
      '支持顺序、并行、层级等协作模式。'
      '适用于需要多角色协作的复杂任务。';
  
  @override
  String get icon => '👥';
  
  @override
  String get category => 'Agent 能力';
  
  @override
  List<SkillParam> get params => [
    const SkillParam(
      name: 'team_name',
      description: '团队名称',
      type: 'string',
      required: true,
    ),
    const SkillParam(
      name: 'agents',
      description: '团队成员配置（JSON数组，每个成员包含 id, name, role, systemPrompt）',
      type: 'string',
      required: true,
    ),
    const SkillParam(
      name: 'tasks',
      description: '任务列表（JSON数组，每个任务包含 id, description, assignedTo）',
      type: 'string',
      required: true,
    ),
    const SkillParam(
      name: 'mode',
      description: '协作模式：sequential（顺序）、parallel（并行）、hierarchical（层级）',
      type: 'string',
      required: false,
      defaultValue: 'sequential',
    ),
    const SkillParam(
      name: 'max_concurrency',
      description: '最大并发数（并行模式下生效，默认3）',
      type: 'int',
      required: false,
      defaultValue: 3,
    ),
  ];
  
  @override
  Future<SkillResult> execute(Map<String, dynamic> args, {void Function(String line)? onOutput}) async {
    // 解析团队配置
    final teamName = args['team_name'] as String? ?? '未命名团队';
    final modeStr = args['mode'] as String? ?? 'sequential';
    final maxConcurrency = args['max_concurrency'] as int? ?? 3;
    
    // 解析 agents
    List<TeamAgent> agents;
    try {
      final agentsJson = args['agents'] as String;
      final agentsList = jsonDecode(agentsJson) as List;
      agents = agentsList.map((a) => TeamAgent(
        id: a['id'] as String,
        name: a['name'] as String,
        role: a['role'] as String,
        systemPrompt: a['systemPrompt'] as String? ?? '',
        allowedTools: (a['allowedTools'] as List?)?.cast<String>() ?? [],
        priority: a['priority'] as int? ?? 100,
      )).toList();
    } catch (e) {
      return SkillResult.fail('agents 参数格式错误: $e');
    }
    
    // 解析 tasks
    List<TeamTask> tasks;
    try {
      final tasksJson = args['tasks'] as String;
      final tasksList = jsonDecode(tasksJson) as List;
      tasks = tasksList.map((t) => TeamTask(
        id: t['id'] as String,
        description: t['description'] as String,
        assignedTo: t['assignedTo'] as String?,
        dependencies: (t['dependencies'] as List?)?.cast<String>() ?? [],
      )).toList();
    } catch (e) {
      return SkillResult.fail('tasks 参数格式错误: $e');
    }
    
    if (agents.isEmpty) {
      return SkillResult.fail('团队至少需要一个成员');
    }
    
    if (tasks.isEmpty) {
      return SkillResult.fail('至少需要一个任务');
    }
    
    // 创建团队配置
    final mode = TeamCollaborationMode.values.firstWhere(
      (m) => m.name == modeStr,
      orElse: () => TeamCollaborationMode.sequential,
    );
    
    final teamConfig = AgentTeamConfig(
      teamId: 'team_${DateTime.now().millisecondsSinceEpoch}',
      teamName: teamName,
      agents: agents,
      maxConcurrency: maxConcurrency,
      mode: mode,
    );
    
    debugPrint('👥 [AgentTeam] 启动团队: ${teamConfig.teamName}');
    debugPrint('👥 [AgentTeam] 成员: ${agents.length}, 任务: ${tasks.length}, 模式: $modeStr');
    
    // 根据协作模式执行
    try {
      final results = await _executeTeamTasks(teamConfig, tasks);
      
      final successCount = results.where((r) => r.success).length;
      final summary = _buildTeamSummary(teamConfig, results);
      
      debugPrint('👥 [AgentTeam] 完成: $successCount/${tasks.length} 任务成功');
      
      return SkillResult.ok(summary, data: {
        'teamId': teamConfig.teamId,
        'teamName': teamConfig.teamName,
        'totalTasks': tasks.length,
        'successCount': successCount,
        'results': results.map((r) => r.toJson()).toList(),
      });
    } catch (e, st) {
      debugPrint('👥 [AgentTeam] 异常: $e\n$st');
      return SkillResult.fail('团队执行异常: $e');
    }
  }
  
  /// 执行团队任务
  Future<List<SubAgentResult>> _executeTeamTasks(
    AgentTeamConfig config, 
    List<TeamTask> tasks,
  ) async {
    switch (config.mode) {
      case TeamCollaborationMode.sequential:
        // 顺序执行
        return await _executeSequential(config.agents, tasks);
        
      case TeamCollaborationMode.parallel:
        // DAG 调度：按依赖关系分阶段执行，同阶段任务并行
        return await _executeWithDAG(config.agents, tasks, config.maxConcurrency);
        
      case TeamCollaborationMode.hierarchical:
        // 层级协作：主 Agent 分配，子 Agent 执行并汇报
        return await _executeHierarchical(config.agents, tasks);
        
      case TeamCollaborationMode.voting:
        // 投票决策：每个 Agent 都尝试，然后选择最佳结果
        return await _executeVoting(config.agents, tasks);
    }
  }
  
  /// 顺序执行
  Future<List<SubAgentResult>> _executeSequential(
    List<TeamAgent> agents,
    List<TeamTask> tasks,
  ) async {
    final results = <SubAgentResult>[];
    for (final task in tasks) {
      final agent = _findAgentForTask(agents, task);
      if (agent != null) {
        final result = await _executeTaskWithAgent(task, agent, results);
        results.add(result);
      }
    }
    return results;
  }
  
  /// DAG 调度执行（支持多阶段依赖）
  /// 例如：A,B 并行 → C → D
  Future<List<SubAgentResult>> _executeWithDAG(
    List<TeamAgent> agents,
    List<TeamTask> tasks,
    int maxConcurrency,
  ) async {
    final results = <SubAgentResult>[];
    final completedTaskIds = <String>{};
    
    // 按阶段执行，直到所有任务完成
    while (completedTaskIds.length < tasks.length) {
      // 找出当前可执行的任务（依赖已全部完成且未执行）
      final readyTasks = tasks.where((task) =>
        !completedTaskIds.contains(task.id) &&
        task.dependencies.every((dep) => completedTaskIds.contains(dep))
      ).toList();
      
      if (readyTasks.isEmpty) {
        // 没有可执行任务但还有未完成任务 → 存在循环依赖或失败
        debugPrint('👥 [AgentTeam] 警告: 剩余任务无法执行（可能存在循环依赖或前置任务失败）');
        break;
      }
      
      debugPrint('👥 [AgentTeam] 阶段执行: ${readyTasks.length} 个任务并行（并发限制: $maxConcurrency）');
      
      // 按并发限制分批执行
      for (var i = 0; i < readyTasks.length; i += maxConcurrency) {
        final batch = readyTasks.skip(i).take(maxConcurrency).toList();
        
        // 并行执行当前批次
        final batchResults = await Future.wait(
          batch.map((task) async {
            final agent = _findAgentForTask(agents, task);
            if (agent != null) {
              return await _executeTaskWithAgent(task, agent, results);
            }
            return SubAgentResult(
              id: task.id,
              success: false,
              result: '',
              turnsUsed: 0,
              steps: [],
              error: '未找到合适的 Agent',
            );
          }),
        );
        
        // 收集结果
        for (final result in batchResults) {
          results.add(result);
          if (result.success) {
            completedTaskIds.add(result.id);
          }
        }
      }
    }
    
    return results;
  }
  
  /// 层级协作执行
  Future<List<SubAgentResult>> _executeHierarchical(
    List<TeamAgent> agents,
    List<TeamTask> tasks,
  ) async {
    final results = <SubAgentResult>[];
    final sortedAgents = List<TeamAgent>.from(agents)
      ..sort((a, b) => a.priority.compareTo(b.priority));
    
    for (final task in tasks) {
      for (final agent in sortedAgents) {
        final result = await _executeTaskWithAgent(task, agent, results);
        results.add(result);
        if (result.success) break;
      }
    }
    return results;
  }
  
  /// 投票决策执行
  Future<List<SubAgentResult>> _executeVoting(
    List<TeamAgent> agents,
    List<TeamTask> tasks,
  ) async {
    final results = <SubAgentResult>[];
    
    for (final task in tasks) {
      final allResults = <SubAgentResult>[];
      
      for (final agent in agents) {
        final result = await _executeTaskWithAgent(task, agent, results);
        allResults.add(result);
      }
      
      // 选择第一个成功的结果
      final bestResult = allResults.firstWhere(
        (r) => r.success,
        orElse: () => allResults.first,
      );
      results.add(bestResult);
    }
    return results;
  }
  
  /// 查找适合执行任务的 Agent
  TeamAgent? _findAgentForTask(List<TeamAgent> agents, TeamTask task) {
    if (task.assignedTo != null) {
      return agents.firstWhere(
        (a) => a.id == task.assignedTo,
        orElse: () => agents.first,
      );
    }
    return agents.first;
  }
  
  /// 用指定 Agent 执行任务
  /// [previousResults] 上游任务的执行结果（用于传递上下文）
  Future<SubAgentResult> _executeTaskWithAgent(
    TeamTask task, 
    TeamAgent agent,
    List<SubAgentResult> previousResults,
  ) async {
    debugPrint('👥 [AgentTeam] Agent ${agent.name} 执行任务: ${task.description}');
    
    // 发送任务开始消息
    _sendMessage(
      fromAgentId: agent.id,
      fromAgentName: agent.name,
      type: TeamMessageType.statusUpdate,
      content: '开始执行任务: ${task.description}',
      taskId: task.id,
    );
    
    // 构建上游任务的上下文（如果有依赖）
    final upstreamContext = StringBuffer();
    final upstreamFiles = <String>[];  // 收集上游产出物文件路径
    
    if (task.dependencies.isNotEmpty) {
      upstreamContext.writeln('\n## 上游任务输出');
      for (final depId in task.dependencies) {
        final depResult = previousResults.where((r) => r.id == depId).firstOrNull;
        if (depResult != null && depResult.success) {
          // 收集产出物文件路径
          if (depResult.outputFile != null) {
            upstreamFiles.add(depResult.outputFile!);
            upstreamContext.writeln('### 任务 $depId 产出物文件: ${depResult.outputFile}');
          }
          
          upstreamContext.writeln('### 任务 $depId 的输出摘要:');
          final output = depResult.summary ?? depResult.result;
          
          // 超长输出使用智能摘要（LLM 生成）
          if (output.length > 2000) {
            final smartSummary = await _generateSmartSummary(output, taskId: depId);
            upstreamContext.writeln(smartSummary);
            upstreamContext.writeln('\n> 💡 详细内容可通过 read_file 技能读取产出物文件');
          } else {
            upstreamContext.writeln(output);
          }
          upstreamContext.writeln();
        }
      }
      
      // 提示可用的产出物文件
      if (upstreamFiles.isNotEmpty) {
        upstreamContext.writeln('\n### 可用的产出物文件:');
        for (final file in upstreamFiles) {
          upstreamContext.writeln('- $file');
        }
        upstreamContext.writeln('\n> 如需详细内容，请使用 read_file 技能读取上述文件');
      }
    }
    
    // 复用 SubAgentSkill 的执行逻辑
    final result = await _subAgentSkill.execute({
      'task': task.description,
      'role': agent.role,
      'max_turns': 10,
      'context': upstreamContext.toString(),
    });
    
    // 提取产出物文件路径（如果 Agent 保存了文件）
    String? outputFile;
    if (result.data?['outputFile'] != null) {
      outputFile = result.data!['outputFile'] as String;
    } else if (result.data?['writtenFiles'] != null) {
      // 如果写入了多个文件，取第一个作为主要产出物
      final files = result.data!['writtenFiles'] as List;
      if (files.isNotEmpty) {
        outputFile = files.first as String;
      }
    }
    
    // 生成智能摘要（如果结果过长）
    String summary = result.message;
    if (result.success && result.message.length > 2000) {
      summary = await _generateSmartSummary(result.message, taskId: task.id);
      debugPrint('📝 [AgentTeam] 任务 ${task.id} 输出过长，已生成智能摘要');
    }
    
    final subResult = SubAgentResult(
      id: task.id,
      success: result.success,
      result: result.message,
      turnsUsed: (result.data?['turnsUsed'] as int?) ?? 0,
      steps: [],
      summary: summary,
      error: result.success ? null : result.message,
      outputFile: outputFile,
    );
    
    // 发送任务完成消息（广播给所有人）
    _sendMessage(
      fromAgentId: agent.id,
      fromAgentName: agent.name,
      type: TeamMessageType.taskResult,
      content: result.success 
          ? '任务完成: ${task.description}\n结果: ${summary.length > 200 ? '${summary.substring(0, 200)}...' : summary}${outputFile != null ? '\n产出物: $outputFile' : ''}'
          : '任务失败: ${task.description}\n错误: ${result.message}',
      taskId: task.id,
      isBroadcast: true,
    );
    
    return subResult;
  }
  
  /// 使用 LLM 生成智能摘要
  Future<String> _generateSmartSummary(String content, {String? taskId}) async {
    try {
      final provider = _subAgentSkill.providerFactory?.call();
      if (provider == null) {
        // 没有 LLM，返回截断版本
        return '${content.substring(0, 1500)}...\n[内容过长已截断，请读取产出物文件获取完整内容]';
      }
      
      final response = await provider.chat([
        {'role': 'system', 'content': '你是一个内容摘要助手。请将以下内容压缩成简洁的摘要，保留关键信息和结论。摘要长度控制在500字以内。'},
        {'role': 'user', 'content': '请摘要以下内容：\n\n$content'},
      ]);
      
      final summary = response.text.isNotEmpty 
          ? response.text 
          : '${content.substring(0, 1500)}...\n[智能摘要生成失败，已截断]';
      
      return '📌 智能摘要:\n$summary\n\n[详细内容请读取产出物文件]';
    } catch (e) {
      debugPrint('⚠️ [AgentTeam] 智能摘要生成失败: $e');
      return '${content.substring(0, 1500)}...\n[摘要生成异常，已截断]';
    }
  }
  
  /// 发送团队消息
  void _sendMessage({
    required String fromAgentId,
    required String fromAgentName,
    required TeamMessageType type,
    required String content,
    String? taskId,
    bool isBroadcast = false,
    List<String> toAgentIds = const [],
  }) {
    final message = TeamMessage(
      id: 'msg_${DateTime.now().millisecondsSinceEpoch}',
      fromAgentId: fromAgentId,
      fromAgentName: fromAgentName,
      type: type,
      toAgentIds: isBroadcast ? [] : toAgentIds,
      content: content,
      taskId: taskId,
    );
    
    // 调用回调通知 UI
    onMessage?.call(message);
    
    debugPrint('💬 [AgentTeam] $fromAgentName: ${isBroadcast ? "@所有人 " : ""}$content');
  }
  
  /// 构建团队执行摘要
  String _buildTeamSummary(AgentTeamConfig config, List<SubAgentResult> results) {
    final sb = StringBuffer();
    sb.writeln('## ${config.teamName} 执行报告');
    sb.writeln();
    sb.writeln('**协作模式**: ${config.mode.name}');
    sb.writeln('**成员数**: ${config.agents.length}');
    sb.writeln('**任务数**: ${results.length}');
    sb.writeln();
    
    final successCount = results.where((r) => r.success).length;
    sb.writeln('### 执行结果: $successCount/${results.length} 成功');
    sb.writeln();
    
    for (final result in results) {
      final icon = result.success ? '✅' : '❌';
      sb.writeln('$icon **任务 ${result.id}**: ${result.success ? result.summary ?? "完成" : result.error ?? "失败"}');
    }
    
    return sb.toString();
  }
}
