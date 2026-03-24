import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';
import '../../ai/llm_manager.dart';
import '../../ai/agent/agent_types.dart';
import '../../ai/agent/agent_loop.dart';
import '../../ai/memory/memory_manager.dart';
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

    _initializeMode();
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
    if (!_isLoading || _cancellationToken == null) return;
    _cancellationToken!.cancel();
    debugPrint('🛑 用户取消了当前会话');
  }

  Future<void> _sendMessage() async {
    final text = _inputController.text.trim();
    final attachments = List<MessageAttachment>.from(_pendingAttachments);
    if (text.isEmpty && attachments.isEmpty) return;
    if (_isLoading) return;

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

      // 获取记忆上下文（首次发送消息时触发衰减清理）
      memoryManager.decayAndCleanup();
      final memoryContext = memoryManager.getMemoryContext(text);

      // 获取 self-improvement 学习策略上下文
      final improvementContext = selfImprove.getImprovementContext();

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

      // ── 情感记忆上下文 ──
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
      final agentSkillsPrompt = skillManager.getAgentSkillsPrompt();

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
      final pythonPath = await SkillFileUtils.detectPythonPath();
      final sessionId = _currentConversationId ?? DateTime.now().millisecondsSinceEpoch.toString();
      await SkillFileUtils.setSessionWorkingDir(sessionId);
      final workDir = SkillFileUtils.effectiveWorkingDir;
      final envPrompt = '\n\n## 运行环境'
          '\n- 操作系统: ${Platform.operatingSystem}'
          '\n- 当前工作目录: $workDir（每次对话独立，所有文件写在此目录下）'
          '\n- write_file 写文件：直接用文件名（如 script.py），不需要 ./ 前缀'
          '\n- shell_exec 执行脚本：用 command 参数，只写文件名，如 `command: "python my_script.py"`。**不要写完整路径**，系统在工作目录下自动找到。'
          '${pythonPath != null ? "\n- Python 绝对路径: `$pythonPath`，系统会自动使用，你无需指定" : ""}';

      final tools = skillManager.toFunctionTools();

      // 构建 system prompt
      String systemPrompt = widget.workMode
          ? GoosePrompts.workModeSystemPrompt
          : GoosePrompts.systemPrompt;
      if (effectiveMemoryContext.isNotEmpty) {
        systemPrompt += '\n\n## 关于主人的记忆\n$effectiveMemoryContext';
      }
      if (improvementContext.isNotEmpty) {
        systemPrompt += '\n\n$improvementContext';
      }
      if (agentSkillsPrompt.isNotEmpty) {
        systemPrompt += '\n\n$agentSkillsPrompt';
      }
      systemPrompt += envPrompt;

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

      // 调用 LLM（有工具调用历史时走 chatWithMessages 保留 API 字段）
      final response = hasToolMessages
          ? await llmManager.chatWithMessages(fullApiMessages, tools: tools)
          : await llmManager.chatWithMessages(fullApiMessages, tools: tools);

      if (response.hasToolCalls) {
        // 有 tool_calls → 进入 Agent 循环
        hasToolCalls = true;
        final loopResult = await AgentLoop.run(
          provider: llmManager.currentProvider!,
          config: llmManager.currentConfig,
          messages: fullApiMessages,
          tools: tools,
          executeTool: (call) => _executeTool(call, skillManager, workDir),
          cancellationToken: _cancellationToken,
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
          onToolFailure: (failedTool, summary, error, solution) {
            // 保存「失败+修复方案」到记忆系统
            try {
              if (mounted) {
                final memoryManager = context.read<MemoryManager>();
                memoryManager.saveFailureLesson(
                  skillId: failedTool,
                  summary: summary.length > 100 ? '${summary.substring(0, 100)}...' : summary,
                  error: error,
                  solution: solution,
                );
                debugPrint('🧠 失败经验已保存: $failedTool → $solution');
              }
            } catch (_) {}
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
        // 纯文本回复 → 模拟打字机效果
        fullResponse = await _typewriterEffect(response.text);
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
      // 用户主动取消会话
      if (!widget.workMode) {
        petEngine.stopWorking();
      }

      setState(() {
        _messages.add(_ChatMessage(
          content: '好的，鹅宝已经停下来了~ 🦢✋',
          isUser: false,
          timestamp: DateTime.now(),
        ));
        _streamingContent = '';
        _toolCallSteps.clear();
      });
      _saveChatHistory();
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
  Future<ToolResult> _executeTool(ToolCall call, SkillManager skillManager, String workDir) async {
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

      final execResult = await skillManager.execute(skillId, args);
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

  /// 模拟打字机效果
  Future<String> _typewriterEffect(String text) async {
    final chars = text.runes.toList();
    const chunkSize = 3;
    String current = '';
    for (int i = 0; i < chars.length; i += chunkSize) {
      if (!mounted) break;
      final end = (i + chunkSize > chars.length) ? chars.length : i + chunkSize;
      current = String.fromCharCodes(chars.sublist(0, end));
      setState(() => _streamingContent = current);
      _scrollToBottom();
      await Future.delayed(const Duration(milliseconds: 8));
    }
    return current;
  }

 

  /// 构建对话历史的 API 消息列表
  /// 对于有 apiMessages（工具调用记录）的 assistant 消息，展开为 assistant(tool_calls) + tool(results) + assistant(final_reply) 序列
  /// 对于普通消息，构建标准的 user/assistant 消息
  /// [messageContent] 最后一条用户消息的实际内容（可能包含附件信息）
  /// [originalText] 用户原始输入文本
  ///
  /// Token 预算控制：
  /// - 总消息列表不超过 [maxMessages] 条（约 40 条 user/assistant 消息 ≈ 20 轮对话）
  /// - 过早的 apiMessages 序列会被整体丢弃（只保留最近 2 组），避免 token 爆炸
  List<Map<String, dynamic>> _buildChatApiHistory(String messageContent, String originalText) {
    final apiHistory = <Map<String, dynamic>>[];
    const maxMessages = 60; // 最多保留 60 条消息
    const maxApiMessageGroups = 2; // 最多保留最近 2 组 apiMessages（更早的用纯文本替代）

    // 第一遍：收集所有消息，计算总条数
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
          // 标记这是一个 apiMessage 组
          allEntries.add({'_type': 'api_group', '_index': i, '_apiMessages': m.apiMessages, '_content': m.content, '_groupIndex': apiMessageGroupCount});
        } else {
          allEntries.add({'role': 'assistant', 'content': m.content, '_index': i});
        }
      }
    }

    // 第二遍：构建最终列表，对超出预算的部分进行裁剪
    // 策略：保留最后的消息，较早的 apiMessage 组替换为纯文本摘要
    final totalApiGroups = apiMessageGroupCount;

    for (final entry in allEntries) {
      if (entry['_type'] == 'api_group') {
        final groupIndex = entry['_groupIndex'] as int;
        final apiMessages = entry['_apiMessages'] as List<Map<String, dynamic>>;
        final finalContent = entry['_content'] as String?;

        // 如果这是较早的 apiMessage 组（超出保留数量），替换为摘要
        if (totalApiGroups - groupIndex >= maxApiMessageGroups) {
          // 提取工具名和简要结果作为摘要
          final toolNames = <String>[];
          for (final msg in apiMessages) {
            if (msg['role'] == 'assistant' && msg['tool_calls'] != null) {
              for (final tc in msg['tool_calls'] as List) {
                final fn = tc['function'] as Map<String, dynamic>;
                toolNames.add(fn['name'] as String);
              }
            }
          }
          final summary = '（历史工具调用：${toolNames.join(', ')}，结果已省略）';
          if (finalContent != null && finalContent.isNotEmpty) {
            // 保留最终回复，标注省略了中间工具调用
            apiHistory.add({'role': 'assistant', 'content': '$summary\n\n$finalContent'});
          } else {
            apiHistory.add({'role': 'assistant', 'content': summary});
          }
        } else {
          // 保留完整的 apiMessage 序列（最近的几组）
          for (final apiMsg in apiMessages) {
            apiHistory.add(Map<String, dynamic>.from(apiMsg));
          }
          if (finalContent != null && finalContent.isNotEmpty) {
            apiHistory.add({'role': 'assistant', 'content': finalContent});
          }
        }
      } else {
        apiHistory.add({
          'role': entry['role'] as String,
          'content': entry['content'],
        });
      }
    }

    // 如果总消息数超限，从头部裁剪（保留 system prompt 和最后 N 条）
    // 注意：chat_panel 会在前面加 system prompt，所以这里只保留用户/assistant 消息
    if (apiHistory.length > maxMessages) {
      final trimmed = apiHistory.sublist(apiHistory.length - maxMessages);
      return trimmed;
    }

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
    if (msg.toolSteps.isEmpty) {
      return RichMessageBubble(
        content: msg.content,
        isUser: msg.isUser,
        timestamp: msg.timestamp,
        isError: msg.isError,
        skillResult: msg.skillResult,
        attachments: msg.attachments,
        fontSize: _chatFontSize,
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 工具调用步骤列表（折叠式）
        _buildToolStepsSummary(msg.toolSteps),
        const SizedBox(height: 4),
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

  /// 构建工具调用步骤摘要（可展开/折叠）
  Widget _buildToolStepsSummary(List<_ToolCallStep> steps) {
    return _ToolStepsSummary(steps: steps);
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
              '鹅宝在思考...',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
            ),
          ],
        ),
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

  _ChatMessage({
    required this.content,
    required this.isUser,
    required this.timestamp,
    this.skillResult,
    this.isError = false,
    this.attachments = const [],
    this.toolSteps = const [],
    this.apiMessages,
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
              child: SelectableText(
                step.content,
                style: TextStyle(
                  fontSize: 11,
                  color: Colors.grey.shade800,
                  height: 1.4,
                ),
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


