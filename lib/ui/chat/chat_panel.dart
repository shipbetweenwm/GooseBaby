import 'dart:io';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../utils/type_utils.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';
import '../../ai/llm_manager.dart';
import '../../ai/agent/agent_types.dart';
import '../../ai/agent/agent_loop.dart';
import '../../ai/agent/agent_mode.dart';
import '../../ai/agent/agent_hooks.dart';
import '../../ai/agent/sub_agent_types.dart';
import '../../ai/agent/failure_lesson_hook.dart';
import '../../ai/memory/memory_manager.dart';
import '../../ai/memory/context_manager.dart';
import '../../ai/self_improvement.dart';
import '../../ai/prompts.dart';
import '../../core/pet_engine.dart';
import '../../models/models.dart';
import '../../skills/skill_manager.dart';
import '../../skills/skill_file_utils.dart';
import '../../services/diary_service.dart';
import '../../utils/storage.dart';
import 'widgets/rich_message_bubble.dart';
import 'widgets/enhanced_input_bar.dart';
import 'conversation_manager.dart';

/// 聊天面板 - 和鹅宝对话的窗口
class ChatPanel extends StatefulWidget {
  final VoidCallback? onClose;
  final bool workMode;
  final VoidCallback? onToggleMode;

  /// 面板是否可见（用于判断 AI 完成时是否需要通知外部）
  final bool isVisible;

  /// 面板隐藏时 AI 完成工作的回调（用于显示气泡提示）
  final void Function(String message)? onBackgroundComplete;

  const ChatPanel({
    super.key,
    this.onClose,
    this.workMode = false,
    this.onToggleMode,
    this.isVisible = true,
    this.onBackgroundComplete,
  });

  @override
  State<ChatPanel> createState() => _ChatPanelState();
}

class _ChatPanelState extends State<ChatPanel> with SingleTickerProviderStateMixin {
  final TextEditingController _inputController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final FocusNode _focusNode = FocusNode();

  final List<_ChatMessage> _messages = [];
  bool _isLoading = false;
  
  /// 当前 Agent 模式
  AgentMode _agentMode = AgentMode.craft;
  /// 待确认/执行中的计划列表（Plan 模式下使用）
  final List<PendingPlan> _pendingPlans = [];
  /// 当前显示的计划索引
  int _activePlanIndex = 0;
  /// 流式输出的当前内容
  String _streamingContent = '';
  /// 工具调用中间步骤（实时显示在页面上）
  final List<_ToolCallStep> _toolCallSteps = [];
  /// 待发送的附件
  List<MessageAttachment> _pendingAttachments = [];
  /// 当前会话的取消令牌（用于中断 AgentLoop）
  CancellationToken? _cancellationToken;

  /// 会话管理器（两种模式共用）
  ConversationManager? _conversationManager;
  /// 当前选中的会话ID
  String? _currentConversationId;
  /// 当前正在处理的会话ID（防止切换会话后保存到错误会话）
  String? _processingConversationId;
  /// 是否显示会话列表（两种模式都可控制）
  bool _showConversationList = true;
  
  /// 是否显示 Agent Team 面板
  bool _showAgentTeamPanel = false;
  /// Agent Team 配置
  final List<TeamAgent> _teamAgents = [];
  /// 团队消息板
  final TeamMessageBoard _teamMessageBoard = TeamMessageBoard();
  /// 当前团队任务（由主管动态创建）
  final List<TeamTask> _dynamicTasks = [];
  /// 角色状态（thinking=思考中, idle=空闲）
  final Map<String, String> _agentStatus = {};
  /// 任务输出文件路径（taskId -> 文件路径）
  final Map<String, String> _taskOutputFiles = {};
  /// 当前输出目录
  String? _currentOutputDir;
  /// Team 模式的取消令牌
  CancellationToken? _teamCancellationToken;
  /// Team 模式是否正在执行
  bool _isTeamExecuting = false;
  
  // ===== 上下文管理 =====
  /// 上下文管理器（Token 预算控制、System Prompt 分段管理）
  final ContextManager _contextManager = ContextManager();
  /// 当前上下文 Token 使用统计（用于 UI 显示）
  int _currentHistoryTokens = 0;
  int _currentSystemPromptTokens = 0;
  
  // ===== 团队任务执行状态跟踪（用于持久化和恢复）=====
  /// 当前执行的用户任务
  String? _currentTeamTask;
  /// 当前执行阶段索引
  int _currentStageIndex = -1;
  /// 已完成的任务 ID 集合
  final Set<String> _completedTaskIds = {};
  /// 任务输出结果（taskId -> output）
  final Map<String, String> _taskOutputs = {};
  
  /// 当前团队模式（任务模式 / 圆桌模式）
  TeamMode _teamMode = TeamMode.task;
  /// 讨论轮次记录
  final List<DiscussionTurn> _discussionTurns = [];
  /// 讨论配置
  DiscussionConfig? _discussionConfig;
  /// 当前讨论轮次
  int _currentDiscussionRound = 0;
  /// 是否正在讨论中
  bool _isDiscussing = false;

  double get _chatFontSize => StorageManager.getSetting<double>('chat_font_size', defaultValue: 14.0) ?? 14.0;

  /// 处理对话后的情感反馈（用户情绪 → 鹅宝反应 + 情感事件记录）
  void _processEmotionalFeedback(String userMessage, String botResponse, PetEngine engine, MemoryManager memoryManager) {
    final lowerMsg = userMessage.toLowerCase();

    // 用户说谢谢 → mood +5, 害羞
    if (lowerMsg.contains('谢谢') || lowerMsg.contains('感谢') || lowerMsg.contains('多谢') || lowerMsg.contains('thank')) {
      engine.adjustMood(5);
      engine.setEmotion('shy');
    }

    // 用户表扬 → mood +8
    if (lowerMsg.contains('厉害') || lowerMsg.contains('棒') || lowerMsg.contains('好用') || lowerMsg.contains('聪明') || lowerMsg.contains('可爱')) {
      engine.adjustMood(8);
      engine.setEmotion('happy');
    }

    // 用户说笨/不好 → mood -5
    if (lowerMsg.contains('笨') || lowerMsg.contains('不好') || lowerMsg.contains('垃圾') || lowerMsg.contains('没用')) {
      engine.adjustMood(-5);
      engine.setEmotion('sad');
    }

    // ── 记录情感事件（基于用户消息的情绪关键词快速判断）──
    final emotionHint = GoosePrompts.detectUserEmotion([userMessage]);
    if (emotionHint.isNotEmpty) {
      String emotion = 'normal';
      double intensity = 0.5;
      if (emotionHint.contains('压力') || emotionHint.contains('烦躁')) {
        emotion = 'stressed'; intensity = 0.7;
      } else if (emotionHint.contains('难过') || emotionHint.contains('失落')) {
        emotion = 'sad'; intensity = 0.7;
      } else if (emotionHint.contains('生气')) {
        emotion = 'stressed'; intensity = 0.8;
      } else if (emotionHint.contains('累') || emotionHint.contains('疲惫')) {
        emotion = 'tired'; intensity = 0.6;
      } else if (emotionHint.contains('兴奋') || emotionHint.contains('激动')) {
        emotion = 'excited'; intensity = 0.7;
      } else if (emotionHint.contains('心情不错') || emotionHint.contains('开心')) {
        emotion = 'happy'; intensity = 0.6;
      } else if (emotionHint.contains('精力不足')) {
        emotion = 'tired'; intensity = 0.4;
      }

      if (emotion != 'normal') {
        // 提取用户消息的前30字作为 context
        final context = userMessage.length > 30 ? '${userMessage.substring(0, 30)}...' : userMessage;
        memoryManager.saveEmotionalEvent(
          emotion: emotion,
          context: context,
          intensity: intensity,
        );
      }
    }
  }

  late AnimationController _slideController;
  late Animation<Offset> _slideAnimation;

  @override
  void initState() {
    super.initState();

    _slideController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 150),
    );
    _slideAnimation = Tween<Offset>(
      begin: const Offset(0.1, 0), // 从很近的位置开始，减少视觉闪烁
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _slideController, curve: Curves.easeOut));

    // 立即开始动画，不延迟
    _slideController.forward();
    
    // 加载保存的 Agent 模式
    _loadAgentMode();

    _initializeMode();
  }
  
  void _loadAgentMode() {
    final savedMode = StorageManager.getSetting<String>('agent_mode', defaultValue: 'craft');
    _agentMode = AgentModeExtension.fromString(savedMode ?? 'craft') ?? AgentMode.craft;
    // 同步设置 Team 面板显示状态
    _showAgentTeamPanel = _agentMode == AgentMode.team;
    // 自动加载上次的团队成员
    _loadCurrentTeam();
  }
  
  /// 自动加载上次的团队成员
  void _loadCurrentTeam() {
    final teamAgents = StorageManager.getSetting<List<dynamic>>('current_team_agents', defaultValue: []);
    if (teamAgents != null && teamAgents.isNotEmpty) {
      setState(() {
        _teamAgents.clear();
        _teamAgents.addAll(teamAgents.map((json) => TeamAgent.fromJson(safeMap(json))));
      });
    }
  }
  
  /// 自动保存当前团队成员
  Future<void> _saveCurrentTeamAgents() async {
    await StorageManager.setSetting(
      'current_team_agents', 
      _teamAgents.map((a) => a.toJson()).toList(),
    );
  }
  
  // ==================== 团队执行状态持久化 ====================
  
  /// 保存团队执行状态（用于恢复被中断的任务）
  Future<void> _saveTeamExecutionState({
    required String userTask,
    required int currentStageIndex,
    required List<String> completedTaskIds,
    required Map<String, String> taskOutputs,
  }) async {
    final state = {
      'userTask': userTask,
      'currentStageIndex': currentStageIndex,
      'completedTaskIds': completedTaskIds,
      'taskOutputs': taskOutputs,
      'tasks': _dynamicTasks.map((t) => t.toJson()).toList(),
      'messages': _teamMessageBoard.messages.map((m) => m.toJson()).toList(),
      'outputDir': _currentOutputDir,
      'savedAt': DateTime.now().toIso8601String(),
    };
    await StorageManager.setSetting('team_execution_state', state);
    debugPrint('💾 团队执行状态已保存: ${completedTaskIds.length}/${_dynamicTasks.length} 任务完成');
  }
  
  /// 加载团队执行状态
  Map<String, dynamic>? _loadTeamExecutionState() {
    final state = StorageManager.getSetting<Map<String, dynamic>>('team_execution_state');
    if (state == null || state.isEmpty) return null;
    
    // 检查是否过期（超过 24 小时）
    final savedAt = state['savedAt'] as String?;
    if (savedAt != null) {
      final savedTime = DateTime.parse(savedAt);
      if (DateTime.now().difference(savedTime).inHours > 24) {
        debugPrint('💾 团队执行状态已过期，忽略');
        return null;
      }
    }
    
    return state;
  }
  
  /// 清除团队执行状态
  Future<void> _clearTeamExecutionState() async {
    await StorageManager.setSetting('team_execution_state', null);
    debugPrint('💾 团队执行状态已清除');
  }
  
  /// 检查是否有可恢复的任务
  bool get _hasResumableTask {
    final state = _loadTeamExecutionState();
    if (state == null) return false;
    
    final completedIds = (state['completedTaskIds'] as List?)?.cast<String>() ?? [];
    final tasks = (state['tasks'] as List?) ?? [];
    
    // 有任务且未全部完成
    return tasks.isNotEmpty && completedIds.length < tasks.length;
  }
  
  /// 获取可恢复任务的描述
  String? get _resumableTaskDescription {
    final state = _loadTeamExecutionState();
    if (state == null) return null;
    
    final userTask = state['userTask'] as String? ?? '未知任务';
    final completedIds = (state['completedTaskIds'] as List?)?.cast<String>() ?? [];
    final tasks = (state['tasks'] as List?) ?? [];
    
    return '$userTask (${completedIds.length}/${tasks.length} 已完成)';
  }
  
  void _saveAgentMode(AgentMode mode) {
    StorageManager.setSetting('agent_mode', mode.name);
  }

  @override
  void didUpdateWidget(ChatPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    
    // 模式切换时，不重新初始化，保持现有状态
    if (oldWidget.workMode != widget.workMode) {
      if (widget.workMode && _conversationManager == null) {
        // 切换到工作模式，初始化会话管理器
        _conversationManager = ConversationManager();
        _conversationManager!.initialize().then((_) {
          if (mounted) {
            setState(() {
              _currentConversationId = _conversationManager!.currentConversationId;
            });
            _loadConversationMessages();
          }
        });
      }
      // 从工作模式切换到休闲模式，保持消息不变，不需要额外操作
    }
  }

  void _initializeMode() {
    // 两种模式统一使用 ConversationManager 管理会话
    _conversationManager = ConversationManager();
    _conversationManager!.initialize().then((_) {
      if (mounted) {
        setState(() {
          _currentConversationId = _conversationManager!.currentConversationId;
        });
        // 统一加载当前会话消息
        _loadConversationMessages();
      }
    }).catchError((e) {
      debugPrint('🦢 会话管理器初始化失败: $e');
      if (mounted) {
        setState(() {
          _messages.clear();
          _messages.add(_ChatMessage(
            content: '嘎~ 会话加载失败，鹅宝正在努力修复中... 🦢',
            isUser: false,
            timestamp: DateTime.now(),
          ));
        });
      }
    });
    
    // 配置 Agent Teams 消息回调
    WidgetsBinding.instance.addPostFrameCallback((_) {
      try {
        final skillManager = context.read<SkillManager>();
        skillManager.configureAgentTeamsSkill(
          onMessage: (message) {
            if (mounted) {
              setState(() {
                _teamMessageBoard.add(message);
              });
            }
          },
        );
      } catch (_) {}
    });
  }


  /// 保存聊天历史（统一使用 ConversationManager）
  /// 使用 _processingConversationId 确保保存到正确的会话
  void _saveChatHistory() {
    try {
      // 优先使用正在处理的会话ID，否则使用当前会话ID
      final targetId = _processingConversationId ?? _currentConversationId;
      if (_conversationManager != null && targetId != null) {
        // 两种模式统一：替换目标会话的全部消息
        _conversationManager!.updateMessagesFor(targetId, _messages.map((m) => ConversationMessage(
          content: m.content,
          isUser: m.isUser,
          timestamp: m.timestamp,
          skillResult: m.skillResult,
          isError: m.isError,
          attachments: m.attachments,
          apiMessages: m.apiMessages,
        )).toList());
      }
    } catch (e) {
      debugPrint('🦢 保存聊天历史失败: $e');
    }
  }

  @override
  void dispose() {
    _saveChatHistory();
    _inputController.dispose();
    _scrollController.dispose();
    _focusNode.dispose();
    _slideController.dispose();
    super.dispose();
  }

  /// 添加主动搭话消息（由外部调用）
  void addProactiveMessage(String message) {
    setState(() {
      _messages.add(_ChatMessage(
        content: message,
        isUser: false,
        timestamp: DateTime.now(),
      ));
    });
    _saveChatHistory();
    _scrollToBottom();
  }

  /// 执行定时任务的 prompt，让鹅宝把结果说出来
  /// [prompt] 要发给 AI 的指令
  /// [taskTitle] 定时任务标题，显示在聊天中
  Future<void> executeScheduledPrompt(String prompt, String taskTitle) async {
    if (_isLoading) return;

    // 自动打开聊天面板，让用户看到结果
    // （由 pet_window 处理）

    setState(() {
      _messages.add(_ChatMessage(
        content: prompt,
        isUser: true,
        timestamp: DateTime.now(),
      ));
      _isLoading = true;
      _streamingContent = '';
    });
    _scrollToBottom();

    try {
      final petEngine = context.read<PetEngine>();
      final llmManager = context.read<LLMManager>();
      final memoryManager = context.read<MemoryManager>();
      final skillManager = context.read<SkillManager>();

      // 注入 MemoryManager 到 SaveMemorySkill
      skillManager.saveMemorySkill?.memoryManager = memoryManager;
      final selfImprove = context.read<SelfImprovementEngine>();

      final memoryContext = memoryManager.getMemoryContext(prompt);
      // 首次触发衰减清理
      memoryManager.decayAndCleanup();
      final improvementContext = selfImprove.getImprovementContext();
      final stateContext = GoosePrompts.getStateContext(
        mood: petEngine.happiness,
        hunger: petEngine.hunger,
        energy: petEngine.energy,
        level: petEngine.state.level,
        companionDays: petEngine.state.companionDays,
        companionRhythm: petEngine.getCompanionRhythm(),
      );
      final emotionalContext = memoryManager.getEmotionalContext();
      final fullMemoryContext = [
        if (memoryContext.isNotEmpty) memoryContext,
        if (stateContext.isNotEmpty) '当前状态: $stateContext',
        if (emotionalContext.isNotEmpty) emotionalContext,
      ].join('\n\n');

      // 获取已升级的永久失败经验（高频错误，避免重复犯错）
      final failureLessonsContext = memoryManager.getFailureLessonsContext();
      final effectiveMemoryContext = fullMemoryContext.isEmpty
          ? failureLessonsContext
          : (failureLessonsContext.isEmpty
              ? fullMemoryContext
              : '$fullMemoryContext\n\n$failureLessonsContext');

      // 获取 Agent Skills 的 prompt 注入（SKILL.md 格式技能的使用说明）
      // 注意：这里是定时任务/主动搭话，不进行任务感知筛选
      final agentSkillsPrompt = skillManager.getAgentSkillsPrompt();

      final chatHistory = _messages
          .where((m) => !m.isError)
          .map((m) => ChatMessage(
                id: m.timestamp.millisecondsSinceEpoch.toString(),
                role: m.isUser ? 'user' : 'assistant',
                content: m.content,
                timestamp: m.timestamp,
              ))
          .toList();

      String fullResponse = '';

      final tools = skillManager.toFunctionTools();
      final response = await llmManager.chat(
        chatHistory: chatHistory,
        memoryContext: effectiveMemoryContext,
        improvementContext: improvementContext,
        agentSkillsPrompt: agentSkillsPrompt,
        tools: tools,
        workMode: widget.workMode,
      );

      fullResponse = response.text;

      setState(() {
        _messages.add(_ChatMessage(
          content: fullResponse,
          isUser: false,
          timestamp: DateTime.now(),
        ));
        _isLoading = false;
        _streamingContent = '';
      });
      _scrollToBottom();
    } catch (e) {
      setState(() {
        _messages.add(_ChatMessage(
          content: '执行定时任务失败: $e',
          isUser: false,
          timestamp: DateTime.now(),
          isError: true,
        ));
        _isLoading = false;
        _streamingContent = '';
      });
    }

    _saveChatHistory();
  }

  /// 复制全部对话内容到剪贴板
  void _copyAllMessages() {
    if (_messages.isEmpty) return;
    final buffer = StringBuffer();
    for (final msg in _messages) {
      final role = msg.isUser ? '我' : '鹅宝';
      final time = '${msg.timestamp.hour.toString().padLeft(2, '0')}:'
          '${msg.timestamp.minute.toString().padLeft(2, '0')}';
      buffer.writeln('[$time] $role: ${msg.content}');
      buffer.writeln();
    }
    Clipboard.setData(ClipboardData(text: buffer.toString().trimRight()));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('已复制全部对话'),
        duration: Duration(seconds: 1),
      ),
    );
  }

  /// 检测用户显式的"记住"指令，直接保存到长期记忆（不走工具链）
  /// 匹配模式如：记住XXX、帮我记住XXX、记一下XXX、别忘了XXX、记住这件事XXX等
  /// 返回保存的记忆内容，未匹配返回 null
  /// 注意：这里做前置保存作为保底，LLM 也会通过 save_memory 工具主动保存
  String? _trySaveExplicitMemory(String text) {
    final memoryPatterns = [
      RegExp(r'(?:帮我?|请|麻烦)?记住(?:这件事|这个|这|一下|吧)?[：:，,]?\s*(.+)', caseSensitive: false),
      RegExp(r'记(?:一下|一下这个|住(?:这|这个|这件事)?)[：:，,]?\s*(.+)', caseSensitive: false),
      RegExp(r'别(?:忘了|忘记)(?:这|这个|这件事)?[：:，,]?\s*(.+)', caseSensitive: false),
      RegExp(r'帮我?存(?:一下)?(?:这|这个)?[：:，,]?\s*(.+)', caseSensitive: false),
      RegExp(r'记住[：:\s]*(.+)', caseSensitive: false),
    ];

    String? memoryContent;
    for (final pattern in memoryPatterns) {
      final match = pattern.firstMatch(text);
      if (match != null) {
        memoryContent = match.group(1)?.trim();
        break;
      }
    }

    if (memoryContent == null || memoryContent.length < 2) return null;

    // 去掉末尾的标点和语气词
    memoryContent = memoryContent.replaceAll(RegExp(r'[。，！？~～、]+$'), '').trim();
    if (memoryContent.length < 2) return null;

    try {
      final memoryManager = context.read<MemoryManager>();
      memoryManager.save(memoryContent, metadata: {
        'type': '用户指令',
        'source': 'explicit_command',
      });
      debugPrint('🧠 显式记忆保存: $memoryContent');
    } catch (e) {
      debugPrint('🧠 显式记忆保存失败: $e');
      return null;
    }
    return memoryContent;
  }

  /// 停止当前会话（用户点击停止按钮）
  void _stopCurrentSession() {
    // 停止普通模式
    if (_isLoading && _cancellationToken != null) {
      _cancellationToken!.cancel();
      debugPrint('🛑 用户取消了当前会话');
      
      // 如果有流式内容正在输出，保留已输出的部分作为消息
      final partialContent = _streamingContent;
      
      // 立即停止 UI 输出
      setState(() {
        if (partialContent.isNotEmpty) {
          _messages.add(_ChatMessage(
            content: '$partialContent\n\n---\n*（已停止）*',
            isUser: false,
            timestamp: DateTime.now(),
          ));
        } else {
          _messages.add(_ChatMessage(
            content: '好的，鹅宝已经停下来了~ 🦢✋',
            isUser: false,
            timestamp: DateTime.now(),
          ));
        }
        _streamingContent = '';
        _toolCallSteps.clear();
        _isLoading = false;
        _cancellationToken = null;
      });
      _saveChatHistory();
      return; // 普通模式已处理完，直接返回
    }
    
    // 停止 Team 模式
    if (_isTeamExecuting && _teamCancellationToken != null) {
      _teamCancellationToken!.cancel();
      debugPrint('🛑 用户取消了 Team 模式任务');
      
      // 保存当前执行状态（用于恢复）
      if (_currentTeamTask != null && _currentStageIndex >= 0) {
        _saveTeamExecutionState(
          userTask: _currentTeamTask!,
          currentStageIndex: _currentStageIndex,
          completedTaskIds: _completedTaskIds.toList(),
          taskOutputs: _taskOutputs,
        );
      }
      
      // 重置所有角色状态
      setState(() {
        _isTeamExecuting = false;
        _isLoading = false;
        for (final agentId in _agentStatus.keys) {
          _agentStatus[agentId] = 'idle';
        }
      });
      
      // 发送取消通知
      _sendTeamMessage(
        fromAgentId: 'system',
        fromAgentName: '系统',
        type: TeamMessageType.broadcast,
        content: '⚠️ 任务已被用户取消\n💡 可以点击"恢复任务"按钮继续执行',
      );
    }
  }

  Future<void> _sendMessage() async {
    final text = _inputController.text.trim();
    final attachments = List<MessageAttachment>.from(_pendingAttachments);
    if (text.isEmpty && attachments.isEmpty) return;
    if (_isLoading) return;

    // Plan 模式下，如果有待确认计划，不允许发送新消息（应先点击按钮确认/取消）
    if (_pendingPlans.any((p) => !p.isConfirmed && !p.isRejected)) {
      return;
    }

    // Team 模式：检查 @ 提及
    if (_agentMode == AgentMode.team && text.isNotEmpty) {
      debugPrint('🦆 Team 模式发送消息: $text');
      debugPrint('🦆 团队成员数量: ${_teamAgents.length}');
      debugPrint('🦆 是否有主管: ${_teamAgents.any((a) => a.id == 'supervisor')}');
      
      _inputController.clear();
      _pendingAttachments.clear();
      
      // 添加用户消息到对话框
      setState(() {
        _messages.add(_ChatMessage(
          content: text,
          isUser: true,
          timestamp: DateTime.now(),
          attachments: attachments,
        ));
      });
      _saveChatHistory();
      _scrollToBottom();
      
      // 检测 @ 提及
      final mentions = _parseMentions(text);
      debugPrint('🦆 解析到的提及: ${mentions.map((a) => a.name).join(", ")}');

      if (mentions.isNotEmpty) {
        // 有 @ 提及，让指定角色回答
        debugPrint('🦆 走 _handleMentionedReply 路线');
        await _handleMentionedReply(text, mentions);
      } else if (_teamMode == TeamMode.discussion) {
        // 圆桌模式：主持人引导讨论
        debugPrint('🦆 走 _startDiscussion 路线');
        await _startDiscussion(text);
      } else {
        // 任务模式：没有 @ 提及时，默认让主管编排分配任务
        debugPrint('🦆 走 _startTeamExecution 路线');
        await _startTeamExecution(text);
      }
      return;
    }

    // 记住当前会话ID，防止切换会话后保存到错误会话
    _processingConversationId = _currentConversationId;
    _inputController.clear();

    // 检测"记住"类指令，直接保存到长期记忆（不走工具链）
    final savedMemory = _trySaveExplicitMemory(text);

    // 注入 MemoryManager 到 SaveMemorySkill（确保工具可用）
    try {
      final skillManager = context.read<SkillManager>();
      final memoryManager = context.read<MemoryManager>();
      skillManager.saveMemorySkill?.memoryManager = memoryManager;
    } catch (_) {}

    // 如果是纯粹的"记住"指令（没有附件，且正则匹配成功），直接回复不走 LLM
    if (savedMemory != null && attachments.isEmpty) {
      setState(() {
        _messages.add(_ChatMessage(
          content: text,
          isUser: true,
          timestamp: DateTime.now(),
        ));
        _messages.add(_ChatMessage(
          content: '记住了鹅~ 放心吧！🧠',
          isUser: false,
          timestamp: DateTime.now(),
        ));
      });
      _saveChatHistory();
      _scrollToBottom();
      return;
    }

    // 开始工作动画（鹅宝开始干活了）
    final petEngine = context.read<PetEngine>();
    petEngine.startWorking();
    petEngine.onUserActive(); // 标记用户活跃

    // 记录成就事件（对话）
    petEngine.achievementManager?.recordChat();

    // 记录日记统计（用户发送消息 + 互动）
    DiaryService.instance.recordMessage();
    DiaryService.instance.recordInteraction(type: 'chat');

    // 构建消息内容（如果有文件附件，将文件信息附加到消息中）
    String messageContent = text;
    if (attachments.isNotEmpty) {
      final fileDescriptions = <String>[];
      for (final att in attachments) {
        if (att.type == AttachmentType.file && att.filePath != null) {
          // 尝试读取文本文件内容
          final fileContent = _tryReadFileContent(att.filePath!);
          if (fileContent != null) {
            fileDescriptions.add('[文件: ${att.fileName}]\n```\n$fileContent\n```');
          } else {
            fileDescriptions.add('[文件: ${att.fileName}, 大小: ${att.formattedSize}]');
          }
        } else if (att.type == AttachmentType.image) {
          fileDescriptions.add('[图片: ${att.fileName}]');
        }
      }
      if (fileDescriptions.isNotEmpty) {
        messageContent = '${fileDescriptions.join('\n')}\n\n$text'.trim();
      }
    }

    setState(() {
      _messages.add(_ChatMessage(
        content: text,
        isUser: true,
        timestamp: DateTime.now(),
        attachments: attachments,
      ));
      _isLoading = true;
      _streamingContent = '';
      _toolCallSteps.clear();
      _pendingAttachments = [];
      _cancellationToken = CancellationToken();
    });
    _scrollToBottom();

    try {
      final llmManager = context.read<LLMManager>();
      final memoryManager = context.read<MemoryManager>();
      final skillManager = context.read<SkillManager>();
      final selfImprove = context.read<SelfImprovementEngine>();
      final petEngine = context.read<PetEngine>();

      // 获取记忆上下文（首次发送消息时触发衰减清理）
      memoryManager.decayAndCleanup();
      
      // ── 使用 Segment 方式管理记忆注入（优化6） ──
      // 清空之前的 segments
      _contextManager.clearSegments();
      
      // 添加记忆 Segments
      final memorySegments = memoryManager.getMemorySegments(text);
      for (final seg in memorySegments) {
        _contextManager.addSegment(seg);
      }
      
      // 添加 self-improvement 作为 Segment
      final improvementContext = selfImprove.getImprovementContext();
      if (improvementContext.isNotEmpty) {
        _contextManager.addSegment(SystemPromptSegment(
          id: 'self_improvement',
          title: '学习策略',
          content: improvementContext,
          priority: 6,
          maxTokens: 300,
          optional: true,
          compressible: true,
        ));
      }
      
      // 构建鹅宝状态上下文（饥饿、精力、心情等）
      // ── 用户情绪感知 ──
      final recentUserMessages = _messages
          .where((m) => m.isUser && !m.isError)
          .map((m) => m.content)
          .toList();
      final userEmotionHint = GoosePrompts.detectUserEmotion(recentUserMessages);

      final stateContext = GoosePrompts.getStateContext(
        mood: petEngine.happiness,
        hunger: petEngine.hunger,
        energy: petEngine.energy,
        level: petEngine.state.level,
        companionDays: petEngine.state.companionDays,
        userEmotionHint: userEmotionHint,
        companionRhythm: petEngine.getCompanionRhythm(),
      );
      
      // 添加状态上下文作为 Segment
      if (stateContext.isNotEmpty) {
        _contextManager.addSegment(SystemPromptSegment(
          id: 'pet_state',
          title: '当前状态',
          content: stateContext,
          priority: 5,
          maxTokens: 200,
          optional: true,
          compressible: true,
        ));
      }

      // ── 情感记忆上下文 ──
      final emotionalContext = memoryManager.getEmotionalContext();
      if (emotionalContext.isNotEmpty) {
        _contextManager.addSegment(SystemPromptSegment(
          id: 'emotional_events',
          title: '情感记录',
          content: emotionalContext,
          priority: 7,
          maxTokens: 300,
          optional: true,
          compressible: true,
        ));
      }
      
      // 使用 ContextManager 构建记忆注入部分（统一管理 token 预算）
      final effectiveMemoryContext = _contextManager.build(
        customMaxTokens: _contextManager.getSystemPromptMaxForLevel(_contextManager.promptLevel),
      );

      // 获取 Agent Skills 的 prompt 注入（SKILL.md 格式技能的使用说明）
      // 根据用户请求进行任务感知的技能筛选
      final agentSkillsPrompt = skillManager.getAgentSkillsPrompt(userRequest: text);

      // 构建对话历史（包含工具调用消息序列）
      final chatApiHistory = _buildChatApiHistory(messageContent, text);
      final chatHistory = _messages
          .where((m) => !m.isError)
          .map((m) => ChatMessage(
                id: m.timestamp.millisecondsSinceEpoch.toString(),
                role: m.isUser ? 'user' : 'assistant',
                content: m.content,
                timestamp: m.timestamp,
              ))
          .toList();
      // 替换最后一条用户消息的 content（附加文件内容）
      if (chatHistory.isNotEmpty && messageContent != text) {
        final last = chatHistory.last;
        chatHistory[chatHistory.length - 1] = ChatMessage(
          id: last.id,
          role: last.role,
          content: messageContent,
          timestamp: last.timestamp,
        );
      }

      // ── 预构造运行环境信息 ──
      String? pythonPath;
      String workDir = '';
      String osName = 'web';
      
      if (!kIsWeb) {
        pythonPath = await SkillFileUtils.detectPythonPath();
        final sessionId = _currentConversationId ?? DateTime.now().millisecondsSinceEpoch.toString();
        await SkillFileUtils.setSessionWorkingDir(sessionId);
        workDir = SkillFileUtils.effectiveWorkingDir;
        osName = Platform.operatingSystem;
      }
      
      final envPrompt = kIsWeb ? '' : '\n\n## 运行环境'
          '\n- 操作系统: $osName'
          '\n- 当前工作目录: $workDir（每次对话独立，所有文件写在此目录下）'
          '\n- write_file 写文件：直接用文件名（如 script.py），不需要 ./ 前缀'
          '\n- shell_exec 执行脚本：用 command 参数，只写文件名，如 `command: "python my_script.py"`。**不要写完整路径**，系统在工作目录下自动找到。'
          '${pythonPath != null ? "\n- Python 绝对路径: `$pythonPath`，系统会自动使用，你无需指定" : ""}';

      final tools = skillManager.toFunctionTools();

      // ── 构建 system prompt（支持分级） ──
      // 从设置中读取用户选择的 Prompt 级别（默认使用最好的提示词）
      final savedLevel = StorageManager.getSetting<String>('prompt_level', defaultValue: 'full');
      final promptLevel = PromptLevelExtension.fromString(savedLevel ?? 'full') ?? PromptLevel.full;
      _contextManager.setPromptLevel(promptLevel);
      
      // 根据级别获取基础 System Prompt
      String systemPrompt = GoosePrompts.getSystemPromptByLevel(
        promptLevel, 
        workMode: widget.workMode,
      );
      
      // 添加记忆上下文（优化6：作为 Segment 管理）
      if (effectiveMemoryContext.isNotEmpty) {
        systemPrompt += '\n\n## 关于主人的记忆\n$effectiveMemoryContext';
      }
      if (improvementContext.isNotEmpty) {
        systemPrompt += '\n\n$improvementContext';
      }
      // 只有 standard/full 级别才注入 agentSkills
      if (agentSkillsPrompt.isNotEmpty && promptLevel != PromptLevel.minimal) {
        systemPrompt += '\n\n$agentSkillsPrompt';
      }
      systemPrompt += envPrompt;
      
      // 更新 System Prompt Token 统计（用于 UI 显示）
      _currentSystemPromptTokens = TokenCounter.count(systemPrompt);
      debugPrint('📊 [Context] System Prompt Token: $_currentSystemPromptTokens (级别: ${promptLevel.name})');

      // 构建完整的 API 消息列表（统一处理有/无工具调用历史的情况）
      final hasToolMessages = chatApiHistory.any((m) => m['role'] == 'tool' || (m['role'] == 'assistant' && m['tool_calls'] != null));
      final fullApiMessages = <Map<String, dynamic>>[
        {'role': 'system', 'content': systemPrompt},
        if (hasToolMessages) ...chatApiHistory else ...chatHistory.map((m) => m.toApiMessage()),
      ];

      String fullResponse = '';
      bool hasToolCalls = false;
      List<MessageAttachment> resultAttachments = [];
      List<String> resultSkillNames = [];
      List<Map<String, dynamic>> resultApiMessages = [];

      // 先同步调用一次检测是否有 tool_calls（流式无法提前知道）
      final response = await llmManager.chatWithMessages(fullApiMessages, tools: tools);
      
      // 检查等待期间用户是否已取消
      if (_cancellationToken?.isCancelled ?? false) {
        throw CancelledException();
      }

      if (response.hasToolCalls) {
        // 有 tool_calls → 进入 Agent 循环
        hasToolCalls = true;
        
        // 创建 Hooks
        final hooks = <AgentHook>[
          LoopDetectionHook(),
          FailureLessonHook(memoryManager),
          ReflectionHook(
            llmProvider: (prompt) async {
              // 使用当前 LLM 进行反思分析和替代方案生成
              final resp = await llmManager.currentProvider!.chat([
                {'role': 'user', 'content': prompt},
              ]);
              return resp.text;
            },
          ),
          PerformanceStatsHook(),
        ];
        
        final loopResult = await AgentLoop.run(
          provider: llmManager.currentProvider!,
          config: llmManager.currentConfig,
          messages: fullApiMessages,
          tools: tools,
          executeTool: (call, {onOutput}) => _executeTool(call, skillManager, workDir, onOutput: onOutput),
          cancellationToken: _cancellationToken,
          hooks: hooks,
          mode: _agentMode,
          userRequest: text,
          onPlanGenerated: (plan) {
            if (!mounted) return;
            setState(() {
              _pendingPlans.add(plan);
              _activePlanIndex = _pendingPlans.length - 1;
            });
          },
          onStepUpdate: (step) {
            if (!mounted) return;
            setState(() {
              // 用 identity 匹配：同一 ToolStep 对象更新而非重复添加
              final existIdx = _toolCallSteps.indexWhere(
                (s) => identical(s.sourceStep, step),
              );
              final widget = _ToolCallStep(
                sourceStep: step,
                title: step.title,
                content: step.content,
                isLoading: step.isLoading,
                isSkip: step.isSkip,
                isFailed: step.isFailed,
                timestamp: step.timestamp,
              );
              if (existIdx >= 0) {
                _toolCallSteps[existIdx] = widget;
              } else {
                _toolCallSteps.add(widget);
              }
            });
            _scrollToBottom();
          },
        );
        fullResponse = loopResult.text;
        resultApiMessages = loopResult.apiMessages;
        resultSkillNames = loopResult.skillNames;
        resultAttachments = loopResult.outputFiles.map((f) => MessageAttachment(
          type: AttachmentType.file,
          fileName: f['name'] as String? ?? '',
          filePath: f['path'] as String?,
          fileSize: f['size'] as int? ?? 0,
        )).toList();
      } else {
        // 纯文本回复 → 真正的流式输出（利用已有的 _streamingContent 机制）
        final streamBuffer = StringBuffer();
        await for (final chunk in llmManager.chatStreamWithMessages(fullApiMessages, tools: tools)) {
          if (!mounted) break;
          if (_cancellationToken?.isCancelled ?? false) break;
          streamBuffer.write(chunk);
          setState(() => _streamingContent = streamBuffer.toString());
          _scrollToBottom();
        }
        // 如果是被取消的，抛出 CancelledException 走统一的取消处理
        if (_cancellationToken?.isCancelled ?? false) {
          throw CancelledException();
        }
        fullResponse = streamBuffer.toString();
      }

      // 停止工作动画（仅休闲模式，工作模式保持工作状态）
      if (!widget.workMode) {
        petEngine.stopWorking();
        final emotion = llmManager.extractEmotion(fullResponse);
        petEngine.setEmotion(emotion);
      }

      // ── 情感反馈循环 ──
      _processEmotionalFeedback(text, fullResponse, petEngine, memoryManager);

      setState(() {
        _messages.add(_ChatMessage(
          content: fullResponse,
          isUser: false,
          timestamp: DateTime.now(),
          skillResult: hasToolCalls && resultSkillNames.isNotEmpty
              ? '🎯 ${resultSkillNames.join(", ")}'
              : (hasToolCalls ? '🎯 已调用技能' : null),
          attachments: resultAttachments,
          toolSteps: List.unmodifiable(_toolCallSteps),
          apiMessages: resultApiMessages.isNotEmpty
              ? List.unmodifiable(resultApiMessages)
              : null,
        ));
        _streamingContent = '';
        _toolCallSteps.clear();
      });

      // 记录日记统计（AI 回复）
      DiaryService.instance.recordMessage();

      // 对话完成奖励金币
      petEngine.earnChatCoins();

      _saveChatHistory();

      // 如果面板当前不可见（用户关闭了对话框），通知外部显示气泡提示
      if (!widget.isVisible && widget.onBackgroundComplete != null) {
        // 截取回复的第一句话作为气泡内容
        final preview = fullResponse.split('\n').first.trim();
        final bubbleText = preview.length > 50
            ? '${preview.substring(0, 50)}...'
            : preview;
        widget.onBackgroundComplete!(bubbleText.isNotEmpty ? '💬 $bubbleText' : '💬 鹅宝完成了思考~');
      }

      // 异步触发 self-improvement（不阻塞 UI）
      selfImprove.afterConversation(
        userMessage: text,
        botResponse: fullResponse,
        recentHistory: chatHistory,
      );
    } on CancelledException {
      // 用户主动取消会话 — UI 已在 _stopCurrentSession 中立即处理，此处仅做兜底清理
      if (!widget.workMode) {
        petEngine.stopWorking();
      }
      // 不重复添加消息（_stopCurrentSession 已添加）
      if (_streamingContent.isNotEmpty || _toolCallSteps.isNotEmpty) {
        setState(() {
          _streamingContent = '';
          _toolCallSteps.clear();
        });
      }
    } catch (e) {
      // 出错也要停止工作动画（仅休闲模式）
      if (!widget.workMode) {
        petEngine.stopWorking();
      }

      setState(() {
        _messages.add(_ChatMessage(
          content: '嘎...鹅宝的大脑出了点问题: $e',
          isUser: false,
          timestamp: DateTime.now(),
          isError: true,
        ));
        _streamingContent = '';
      });
      _saveChatHistory();
    } finally {
      setState(() {
        _isLoading = false;
        _cancellationToken = null;
      });
      _scrollToBottom();
      // 清除正在处理的会话ID
      _processingConversationId = null;
    }
  }

  /// 执行单个工具（供 AgentLoop 调用）
  /// 将旧的 _handleToolCalls 中的工具执行逻辑抽取为独立方法
  Future<ToolResult> _executeTool(ToolCall call, SkillManager skillManager, String workDir, {void Function(String line)? onOutput}) async {
    final skillId = call.name;
    final args = call.arguments;

    try {
      // ── think 工具：空操作 ──
      if (skillId == 'think') {
        return ToolResult(toolCallId: call.id, content: '思考已记录，请继续执行下一步。');
      }

      // ── save_memory 工具 ──
      if (skillId == 'save_memory') {
        try {
          if (mounted) {
            final memMgr = context.read<MemoryManager>();
            skillManager.saveMemorySkill?.memoryManager = memMgr;
          }
        } catch (_) {}
        final result = await skillManager.execute(skillId, args);
        return ToolResult(toolCallId: call.id, content: result.message, isError: !result.success);
      }

      // ── activate_skill 工具 ──
      if (skillManager.isActivateSkillTool(skillId)) {
        final skillName = args['name'] as String? ?? '';
        final result = await skillManager.activateSkill(skillName);
        final content = result.success
            ? result.message
            : '激活技能失败: ${result.message}';
        return ToolResult(toolCallId: call.id, content: content, isError: !result.success);
      }

      // ── 通用工具执行 ──
      // 检索相关失败经验
      String? relevantFailureHint;
      try {
        if (mounted) {
          final memoryManager = context.read<MemoryManager>();
          relevantFailureHint = memoryManager.searchRelevantFailures(skillId, args);
        }
      } catch (_) {}

      final execResult = await skillManager.execute(skillId, args, onOutput: onOutput);
      String toolResultContent = execResult.message;

      // 仅在失败时注入相关失败经验（成功时不注入，避免干扰正常流程）
      if (relevantFailureHint != null && !execResult.success) {
        toolResultContent = '$relevantFailureHint\n\n$toolResultContent';
      }

      // 所有工具失败时追加反思引导（防止盲目重试）
      if (!execResult.success) {
        final hint = skillId == 'shell_exec'
            ? _shellExecFailureHint()
            : _genericFailureHint(skillId);
        toolResultContent += '\n\n$hint';
      }

      // 收集输出文件信息（传递给 AgentLoop 用于 UI 展示）
      Map<String, dynamic>? toolData;
      if (execResult.success && execResult.data != null) {
        if (skillId == 'write_file') {
          // write_file: 单个文件信息
          toolData = execResult.data;
        } else if (skillId == 'shell_exec' && execResult.data!['outputFiles'] != null) {
          // shell_exec: outputFiles 列表 → 扁平化为单个文件的 data
          final files = execResult.data!['outputFiles'] as List;
          if (files.isNotEmpty) {
            toolData = {'_outputFiles': files};
          }
        }
      }

      return ToolResult(toolCallId: call.id, content: toolResultContent, isError: !execResult.success, data: toolData);
    } catch (e) {
      return ToolResult(toolCallId: call.id, content: '工具执行异常: $e', isError: true);
    }
  }

  /// shell_exec 失败时的深度反思引导
  static String _shellExecFailureHint() {
    return '【⚠️ 执行失败】\n'
        '请先用 think 工具分析根因（路径错误？依赖缺失？语法错误？），'
        '然后立即用正确的工具修复问题并重新执行。不要只分析不行动。';
  }

  /// 通用工具失败时的反思引导
  static String _genericFailureHint(String skillId) {
    switch (skillId) {
      case 'write_file':
        return '【⚠️ 写入失败】\n'
            '常见原因：路径无效、权限不足、尝试写入二进制文件。\n'
            '请分析原因后立即修复并重试，不要只分析不行动。';
      case 'read_file':
        return '【⚠️ 读取失败】\n'
            '常见原因：路径不正确、文件不存在、文件是二进制格式。\n'
            '请检查路径后立即修正重试。';
      case 'activate_skill':
        return '【⚠️ 技能激活失败】\n'
            '请检查技能名是否正确，或直接用其他可用工具完成任务。';
      default:
        return '【⚠️ 工具执行失败】\n'
            '请分析错误原因后，换一种方式完成任务，不要重复相同的失败操作。';
        }
  }

  

  /// 构建对话历史的 API 消息列表
  /// 对于有 apiMessages（工具调用记录）的 assistant 消息，展开为 assistant(tool_calls) + tool(results) + assistant(final_reply) 序列
  /// 对于普通消息，构建标准的 user/assistant 消息
  /// [messageContent] 最后一条用户消息的实际内容（可能包含附件信息）
  /// [originalText] 用户原始输入文本
  ///
  /// Token 预算控制（优化后）：
  /// - 使用 ContextManager 的 Token 预算控制替代简单条数限制
  /// - 历史消息总 Token 不超过 [historyTokenBudget]（默认 20000）
  /// - 较早的 apiMessages 组使用结构化摘要替代
  List<Map<String, dynamic>> _buildChatApiHistory(String messageContent, String originalText) {
    final apiHistory = <Map<String, dynamic>>[];
    final historyTokenBudget = _contextManager.historyReserve;
    
    // 第一遍：收集所有消息
    final allEntries = <Map<String, dynamic>>[];
    int apiMessageGroupCount = 0;

    for (int i = 0; i < _messages.length; i++) {
      final m = _messages[i];
      if (m.isError) continue;

      if (m.isUser) {
        final isLast = (i == _messages.length - 1);
        allEntries.add({'role': 'user', 'content': isLast ? messageContent : m.content, '_index': i});
      } else {
        if (m.apiMessages != null && m.apiMessages!.isNotEmpty) {
          apiMessageGroupCount++;
          allEntries.add({
            '_type': 'api_group', 
            '_index': i, 
            '_apiMessages': m.apiMessages, 
            '_content': m.content, 
            '_groupIndex': apiMessageGroupCount
          });
        } else {
          allEntries.add({'role': 'assistant', 'content': m.content, '_index': i});
        }
      }
    }

    // 第二遍：构建最终列表，使用 Token 预算控制
    final totalApiGroups = apiMessageGroupCount;
    // 保留最近的 2 组完整 apiMessages，更早的用摘要
    const maxFullApiGroups = 2;
    
    // Token 计数和预算控制
    int currentTokens = 0;
    final budgetAwareEntries = <Map<String, dynamic>>[];
    
    // 从后向前遍历，保留最新消息
    for (int i = allEntries.length - 1; i >= 0; i--) {
      final entry = allEntries[i];
      
      if (entry['_type'] == 'api_group') {
        final groupIndex = entry['_groupIndex'] as int;
        final apiMessages = entry['_apiMessages'] as List<Map<String, dynamic>>;
        final finalContent = entry['_content'] as String?;
        
        // 判断是否保留完整 apiMessages
        final shouldKeepFull = (totalApiGroups - groupIndex) < maxFullApiGroups;
        
        if (shouldKeepFull) {
          // 保留完整的 apiMessage 序列
          int groupTokens = 0;
          for (final apiMsg in apiMessages) {
            groupTokens += TokenCounter.countMessages([apiMsg]);
          }
          if (finalContent != null) {
            groupTokens += TokenCounter.count(finalContent);
          }
          
          // 预算检查
          if (currentTokens + groupTokens <= historyTokenBudget) {
            budgetAwareEntries.insert(0, {
              '_type': 'full_api_group',
              '_apiMessages': apiMessages,
              '_content': finalContent,
            });
            currentTokens += groupTokens;
          } else {
            // 预算不足，转为摘要
            final summary = _contextManager.generateToolCallSummary(apiMessages, finalContent: finalContent);
            final summaryTokens = TokenCounter.count(summary);
            if (currentTokens + summaryTokens <= historyTokenBudget) {
              budgetAwareEntries.insert(0, {'role': 'assistant', 'content': summary});
              currentTokens += summaryTokens;
            }
          }
        } else {
          // 较早的 apiMessages 组：使用结构化摘要
          final summary = _contextManager.generateToolCallSummary(apiMessages, finalContent: finalContent);
          final summaryTokens = TokenCounter.count(summary);
          
          if (currentTokens + summaryTokens <= historyTokenBudget) {
            budgetAwareEntries.insert(0, {'role': 'assistant', 'content': summary});
            currentTokens += summaryTokens;
          }
        }
      } else {
        // 普通消息
        final content = entry['content'] as String;
        final msgTokens = TokenCounter.count(content) + 4; // +4 for role overhead
        
        if (currentTokens + msgTokens <= historyTokenBudget) {
          budgetAwareEntries.insert(0, {
            'role': entry['role'] as String,
            'content': content,
          });
          currentTokens += msgTokens;
        }
      }
    }
    
    // 第三遍：展开 full_api_group 为实际的 API 消息
    for (final entry in budgetAwareEntries) {
      if (entry['_type'] == 'full_api_group') {
        final apiMessages = entry['_apiMessages'] as List<Map<String, dynamic>>;
        final finalContent = entry['_content'] as String?;
        
        for (final apiMsg in apiMessages) {
          apiHistory.add(Map<String, dynamic>.from(apiMsg));
        }
        if (finalContent != null && finalContent.isNotEmpty) {
          apiHistory.add({'role': 'assistant', 'content': finalContent});
        }
      } else {
        apiHistory.add({
          'role': entry['role'] as String,
          'content': entry['content'],
        });
      }
    }
    
    // 更新 Token 统计（用于 UI 显示）
    _currentHistoryTokens = currentTokens;
    
    debugPrint('📊 [Context] 历史消息 Token: $currentTokens / $historyTokenBudget');
    
    return apiHistory;
  }



  void _scrollToBottom({bool jump = false}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        if (jump) {
          _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
        } else {
          _scrollController.animateTo(
            _scrollController.position.maxScrollExtent,
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOut,
          );
        }
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return SlideTransition(
      position: _slideAnimation,
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xFFF5F5F5),
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(20),
            bottomLeft: Radius.circular(20),
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.1),
              blurRadius: 20,
              offset: const Offset(-4, 0),
            ),
          ],
        ),
        child: (_showConversationList && _conversationManager != null)
            ? Row(
                children: [
                  // 左侧会话列表（根据状态显示/隐藏）
                  SizedBox(
                    width: 240,
                    child: _buildConversationList(),
                  ),
                  // 右侧聊天区域
                  Expanded(
                    child: Column(
                      children: [
                        _buildHeader(),
                        if (_showAgentTeamPanel) _buildAgentTeamPanel(),
                        if (_pendingPlans.isNotEmpty) _buildPlanPanel(),
                        Expanded(child: _buildMessageList()),
                        _buildInputBar(),
                      ],
                    ),
                  ),
                ],
              )
            : Column(
                children: [
                  _buildHeader(),
                  if (_showAgentTeamPanel) _buildAgentTeamPanel(),
                  if (_pendingPlans.isNotEmpty) _buildPlanPanel(),
                  Expanded(child: _buildMessageList()),
                  _buildInputBar(),
                ],
              ),
      ),
    );
  }

  Widget _buildHeader() {
    return GestureDetector(
      onPanStart: (_) => windowManager.startDragging(),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.only(topLeft: Radius.circular(20)),
          border: Border(bottom: BorderSide(color: Color(0xFFE0E0E0), width: 0.5)),
        ),
        child: Row(
          children: [
            const Text('🦢', style: TextStyle(fontSize: 22)),
            const SizedBox(width: 8),
            const Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '鹅宝',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                  ),
                  Text(
                    '在线 · 嘎嘎嘎',
                    style: TextStyle(fontSize: 11, color: Colors.green),
                  ),
                ],
              ),
            ),
            // Agent 模式切换
            _buildModeSelector(),
            const SizedBox(width: 8),
            // 会话列表显示/隐藏按钮（两种模式都可用）
            _HeaderButton(
              icon: Icon(
                _showConversationList ? Icons.list : Icons.list_alt,
                size: 18,
                color: _showConversationList ? const Color(0xFF4FC3F7) : Colors.grey,
              ),
              label: _showConversationList ? '隐藏列表' : '显示列表',
              onPressed: () {
                setState(() {
                  _showConversationList = !_showConversationList;
                });
              },
              tooltip: _showConversationList ? '隐藏会话列表' : '显示会话列表',
            ),
            // 模式切换按钮（显示当前状态，点击切换）
            if (widget.onToggleMode != null)
              _HeaderButton(
                icon: Icon(
                  widget.workMode ? Icons.work : Icons.chat_bubble,
                  size: 18,
                  color: widget.workMode ? const Color(0xFF4FC3F7) : const Color(0xFFFFB74D),
                ),
                label: widget.workMode ? '工作' : '休闲',
                onPressed: widget.onToggleMode,
                tooltip: widget.workMode ? '当前：工作模式（点击切换到休闲模式）' : '当前：休闲模式（点击切换到工作模式）',
                isActive: true,
              ),
            // 复制全部对话
            _HeaderButton(
              icon: const Icon(Icons.copy, size: 16, color: Colors.grey),
              label: '复制',
              onPressed: _copyAllMessages,
              tooltip: '复制全部对话',
            ),
            // 清空对话
            _HeaderButton(
              icon: const Icon(Icons.delete_outline, size: 18, color: Colors.grey),
              label: '清空',
              onPressed: () {
                setState(() {
                  _messages.clear();
                  _messages.add(_ChatMessage(
                    content: '对话已清空~ 嘎~ 我们重新开始聊吧！',
                    isUser: false,
                    timestamp: DateTime.now(),
                  ));
                });
                _saveChatHistory();
              },
              tooltip: '清空对话',
            ),
            _HeaderButton(
              icon: const Icon(Icons.close, size: 18, color: Colors.grey),
              label: '关闭',
              onPressed: widget.onClose,
              tooltip: '关闭对话框',
            ),
          ],
        ),
      ),
    );
  }

  /// 构建 Agent 模式选择器
  Widget _buildModeSelector() {
    // 只有工作模式才支持 Team 模式
    final availableModes = widget.workMode 
        ? AgentMode.values 
        : AgentMode.values.where((m) => m != AgentMode.team).toList();
    
    // 如果当前模式是 team 但不是工作模式，自动切换到 craft
    if (_agentMode == AgentMode.team && !widget.workMode) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        setState(() {
          _agentMode = AgentMode.craft;
          _showAgentTeamPanel = false;
        });
      });
    }
    
    return PopupMenuButton<AgentMode>(
      initialValue: _agentMode,
      onSelected: (mode) {
        setState(() {
          _agentMode = mode;
          // Team 模式时显示 Agent Team 面板
          _showAgentTeamPanel = mode == AgentMode.team;
        });
        _saveAgentMode(mode);
      },
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      itemBuilder: (context) => availableModes.map((mode) {
        final isSelected = mode == _agentMode;
        return PopupMenuItem(
          value: mode,
          child: Row(
            children: [
              Text(mode.icon, style: const TextStyle(fontSize: 16)),
              const SizedBox(width: 8),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    mode.displayName,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                    ),
                  ),
                  Text(
                    mode.description,
                    style: TextStyle(fontSize: 10, color: Colors.grey.shade500),
                  ),
                ],
              ),
              if (isSelected) ...[
                const Spacer(),
                const Icon(Icons.check, size: 16, color: Color(0xFF4FC3F7)),
              ],
            ],
          ),
        );
      }).toList(),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: _getModeColor().withOpacity(0.1),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: _getModeColor().withOpacity(0.3)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_agentMode.icon, style: const TextStyle(fontSize: 14)),
            const SizedBox(width: 4),
            Text(
              _agentMode.displayName,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: _getModeColor(),
              ),
            ),
            const SizedBox(width: 2),
            Icon(Icons.arrow_drop_down, size: 16, color: _getModeColor()),
          ],
        ),
      ),
    );
  }

  /// 获取模式颜色
  Color _getModeColor() {
    switch (_agentMode) {
      case AgentMode.craft:
        return const Color(0xFF4CAF50); // 绿色
      case AgentMode.plan:
        return const Color(0xFF2196F3); // 蓝色
      case AgentMode.ask:
        return const Color(0xFF9E9E9E); // 灰色
      case AgentMode.team:
        return const Color(0xFF9C27B0); // 紫色
    }
  }

  /// 构建 Agent Team 配置面板
  Widget _buildAgentTeamPanel() {
    return Container(
      constraints: const BoxConstraints(maxHeight: 200),
      decoration: BoxDecoration(
        color: Colors.purple.shade50,
        border: Border(bottom: BorderSide(color: Colors.purple.shade200, width: 0.5)),
      ),
      child: Column(
        children: [
          // 标题栏
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.purple.shade100,
              border: Border(bottom: BorderSide(color: Colors.purple.shade200)),
            ),
            child: Row(
              children: [
                const Icon(Icons.groups, size: 16, color: Color(0xFF9C27B0)),
                const SizedBox(width: 6),
                const Text(
                  'Agent Team',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFF9C27B0)),
                ),
                const SizedBox(width: 8),
                // 模式切换
                _buildTeamModeSelector(),
                const Spacer(),
                // 导入按钮
                InkWell(
                  onTap: _showSavedTeams,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: Colors.blue.shade200,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: const Text('导入', style: TextStyle(fontSize: 10, color: Colors.white)),
                  ),
                ),
                const SizedBox(width: 4),
                // 保存按钮
                if (_teamAgents.isNotEmpty)
                  InkWell(
                    onTap: _saveCurrentTeam,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: Colors.green.shade200,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: const Text('保存', style: TextStyle(fontSize: 10, color: Colors.white)),
                    ),
                  ),
              ],
            ),
          ),
          // 左右两列布局
          Expanded(
            child: Row(
              children: [
                // 左侧：团队成员
                Expanded(
                  flex: 3,
                  child: _buildAgentsSection(),
                ),
                // 分隔线
                Container(
                  width: 1,
                  color: Colors.purple.shade100,
                ),
                // 右侧：任务面板/讨论面板
                Expanded(
                  flex: 4,
                  child: _teamMode == TeamMode.task 
                      ? _buildTasksPanel() 
                      : _buildDiscussionPanel(),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
  
  /// 构建团队模式选择器
  Widget _buildTeamModeSelector() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      decoration: BoxDecoration(
        color: Colors.purple.shade50,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: Colors.purple.shade200),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildModeButton('任务模式', TeamMode.task, Icons.assignment),
          _buildModeButton('圆桌模式', TeamMode.discussion, Icons.forum),
        ],
      ),
    );
  }
  
  Widget _buildModeButton(String label, TeamMode mode, IconData icon) {
    final isSelected = _teamMode == mode;
    return InkWell(
      onTap: () => setState(() => _teamMode = mode),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
        decoration: BoxDecoration(
          color: isSelected ? Colors.purple.shade300 : Colors.transparent,
          borderRadius: BorderRadius.circular(4),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 10, color: isSelected ? Colors.white : Colors.purple.shade400),
            const SizedBox(width: 2),
            Text(
              label,
              style: TextStyle(
                fontSize: 9,
                color: isSelected ? Colors.white : Colors.purple.shade400,
                fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 团队成员区域（紧凑版）
  Widget _buildAgentsSection() {
    final hasSupervisor = _teamAgents.any((a) => a.id == 'supervisor');
    final isReady = hasSupervisor && _teamAgents.length >= 2;
    
    return Container(
      padding: const EdgeInsets.all(8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 标题行
          Row(
            children: [
              const Text('👥 成员', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600)),
              const SizedBox(width: 6),
              // 状态指示
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                decoration: BoxDecoration(
                  color: isReady ? Colors.green.shade100 : Colors.orange.shade100,
                  borderRadius: BorderRadius.circular(3),
                ),
                child: Text(
                  isReady ? '就绪' : '未就绪',
                  style: TextStyle(
                    fontSize: 8,
                    fontWeight: FontWeight.w600,
                    color: isReady ? Colors.green.shade700 : Colors.orange.shade700,
                  ),
                ),
              ),
              const Spacer(),
              // AI生成按钮
              InkWell(
                onTap: _showAIGenerateDialog,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [Colors.purple.shade300, Colors.blue.shade300],
                    ),
                    borderRadius: BorderRadius.circular(3),
                  ),
                  child: const Text('✨AI', style: TextStyle(fontSize: 9, color: Colors.white)),
                ),
              ),
              const SizedBox(width: 3),
              // 添加主管按钮
              InkWell(
                onTap: _addSupervisor,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                  decoration: BoxDecoration(
                    color: Colors.orange.shade200,
                    borderRadius: BorderRadius.circular(3),
                  ),
                  child: const Text('+主管', style: TextStyle(fontSize: 9, color: Colors.white)),
                ),
              ),
              const SizedBox(width: 3),
              InkWell(
                onTap: _addAgent,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                  decoration: BoxDecoration(
                    color: Colors.purple.shade200,
                    borderRadius: BorderRadius.circular(3),
                  ),
                  child: const Text('+', style: TextStyle(fontSize: 9, color: Colors.white)),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          // 成员列表
          Expanded(
            child: _teamAgents.isEmpty
                ? Center(
                    child: Text(
                      '点击 ✨AI 一键生成团队',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 10, color: Colors.grey.shade500),
                    ),
                  )
                : ListView.builder(
                    itemCount: _teamAgents.length,
                    itemBuilder: (ctx, idx) => _buildAgentItem(_teamAgents[idx], idx),
                  ),
          ),
        ],
      ),
    );
  }

  /// 成员项
  Widget _buildAgentItem(TeamAgent agent, int index) {
    final status = _agentStatus[agent.id] ?? 'idle';
    final isThinking = status == 'thinking';
    
    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: isThinking ? Colors.blue.shade200 : Colors.purple.shade100,
          width: isThinking ? 1.5 : 1,
        ),
      ),
      child: Row(
        children: [
          // 头像 + 状态指示器
          Stack(
            children: [
              Container(
                width: 24,
                height: 24,
                decoration: BoxDecoration(
                  color: isThinking ? Colors.blue.shade200 : Colors.purple.shade200,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Center(
                  child: isThinking
                      ? const SizedBox(
                          width: 12,
                          height: 12,
                          child: CircularProgressIndicator(
                            strokeWidth: 1.5,
                            color: Colors.white,
                          ),
                        )
                      : Text(
                          agent.name.isNotEmpty ? agent.name[0] : 'A',
                          style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.white),
                        ),
                ),
              ),
              // 在线状态点
              Positioned(
                right: 0,
                bottom: 0,
                child: Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: isThinking ? Colors.blue : Colors.green,
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 1.5),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(agent.name, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w500)),
                    const SizedBox(width: 4),
                    if (isThinking)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                        decoration: BoxDecoration(
                          color: Colors.blue.shade50,
                          borderRadius: BorderRadius.circular(3),
                        ),
                        child: Text(
                          '思考中',
                          style: TextStyle(fontSize: 8, color: Colors.blue.shade700),
                        ),
                      ),
                  ],
                ),
                Text(agent.role, style: TextStyle(fontSize: 9, color: Colors.grey.shade600)),
              ],
            ),
          ),
          // 编辑按钮
          InkWell(
            onTap: () => _editAgent(agent, index),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Icon(Icons.edit, size: 14, color: Colors.purple.shade300),
            ),
          ),
          // 删除按钮
          InkWell(
            onTap: () {
              setState(() => _teamAgents.removeAt(index));
              _saveCurrentTeamAgents();
            },
            child: Icon(Icons.close, size: 14, color: Colors.red.shade300),
          ),
        ],
      ),
    );
  }
  
  /// 编辑角色
  void _editAgent(TeamAgent agent, int index) {
    final nameController = TextEditingController(text: agent.name);
    final roleController = TextEditingController(text: agent.role);
    final systemPromptController = TextEditingController(text: agent.systemPrompt);
    final skillManager = context.read<SkillManager>();
    final availableSkills = skillManager.enabledSkills;
    final selectedSkillIds = <String>{...agent.skillIds};
    
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Text('编辑角色'),
          content: SingleChildScrollView(
            child: SizedBox(
              width: 300,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: nameController,
                    decoration: const InputDecoration(
                      labelText: '名字',
                      hintText: '角色名字',
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: roleController,
                    decoration: const InputDecoration(
                      labelText: '角色描述',
                      hintText: '如：前端开发、UI设计师',
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: systemPromptController,
                    maxLines: 4,
                    decoration: const InputDecoration(
                      labelText: '系统提示词',
                      hintText: '描述角色的职责和专长...',
                      alignLabelWithHint: true,
                      isDense: true,
                    ),
                  ),
                  // 技能绑定区域
                  if (availableSkills.isNotEmpty) ...[
                    const Divider(height: 16),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text('绑定技能', style: TextStyle(fontSize: 11, color: Colors.grey.shade700)),
                    ),
                    const SizedBox(height: 4),
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: availableSkills.map((skill) {
                        final isSelected = selectedSkillIds.contains(skill.id);
                        return FilterChip(
                          label: Text(skill.name, style: const TextStyle(fontSize: 10)),
                          selected: isSelected,
                          onSelected: (selected) {
                            setDialogState(() {
                              if (selected) {
                                selectedSkillIds.add(skill.id);
                              } else {
                                selectedSkillIds.remove(skill.id);
                              }
                            });
                          },
                          selectedColor: Colors.purple.shade100,
                          checkmarkColor: Colors.purple,
                          labelStyle: TextStyle(
                            fontSize: 10,
                            color: isSelected ? Colors.purple.shade700 : Colors.grey.shade700,
                          ),
                        );
                      }).toList(),
                    ),
                  ],
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('取消'),
            ),
            ElevatedButton(
              onPressed: () {
                if (nameController.text.isNotEmpty) {
                  setState(() {
                    _teamAgents[index] = TeamAgent(
                      id: agent.id,
                      name: nameController.text,
                      role: roleController.text.isNotEmpty ? roleController.text : '助手',
                      systemPrompt: systemPromptController.text.isNotEmpty 
                          ? systemPromptController.text 
                          : '你是一个${roleController.text.isNotEmpty ? roleController.text : "助手"}，请完成分配给你的任务。',
                      allowedTools: agent.allowedTools,
                      skillIds: selectedSkillIds.toList(),
                      priority: agent.priority,
                    );
                  });
                  _saveCurrentTeamAgents();
                  Navigator.of(ctx).pop();
                }
              },
              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF9C27B0), foregroundColor: Colors.white),
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
  }

  /// 任务面板（右侧）
  Widget _buildTasksPanel() {
    final totalTasks = _dynamicTasks.length;
    final completedTasks = _dynamicTasks.where((t) => t.status == TaskStatus.completed).length;
    final runningTasks = _dynamicTasks.where((t) => t.status == TaskStatus.running).length;
    final pendingTasks = totalTasks - completedTasks - runningTasks;
    
    return Container(
      padding: const EdgeInsets.all(8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 标题行 + 进度
          Row(
            children: [
              const Text('📋 任务', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600)),
              const SizedBox(width: 6),
              if (totalTasks > 0)
                Expanded(
                  child: Row(
                    children: [
                      Expanded(
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(4),
                          child: LinearProgressIndicator(
                            value: totalTasks > 0 ? completedTasks / totalTasks : 0,
                            backgroundColor: Colors.grey.shade200,
                            valueColor: AlwaysStoppedAnimation<Color>(Colors.green.shade400),
                            minHeight: 4,
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        '$completedTasks/$totalTasks',
                        style: TextStyle(fontSize: 9, color: Colors.grey.shade600),
                      ),
                    ],
                  ),
                ),
            ],
          ),
          const SizedBox(height: 4),
          // 任务统计
          if (totalTasks > 0)
            Row(
              children: [
                _buildTaskStat('待执行', pendingTasks, Colors.grey),
                const SizedBox(width: 8),
                _buildTaskStat('执行中', runningTasks, Colors.blue),
                const SizedBox(width: 8),
                _buildTaskStat('已完成', completedTasks, Colors.green),
              ],
            ),
          const SizedBox(height: 4),
          // 任务列表
          Expanded(
            child: totalTasks == 0
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.assignment, size: 24, color: Colors.grey.shade400),
                        const SizedBox(height: 4),
                        Text(
                          '在对话框发送任务\n主管将自动分解',
                          textAlign: TextAlign.center,
                          style: TextStyle(fontSize: 9, color: Colors.grey.shade500),
                        ),
                        // 恢复任务按钮
                        if (_hasResumableTask) ...[
                          const SizedBox(height: 8),
                          InkWell(
                            onTap: _resumeTeamExecution,
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                              decoration: BoxDecoration(
                                color: Colors.orange.shade100,
                                borderRadius: BorderRadius.circular(4),
                                border: Border.all(color: Colors.orange.shade300),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Icons.play_circle_outline, size: 12, color: Colors.orange.shade700),
                                  const SizedBox(width: 4),
                                  Text(
                                    '恢复任务',
                                    style: TextStyle(fontSize: 9, color: Colors.orange.shade700),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            _resumableTaskDescription ?? '',
                            style: TextStyle(fontSize: 8, color: Colors.orange.shade600),
                          ),
                        ],
                      ],
                    ),
                  )
                : ListView.builder(
                    itemCount: _dynamicTasks.length,
                    itemBuilder: (ctx, idx) => _buildTaskItem(_dynamicTasks[idx], idx),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildTaskStat(String label, int count, Color color) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 6,
          height: 6,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: 3),
        Text('$label $count', style: TextStyle(fontSize: 9, color: Colors.grey.shade600)),
      ],
    );
  }
  
  /// 讨论面板（圆桌模式）
  Widget _buildDiscussionPanel() {
    final hasModerator = _teamAgents.any((a) => a.id == 'supervisor');
    final experts = _teamAgents.where((a) => a.id != 'supervisor').toList();
    final currentRound = _currentDiscussionRound;
    final maxRounds = _discussionConfig?.maxRounds ?? 2;
    
    return Container(
      padding: const EdgeInsets.all(8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 标题行 + 轮次进度
          Row(
            children: [
              const Text('💬 圆桌讨论', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600)),
              const SizedBox(width: 6),
              if (_isDiscussing) ...[
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                  decoration: BoxDecoration(
                    color: Colors.orange.shade100,
                    borderRadius: BorderRadius.circular(3),
                  ),
                  child: Text(
                    '第 $currentRound/$maxRounds 轮',
                    style: TextStyle(fontSize: 8, fontWeight: FontWeight.w600, color: Colors.orange.shade700),
                  ),
                ),
              ],
              const Spacer(),
              // 结束讨论按钮
              if (_isDiscussing)
                InkWell(
                  onTap: _endDiscussion,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                    decoration: BoxDecoration(
                      color: Colors.red.shade200,
                      borderRadius: BorderRadius.circular(3),
                    ),
                    child: const Text('结束', style: TextStyle(fontSize: 9, color: Colors.white)),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 4),
          // 主持人提示
          if (!hasModerator)
            Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: Colors.orange.shade50,
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: Colors.orange.shade200),
              ),
              child: Row(
                children: [
                  Icon(Icons.info_outline, size: 12, color: Colors.orange.shade400),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      '请先添加主持人（主管角色）',
                      style: TextStyle(fontSize: 9, color: Colors.orange.shade700),
                    ),
                  ),
                ],
              ),
            )
          else ...[
            // 专家团信息
            Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: Colors.blue.shade50,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.person, size: 10, color: Colors.blue.shade400),
                      const SizedBox(width: 3),
                      Text('主持人', style: TextStyle(fontSize: 9, fontWeight: FontWeight.w600, color: Colors.blue.shade700)),
                      const SizedBox(width: 4),
                      Text(
                        _teamAgents.firstWhere((a) => a.id == 'supervisor').name,
                        style: TextStyle(fontSize: 9, color: Colors.blue.shade600),
                      ),
                    ],
                  ),
                  if (experts.isNotEmpty) ...[
                    const SizedBox(height: 3),
                    Row(
                      children: [
                        Icon(Icons.group, size: 10, color: Colors.purple.shade400),
                        const SizedBox(width: 3),
                        Text('专家团', style: TextStyle(fontSize: 9, fontWeight: FontWeight.w600, color: Colors.purple.shade700)),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Text(
                            experts.map((e) => e.name).join('、'),
                            style: TextStyle(fontSize: 9, color: Colors.purple.shade600),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 4),
            // 讨论设置
            Row(
              children: [
                Text('轮次:', style: TextStyle(fontSize: 9, color: Colors.grey.shade600)),
                const SizedBox(width: 4),
                // 预设轮次选项
                for (int r in [1, 2, 3, 4, 5])
                  InkWell(
                    onTap: _isDiscussing ? null : () => setState(() {
                      _discussionConfig = DiscussionConfig(
                        topic: _discussionConfig?.topic ?? '',
                        maxRounds: r,
                      );
                    }),
                    child: Container(
                      margin: const EdgeInsets.only(right: 3),
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: (_discussionConfig?.maxRounds ?? 2) == r 
                            ? Colors.purple.shade300 
                            : Colors.grey.shade200,
                        borderRadius: BorderRadius.circular(3),
                      ),
                      child: Text(
                        '$r',
                        style: TextStyle(
                          fontSize: 9, 
                          color: (_discussionConfig?.maxRounds ?? 2) == r 
                              ? Colors.white 
                              : Colors.grey.shade600,
                        ),
                      ),
                    ),
                  ),
                const SizedBox(width: 4),
                // 自定义轮次输入
                InkWell(
                  onTap: _isDiscussing ? null : _showCustomRoundsDialog,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: (_discussionConfig?.maxRounds ?? 2) > 5 
                          ? Colors.purple.shade300 
                          : Colors.grey.shade200,
                      borderRadius: BorderRadius.circular(3),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.edit, size: 10, 
                          color: (_discussionConfig?.maxRounds ?? 2) > 5 
                              ? Colors.white 
                              : Colors.grey.shade600),
                        const SizedBox(width: 2),
                        Text(
                          (_discussionConfig?.maxRounds ?? 2) > 5 
                              ? '${_discussionConfig?.maxRounds}' 
                              : '自定义',
                          style: TextStyle(
                            fontSize: 9, 
                            color: (_discussionConfig?.maxRounds ?? 2) > 5 
                                ? Colors.white 
                                : Colors.grey.shade600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            // 讨论历史预览
            if (_discussionTurns.isNotEmpty)
              Expanded(
                child: Container(
                  padding: const EdgeInsets.all(4),
                  decoration: BoxDecoration(
                    color: Colors.grey.shade50,
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: Colors.grey.shade200),
                  ),
                  child: ListView.builder(
                    itemCount: _discussionTurns.length,
                    itemBuilder: (ctx, idx) {
                      final turn = _discussionTurns[idx];
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 2),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
                              decoration: BoxDecoration(
                                color: _getAgentColor(turn.agentId).withOpacity(0.1),
                                borderRadius: BorderRadius.circular(2),
                              ),
                              child: Text(
                                turn.agentName,
                                style: TextStyle(fontSize: 8, color: _getAgentColor(turn.agentId)),
                              ),
                            ),
                            const SizedBox(width: 4),
                            Expanded(
                              child: Text(
                                turn.content.length > 50 
                                    ? '${turn.content.substring(0, 50)}...'
                                    : turn.content,
                                style: TextStyle(fontSize: 8, color: Colors.grey.shade600),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              )
            else
              Expanded(
                child: Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.forum, size: 24, color: Colors.grey.shade400),
                      const SizedBox(height: 4),
                      Text(
                        '在对话框抛出观点或问题\n主持人将引导讨论',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 9, color: Colors.grey.shade500),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }

  Widget _buildTaskItem(TeamTask task, int index) {
    final agent = _teamAgents.where((a) => a.id == task.assignedTo).firstOrNull;
    final statusColor = _getTaskStatusColor(task.status);
    final statusIcon = _getTaskStatusIcon(task.status);
    
    return Container(
      margin: const EdgeInsets.only(bottom: 2),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Row(
        children: [
          // 状态图标
          Icon(statusIcon, size: 12, color: statusColor),
          const SizedBox(width: 4),
          // 任务序号
          Container(
            width: 14,
            height: 14,
            decoration: BoxDecoration(
              color: Colors.purple.shade100,
              borderRadius: BorderRadius.circular(2),
            ),
            child: Center(
              child: Text(
                '${index + 1}',
                style: TextStyle(fontSize: 8, fontWeight: FontWeight.w600, color: Colors.purple.shade700),
              ),
            ),
          ),
          const SizedBox(width: 4),
          // 任务描述
          Expanded(
            child: Text(
              task.description,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 9,
                color: task.status == TaskStatus.completed ? Colors.grey.shade500 : Colors.black87,
                decoration: task.status == TaskStatus.completed ? TextDecoration.lineThrough : null,
              ),
            ),
          ),
          // 执行者
          if (agent != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
              decoration: BoxDecoration(
                color: _getAgentColor(agent.id).withOpacity(0.1),
                borderRadius: BorderRadius.circular(3),
              ),
              child: Text(
                agent.name,
                style: TextStyle(fontSize: 8, color: _getAgentColor(agent.id)),
              ),
            ),
        ],
      ),
    );
  }

  Color _getTaskStatusColor(TaskStatus status) {
    switch (status) {
      case TaskStatus.pending:
      case TaskStatus.waiting:
        return Colors.grey;
      case TaskStatus.ready:
        return Colors.orange;
      case TaskStatus.running:
        return Colors.blue;
      case TaskStatus.completed:
        return Colors.green;
      case TaskStatus.failed:
        return Colors.red;
    }
  }

  IconData _getTaskStatusIcon(TaskStatus status) {
    switch (status) {
      case TaskStatus.pending:
      case TaskStatus.waiting:
        return Icons.circle_outlined;
      case TaskStatus.ready:
        return Icons.schedule;
      case TaskStatus.running:
        return Icons.sync;
      case TaskStatus.completed:
        return Icons.check_circle;
      case TaskStatus.failed:
        return Icons.error;
    }
  }

  /// 获取 Agent 颜色
  Color _getAgentColor(String agentId) {
    final colors = [
      const Color(0xFF9C27B0),
      const Color(0xFF2196F3),
      const Color(0xFF4CAF50),
      const Color(0xFFFF9800),
      const Color(0xFFE91E63),
      const Color(0xFF00BCD4),
    ];
    final index = _teamAgents.indexWhere((a) => a.id == agentId);
    return colors[index % colors.length];
  }

  /// 获取 Agent 名称
  String _getAgentName(String agentId) {
    final agent = _teamAgents.where((a) => a.id == agentId).firstOrNull;
    return agent?.name ?? agentId;
  }

  /// 获取消息类型颜色
  Color _getMessageTypeColor(TeamMessageType type) {
    switch (type) {
      case TeamMessageType.broadcast:
        return Colors.orange;
      case TeamMessageType.direct:
        return Colors.blue;
      case TeamMessageType.taskResult:
        return Colors.green;
      case TeamMessageType.statusUpdate:
        return Colors.grey;
      case TeamMessageType.discussion:
        return Colors.purple;
      case TeamMessageType.discussionSummary:
        return Colors.teal;
    }
  }

  /// 获取消息类型标签
  String _getMessageTypeLabel(TeamMessageType type) {
    switch (type) {
      case TeamMessageType.broadcast:
        return '广播';
      case TeamMessageType.direct:
        return '私信';
      case TeamMessageType.taskResult:
        return '结果';
      case TeamMessageType.statusUpdate:
        return '状态';
      case TeamMessageType.discussion:
        return '发言';
      case TeamMessageType.discussionSummary:
        return '总结';
    }
  }

  /// 添加主管角色（默认的任务拆解和分配者）
  void _addSupervisor() {
    // 检查是否已有主管
    if (_teamAgents.any((a) => a.id == 'supervisor')) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('团队已存在主管鹅'), duration: Duration(seconds: 1)),
      );
      return;
    }
    
    setState(() {
      _teamAgents.insert(0, TeamAgent(
        id: 'supervisor',
        name: '主管鹅',
        role: '团队协调者',
        systemPrompt: '你是团队主管，负责：\n'
            '1. 分析用户需求，拆解为可执行的子任务\n'
            '2. 根据团队成员能力，合理分配任务\n'
            '3. 监控任务进度，协调成员协作\n'
            '4. 汇总结果，给用户清晰反馈\n\n'
            '输出格式：简洁、结构化，使用 @成员名 指定任务接收者。',
        priority: 1, // 最高优先级
      ));
    });
    _saveCurrentTeamAgents();
  }

  /// 添加成员
  void _addAgent() {
    final nameController = TextEditingController();
    final roleController = TextEditingController();
    final systemPromptController = TextEditingController();
    bool showSystemPrompt = false;
    bool isGenerating = false;
    String? generateError;
    
    // 技能选择状态
    final Set<String> selectedSkillIds = {};
    
    // 获取 LLMManager 和 SkillManager
    final llmManager = context.read<LLMManager>();
    final skillManager = context.read<SkillManager>();
    final availableSkills = skillManager.enabledSkills;
    
    // 预设角色模板
    final presetTemplates = [
      {'name': '代码审查员', 'role': '代码审查专家', 'prompt': '你是一个资深代码审查专家。专注于：安全漏洞、性能问题、代码规范、可维护性。输出格式：问题列表 + 修复建议，按严重程度排序。'},
      {'name': '文档撰写者', 'role': '技术文档撰写专家', 'prompt': '你是技术文档撰写专家。风格：简洁、结构化、面向开发者。输出：Markdown 格式，包含代码示例和清晰的使用说明。'},
      {'name': '测试工程师', 'role': '测试开发工程师', 'prompt': '你是测试开发工程师。专注于：边界条件、异常处理、集成测试。输出：测试用例列表，包含输入、预期输出、测试类型。'},
      {'name': '架构分析师', 'role': '软件架构师', 'prompt': '你是软件架构师。分析：系统设计、模块划分、技术选型、扩展性。输出：架构图描述 + 关键决策说明 + 风险评估。'},
    ];
    
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Row(
            children: [
              const Text('添加团队成员', style: TextStyle(fontSize: 14)),
              const Spacer(),
              // 预设模板下拉
              PopupMenuButton<String>(
                tooltip: '选择预设模板',
                icon: const Icon(Icons.auto_awesome, size: 18),
                onSelected: (value) {
                  final template = presetTemplates[int.parse(value)];
                  nameController.text = template['name']!;
                  roleController.text = template['role']!;
                  systemPromptController.text = template['prompt']!;
                  setDialogState(() => showSystemPrompt = true);
                },
                itemBuilder: (context) => presetTemplates.asMap().entries.map((e) =>
                  PopupMenuItem(
                    value: e.key.toString(),
                    child: Text(e.value['name']!, style: const TextStyle(fontSize: 12)),
                  ),
                ).toList(),
              ),
            ],
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: nameController,
                  decoration: const InputDecoration(
                    labelText: '名称',
                    hintText: '如: 审查员',
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: roleController,
                  decoration: const InputDecoration(
                    labelText: '角色描述',
                    hintText: '如: 代码审查专家',
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 8),
                // 技能选择区域
                if (availableSkills.isNotEmpty) ...[
                  const Divider(height: 16),
                  Text('绑定技能', style: TextStyle(fontSize: 11, color: Colors.grey.shade700)),
                  const SizedBox(height: 4),
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: availableSkills.map((skill) {
                      final isSelected = selectedSkillIds.contains(skill.id);
                      return FilterChip(
                        label: Text(skill.name, style: const TextStyle(fontSize: 10)),
                        selected: isSelected,
                        onSelected: (selected) {
                          setDialogState(() {
                            if (selected) {
                              selectedSkillIds.add(skill.id);
                            } else {
                              selectedSkillIds.remove(skill.id);
                            }
                          });
                        },
                        selectedColor: Colors.purple.shade100,
                        checkmarkColor: Colors.purple,
                        labelStyle: TextStyle(
                          fontSize: 10,
                          color: isSelected ? Colors.purple.shade700 : Colors.grey.shade700,
                        ),
                      );
                    }).toList(),
                  ),
                ],
                const SizedBox(height: 8),
                // 展开/折叠 systemPrompt
                InkWell(
                  onTap: () => setDialogState(() => showSystemPrompt = !showSystemPrompt),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      children: [
                        Icon(
                          showSystemPrompt ? Icons.expand_less : Icons.expand_more,
                          size: 18,
                          color: Colors.purple,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          '系统提示词 (System Prompt)',
                          style: TextStyle(fontSize: 11, color: Colors.purple.shade700),
                        ),
                        const Spacer(),
                        // AI 生成按钮
                        if (roleController.text.isNotEmpty)
                          InkWell(
                            onTap: isGenerating ? null : () async {
                              setDialogState(() {
                                isGenerating = true;
                                generateError = null;
                              });
                              
                              try {
                                // 调用 LLMManager 生成系统提示词
                                final role = roleController.text;
                                final generatePrompt = '''请为以下角色生成一段专业的系统提示词(System Prompt)。

角色: $role

要求:
1. 明确定义角色的职责范围和专业领域
2. 说明该角色应该关注的重点事项
3. 指定输出格式和风格要求
4. 保持简洁但专业，不超过200字

请直接输出系统提示词内容，不需要其他解释。''';

                                final response = await llmManager.chatRaw([
                                  {'role': 'user', 'content': generatePrompt}
                                ]);
                                
                                systemPromptController.text = response.trim();
                                setDialogState(() {
                                  isGenerating = false;
                                  showSystemPrompt = true;
                                });
                              } catch (e) {
                                setDialogState(() {
                                  isGenerating = false;
                                  generateError = '生成失败: $e';
                                });
                              }
                            },
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: Colors.purple.shade100,
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  if (isGenerating)
                                    const SizedBox(
                                      width: 10,
                                      height: 10,
                                      child: CircularProgressIndicator(strokeWidth: 1.5),
                                    )
                                  else
                                    const Icon(Icons.auto_awesome, size: 12, color: Colors.purple),
                                  const SizedBox(width: 2),
                                  Text(
                                    isGenerating ? '生成中...' : 'AI生成',
                                    style: const TextStyle(fontSize: 10, color: Colors.purple),
                                  ),
                                ],
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                // 错误提示
                if (generateError != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      generateError!,
                      style: const TextStyle(fontSize: 10, color: Colors.red),
                    ),
                  ),
                // 折叠的 systemPrompt 输入区
                if (showSystemPrompt)
                  Container(
                    margin: const EdgeInsets.only(top: 4),
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Colors.purple.shade50,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.purple.shade200),
                    ),
                    child: TextField(
                      controller: systemPromptController,
                      maxLines: 4,
                      decoration: const InputDecoration(
                        hintText: '输入系统提示词，或使用 AI 生成...',
                        border: InputBorder.none,
                        isDense: true,
                        contentPadding: EdgeInsets.zero,
                      ),
                      style: const TextStyle(fontSize: 11),
                    ),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('取消'),
            ),
            ElevatedButton(
              onPressed: () {
                if (nameController.text.isNotEmpty) {
                  final prompt = systemPromptController.text.isNotEmpty
                      ? systemPromptController.text
                      : '你是一个${roleController.text.isNotEmpty ? roleController.text : '助手'}，请完成分配给你的任务。';
                  setState(() {
                    _teamAgents.add(TeamAgent(
                      id: 'agent_${DateTime.now().millisecondsSinceEpoch}',
                      name: nameController.text,
                      role: roleController.text.isNotEmpty ? roleController.text : '助手',
                      systemPrompt: prompt,
                      skillIds: selectedSkillIds.toList(),
                    ));
                  });
                  _saveCurrentTeamAgents();
                  Navigator.of(ctx).pop();
                }
              },
              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF9C27B0), foregroundColor: Colors.white),
              child: const Text('添加'),
            ),
          ],
        ),
      ),
    );
  }

  /// 保存当前团队配置
  void _saveCurrentTeam() async {
    final nameController = TextEditingController();
    
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('保存团队配置'),
        content: TextField(
          controller: nameController,
          decoration: const InputDecoration(
            labelText: '团队名称',
            hintText: '例如：游戏开发团队',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    
    if (confirmed != true || nameController.text.isEmpty) return;
    
    // 获取已保存的团队列表
    final savedTeams = StorageManager.getSetting<List<dynamic>>('saved_teams', defaultValue: []) ?? [];
    
    // 创建团队配置
    final teamConfig = {
      'name': nameController.text,
      'createdAt': DateTime.now().toIso8601String(),
      'agents': _teamAgents.map((a) => a.toJson()).toList(),
    };
    
    savedTeams.add(teamConfig);
    await StorageManager.setSetting('saved_teams', savedTeams);
    
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('团队"${nameController.text}"已保存'), duration: const Duration(seconds: 2)),
      );
    }
  }

  /// 显示已保存的团队列表
  void _showSavedTeams() async {
    final savedTeams = StorageManager.getSetting<List<dynamic>>('saved_teams', defaultValue: []) ?? [];
    
    if (savedTeams.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('暂无已保存的团队配置'), duration: Duration(seconds: 2)),
      );
      return;
    }
    
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('选择团队配置'),
        content: SizedBox(
          width: 300,
          height: 300,
          child: ListView.builder(
            itemCount: savedTeams.length,
            itemBuilder: (context, index) {
              final team = safeMap(savedTeams[index]);
              final name = team['name'] as String;
              final createdAt = DateTime.tryParse(team['createdAt'] as String? ?? '');
              final agentsCount = (team['agents'] as List?)?.length ?? 0;
              
              return ListTile(
                leading: const Icon(Icons.group, color: Color(0xFF9C27B0)),
                title: Text(name),
                subtitle: Text(
                  '${agentsCount} 名成员 · ${createdAt != null ? '${createdAt.month}/${createdAt.day}' : ''}',
                  style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // 删除按钮
                    IconButton(
                      icon: Icon(Icons.delete, size: 18, color: Colors.red.shade300),
                      onPressed: () async {
                        savedTeams.removeAt(index);
                        await StorageManager.setSetting('saved_teams', savedTeams);
                        if (mounted) {
                          Navigator.of(ctx).pop();
                          _showSavedTeams(); // 刷新列表
                        }
                      },
                    ),
                  ],
                ),
                onTap: () {
                  _loadTeamFromConfig(team);
                  Navigator.of(ctx).pop();
                },
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  /// 从配置加载团队
  void _loadTeamFromConfig(Map<String, dynamic> config) {
    final agentsList = (config['agents'] as List?)?.cast<Map<String, dynamic>>() ?? [];
    
    setState(() {
      _teamAgents.clear();
      _teamAgents.addAll(agentsList.map((json) => TeamAgent.fromJson(json)));
    });
    _saveCurrentTeamAgents();
    
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已加载团队: ${config['name']}'), duration: const Duration(seconds: 2)),
    );
  }

  /// 显示 AI 生成团队对话框
  void _showAIGenerateDialog() {
    final projectController = TextEditingController();
    bool isGenerating = false;
    
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(4),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [Colors.purple.shade300, Colors.blue.shade300],
                  ),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: const Text('✨', style: TextStyle(fontSize: 14)),
              ),
              const SizedBox(width: 8),
              const Text('AI 生成团队'),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '描述你的项目，AI 将自动生成合适的团队配置',
                style: TextStyle(fontSize: 12, color: Colors.grey),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: projectController,
                maxLines: 3,
                autofocus: true,
                decoration: const InputDecoration(
                  hintText: '例如：开发一个AI宠物养成游戏，包含战斗、养成、社交功能',
                  hintStyle: TextStyle(fontSize: 11),
                  border: OutlineInputBorder(),
                  contentPadding: EdgeInsets.all(10),
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  _buildQuickTag('AI宠物游戏', projectController),
                  _buildQuickTag('电商平台', projectController),
                  _buildQuickTag('数据分析系统', projectController),
                  _buildQuickTag('社交应用', projectController),
                  _buildQuickTag('内容管理系统', projectController),
                ],
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: isGenerating ? null : () => Navigator.of(ctx).pop(),
              child: const Text('取消'),
            ),
            ElevatedButton(
              onPressed: isGenerating
                  ? null
                  : () async {
                      if (projectController.text.trim().isEmpty) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('请输入项目描述'), duration: Duration(seconds: 1)),
                        );
                        return;
                      }
                      
                      setDialogState(() => isGenerating = true);
                      
                      try {
                        await _generateTeamWithAI(projectController.text.trim());
                        if (mounted) Navigator.of(ctx).pop();
                      } catch (e) {
                        setDialogState(() => isGenerating = false);
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text('生成失败: $e'), duration: const Duration(seconds: 2)),
                          );
                        }
                      }
                    },
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.purple.shade400,
                foregroundColor: Colors.white,
              ),
              child: isGenerating
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                    )
                  : const Text('生成团队'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildQuickTag(String text, TextEditingController controller) {
    return InkWell(
      onTap: () => controller.text = text,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: Colors.purple.shade50,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.purple.shade200),
        ),
        child: Text(text, style: TextStyle(fontSize: 10, color: Colors.purple.shade700)),
      ),
    );
  }

  /// AI 生成团队配置
  Future<void> _generateTeamWithAI(String projectDescription) async {
    final skillManager = context.read<SkillManager>();
    final availableSkills = skillManager.enabledSkills;
    
    // 构建技能列表描述
    final skillsDesc = availableSkills.map((s) => 
      '- ${s.id}: ${s.name} - ${s.description}'
    ).join('\n');
    
    // 根据模式生成不同的 prompt
    String prompt;
    if (_teamMode == TeamMode.discussion) {
      // 圆桌模式：生成不同角度的专家
      prompt = '''你是一个圆桌讨论专家团配置师。根据以下讨论主题，生成一个多元化的专家团。

讨论主题：
$projectDescription

可用技能列表：
$skillsDesc

请以 JSON 数组格式输出专家团配置，每个成员包含：
- name: 专家名称（简洁，2-4个字）
- role: 专家领域（如：产品专家、技术专家、用户研究员、商业分析师、风险控制专家等）
- systemPrompt: 该专家的思维方式、关注点、立场倾向
- skillIds: 该角色适合绑定的技能ID数组（可选）
- perspective: 该专家的独特视角描述（一句话）

要求：
1. 第一个成员必须是"主持人"（id: supervisor），负责引导讨论、总结观点
2. 生成 3-5 位不同领域的专家，确保：
   - 专家之间有观点互补或对立，确保讨论有碰撞
   - 每个专家都有独特的视角和关注点
   - 覆盖讨论主题的多个维度（如：技术、产品、用户、商业、风险等）
3. systemPrompt 要体现专家的：
   - 专业背景和思维方式
   - 关注的核心问题
   - 可能的立场倾向
4. perspective 要突出该专家与其他专家的区别

示例输出：
[
  {"name": "主持人", "role": "讨论主持人", "systemPrompt": "你是圆桌讨论的主持人，负责引导讨论方向、平衡发言时间、总结各方观点、推进共识形成。你中立客观，善于发现不同观点的关联和价值。", "skillIds": [], "perspective": "统筹全局，促进共识"},
  {"name": "产品专家", "role": "产品视角", "systemPrompt": "你是产品专家，关注用户体验、产品价值、市场定位。你倾向于从用户需求出发思考，重视产品的可用性和竞争力。", "skillIds": [], "perspective": "用户至上，体验优先"},
  {"name": "技术专家", "role": "技术视角", "systemPrompt": "你是技术专家，关注技术可行性、实现成本、架构设计。你倾向于从技术实现角度思考，重视方案的稳健性和可维护性。", "skillIds": [], "perspective": "技术稳健，成本可控"}
]

只输出 JSON 数组，不要其他内容。''';
    } else {
      // 任务模式：生成任务执行团队
      prompt = '''你是一个团队配置专家。根据以下项目描述，生成一个合适的团队配置。

项目描述：
$projectDescription

可用技能列表：
$skillsDesc

请以 JSON 数组格式输出团队成员配置，每个成员包含：
- name: 成员名称（简洁，2-4个字）
- role: 角色定位（如：架构师、前端开发、UI设计师、测试工程师等）
- systemPrompt: 该成员的系统提示词（描述其职责和专长）
- skillIds: 该角色适合绑定的技能ID数组（从上面的可用技能列表中选择，根据角色职责匹配）

要求：
1. 第一个成员必须是"主管"（id: supervisor），负责协调团队和任务分配
2. 根据项目需求选择合适的角色，通常 3-6 人
3. 确保覆盖项目所需的核心能力
4. systemPrompt 要具体、专业
5. skillIds 要根据角色职责合理选择，不是每个角色都需要技能

示例输出：
[
  {"name": "主管", "role": "团队协调者", "systemPrompt": "你是团队主管，负责分解任务、协调成员、汇总成果、把控质量。", "skillIds": []},
  {"name": "架构师", "role": "系统架构", "systemPrompt": "你是架构师，负责技术选型、架构设计、接口定义、技术难点攻关。", "skillIds": ["think"]}
]

只输出 JSON 数组，不要其他内容。''';
    }

    final llmManager = context.read<LLMManager>();
    final response = await llmManager.chatRaw([
      {'role': 'user', 'content': prompt}
    ]);
    
    // 解析 JSON
    final content = response.trim();
    final jsonMatch = RegExp(r'\[[\s\S]*\]').firstMatch(content);
    if (jsonMatch == null) {
      throw Exception('无法解析团队配置');
    }
    
    final agentsJson = jsonDecode(jsonMatch.group(0)!) as List;
    
    // 默认绑定的文件操作技能（任务模式下使用）
    const defaultSkillIds = ['write_file', 'read_file'];
    
    setState(() {
      _teamAgents.clear();
      for (int i = 0; i < agentsJson.length; i++) {
        final agentData = safeMap(agentsJson[i]);
        // 名字鹅化：给每个名字后面加"鹅"
        final originalName = agentData['name'] as String;
        final gooseName = originalName.endsWith('鹅') ? originalName : '$originalName鹅';
        
        // 解析 skillIds，过滤无效的 ID
        final rawSkillIds = (agentData['skillIds'] as List<dynamic>?)?.cast<String>() ?? [];
        final validSkillIds = rawSkillIds.where((id) => 
          availableSkills.any((s) => s.id == id)
        ).toList();
        
        // 任务模式才绑定默认技能，圆桌模式不需要
        final allSkillIds = _teamMode == TeamMode.task 
            ? <String>{...defaultSkillIds, ...validSkillIds}.toList()
            : validSkillIds;
        
        _teamAgents.add(TeamAgent(
          id: i == 0 ? 'supervisor' : 'agent_${DateTime.now().millisecondsSinceEpoch}_$i',
          name: gooseName,
          role: agentData['role'] as String,
          systemPrompt: agentData['systemPrompt'] as String,
          skillIds: allSkillIds,
        ));
      }
    });
    _saveCurrentTeamAgents();
    
    final modeText = _teamMode == TeamMode.discussion ? '专家团，可开始圆桌讨论' : '团队，可在对话框发送任务';
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('已生成 ${_teamAgents.length} 人$modeText'),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  /// 解析文本中的 @ 提及
  List<TeamAgent> _parseMentions(String text) {
    final mentions = <TeamAgent>[];
    final regex = RegExp(r'@(\S+)');
    final matches = regex.allMatches(text);
    
    for (final match in matches) {
      final mentionedName = match.group(1);
      if (mentionedName != null) {
        // 查找匹配的团队成员（支持部分匹配）
        final agent = _teamAgents.where((a) => 
          a.name == mentionedName || 
          a.name.contains(mentionedName) ||
          mentionedName.contains(a.name)
        ).firstOrNull;
        
        if (agent != null && !mentions.any((a) => a.id == agent.id)) {
          mentions.add(agent);
        }
      }
    }
    
    return mentions;
  }

  /// 处理 @ 提及的回复
  Future<void> _handleMentionedReply(String text, List<TeamAgent> mentionedAgents) async {
    if (mentionedAgents.isEmpty) return;
    
    // 初始化取消令牌
    _teamCancellationToken = CancellationToken();
    
    setState(() {
      _isLoading = true;
      _isTeamExecuting = true;
    });
    
    try {
      final llmManager = context.read<LLMManager>();
      final skillManager = context.read<SkillManager>();
      
      // 构建上下文：最近的消息历史
      final recentMessages = _messages.length > 10 
          ? _messages.sublist(_messages.length - 10) 
          : _messages;
      
      final contextBuffer = StringBuffer();
      contextBuffer.writeln('【会话上下文】');
      for (final msg in recentMessages) {
        if (msg.isUser) {
          contextBuffer.writeln('用户: ${msg.content}');
        } else if (msg.teamMessage != null) {
          contextBuffer.writeln('${msg.teamMessage!.fromAgentName}: ${msg.content}');
        } else {
          contextBuffer.writeln('助手: ${msg.content}');
        }
      }
      contextBuffer.writeln();
      
      // 并行执行：所有被 @ 的角色同时思考
      final results = await Future.wait(
        mentionedAgents.map((agent) async {
          // 检查是否被取消
          if (_teamCancellationToken?.isCancelled ?? false) {
            return (agent: agent, response: null, error: '已取消');
          }
          
          // 构建技能信息
          final skillBuffer = StringBuffer();
          if (agent.skillIds.isNotEmpty) {
            skillBuffer.writeln('【可用技能】');
            for (final skillId in agent.skillIds) {
              final skill = skillManager.getSkill(skillId);
              if (skill != null) {
                skillBuffer.writeln('- ${skill.name}: ${skill.description}');
              }
            }
            skillBuffer.writeln();
          }

          final prompt = '''${agent.systemPrompt}

$contextBuffer
$skillBuffer
用户向你提问：$text

请以"${agent.name}"的身份，基于你的专业领域（${agent.role}）和上述上下文，回答用户的问题。
回答要专业、具体，体现你的角色特点。''';

          // 设置角色状态为思考中
          if (mounted) setState(() => _agentStatus[agent.id] = 'thinking');
          
          try {
            final response = await llmManager.chatRaw([
              {'role': 'system', 'content': agent.systemPrompt},
              {'role': 'user', 'content': prompt},
            ]);
            return (agent: agent, response: response, error: null);
          } catch (e) {
            return (agent: agent, response: null, error: e.toString());
          } finally {
            // 设置角色状态为空闲
            if (mounted) setState(() => _agentStatus[agent.id] = 'idle');
          }
        }),
      );
      
      // 发送所有角色的回复（按原始顺序）
      for (final result in results) {
        if (result.response != null) {
          _sendTeamMessage(
            fromAgentId: result.agent.id,
            fromAgentName: result.agent.name,
            type: TeamMessageType.direct,
            content: result.response!,
          );
        } else {
          _sendTeamMessage(
            fromAgentId: result.agent.id,
            fromAgentName: result.agent.name,
            type: TeamMessageType.direct,
            content: '抱歉，思考过程中出现错误：${result.error}',
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('回复失败: $e'), duration: const Duration(seconds: 2)),
        );
      }
    } finally {
      if (mounted) setState(() {
        _isLoading = false;
        _isTeamExecuting = false;
        _teamCancellationToken = null;
      });
    }
  }

  /// 启动团队执行（主管自动分解任务）
  Future<void> _startTeamExecution(String userTask) async {
    // 清空之前的消息和任务
    _teamMessageBoard.clear();
    _dynamicTasks.clear();
    _taskOutputFiles.clear();
    
    // 初始化执行状态跟踪
    _currentTeamTask = userTask;
    _currentStageIndex = 0;
    _completedTaskIds.clear();
    _taskOutputs.clear();
    
    // 初始化取消令牌
    _teamCancellationToken = CancellationToken();
    
    // 初始化本次任务的输出目录（Web 平台不支持）
    if (!kIsWeb) {
      final timestamp = DateTime.now().toIso8601String().replaceAll(':', '-').replaceAll('.', '-').substring(0, 19);
      final workDir = Directory.current;
      _currentOutputDir = '${workDir.path}/goosebaby_outputs/$timestamp';
    }
    
    // 设置执行状态
    setState(() {
      _isTeamExecuting = true;
      _isLoading = true;
    });
    
    // 检查是否有主管
    final supervisor = _teamAgents.where((a) => a.id == 'supervisor').firstOrNull;
    
    if (supervisor == null) {
      // 没有主管，提示用户（发送消息到对话框更明显）
      _sendTeamMessage(
        fromAgentId: 'system',
        fromAgentName: '系统',
        type: TeamMessageType.broadcast,
        content: '⚠️ 请先添加主管角色！点击左侧面板的"+主管"按钮添加主管，或点击"✨AI"一键生成团队。',
      );
      setState(() {
        _isTeamExecuting = false;
        _isLoading = false;
      });
      return;
    }
    
    // 发送启动广播
    _sendTeamMessage(
      fromAgentId: 'system',
      fromAgentName: '系统',
      type: TeamMessageType.broadcast,
      content: '收到任务：$userTask\n主管正在分析并分解任务...',
    );
    
    try {
      // 让主管分解任务
      await _supervisorBreakdownTask(supervisor, userTask);
    } finally {
      // 确保状态被清理
      if (mounted) setState(() {
        _isTeamExecuting = false;
        _isLoading = false;
        _teamCancellationToken = null;
      });
    }
  }
  
  /// 恢复被中断的团队任务
  Future<void> _resumeTeamExecution() async {
    final state = _loadTeamExecutionState();
    if (state == null) {
      _sendTeamMessage(
        fromAgentId: 'system',
        fromAgentName: '系统',
        type: TeamMessageType.broadcast,
        content: '⚠️ 没有可恢复的任务',
      );
      return;
    }
    
    // 恢复任务状态
    final userTask = state['userTask'] as String;
    final savedStageIndex = state['currentStageIndex'] as int;
    final savedCompletedIds = (state['completedTaskIds'] as List?)?.cast<String>() ?? <String>[];
    final savedTaskOutputs = Map<String, String>.from(state['taskOutputs'] as Map? ?? {});
    final savedTasks = (state['tasks'] as List?)?.map((t) => TeamTask.fromJson(Map<String, dynamic>.from(t))).toList() ?? <TeamTask>[];
    final savedMessages = (state['messages'] as List?)?.map((m) => TeamMessage.fromJson(Map<String, dynamic>.from(m))).toList() ?? <TeamMessage>[];
    
    // 恢复状态
    _currentTeamTask = userTask;
    _currentStageIndex = savedStageIndex;
    _completedTaskIds.clear();
    _completedTaskIds.addAll(savedCompletedIds);
    _taskOutputs.clear();
    _taskOutputs.addAll(savedTaskOutputs);
    _dynamicTasks.clear();
    _dynamicTasks.addAll(savedTasks);
    _teamMessageBoard.clear();
    for (final msg in savedMessages) {
      _teamMessageBoard.add(msg);
    }
    _currentOutputDir = state['outputDir'] as String?;
    
    // 检查主管
    final supervisor = _teamAgents.where((a) => a.id == 'supervisor').firstOrNull;
    if (supervisor == null) {
      _sendTeamMessage(
        fromAgentId: 'system',
        fromAgentName: '系统',
        type: TeamMessageType.broadcast,
        content: '⚠️ 无法恢复：缺少主管角色',
      );
      return;
    }
    
    // 初始化取消令牌
    _teamCancellationToken = CancellationToken();
    
    setState(() {
      _isTeamExecuting = true;
      _isLoading = true;
    });
    
    _sendTeamMessage(
      fromAgentId: 'system',
      fromAgentName: '系统',
      type: TeamMessageType.broadcast,
      content: '🔄 恢复任务执行\n任务：$userTask\n已完成：${savedCompletedIds.length}/${savedTasks.length}',
    );
    
    try {
      // 继续执行工作流
      await _resumeSupervisorDrivenWorkflow(supervisor, userTask, savedStageIndex);
      
      // 成功完成后清除保存的状态
      await _clearTeamExecutionState();
    } finally {
      if (mounted) setState(() {
        _isTeamExecuting = false;
        _isLoading = false;
        _teamCancellationToken = null;
      });
    }
  }
  
  /// 恢复执行主管驱动的工作流
  Future<void> _resumeSupervisorDrivenWorkflow(
    TeamAgent supervisor,
    String userTask,
    int startStageIndex,
  ) async {
    // 按阶段分组任务
    final stages = _groupTasksByStages(_dynamicTasks);
    
    _sendTeamMessage(
      fromAgentId: 'system',
      fromAgentName: '系统',
      type: TeamMessageType.broadcast,
      content: '任务恢复，继续执行第 ${startStageIndex + 1}/${stages.length} 阶段',
    );
    
    // 从中断的阶段继续执行
    for (int stageIndex = startStageIndex; stageIndex < stages.length; stageIndex++) {
      // 检查是否被取消
      if (_teamCancellationToken?.isCancelled ?? false) {
        // 保存状态
        await _saveTeamExecutionState(
          userTask: userTask,
          currentStageIndex: stageIndex,
          completedTaskIds: _completedTaskIds.toList(),
          taskOutputs: _taskOutputs,
        );
        return;
      }
      
      _currentStageIndex = stageIndex;
      final stageTasks = stages[stageIndex];
      
      // 过滤掉已完成的任务
      final pendingTasks = stageTasks.where((t) => !_completedTaskIds.contains(t.id)).toList();
      if (pendingTasks.isEmpty) {
        debugPrint('🔄 阶段 ${stageIndex + 1} 所有任务已完成，跳过');
        continue;
      }
      
      // 主管广播当前阶段任务
      final taskNames = pendingTasks.map((t) {
        final agent = _teamAgents.where((a) => a.id == t.assignedTo).firstOrNull;
        return '${agent?.name ?? "待分配"}: ${t.description}';
      }).join('\n  ');
      
      _sendTeamMessage(
        fromAgentId: supervisor.id,
        fromAgentName: supervisor.name,
        type: TeamMessageType.broadcast,
        content: '📋 **阶段 ${stageIndex + 1}/${stages.length}**\n当前阶段任务：\n  $taskNames',
      );
      
      // 并行执行当前阶段的所有任务
      final results = await _executeStageTasks(pendingTasks, _taskOutputs);
      
      // 收集结果
      for (final entry in results.entries) {
        _taskOutputs[entry.key] = entry.value;
        _completedTaskIds.add(entry.key);
      }
      
      // 保存进度
      await _saveTeamExecutionState(
        userTask: userTask,
        currentStageIndex: stageIndex + 1,
        completedTaskIds: _completedTaskIds.toList(),
        taskOutputs: _taskOutputs,
      );
      
      // 主管汇总当前阶段结果（除了最后一个阶段）
      if (stageIndex < stages.length - 1) {
        await _supervisorSummarizeStage(supervisor, stageIndex, pendingTasks, results);
      }
    }
    
    // 主管输出最终总结
    await _supervisorFinalSummary(supervisor, userTask, _taskOutputs);
  }
  
  /// 执行主管驱动的团队协作（分阶段执行，每个阶段主管介入）
  Future<void> _executeSupervisorDrivenWorkflow(
    TeamAgent supervisor, 
    String userTask,
  ) async {
    // 按阶段分组任务
    final stages = _groupTasksByStages(_dynamicTasks);
    
    _sendTeamMessage(
      fromAgentId: 'system',
      fromAgentName: '系统',
      type: TeamMessageType.broadcast,
      content: '任务分解完成，共 ${stages.length} 个阶段，${_dynamicTasks.length} 个子任务',
    );
    
    // 逐阶段执行
    for (int stageIndex = 0; stageIndex < stages.length; stageIndex++) {
      // 检查是否被取消
      if (_teamCancellationToken?.isCancelled ?? false) {
        // 保存状态以便恢复
        await _saveTeamExecutionState(
          userTask: userTask,
          currentStageIndex: stageIndex,
          completedTaskIds: _completedTaskIds.toList(),
          taskOutputs: _taskOutputs,
        );
        return;
      }
      
      _currentStageIndex = stageIndex;
      final stageTasks = stages[stageIndex];
      
      // 主管广播当前阶段任务
      final taskNames = stageTasks.map((t) {
        final agent = _teamAgents.where((a) => a.id == t.assignedTo).firstOrNull;
        return '${agent?.name ?? "待分配"}: ${t.description}';
      }).join('\n  ');
      
      _sendTeamMessage(
        fromAgentId: supervisor.id,
        fromAgentName: supervisor.name,
        type: TeamMessageType.broadcast,
        content: '📋 **阶段 ${stageIndex + 1}/${stages.length}**\n当前阶段任务：\n  $taskNames',
      );
      
      // 并行执行当前阶段的所有任务
      final results = await _executeStageTasks(stageTasks, _taskOutputs);
      
      // 收集结果
      for (final entry in results.entries) {
        _taskOutputs[entry.key] = entry.value;
        _completedTaskIds.add(entry.key);
      }
      
      // 保存进度
      await _saveTeamExecutionState(
        userTask: userTask,
        currentStageIndex: stageIndex + 1,
        completedTaskIds: _completedTaskIds.toList(),
        taskOutputs: _taskOutputs,
      );
      
      // 主管汇总当前阶段结果（除了最后一个阶段）
      if (stageIndex < stages.length - 1) {
        await _supervisorSummarizeStage(supervisor, stageIndex, stageTasks, results);
      }
    }
    
    // 主管输出最终总结
    await _supervisorFinalSummary(supervisor, userTask, _taskOutputs);
    
    // 成功完成后清除保存的状态
    await _clearTeamExecutionState();
  }
  
  /// 按阶段分组任务（基于依赖关系）
  List<List<TeamTask>> _groupTasksByStages(List<TeamTask> tasks) {
    final stages = <List<TeamTask>>[];
    final assigned = <String>{};
    
    while (assigned.length < tasks.length) {
      // 找出当前可执行的任务（所有依赖都已完成）
      final readyTasks = tasks.where((task) =>
        !assigned.contains(task.id) &&
        task.dependencies.every((dep) => assigned.contains(dep))
      ).toList();
      
      if (readyTasks.isEmpty) {
        // 存在循环依赖或无法解决的任务
        break;
      }
      
      stages.add(readyTasks);
      for (final task in readyTasks) {
        assigned.add(task.id);
      }
    }
    
    return stages;
  }
  
  /// 执行一个阶段的所有任务（并行）
  Future<Map<String, String>> _executeStageTasks(
    List<TeamTask> tasks,
    Map<String, String> previousOutputs,
  ) async {
    // 检查是否被取消
    if (_teamCancellationToken?.isCancelled ?? false) {
      return {};
    }
    
    final llmManager = context.read<LLMManager>();
    final skillManager = context.read<SkillManager>();
    final results = <String, String>{};
    
    // 并行执行所有任务
    final futures = tasks.map((task) async {
      // 检查是否被取消
      if (_teamCancellationToken?.isCancelled ?? false) {
        return MapEntry(task.id, '任务已取消');
      }
      
      final agent = _teamAgents.where((a) => a.id == task.assignedTo).firstOrNull;
      if (agent == null) return MapEntry(task.id, '错误：未分配执行者');
      
      // 更新任务状态为运行中
      setState(() {
        task.status = TaskStatus.running;
        task.startedAt = DateTime.now();
        _agentStatus[agent.id] = 'thinking';
      });
      
      try {
        // 构建上游任务的上下文
        final contextBuffer = StringBuffer();
        if (task.dependencies.isNotEmpty) {
          contextBuffer.writeln('【上游任务输出】');
          for (final depId in task.dependencies) {
            final output = previousOutputs[depId];
            if (output != null) {
              contextBuffer.writeln('任务 $depId 的结果:');
              contextBuffer.writeln(output.length > 800 ? '${output.substring(0, 800)}...' : output);
              contextBuffer.writeln();
            }
          }
        }
        
        // 构建技能信息
        final skillBuffer = StringBuffer();
        if (agent.skillIds.isNotEmpty) {
          skillBuffer.writeln('【可用技能】');
          for (final skillId in agent.skillIds) {
            final skill = skillManager.getSkill(skillId);
            if (skill != null) {
              skillBuffer.writeln('- ${skill.name}: ${skill.description}');
            }
          }
          skillBuffer.writeln();
        }
        
        final prompt = '''${agent.systemPrompt}

${contextBuffer}
${skillBuffer}
你的任务是：${task.description}

请独立完成这个任务，输出你的工作结果。
输出格式要求：
【任务输出】
- 完成的工作内容
- 产出物/结论
- 给后续任务的关键信息''';

        final response = await llmManager.chatRaw([
          {'role': 'system', 'content': agent.systemPrompt},
          {'role': 'user', 'content': prompt},
        ]);
        
        // 发送任务完成消息
        _sendTeamMessage(
          fromAgentId: agent.id,
          fromAgentName: agent.name,
          type: TeamMessageType.taskResult,
          content: response,
          taskId: task.id,
        );
        
        // 更新任务状态为已完成
        setState(() {
          task.status = TaskStatus.completed;
          task.completedAt = DateTime.now();
          task.result = response;
        });
        
        // 保存任务输出到子目录
        await _saveTaskOutput(task, agent.name, response);
        
        return MapEntry(task.id, response);
      } catch (e) {
        // 更新任务状态为失败
        setState(() {
          task.status = TaskStatus.failed;
          task.completedAt = DateTime.now();
          task.error = e.toString();
        });
        return MapEntry(task.id, '任务执行失败: $e');
      } finally {
        // 设置状态为空闲
        if (mounted) setState(() => _agentStatus[agent.id] = 'idle');
      }
    });
    
    // 等待所有任务完成
    final entries = await Future.wait(futures);
    for (final entry in entries) {
      results[entry.key] = entry.value;
    }
    
    return results;
  }
  
  /// 保存单个任务输出到子目录
  Future<void> _saveTaskOutput(TeamTask task, String agentName, String output) async {
    try {
      // 获取或创建输出目录
      final workDir = Directory.current;
      final timestamp = DateTime.now().toIso8601String().replaceAll(':', '-').replaceAll('.', '-').substring(0, 19);
      final outputDir = _currentOutputDir ?? '${workDir.path}/goosebaby_outputs/$timestamp';
      
      // 创建任务子目录
      final taskDir = Directory('$outputDir/tasks');
      if (!await taskDir.exists()) {
        await taskDir.create(recursive: true);
      }
      
      // 生成安全的文件名（使用任务序号和简化描述）
      final taskIndex = _dynamicTasks.indexOf(task) + 1;
      final safeDesc = task.description
          .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')
          .replaceAll(RegExp(r'\s+'), '_')
          .substring(0, task.description.length > 20 ? 20 : task.description.length);
      final fileName = '任务${taskIndex}_$safeDesc.md';
      final filePath = '${taskDir.path}/$fileName';
      
      // 构建输出内容
      final content = StringBuffer();
      content.writeln('# ${task.description}');
      content.writeln();
      content.writeln('**负责人**: $agentName');
      content.writeln('**状态**: ${task.status.name}');
      content.writeln('**开始时间**: ${task.startedAt}');
      content.writeln('**完成时间**: ${task.completedAt}');
      content.writeln();
      content.writeln('---');
      content.writeln();
      content.writeln('## 产出内容');
      content.writeln();
      content.writeln(output);
      
      // 写入文件
      final file = File(filePath);
      await file.writeAsString(content.toString());
      
      // 记录文件路径
      setState(() {
        _taskOutputFiles[task.id] = filePath;
      });
      
      debugPrint('📄 [GooseBaby] 任务输出已保存: $filePath');
    } catch (e) {
      debugPrint('❌ [GooseBaby] 保存任务输出失败: $e');
    }
  }
  
  /// 主管汇总当前阶段结果
  Future<void> _supervisorSummarizeStage(
    TeamAgent supervisor,
    int stageIndex,
    List<TeamTask> stageTasks,
    Map<String, String> results,
  ) async {
    final llmManager = context.read<LLMManager>();
    
    // 设置主管状态为思考中
    setState(() => _agentStatus[supervisor.id] = 'thinking');
    
    try {
      // 构建阶段结果汇总
      final resultsSummary = StringBuffer();
      for (final task in stageTasks) {
        final agent = _teamAgents.where((a) => a.id == task.assignedTo).firstOrNull;
        final output = results[task.id] ?? '';
        resultsSummary.writeln('**${agent?.name ?? "未知"}** 完成了: ${task.description}');
        resultsSummary.writeln(output.length > 300 ? '${output.substring(0, 300)}...' : output);
        resultsSummary.writeln();
      }
      
      final prompt = '''作为主管，阶段 ${stageIndex + 1} 的任务已完成。请汇总当前进展。

**已完成的工作**：
$resultsSummary

请简要总结：
1. 当前阶段的关键产出
2. 有无需要调整的后续计划
3. 下一阶段的注意事项''';

      final response = await llmManager.chatRaw([
        {'role': 'system', 'content': supervisor.systemPrompt},
        {'role': 'user', 'content': prompt},
      ]);
      
      _sendTeamMessage(
        fromAgentId: supervisor.id,
        fromAgentName: supervisor.name,
        type: TeamMessageType.broadcast,
        content: '📊 **阶段 ${stageIndex + 1} 汇总**\n$response',
      );
    } finally {
      if (mounted) setState(() => _agentStatus[supervisor.id] = 'idle');
    }
  }
  
  /// 主管输出最终总结
  Future<void> _supervisorFinalSummary(
    TeamAgent supervisor,
    String userTask,
    Map<String, String> allOutputs,
  ) async {
    final llmManager = context.read<LLMManager>();
    
    // 设置主管状态为思考中
    setState(() => _agentStatus[supervisor.id] = 'thinking');
    
    try {
      // 构建所有任务输出汇总
      final allResults = StringBuffer();
      for (final task in _dynamicTasks) {
        final agent = _teamAgents.where((a) => a.id == task.assignedTo).firstOrNull;
        final output = allOutputs[task.id] ?? '';
        allResults.writeln('### ${agent?.name ?? "未知"}: ${task.description}');
        allResults.writeln(output.length > 500 ? '${output.substring(0, 500)}...' : output);
        allResults.writeln();
      }
      
      final prompt = '''作为主管，所有任务已完成。请输出最终总结报告。

**用户原始需求**：
$userTask

**团队工作成果**：
$allResults

请输出：
1. 任务完成情况总结
2. 关键产出物清单
3. 后续建议或注意事项''';

      final response = await llmManager.chatRaw([
        {'role': 'system', 'content': supervisor.systemPrompt},
        {'role': 'user', 'content': prompt},
      ]);
      
      _sendTeamMessage(
        fromAgentId: supervisor.id,
        fromAgentName: supervisor.name,
        type: TeamMessageType.broadcast,
        content: '🎉 **任务完成 - 最终报告**\n\n$response',
      );
      
      // 保存最终报告到工作目录
      await _saveFinalReport(userTask, allResults.toString(), response);
    } finally {
      if (mounted) setState(() => _agentStatus[supervisor.id] = 'idle');
    }
  }
  
  /// 保存最终报告到工作目录
  Future<void> _saveFinalReport(String userTask, String allResults, String finalSummary) async {
    try {
      // 获取工作目录
      final workDir = Directory.current;
      
      // 使用已创建的输出目录（如果存在）
      String outputDirPath;
      if (_currentOutputDir != null) {
        outputDirPath = _currentOutputDir!;
      } else {
        final timestamp = DateTime.now().toIso8601String().replaceAll(':', '-').replaceAll('.', '-').substring(0, 19);
        outputDirPath = '${workDir.path}/goosebaby_outputs/$timestamp';
      }
      
      final outputDir = Directory(outputDirPath);
      
      // 创建输出目录（如果不存在）
      if (!await outputDir.exists()) {
        await outputDir.create(recursive: true);
      }
      
      // 生成文件名
      final fileName = '团队工作成果报告.md';
      final file = File('${outputDir.path}/$fileName');
      
      // 获取相对路径用于链接
      String getRelativePath(String absolutePath) {
        if (absolutePath.startsWith(outputDirPath)) {
          return absolutePath.substring(outputDirPath.length + 1);
        }
        return absolutePath;
      }
      
      // 构建报告内容
      final reportContent = StringBuffer();
      reportContent.writeln('# 团队工作成果报告');
      reportContent.writeln();
      reportContent.writeln('**生成时间**: ${DateTime.now().toString()}');
      reportContent.writeln();
      reportContent.writeln('---');
      reportContent.writeln();
      reportContent.writeln('## 用户需求');
      reportContent.writeln();
      reportContent.writeln(userTask);
      reportContent.writeln();
      reportContent.writeln('---');
      reportContent.writeln();
      reportContent.writeln('## 团队成员');
      reportContent.writeln();
      for (final agent in _teamAgents) {
        reportContent.writeln('- **${agent.name}** (${agent.role})');
      }
      reportContent.writeln();
      reportContent.writeln('---');
      reportContent.writeln();
      reportContent.writeln('## 任务执行情况');
      reportContent.writeln();
      for (final task in _dynamicTasks) {
        final agent = _teamAgents.where((a) => a.id == task.assignedTo).firstOrNull;
        final statusIcon = task.status == TaskStatus.completed ? '✅' : 
                          task.status == TaskStatus.failed ? '❌' : '⏳';
        reportContent.writeln('### $statusIcon ${task.description}');
        reportContent.writeln('- **负责人**: ${agent?.name ?? "未分配"}');
        reportContent.writeln('- **状态**: ${task.status.name}');
        
        // 添加产出文件链接
        final outputPath = _taskOutputFiles[task.id];
        if (outputPath != null) {
          final relativePath = getRelativePath(outputPath);
          reportContent.writeln('- **产出文件**: [$relativePath](./$relativePath)');
        }
        
        if (task.result != null) {
          reportContent.writeln('- **产出摘要**:');
          reportContent.writeln('```');
          reportContent.writeln(task.result!.length > 500 
            ? '${task.result!.substring(0, 500)}...' 
            : task.result!);
          reportContent.writeln('```');
        }
        reportContent.writeln();
      }
      reportContent.writeln('---');
      reportContent.writeln();
      reportContent.writeln('## 最终总结');
      reportContent.writeln();
      reportContent.writeln(finalSummary);
      reportContent.writeln();
      reportContent.writeln('---');
      reportContent.writeln();
      reportContent.writeln('*本报告由 GooseBaby 自动生成*');
      
      // 写入文件
      await file.writeAsString(reportContent.toString());
      
      // 通知用户（带可点击的目录链接）
      if (mounted) {
        _sendTeamMessage(
          fromAgentId: 'supervisor',
          fromAgentName: '主管鹅',
          type: TeamMessageType.broadcast,
          content: '''🎉 **任务完成 - 最终报告已保存**

📁 **输出目录**: `$outputDirPath`

📄 **产出物清单**:
- [团队工作成果报告.md](file://$outputDirPath/$fileName)
${_taskOutputFiles.entries.map((e) {
  final task = _dynamicTasks.where((t) => t.id == e.key).firstOrNull;
  return '- [${task?.description ?? "任务产出"}](file://${e.value})';
}).join('\n')}

💡 点击上方链接可直接打开对应文件。''',
        );
      }
      
      debugPrint('📄 [GooseBaby] 报告已保存: ${file.path}');
    } catch (e) {
      debugPrint('❌ [GooseBaby] 保存报告失败: $e');
      if (mounted) {
        _sendTeamMessage(
          fromAgentId: 'system',
          fromAgentName: '系统',
          type: TeamMessageType.broadcast,
          content: '⚠️ 保存报告失败: $e',
        );
      }
    }
  }

  /// 主管分解任务并分配给团队成员
  Future<void> _supervisorBreakdownTask(TeamAgent supervisor, String userTask) async {
    // 设置主管状态为思考中
    setState(() => _agentStatus[supervisor.id] = 'thinking');
    
    // 构建团队成员信息
    final agentsInfo = _teamAgents.where((a) => a.id != 'supervisor').map((a) => 
      '- ${a.name}（${a.role}）'
    ).join('\n');
    
    final breakdownPrompt = '''作为团队主管，请分析以下用户需求，将其分解为可执行的子任务，并分配给合适的团队成员。

用户需求：
$userTask

团队成员（不含主管）：
${agentsInfo.isNotEmpty ? agentsInfo : '（暂无其他成员，主管将自行执行所有任务）'}

请以 JSON 数组格式输出任务分解结果，每个元素包含：
- task: 子任务描述（简洁明确）
- assignTo: 分配给的成员名称（如果没有合适成员，填"主管"）
- mode: 执行模式 - "sequential"（串行，需等待前序任务）或 "parallel"（可并行执行）
- dependsOn: 依赖的任务序号数组（从1开始，无依赖则为空数组）

分解原则：
1. 任务粒度适中，每个任务可由单个成员独立完成
2. 明确任务间的依赖关系（如：原画设计需要先有策划方案）
3. 可并行的任务尽量标记为 parallel
4. 按执行顺序排列任务

示例输出：
[
  {"task": "设计 AI 宠物的核心玩法和交互方式", "assignTo": "游戏策划", "mode": "sequential", "dependsOn": []},
  {"task": "设计角色外观和动作", "assignTo": "原画师", "mode": "sequential", "dependsOn": [1]},
  {"task": "设计数值系统和成长曲线", "assignTo": "数值策划", "mode": "parallel", "dependsOn": [1]},
  {"task": "设计技术架构方案", "assignTo": "架构师", "mode": "parallel", "dependsOn": [1]},
  {"task": "汇总所有方案，输出完整设计文档", "assignTo": "主管", "mode": "sequential", "dependsOn": [2, 3, 4]}
]

只输出 JSON 数组，不要其他内容。''';

    try {
      final llmManager = context.read<LLMManager>();
      final response = await llmManager.chatRaw([
        {'role': 'user', 'content': breakdownPrompt}
      ]);
      
      // 解析 JSON 结果
      final jsonMatch = RegExp(r'\[[\s\S]*\]').firstMatch(response);
      if (jsonMatch != null) {
        final tasks = jsonDecode(jsonMatch.group(0)!) as List;
        
        // 创建任务列表
        setState(() {
          for (int i = 0; i < tasks.length; i++) {
            final taskData = safeMap(tasks[i]);
            final assignTo = taskData['assignTo'] as String?;
            final agent = assignTo != null 
                ? _teamAgents.where((a) => a.name == assignTo).firstOrNull 
                : null;
            
            final modeStr = taskData['mode'] as String? ?? 'sequential';
            final mode = modeStr == 'parallel' ? TaskExecutionMode.parallel : TaskExecutionMode.sequential;
            
            final dependsOn = (taskData['dependsOn'] as List?)?.cast<int>() ?? [];
            
            _dynamicTasks.add(TeamTask(
              id: 'task_${i + 1}',
              description: taskData['task'] as String,
              assignedTo: agent?.id,
              executionMode: mode,
              dependencies: dependsOn.map((idx) => 'task_$idx').toList(),
              priority: i + 1,
            ));
          }
        });
        
        // 发送任务分解结果
        final taskList = _dynamicTasks.asMap().entries.map((e) {
          final task = e.value;
          final agent = _teamAgents.where((a) => a.id == task.assignedTo).firstOrNull;
          final modeLabel = task.executionMode == TaskExecutionMode.parallel ? '并行' : '串行';
          return '${e.key + 1}. ${task.description} → ${agent?.name ?? '待分配'} ($modeLabel)';
        }).join('\n');
        
        _sendTeamMessage(
          fromAgentId: supervisor.id,
          fromAgentName: supervisor.name,
          type: TeamMessageType.broadcast,
          content: '任务分解完成，共 ${_dynamicTasks.length} 个子任务：\n$taskList\n\n现在开始执行...',
        );
        
        // 构建 spawn_agent_team 的 prompt
        // 执行主管驱动的工作流
        await _executeSupervisorDrivenWorkflow(supervisor, userTask);
        
        // 设置主管状态为空闲
        if (mounted) setState(() => _agentStatus[supervisor.id] = 'idle');
      }
    } catch (e) {
      // 设置主管状态为空闲
      setState(() => _agentStatus[supervisor.id] = 'idle');
      
      _sendTeamMessage(
        fromAgentId: supervisor.id,
        fromAgentName: supervisor.name,
        type: TeamMessageType.broadcast,
        content: '任务分解失败: $e\n将由主管直接处理该任务。',
      );
      
      // 主管直接处理
      _inputController.text = userTask;
      _sendMessage();
    }
  }
  
  /// 发送团队消息（直接显示在主对话框）
  void _sendTeamMessage({
    required String fromAgentId,
    required String fromAgentName,
    required TeamMessageType type,
    required String content,
    List<String> toAgentIds = const [],
    String? taskId,
  }) {
    final message = TeamMessage(
      id: 'msg_${DateTime.now().millisecondsSinceEpoch}',
      fromAgentId: fromAgentId,
      fromAgentName: fromAgentName,
      type: type,
      toAgentIds: toAgentIds,
      content: content,
      taskId: taskId,
    );
    
    // 添加到消息板（供历史查询）
    _teamMessageBoard.add(message);
    
    // 同时直接显示在主对话框
    setState(() {
      _messages.add(_ChatMessage(
        content: content,
        isUser: false,
        timestamp: DateTime.now(),
        teamMessage: message,
      ));
    });
    
    _scrollToBottom();
  }
  
  // ==================== 圆桌讨论模式 ====================
  
  /// 启动圆桌讨论
  Future<void> _startDiscussion(String topic) async {
    // 检查是否有主持人
    final moderator = _teamAgents.where((a) => a.id == 'supervisor').firstOrNull;
    if (moderator == null) {
      _sendTeamMessage(
        fromAgentId: 'system',
        fromAgentName: '系统',
        type: TeamMessageType.broadcast,
        content: '⚠️ 圆桌讨论需要主持人（主管角色），请先添加主管',
      );
      return;
    }
    
    // 检查是否有专家
    final experts = _teamAgents.where((a) => a.id != 'supervisor').toList();
    if (experts.isEmpty) {
      _sendTeamMessage(
        fromAgentId: 'system',
        fromAgentName: '系统',
        type: TeamMessageType.broadcast,
        content: '⚠️ 圆桌讨论需要至少一位专家参与讨论',
      );
      return;
    }
    
    // 清空之前的讨论记录
    _discussionTurns.clear();
    
    // 初始化讨论配置
    _discussionConfig = DiscussionConfig(
      topic: topic,
      maxRounds: _discussionConfig?.maxRounds ?? 2,
    );
    _currentDiscussionRound = 0;
    
    // 初始化取消令牌
    _teamCancellationToken = CancellationToken();
    
    setState(() {
      _isLoading = true;
      _isDiscussing = true;
      _isTeamExecuting = true;
    });
    
    try {
      // 1. 主持人发起讨论
      _sendTeamMessage(
        fromAgentId: 'system',
        fromAgentName: '系统',
        type: TeamMessageType.broadcast,
        content: '📢 圆桌讨论开始！\n讨论主题：$topic',
      );
      
      await _moderatorOpening(moderator, topic);
      
      // 2. 多轮讨论
      for (int round = 1; round <= _discussionConfig!.maxRounds; round++) {
        // 检查是否被取消
        if (_teamCancellationToken?.isCancelled ?? false) {
          _sendTeamMessage(
            fromAgentId: 'system',
            fromAgentName: '系统',
            type: TeamMessageType.broadcast,
            content: '⚠️ 讨论已被用户终止',
          );
          return;
        }
        
        _currentDiscussionRound = round;
        
        // 轮次开始提示
        _sendTeamMessage(
          fromAgentId: 'system',
          fromAgentName: '系统',
          type: TeamMessageType.broadcast,
          content: '────── 第 $round 轮讨论 ──────',
        );
        
        // 执行一轮讨论
        await _executeDiscussionRound(round, topic, moderator, experts);
        
        // 检查是否需要提前结束（AI判断共识）
        if (_discussionConfig!.endCondition == 'consensus') {
          final hasConsensus = await _checkConsensus(moderator);
          if (hasConsensus) {
            _sendTeamMessage(
              fromAgentId: 'system',
              fromAgentName: '系统',
              type: TeamMessageType.broadcast,
              content: '✅ 已达成共识，讨论结束',
            );
            break;
          }
        }
      }
      
      // 3. 主持人总结
      if (!(_teamCancellationToken?.isCancelled ?? false)) {
        await _moderatorConclusion(moderator, topic);
      }
      
    } catch (e) {
      _sendTeamMessage(
        fromAgentId: 'system',
        fromAgentName: '系统',
        type: TeamMessageType.broadcast,
        content: '❌ 讨论过程中出现错误：$e',
      );
    } finally {
      if (mounted) setState(() {
        _isLoading = false;
        _isDiscussing = false;
        _isTeamExecuting = false;
        _teamCancellationToken = null;
      });
    }
  }
  
  /// 主持人开场
  Future<void> _moderatorOpening(TeamAgent moderator, String topic) async {
    if (_teamCancellationToken?.isCancelled ?? false) return;
    
    final llmManager = context.read<LLMManager>();
    final experts = _teamAgents.where((a) => a.id != 'supervisor').toList();
    final expertInfo = experts.map((e) => '- ${e.name}（${e.role}）').join('\n');
    
    final prompt = '''你是圆桌讨论的主持人：${moderator.name}

【讨论主题】$topic

【参与专家】
$expertInfo

作为主持人，请：
1. 简要介绍讨论主题的背景和意义
2. 点名邀请各位专家从各自专业角度发表观点
3. 引导讨论方向，确保讨论聚焦

请用简洁有力的开场白开启讨论（100字以内）。''';

    setState(() => _agentStatus[moderator.id] = 'thinking');
    
    try {
      final response = await llmManager.chatRaw([
        {'role': 'system', 'content': moderator.systemPrompt},
        {'role': 'user', 'content': prompt},
      ]);
      
      _sendTeamMessage(
        fromAgentId: moderator.id,
        fromAgentName: moderator.name,
        type: TeamMessageType.discussion,
        content: response,
      );
    } finally {
      if (mounted) setState(() => _agentStatus[moderator.id] = 'idle');
    }
  }
  
  /// 执行一轮讨论
  Future<void> _executeDiscussionRound(
    int round, 
    String topic, 
    TeamAgent moderator,
    List<TeamAgent> experts,
  ) async {
    final llmManager = context.read<LLMManager>();
    
    // 逐个专家发言
    for (final expert in experts) {
      // 检查是否被取消
      if (_teamCancellationToken?.isCancelled ?? false) return;
      
      // 构建讨论上下文
      final discussionContext = _buildDiscussionContext();
      
      final prompt = '''你是 ${expert.name}，一位${expert.role}。

【讨论主题】$topic

【当前轮次】第 $round 轮

【已有讨论】
$discussionContext

请从你的专业角度发表观点。你可以：
1. 提出新的见解和分析
2. 赞同或反驳之前的观点，并说明理由
3. 补充被忽略的重要角度
4. 向其他专家提问

注意：
- 观点要鲜明，体现你的专业特色
- 可以引用其他专家的观点进行互动
- 控制在150字以内，简洁有力''';

      setState(() => _agentStatus[expert.id] = 'thinking');
      
      try {
        final response = await llmManager.chatRaw([
          {'role': 'system', 'content': expert.systemPrompt},
          {'role': 'user', 'content': prompt},
        ]);
        
        // 记录发言
        _discussionTurns.add(DiscussionTurn(
          round: round,
          agentId: expert.id,
          agentName: expert.name,
          content: response,
          timestamp: DateTime.now(),
        ));
        
        // 发送消息
        _sendTeamMessage(
          fromAgentId: expert.id,
          fromAgentName: expert.name,
          type: TeamMessageType.discussion,
          content: response,
        );
      } finally {
        if (mounted) setState(() => _agentStatus[expert.id] = 'idle');
      }
      
      // 专家之间稍微间隔一下
      await Future.delayed(const Duration(milliseconds: 300));
    }
  }
  
  /// 构建讨论上下文（之前的发言记录）
  String _buildDiscussionContext() {
    if (_discussionTurns.isEmpty) return '（暂无发言）';
    
    final buffer = StringBuffer();
    for (final turn in _discussionTurns) {
      buffer.writeln('【${turn.agentName}】(第${turn.round}轮)');
      buffer.writeln('${turn.content}');
      buffer.writeln();
    }
    return buffer.toString();
  }
  
  /// 检查是否达成共识
  Future<bool> _checkConsensus(TeamAgent moderator) async {
    final llmManager = context.read<LLMManager>();
    final discussionContext = _buildDiscussionContext();
    
    final prompt = '''你是圆桌讨论的主持人：${moderator.name}

【讨论内容】
$discussionContext

请判断：讨论是否已经达成了基本共识？
- 如果各方观点已经趋于一致，回答 YES
- 如果还存在明显分歧需要继续讨论，回答 NO

只回答 YES 或 NO。''';

    try {
      final response = await llmManager.chatRaw([
        {'role': 'system', 'content': moderator.systemPrompt},
        {'role': 'user', 'content': prompt},
      ]);
      return response.trim().toUpperCase().contains('YES');
    } catch (e) {
      return false;
    }
  }
  
  /// 主持人总结
  Future<void> _moderatorConclusion(TeamAgent moderator, String topic) async {
    final llmManager = context.read<LLMManager>();
    final discussionContext = _buildDiscussionContext();
    
    final prompt = '''你是圆桌讨论的主持人：${moderator.name}

【讨论主题】$topic

【讨论记录】
$discussionContext

作为主持人，请：
1. 总结各方专家的主要观点
2. 指出共识点和分歧点
3. 给出讨论结论或建议

请用结构化的方式输出总结（可以用 Markdown 格式）。''';

    setState(() => _agentStatus[moderator.id] = 'thinking');
    
    try {
      final response = await llmManager.chatRaw([
        {'role': 'system', 'content': moderator.systemPrompt},
        {'role': 'user', 'content': prompt},
      ]);
      
      _sendTeamMessage(
        fromAgentId: moderator.id,
        fromAgentName: moderator.name,
        type: TeamMessageType.discussionSummary,
        content: '📋 **讨论总结**\n\n$response',
      );
    } finally {
      if (mounted) setState(() => _agentStatus[moderator.id] = 'idle');
    }
  }
  
  /// 显示自定义轮次对话框
  void _showCustomRoundsDialog() {
    final controller = TextEditingController(text: '${_discussionConfig?.maxRounds ?? 2}');
    
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('自定义讨论轮次', style: TextStyle(fontSize: 14)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: controller,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: '轮次数 (1-10)',
                hintText: '输入 1-10 之间的数字',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '轮次越多，讨论越深入，但耗时也越长',
              style: TextStyle(fontSize: 10, color: Colors.grey.shade600),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          ElevatedButton(
            onPressed: () {
              final rounds = int.tryParse(controller.text) ?? 2;
              if (rounds >= 1 && rounds <= 10) {
                setState(() {
                  _discussionConfig = DiscussionConfig(
                    topic: _discussionConfig?.topic ?? '',
                    maxRounds: rounds,
                  );
                });
                Navigator.of(ctx).pop();
              }
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF9C27B0),
              foregroundColor: Colors.white,
            ),
            child: const Text('确定'),
          ),
        ],
      ),
    );
  }
  
  /// 结束讨论
  void _endDiscussion() {
    if (_teamCancellationToken != null) {
      _teamCancellationToken!.cancel();
    }
    
    setState(() {
      _isDiscussing = false;
      _isLoading = false;
    });
    
    _sendTeamMessage(
      fromAgentId: 'system',
      fromAgentName: '系统',
      type: TeamMessageType.broadcast,
      content: '⏹️ 讨论已手动结束',
    );
  }

  Widget _buildMessageList() {
    final stepCount = _isLoading ? _toolCallSteps.length : 0;
    final hasLoadingIndicator = _isLoading && _toolCallSteps.isEmpty;
    final itemCount = _messages.length + (stepCount > 0 ? stepCount + 1 : 0) + (hasLoadingIndicator ? 1 : 0);
    return SelectionArea(
      child: ListView.builder(
        controller: _scrollController,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        itemCount: itemCount,
        itemBuilder: (context, index) {
          final msgEnd = _messages.length;

          if (index < msgEnd) {
            // 正常消息
            final msg = _messages[index];
            return _buildMessageWithSteps(msg);
          }

          if (hasLoadingIndicator && index == msgEnd) {
            // 没有步骤时的普通加载指示器
            if (_streamingContent.isNotEmpty) {
              return RichMessageBubble(
                content: _streamingContent,
                isUser: false,
                timestamp: DateTime.now(),
                fontSize: _chatFontSize,
              );
            }
            return _buildTypingIndicator();
          }

          // 工具调用中间步骤区域
          if (_isLoading && _toolCallSteps.isNotEmpty) {
            final stepIndex = index - msgEnd;
            if (stepIndex < _toolCallSteps.length) {
              return _buildToolCallStepWidget(_toolCallSteps[stepIndex]);
            }
            // 最后一个位置：流式内容或 thinking 指示器
            if (stepIndex == _toolCallSteps.length) {
              if (_streamingContent.isNotEmpty) {
                return RichMessageBubble(
                  content: _streamingContent,
                  isUser: false,
                  timestamp: DateTime.now(),
                  fontSize: _chatFontSize,
                );
              }
              return _buildTypingIndicator();
            }
          }

          return const SizedBox.shrink();
        },
      ),
    );
  }

  /// 构建带工具调用步骤的消息（步骤在消息上方）
  Widget _buildMessageWithSteps(_ChatMessage msg) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 团队消息：显示发送者头像和名称
        if (msg.teamMessage != null) _buildTeamMessageHeader(msg.teamMessage!),
        // 工具调用步骤列表（折叠式）
        if (msg.toolSteps.isNotEmpty) _buildToolStepsSummary(msg.toolSteps),
        if (msg.toolSteps.isNotEmpty) const SizedBox(height: 4),
        // 主消息气泡
        RichMessageBubble(
          content: msg.content,
          isUser: msg.isUser,
          timestamp: msg.timestamp,
          isError: msg.isError,
          skillResult: msg.skillResult,
          attachments: msg.attachments,
          fontSize: _chatFontSize,
        ),
      ],
    );
  }

  /// 构建团队消息头部（显示发送者信息）
  Widget _buildTeamMessageHeader(TeamMessage teamMsg) {
    final senderColor = _getAgentColor(teamMsg.fromAgentId);
    
    return Container(
      margin: const EdgeInsets.only(bottom: 4, top: 8),
      child: Row(
        children: [
          // 发送者头像
          Container(
            width: 20,
            height: 20,
            decoration: BoxDecoration(
              color: senderColor,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Center(
              child: Text(
                teamMsg.fromAgentName.isNotEmpty ? teamMsg.fromAgentName[0] : 'A',
                style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.white),
              ),
            ),
          ),
          const SizedBox(width: 6),
          // 发送者名称
          Text(
            teamMsg.fromAgentName,
            style: TextStyle(fontSize: 11, fontWeight: FontWeight.w500, color: senderColor),
          ),
          const SizedBox(width: 6),
          // 消息类型标签
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
            decoration: BoxDecoration(
              color: _getMessageTypeColor(teamMsg.type).withOpacity(0.2),
              borderRadius: BorderRadius.circular(3),
            ),
            child: Text(
              _getMessageTypeLabel(teamMsg.type),
              style: TextStyle(fontSize: 9, color: _getMessageTypeColor(teamMsg.type)),
            ),
          ),
          // @ 提及（只显示特定 @ 的角色，不显示广播）
          if (!teamMsg.isBroadcast && teamMsg.toAgentIds.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 6),
              child: Text(
                '@${teamMsg.toAgentIds.map((id) => _getAgentName(id)).join(' @')}',
                style: TextStyle(fontSize: 10, color: Colors.purple.shade400, fontWeight: FontWeight.w500),
              ),
            ),
        ],
      ),
    );
  }

  /// 构建工具调用步骤摘要（可展开/折叠）
  Widget _buildToolStepsSummary(List<_ToolCallStep> steps) {
    return _ToolStepsSummary(steps: steps);
  }

  /// 构建 Plan 面板（支持多 Plan Tab 切换）
  Widget _buildPlanPanel() {
    // 安全边界
    if (_pendingPlans.isEmpty) return const SizedBox.shrink();
    if (_activePlanIndex >= _pendingPlans.length) {
      _activePlanIndex = _pendingPlans.length - 1;
    }
    final plan = _pendingPlans[_activePlanIndex];
    final isExecuting = plan.isConfirmed && !plan.isCompleted;
    
    return Container(
      constraints: const BoxConstraints(maxHeight: 200),
      decoration: BoxDecoration(
        color: Colors.blue.shade50,
        border: Border(bottom: BorderSide(color: Colors.blue.shade200, width: 0.5)),
      ),
      child: Column(
        children: [
          // 标题栏：Tab 切换 + 操作按钮
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.blue.shade100,
              border: Border(bottom: BorderSide(color: Colors.blue.shade200)),
            ),
            child: Row(
              children: [
                // Plan Tabs（多个时显示）
                if (_pendingPlans.length > 1)
                  ..._pendingPlans.asMap().entries.map((entry) {
                    final idx = entry.key;
                    final p = entry.value;
                    final isActive = idx == _activePlanIndex;
                    final label = p.userRequest.length > 12 
                        ? '${p.userRequest.substring(0, 12)}…'
                        : p.userRequest;
                    return GestureDetector(
                      onTap: () => setState(() => _activePlanIndex = idx),
                      child: Container(
                        margin: const EdgeInsets.only(right: 4),
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: isActive ? Colors.white : Colors.transparent,
                          borderRadius: BorderRadius.circular(4),
                          border: isActive ? Border.all(color: Colors.blue.shade300) : null,
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (p.isCompleted)
                              Icon(Icons.check_circle, size: 10, color: Colors.green.shade600)
                            else if (p.isConfirmed)
                              SizedBox(width: 10, height: 10, child: CircularProgressIndicator(strokeWidth: 1.5, color: Colors.blue.shade600))
                            else
                              Icon(Icons.circle_outlined, size: 10, color: Colors.grey.shade500),
                            const SizedBox(width: 4),
                            Text(label, style: TextStyle(
                              fontSize: 11, 
                              color: isActive ? const Color(0xFF2196F3) : Colors.grey.shade600,
                              fontWeight: isActive ? FontWeight.w600 : FontWeight.normal,
                            )),
                          ],
                        ),
                      ),
                    );
                  })
                else ...[
                  const Icon(Icons.assignment, size: 14, color: Color(0xFF2196F3)),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      plan.userRequest.length > 30 
                          ? '${plan.userRequest.substring(0, 30)}…'
                          : plan.userRequest,
                      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFF2196F3)),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
                // 进度
                if (isExecuting) ...[
                  const SizedBox(width: 6),
                  Text('${(plan.progress * 100).toInt()}%', style: TextStyle(fontSize: 10, color: Colors.blue.shade700)),
                  const SizedBox(width: 4),
                  SizedBox(width: 40, height: 3, child: LinearProgressIndicator(
                    value: plan.progress,
                    backgroundColor: Colors.blue.shade100,
                    valueColor: AlwaysStoppedAnimation<Color>(Colors.blue.shade600),
                  )),
                ],
                if (_pendingPlans.length <= 1) const Spacer(),
                if (_pendingPlans.length > 1) const Spacer(),
                // 确认/取消按钮
                if (!plan.isConfirmed && !plan.isRejected) ...[
                  TextButton(
                    onPressed: () {
                      setState(() {
                        plan.isRejected = true;
                        _pendingPlans.removeAt(_activePlanIndex);
                        if (_activePlanIndex >= _pendingPlans.length && _pendingPlans.isNotEmpty) {
                          _activePlanIndex = _pendingPlans.length - 1;
                        }
                      });
                    },
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                      minimumSize: Size.zero,
                    ),
                    child: const Text('取消', style: TextStyle(fontSize: 11)),
                  ),
                  const SizedBox(width: 2),
                  ElevatedButton(
                    onPressed: () async {
                      setState(() => plan.isConfirmed = true);
                      await _executeConfirmedPlan(plan);
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.blue,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                      minimumSize: Size.zero,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
                    ),
                    child: const Text('确认', style: TextStyle(fontSize: 11)),
                  ),
                ],
                // 已完成的 Plan 可关闭
                if (plan.isCompleted || plan.isRejected)
                  InkWell(
                    onTap: () {
                      setState(() {
                        _pendingPlans.removeAt(_activePlanIndex);
                        if (_activePlanIndex >= _pendingPlans.length && _pendingPlans.isNotEmpty) {
                          _activePlanIndex = _pendingPlans.length - 1;
                        }
                      });
                    },
                    child: const Padding(
                      padding: EdgeInsets.all(4),
                      child: Icon(Icons.close, size: 14, color: Colors.grey),
                    ),
                  ),
              ],
            ),
          ),
          // 步骤列表
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              itemCount: plan.steps.length,
              itemBuilder: (context, index) => _buildPlanStepItem(plan.steps[index], index),
            ),
          ),
        ],
      ),
    );
  }
  
  /// 构建计划步骤项（参考 Team 任务样式）
  Widget _buildPlanStepItem(PlanStep step, int index) {
    final statusColor = _getPlanStepStatusColor(step.status);
    final statusIcon = _getPlanStepStatusIcon(step.status);
    
    return Container(
      margin: const EdgeInsets.only(bottom: 2),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Row(
        children: [
          // 序号/状态图标
          Container(
            width: 20,
            height: 20,
            decoration: BoxDecoration(
              color: statusColor.withOpacity(0.15),
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: step.status == PlanStepStatus.pending
                ? Text('${index + 1}', style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: statusColor))
                : Icon(statusIcon, size: 12, color: statusColor),
          ),
          const SizedBox(width: 8),
          // 步骤描述
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  step.description,
                  style: TextStyle(
                    fontSize: 12,
                    color: step.status == PlanStepStatus.pending ? Colors.black87 : Colors.grey.shade600,
                    decoration: step.status == PlanStepStatus.skipped ? TextDecoration.lineThrough : null,
                  ),
                ),
                if (step.toolName != null)
                  Text(
                    '🔧 ${step.toolName}',
                    style: TextStyle(fontSize: 10, color: Colors.grey.shade500),
                  ),
              ],
            ),
          ),
          // 状态标签
          if (step.status != PlanStepStatus.pending)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
              decoration: BoxDecoration(
                color: statusColor.withOpacity(0.1),
                borderRadius: BorderRadius.circular(3),
              ),
              child: Text(
                _getPlanStepStatusLabel(step.status),
                style: TextStyle(fontSize: 9, color: statusColor),
              ),
            ),
        ],
      ),
    );
  }
  
  /// 获取步骤状态颜色
  Color _getPlanStepStatusColor(PlanStepStatus status) {
    switch (status) {
      case PlanStepStatus.pending:
        return Colors.grey;
      case PlanStepStatus.running:
        return Colors.blue;
      case PlanStepStatus.completed:
        return Colors.green;
      case PlanStepStatus.failed:
        return Colors.red;
      case PlanStepStatus.skipped:
        return Colors.orange;
    }
  }
  
  /// 获取步骤状态图标
  IconData _getPlanStepStatusIcon(PlanStepStatus status) {
    switch (status) {
      case PlanStepStatus.pending:
        return Icons.circle_outlined;
      case PlanStepStatus.running:
        return Icons.refresh;
      case PlanStepStatus.completed:
        return Icons.check;
      case PlanStepStatus.failed:
        return Icons.close;
      case PlanStepStatus.skipped:
        return Icons.skip_next;
    }
  }
  
  /// 获取步骤状态标签
  String _getPlanStepStatusLabel(PlanStepStatus status) {
    switch (status) {
      case PlanStepStatus.pending:
        return '待执行';
      case PlanStepStatus.running:
        return '执行中';
      case PlanStepStatus.completed:
        return '完成';
      case PlanStepStatus.failed:
        return '失败';
      case PlanStepStatus.skipped:
        return '跳过';
    }
  }

  /// 构建工具调用中间步骤的 UI
  Widget _buildToolCallStepWidget(_ToolCallStep step) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 3),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: step.isFailed
              ? Colors.red.shade50
              : step.isSkip
                  ? Colors.orange.shade50
                  : Colors.blue.shade50,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: step.isFailed
                ? Colors.red.shade200
                : step.isSkip
                    ? Colors.orange.shade200
                    : Colors.blue.shade200,
            width: 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (step.isLoading)
                  SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.blue.shade400,
                    ),
                  )
                else if (step.isFailed)
                  Icon(Icons.close, size: 14, color: Colors.red.shade400)
                else if (step.isSkip)
                  Icon(Icons.skip_next, size: 14, color: Colors.orange.shade400)
                else
                  Icon(Icons.check_circle, size: 14, color: Colors.green.shade400),
                const SizedBox(width: 6),
                Text(
                  step.title,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: step.isFailed
                        ? Colors.red.shade700
                        : step.isSkip
                            ? Colors.orange.shade700
                            : Colors.blue.shade700,
                  ),
                ),
              ],
            ),
            if (step.content.isNotEmpty) ...[
              const SizedBox(height: 4),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.6),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  step.content,
                  style: TextStyle(
                    fontSize: 11,
                    color: Colors.grey.shade700,
                    height: 1.4,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildTypingIndicator() {
    // 获取当前正在思考的角色
    String thinkingText = '鹅宝在思考...';
    
    if (_agentMode == AgentMode.team && _teamAgents.isNotEmpty) {
      // 找出正在思考的角色
      final thinkingAgents = _teamAgents
          .where((a) => _agentStatus[a.id] == 'thinking')
          .toList();
      
      if (thinkingAgents.isNotEmpty) {
        if (thinkingAgents.length == 1) {
          thinkingText = '${thinkingAgents[0].name}在思考...';
        } else {
          // 多个角色同时思考
          final names = thinkingAgents.map((a) => a.name).take(3).join('、');
          thinkingText = '$names在思考...';
        }
      }
    }
    
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const _TypingDot(delay: 0),
            const SizedBox(width: 4),
            const _TypingDot(delay: 200),
            const SizedBox(width: 4),
            const _TypingDot(delay: 400),
            const SizedBox(width: 8),
            Text(
              thinkingText,
              style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
            ),
          ],
        ),
      ),
    );
  }

  /// 构建上下文使用监控 UI（优化5）
  /// 显示历史消息 Token 使用进度条和 Prompt 级别
  Widget _buildContextMonitor() {
    final historyBudget = _contextManager.historyReserve;
    final historyUsage = _currentHistoryTokens;
    final usagePercent = (historyUsage / historyBudget * 100).clamp(0.0, 100.0);
    final promptLevel = _contextManager.promptLevel;
    
    // 根据使用率选择颜色
    Color progressColor;
    String statusText;
    if (usagePercent < 50) {
      progressColor = Colors.green;
      statusText = '正常';
    } else if (usagePercent < 75) {
      progressColor = Colors.orange;
      statusText = '适中';
    } else {
      progressColor = Colors.red;
      statusText = '较高';
    }
    
    // Prompt 级别标签
    String levelLabel;
    Color levelColor;
    switch (promptLevel) {
      case PromptLevel.minimal:
        levelLabel = '轻量';
        levelColor = Colors.blue;
        break;
      case PromptLevel.standard:
        levelLabel = '标准';
        levelColor = Colors.teal;
        break;
      case PromptLevel.full:
        levelLabel = '完整';
        levelColor = Colors.purple;
        break;
    }
    
    // 总 Token（System + History）
    final totalTokens = _currentSystemPromptTokens + historyUsage;
    
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.grey.shade50,
        border: Border(
          bottom: BorderSide(color: Colors.grey.shade200, width: 0.5),
        ),
      ),
      child: Row(
        children: [
          // Prompt 级别标签
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: levelColor.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: levelColor.withValues(alpha: 0.3)),
            ),
            child: Text(
              levelLabel,
              style: TextStyle(
                fontSize: 10,
                color: levelColor,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          const SizedBox(width: 8),
          // Token 使用进度条
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Text(
                      '上下文',
                      style: TextStyle(
                        fontSize: 10,
                        color: Colors.grey.shade600,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Text(
                      '${(totalTokens / 1000).toStringAsFixed(1)}k',
                      style: TextStyle(
                        fontSize: 10,
                        color: progressColor,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    Text(
                      ' (Sys ${(_currentSystemPromptTokens / 1000).toStringAsFixed(1)}k + Hist ${(historyUsage / 1000).toStringAsFixed(1)}k)',
                      style: TextStyle(
                        fontSize: 9,
                        color: Colors.grey.shade500,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Text(
                      '($statusText)',
                      style: TextStyle(
                        fontSize: 9,
                        color: progressColor,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                LinearProgressIndicator(
                  value: usagePercent / 100,
                  backgroundColor: Colors.grey.shade200,
                  valueColor: AlwaysStoppedAnimation<Color>(progressColor),
                  minHeight: 3,
                ),
              ],
            ),
          ),
          // 消息数量
          const SizedBox(width: 8),
          Text(
            '${_messages.length}条',
            style: TextStyle(
              fontSize: 10,
              color: Colors.grey.shade500,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInputBar() {
    return EnhancedInputBar(
      controller: _inputController,
      focusNode: _focusNode,
      isLoading: _isLoading,
      attachments: _pendingAttachments,
      onAttachmentsChanged: (attachments) {
        setState(() => _pendingAttachments = attachments);
      },
      onSend: _sendMessage,
      onStop: _stopCurrentSession,
    );
  }

  /// 执行已确认的计划（利用 Agent 循环逐步执行）
  Future<void> _executeConfirmedPlan(PendingPlan plan) async {
    if (!mounted) return;
    
    final llmManager = context.read<LLMManager>();
    final memoryManager = context.read<MemoryManager>();
    final skillManager = context.read<SkillManager>();
    final petEngine = context.read<PetEngine>();
    
    setState(() {
      _isLoading = true;
      _streamingContent = '';
      _toolCallSteps.clear();
      _cancellationToken = CancellationToken();
    });
    
    petEngine.startWorking();
    
    // 初始化工作目录（和主流程一致）
    String workDir = '';
    String osName = 'unknown';
    if (!kIsWeb) {
      try {
        final sessionId = _currentConversationId ?? DateTime.now().millisecondsSinceEpoch.toString();
        await SkillFileUtils.setSessionWorkingDir(sessionId);
        workDir = SkillFileUtils.effectiveWorkingDir;
        osName = Platform.operatingSystem;
      } catch (e) {
        debugPrint('⚠️ [Plan] 初始化工作目录失败: $e');
      }
    }
    
    try {
      // 构建计划步骤描述
      final stepsDesc = plan.steps.asMap().entries
          .map((e) => '步骤${e.key + 1}: ${e.value.description}')
          .join('\n');
      
      // 逐步执行
      for (int i = 0; i < plan.steps.length; i++) {
        final step = plan.steps[i];
        if (!mounted || _cancellationToken?.isCancelled == true) break;
        
        // 标记当前步骤为执行中
        setState(() => step.start());
        
        // 构建执行该步骤的 prompt
        final completedSteps = plan.steps
            .where((s) => s.status == PlanStepStatus.completed)
            .map((s) => '✅ ${s.description}: ${s.result?.substring(0, (s.result!.length > 200 ? 200 : s.result!.length)) ?? "完成"}')
            .join('\n');
        
        final stepPrompt = '''用户请求: ${plan.userRequest}

完整计划:
$stepsDesc

${completedSteps.isNotEmpty ? '已完成步骤:\n$completedSteps\n' : ''}当前执行: 步骤${i + 1} - ${step.description}

请执行当前步骤，直接给出结果。''';
        
        // 构建 system prompt（复用主流程逻辑）
        _contextManager.clearSegments();
        final memorySegments = memoryManager.getMemorySegments(plan.userRequest);
        for (final seg in memorySegments) {
          _contextManager.addSegment(seg);
        }
        final effectiveMemoryContext = _contextManager.build(
          customMaxTokens: _contextManager.getSystemPromptMaxForLevel(_contextManager.promptLevel),
        );
        
        String systemPrompt = GoosePrompts.getSystemPromptByLevel(
          _contextManager.promptLevel,
          workMode: widget.workMode,
        );
        if (effectiveMemoryContext.isNotEmpty) {
          systemPrompt += '\n\n## 关于主人的记忆\n$effectiveMemoryContext';
        }
        final agentSkillsPrompt = skillManager.getAgentSkillsPrompt(userRequest: step.description);
        if (agentSkillsPrompt.isNotEmpty && _contextManager.promptLevel != PromptLevel.minimal) {
          systemPrompt += '\n\n$agentSkillsPrompt';
        }
        
        // 添加运行环境
        if (!kIsWeb && workDir.isNotEmpty) {
          systemPrompt += '\n\n## 运行环境\n- 操作系统: $osName\n- 工作目录: $workDir';
        }
        
        final tools = skillManager.toFunctionTools();
        final messages = <Map<String, dynamic>>[
          {'role': 'system', 'content': systemPrompt},
          {'role': 'user', 'content': stepPrompt},
        ];
        
        // 先检测是否有 tool calls
        final response = await llmManager.chatWithMessages(messages, tools: tools);
        
        String stepResult;
        if (response.hasToolCalls) {
          // 有工具调用 → 进入 Agent 循环
          final hooks = <AgentHook>[
            LoopDetectionHook(),
            FailureLessonHook(memoryManager),
            PerformanceStatsHook(),
          ];
          
          final loopResult = await AgentLoop.run(
            provider: llmManager.currentProvider!,
            config: llmManager.currentConfig,
            messages: messages,
            tools: tools,
            executeTool: (call, {onOutput}) => _executeTool(call, skillManager, workDir, onOutput: onOutput),
            cancellationToken: _cancellationToken,
            hooks: hooks,
            mode: AgentMode.craft, // 执行阶段用 craft 模式
            userRequest: step.description,
            onStepUpdate: (toolStep) {
              if (!mounted) return;
              setState(() {
                final existIdx = _toolCallSteps.indexWhere(
                  (s) => identical(s.sourceStep, toolStep),
                );
                final widget = _ToolCallStep(
                  sourceStep: toolStep,
                  title: toolStep.title,
                  content: toolStep.content,
                  isLoading: toolStep.isLoading,
                  isSkip: toolStep.isSkip,
                  isFailed: toolStep.isFailed,
                  timestamp: toolStep.timestamp,
                );
                if (existIdx >= 0) {
                  _toolCallSteps[existIdx] = widget;
                } else {
                  _toolCallSteps.add(widget);
                }
              });
              _scrollToBottom();
            },
          );
          stepResult = loopResult.text;
        } else {
          // 纯文本回复 → 流式输出
          final streamBuffer = StringBuffer();
          await for (final chunk in llmManager.chatStreamWithMessages(messages, tools: tools)) {
            if (!mounted) break;
            if (_cancellationToken?.isCancelled ?? false) break;
            streamBuffer.write(chunk);
            setState(() => _streamingContent = streamBuffer.toString());
            _scrollToBottom();
          }
          if (_cancellationToken?.isCancelled ?? false) {
            throw CancelledException();
          }
          stepResult = streamBuffer.toString();
        }
        
        // 标记步骤完成
        setState(() {
          step.complete(stepResult);
          _streamingContent = '';
        });
      }
      
      // 全部完成 → 输出最终结果
      if (mounted) {
        final lastResult = plan.steps.lastWhere(
          (s) => s.status == PlanStepStatus.completed,
          orElse: () => plan.steps.last,
        ).result ?? '计划执行完成';
        
        setState(() {
          _messages.add(_ChatMessage(
            content: lastResult,
            isUser: false,
            timestamp: DateTime.now(),
            toolSteps: List.unmodifiable(_toolCallSteps),
          ));
          _toolCallSteps.clear();
        });
        _saveChatHistory();
      }
    } catch (e) {
      // 标记当前执行中的步骤为失败
      final runningStep = plan.steps.where((s) => s.status == PlanStepStatus.running).firstOrNull;
      if (runningStep != null) {
        setState(() => runningStep.fail('$e'));
      }
      
      if (mounted) {
        setState(() {
          _messages.add(_ChatMessage(
            content: '❌ 计划执行出错: $e',
            isUser: false,
            timestamp: DateTime.now(),
            isError: true,
          ));
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _streamingContent = '';
          _cancellationToken = null;
          // 执行完的 Plan 保留在列表中（显示完成状态），不自动移除
          // 用户可手动关闭
        });
        if (!widget.workMode) petEngine.stopWorking();
      }
    }
  }

  /// 从当前会话加载消息（工作模式）
  void _loadConversationMessages() {
    if (_conversationManager == null || _currentConversationId == null) return;

    final conversation = _conversationManager!.conversations
        .firstWhere((c) => c.id == _currentConversationId);

    setState(() {
      _messages.clear();
      _messages.addAll(conversation.messages.map((m) => _ChatMessage(
        content: m.content,
        isUser: m.isUser,
        timestamp: m.timestamp,
        skillResult: m.skillResult,
        isError: m.isError,
        attachments: m.attachments,
        apiMessages: m.apiMessages,
      )));

      // 如果没有历史消息，添加欢迎消息
      if (_messages.isEmpty) {
        _messages.add(_ChatMessage(
          content: '嘎~ 鹅宝来啦！你想聊什么呀？双击鹅宝或者直接打字都可以哦~ 🦢',
          isUser: false,
          timestamp: DateTime.now(),
        ));
      }
    });

    // 切换会话时立即跳到底部
    _scrollToBottom(jump: true);
    Future.delayed(const Duration(milliseconds: 50), () {
      if (mounted) _scrollToBottom(jump: true);
    });
  }

  /// 尝试读取文件内容（只读取文本文件，最多读取前 2000 字符）
  String? _tryReadFileContent(String path) {
    try {
      final file = File(path);
      if (!file.existsSync()) return null;
      final size = file.lengthSync();
      if (size > 512 * 1024) return null; // > 512KB 不读取
      final content = file.readAsStringSync();
      if (content.length > 2000) {
        return '${content.substring(0, 2000)}\n... (文件内容过长，已截断)';
      }
      return content;
    } catch (_) {
      return null; // 非文本文件或读取失败
    }
  }

  /// 会话列表（工作模式）
  Widget _buildConversationList() {
    if (_conversationManager == null) {
      return const Center(child: CircularProgressIndicator());
    }

    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFFFFFFFF),
        border: Border(right: BorderSide(color: Color(0xFFE0E0E0), width: 0.5)),
      ),
      child: Column(
        children: [
          // 标题栏
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: Color(0xFFE0E0E0), width: 0.5)),
            ),
            child: Row(
              children: [
                const Text(
                  '会话列表',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                ),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.add, size: 18),
                  onPressed: _createNewConversation,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  tooltip: '新建会话',
                ),
              ],
            ),
          ),
          // 会话列表
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(vertical: 4),
              itemCount: _conversationManager!.conversations.length,
              itemBuilder: (context, index) {
                final conversation = _conversationManager!.conversations[index];
                final isActive = conversation.id == _currentConversationId;
                
                // 获取最后一条消息
                final lastMessage = conversation.messages.isNotEmpty
                    ? conversation.messages.last.content
                    : '暂无消息';
                
                // 格式化时间
                final now = DateTime.now();
                final diff = now.difference(conversation.updatedAt);
                String timeStr;
                if (diff.inMinutes < 1) {
                  timeStr = '刚刚';
                } else if (diff.inHours < 1) {
                  timeStr = '${diff.inMinutes}分钟前';
                } else if (diff.inDays < 1) {
                  timeStr = '${diff.inHours}小时前';
                } else if (diff.inDays < 7) {
                  timeStr = '${diff.inDays}天前';
                } else {
                  timeStr = '${conversation.updatedAt.month}/${conversation.updatedAt.day}';
                }
                
                return _ConversationItem(
                  title: conversation.title,
                  lastMessage: lastMessage,
                  time: timeStr,
                  isActive: isActive,
                  onTap: () => _switchConversation(conversation.id),
                  onDelete: () => _deleteConversation(conversation.id),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  /// 新建会话
  void _createNewConversation() async {
    if (_conversationManager == null) return;
    
    final newId = await _conversationManager!.createConversation('新会话 ${_conversationManager!.conversations.length + 1}');
    setState(() {
      _currentConversationId = newId;
      _messages.clear();
    });
  }

  /// 切换会话
  void _switchConversation(String conversationId) {
    if (_currentConversationId == conversationId) return;
    
    _conversationManager!.switchConversation(conversationId);
    setState(() {
      _currentConversationId = conversationId;
    });
    _loadConversationMessages();
  }

  /// 删除会话
  void _deleteConversation(String conversationId) {
    if (_conversationManager == null) return;
    if (_conversationManager!.conversations.length <= 1) {
      // 至少保留一个会话
      return;
    }
    
    _conversationManager!.deleteConversation(conversationId);
    
    // 如果删除的是当前会话，切换到第一个会话
    if (_currentConversationId == conversationId) {
      final firstConv = _conversationManager!.conversations.first;
      setState(() {
        _currentConversationId = firstConv.id;
      });
      _loadConversationMessages();
    } else {
      setState(() {});
    }
  }
}

/// 打字指示动画点
class _TypingDot extends StatefulWidget {
  final int delay;

  // ignore: unused_element
  const _TypingDot({required this.delay});

  @override
  State<_TypingDot> createState() => _TypingDotState();
}

class _TypingDotState extends State<_TypingDot> with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _animation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _animation = Tween<double>(begin: 0, end: -6).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
    );

    Future.delayed(Duration(milliseconds: widget.delay), () {
      if (mounted) _controller.repeat(reverse: true);
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _animation,
      builder: (context, child) {
        return Transform.translate(
          offset: Offset(0, _animation.value),
          child: Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: Colors.grey.shade400,
              shape: BoxShape.circle,
            ),
          ),
        );
      },
    );
  }
}

/// 聊天消息数据
class _ChatMessage {
  final String content;
  final bool isUser;
  final DateTime timestamp;
  final String? skillResult;
  final bool isError;
  final List<MessageAttachment> attachments;
  /// 工具调用步骤记录（保留在消息中供用户查看完整过程）
  final List<_ToolCallStep> toolSteps;

  /// 工具调用期间产生的 API 消息序列（assistant tool_calls + tool results）
  /// 用于多轮会话时重建完整的消息历史，让 LLM 能看到之前的工具调用上下文
  /// 仅 assistant 消息在涉及 tool_calls 时才有值
  final List<Map<String, dynamic>>? apiMessages;

  /// 团队消息（用于标识来自哪个 Agent）
  final TeamMessage? teamMessage;

  _ChatMessage({
    required this.content,
    required this.isUser,
    required this.timestamp,
    this.skillResult,
    this.isError = false,
    this.attachments = const [],
    this.toolSteps = const [],
    this.apiMessages,
    this.teamMessage,
  });
}

/// 工具调用中间步骤（实时显示）
class _ToolCallStep {
  /// 原始 ToolStep 引用（用于 identity 匹配，避免重复添加）
  final Object? sourceStep;
  final String title;
  final String content;
  final bool isLoading;
  final bool isSkip;
  final bool isFailed;
  final DateTime timestamp;

  _ToolCallStep({
    this.sourceStep,
    required this.title,
    required this.content,
    this.isLoading = false,
    this.isSkip = false,
    this.isFailed = false,
    required this.timestamp,
  });
}

/// 工具调用步骤摘要组件（可展开/折叠）
class _ToolStepsSummary extends StatefulWidget {
  final List<_ToolCallStep> steps;
  const _ToolStepsSummary({required this.steps});

  @override
  State<_ToolStepsSummary> createState() => _ToolStepsSummaryState();
}

class _ToolStepsSummaryState extends State<_ToolStepsSummary> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    // 统计步骤结果
    final successCount = widget.steps.where((s) => !s.isFailed && !s.isSkip).length;
    final failedCount = widget.steps.where((s) => s.isFailed).length;
    final skippedCount = widget.steps.where((s) => s.isSkip).length;

    // 构建摘要文字
    final parts = <String>[];
    if (successCount > 0) parts.add('$successCount 步完成');
    if (failedCount > 0) parts.add('$failedCount 步失败');
    if (skippedCount > 0) parts.add('$skippedCount 步跳过');

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 折叠头部
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            borderRadius: BorderRadius.circular(8),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.grey.shade100,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.grey.shade300, width: 0.5),
              ),
              child: Row(
                children: [
                  Icon(
                    _expanded ? Icons.expand_less : Icons.expand_more,
                    size: 16,
                    color: Colors.grey.shade600,
                  ),
                  const SizedBox(width: 6),
                  Icon(Icons.build_circle_outlined, size: 14, color: Colors.blue.shade400),
                  const SizedBox(width: 4),
                  Text(
                    '执行过程 (${parts.join(', ')})',
                    style: TextStyle(
                      fontSize: 11,
                      color: Colors.grey.shade700,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
          ),
          // 展开的步骤详情
          if (_expanded) ...[
            const SizedBox(height: 4),
            ...widget.steps.map((step) => _buildStepItem(step)),
          ],
        ],
      ),
    );
  }

  Widget _buildStepItem(_ToolCallStep step) {
    return _StepItemWidget(step: step);
  }
}

/// 单个工具调用步骤（支持内容折叠/展开）
class _StepItemWidget extends StatefulWidget {
  final _ToolCallStep step;
  const _StepItemWidget({required this.step});

  @override
  State<_StepItemWidget> createState() => _StepItemWidgetState();
}

class _StepItemWidgetState extends State<_StepItemWidget> {
  bool _contentExpanded = false;
  static const int _previewLines = 3;

  @override
  void didUpdateWidget(covariant _StepItemWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 正在执行中 → 自动展开，让用户看到实时输出
    if (widget.step.isLoading && !oldWidget.step.isLoading) {
      _contentExpanded = true;
    }
    // 执行结束 → 自动折叠，节省空间
    if (!widget.step.isLoading && oldWidget.step.isLoading) {
      _contentExpanded = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final step = widget.step;
    final iconColor = step.isFailed
        ? Colors.red.shade400
        : step.isSkip
            ? Colors.orange.shade400
            : Colors.green.shade400;

    final bgColor = step.isFailed
        ? Colors.red.shade50
        : step.isSkip
            ? Colors.orange.shade50
            : Colors.blue.shade50;

    final borderColor = step.isFailed
        ? Colors.red.shade200
        : step.isSkip
            ? Colors.orange.shade200
            : Colors.blue.shade200;

    // 计算内容行数，决定是否需要折叠
    final contentLines = step.content.split('\n');
    final needsCollapse = contentLines.length > _previewLines && !_contentExpanded;
    final displayContent = needsCollapse
        ? contentLines.take(_previewLines).join('\n')
        : step.content;

    return Container(
      margin: const EdgeInsets.only(bottom: 3, left: 4),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: borderColor, width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                step.isFailed ? Icons.close : step.isSkip ? Icons.skip_next : Icons.check_circle,
                size: 13,
                color: iconColor,
              ),
              const SizedBox(width: 6),
              Text(
                step.title,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: step.isFailed
                      ? Colors.red.shade700
                      : step.isSkip
                          ? Colors.orange.shade700
                          : Colors.blue.shade700,
                ),
              ),
              // 加载中指示器
              if (step.isLoading) ...[
                const SizedBox(width: 8),
                SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.5,
                    color: Colors.blue.shade400,
                  ),
                ),
              ],
            ],
          ),
          if (step.content.isNotEmpty) ...[
            const SizedBox(height: 4),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SelectableText(
                    displayContent,
                    style: TextStyle(
                      fontSize: 11,
                      color: Colors.grey.shade800,
                      height: 1.4,
                    ),
                  ),
                  // 折叠/展开按钮
                  if (contentLines.length > _previewLines)
                    InkWell(
                      onTap: () => setState(() => _contentExpanded = !_contentExpanded),
                      borderRadius: BorderRadius.circular(4),
                      child: Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              _contentExpanded ? Icons.expand_less : Icons.expand_more,
                              size: 14,
                              color: Colors.grey.shade500,
                            ),
                            const SizedBox(width: 2),
                            Text(
                              _contentExpanded ? '收起' : '展开全部 (${contentLines.length} 行)',
                              style: TextStyle(
                                fontSize: 10,
                                color: Colors.grey.shade500,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 会话列表项
class _ConversationItem extends StatelessWidget {
  final String title;
  final String lastMessage;
  final String time;
  final bool isActive;
  final VoidCallback onTap;
  final VoidCallback? onDelete;

  const _ConversationItem({
    required this.title,
    required this.lastMessage,
    required this.time,
    required this.isActive,
    required this.onTap,
    this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: isActive ? const Color(0xFFE3F2FD) : Colors.transparent,
          border: Border(
            left: BorderSide(
              color: isActive ? const Color(0xFF4FC3F7) : Colors.transparent,
              width: 3,
            ),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: isActive ? FontWeight.w600 : FontWeight.normal,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (onDelete != null)
                  InkWell(
                    onTap: onDelete,
                    child: Padding(
                      padding: const EdgeInsets.all(4),
                      child: Icon(
                        Icons.close,
                        size: 14,
                        color: Colors.grey.shade400,
                      ),
                    ),
                  ),
                const SizedBox(width: 4),
                Text(
                  time,
                  style: TextStyle(fontSize: 10, color: Colors.grey.shade500),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              lastMessage,
              style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}

/// 头部按钮组件（带图标和文字标签）
class _HeaderButton extends StatelessWidget {
  final Widget icon;
  final String label;
  final VoidCallback? onPressed;
  final String? tooltip;
  final bool isActive;

  const _HeaderButton({
    required this.icon,
    required this.label,
    this.onPressed,
    this.tooltip,
    this.isActive = false,
  });

  @override
  Widget build(BuildContext context) {
    final button = InkWell(
      onTap: onPressed,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: isActive
            ? BoxDecoration(
                color: Colors.black.withOpacity(0.05),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.black.withOpacity(0.1)),
              )
            : null,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            icon,
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                color: isActive ? Colors.black87 : Colors.grey,
                fontWeight: isActive ? FontWeight.w600 : FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );

    if (tooltip != null) {
      return Tooltip(message: tooltip!, child: button);
    }
    return button;
  }
}


