import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';
import '../../core/pet_engine.dart';
import '../../core/achievement_manager.dart';
import '../../ai/llm_manager.dart';
import '../../ai/memory/memory_manager.dart';
import '../../ai/prompts.dart';
import '../../models/models.dart';
import '../../services/weather_service.dart';
import '../../services/smart_care_context.dart';
import '../../services/diary_service.dart';
import '../../skills/skill_manager.dart';
import '../../skills/scheduled_task.dart';
import '../../utils/storage.dart';
import '../chat/chat_panel.dart';
import '../chat/conversation_manager.dart';
import '../settings/settings_panel.dart';
import '../shop/shop_panel.dart';
import '../achievement/achievement_panel.dart';

import '../widgets/tray_manager.dart';
import '../widgets/firework_celebration.dart';
import '../diary/diary_panel.dart';
import 'pet_canvas.dart';

/// 宠物主窗口 - 组合鹅宝画布+交互逻辑
class PetWindow extends StatefulWidget {
  const PetWindow({super.key});

  @override
  State<PetWindow> createState() => _PetWindowState();
}

class _PetWindowState extends State<PetWindow> with TickerProviderStateMixin, WindowListener {
  bool _showChat = false;
  bool _showSettings = false;
  bool _showMenu = false;
  bool _showShop = false;
  bool _showPetStats = false;
  bool _showAchievements = false;
  bool _showDiary = false;

  /// 原生层鼠标穿透通道
  static const _hitTestChannel = MethodChannel('goose_baby/hit_test');

  /// 烟花庆祝动画状态
  bool _showFirework = false;
  String _fireworkAchievementName = '';
  String _fireworkAchievementIcon = '';

  /// 鼠标是否悬浮在宠物区域上（用于控制名字和进度条显示）
  bool _isHovering = false;

  /// 鼠标是否悬浮在菜单上
  bool _isMenuHovering = false;

  /// 菜单延迟隐藏定时器
  Timer? _menuHideTimer;

  /// 宠物说话气泡
  String? _bubbleText;
  Timer? _bubbleTimer;
  late AnimationController _bubbleAnimController;
  late Animation<double> _bubbleSlideAnimation;
  late Animation<double> _bubbleFadeAnimation;

  /// 聊天面板宽度（屏幕宽度 * 0.618 - 宠物区域宽度，最小 400，最大 800）
  double get _chatPanelWidth {
    final screenW = _screenSize.width;
    final w = screenW * 0.618 - _petWindowWidth;
    return w.clamp(400.0, 800.0);
  }
  /// 聊天面板工作模式宽度（屏幕宽度 * 0.618，最小 650，最大 1100）
  double get _chatPanelWorkWidth {
    final screenW = _screenSize.width;
    final w = screenW * 0.618;
    return w.clamp(650.0, 1100.0);
  }
  /// 商店面板宽度（屏幕宽度 * 0.382 - 宠物区域宽度，最小 380，最大 600）
  double get _shopPanelWidth {
    final screenW = _screenSize.width;
    final w = screenW * 0.382 - _petWindowWidth + 500;
    return w.clamp(380.0, 600.0);
  }
  /// 设置面板宽度（稍大以容纳更多内容，最小 480，最大 780）
  double get _settingsPanelWidth {
    final screenW = _screenSize.width;
    final w = screenW * 0.45 - _petWindowWidth + 600;
    return w.clamp(480.0, 780.0);
  }
  /// 日记面板宽度（比商店面板更大，最小 500，最大 750）
  double get _diaryPanelWidth {
    final screenW = _screenSize.width;
    final w = screenW * 0.45 - _petWindowWidth + 600;
    return w.clamp(500.0, 750.0);
  }
  /// 宠物区域原始窗口宽度（菜单栏宽度，功能栏在下方横排）
  static const double _petWindowWidth = 220;
  /// 宠物区域原始窗口高度（气泡 + 视频 + 底部空间）
  // ignore: unused_field
  static const double _petWindowHeight = 400;
  /// 面板窗口高度（屏幕高度 * 0.618，最小 550，最大 900）
  double get _panelWindowHeight {
    final screenH = _screenSize.height;
    final h = screenH * 0.618;
    return h.clamp(550.0, 900.0);
  }


  /// 缓存的屏幕尺寸
  Size _screenSize = const Size(1920, 1080); // 默认回退值

  /// 当前左侧面板扩展的宽度（用于窗口调整）
  double _currentExpandWidth = 0;

  /// 初始窗口高度（不带面板时的高度，通常是屏幕高度的 0.618）
  double _initialWindowHeight = 450;

  /// 聊天模式：false=休闲模式，true=工作模式
  /// 默认工作模式，提供更专业的AI助手体验
  bool _chatWorkMode = true;

  // 功能栏滑入/滑出动画
  late AnimationController _menuAnimController;
  late Animation<double> _menuSlideAnimation;
  late Animation<double> _menuFadeAnimation;

  // 状态条/名字淡入淡出动画
  late AnimationController _hoverAnimController;
  late Animation<double> _hoverFadeAnimation;

  /// ChatPanel 的 GlobalKey（用于调用 addProactiveMessage）
  final GlobalKey<dynamic> _chatPanelKey = GlobalKey();

  /// PetCanvas 的 GlobalKey（确保动画不因 widget 树变化而重建）
  final GlobalKey _petCanvasKey = GlobalKey();

  /// 通知原生层当前"活跃内容区域"的矩形列表
  /// 鼠标在这些区域内可点击，在区域外穿透到桌面
  Future<void> _updateHitRects() async {
    try {
      final size = await windowManager.getSize();
      final rects = <Map<String, double>>[];
      final anyPanel = _showChat || _showShop || _showSettings ||
          _showPetStats || _showAchievements || _showDiary;

      if (anyPanel) {
        // 面板打开时，整个窗口都响应点击
        rects.add({
          'left': 0, 'top': 0,
          'right': size.width, 'bottom': size.height,
        });
      } else {
        // 宠物视频区域（往左偏移 10px，上方 30px 穿透）
        final petWidth = 157.0;
        rects.add({
          'left': size.width - petWidth - 25,
          'top': size.height - 220,  // 50 + 280 - 30 = 300（上方 30px 可点击穿透）
          'right': size.width - 60,
          'bottom': size.height - 30,
        });
        // 功能栏（底部横排）
        if (_showMenu) {
          rects.add({
            'left': 0,
            'top': size.height - 50,
            'right': size.width,
            'bottom': size.height,
          });
        }
      }

      debugPrint('🦢 HitRects: window=${size.width}x${size.height}, rects=$rects');
      await _hitTestChannel.invokeMethod('setHitRects', rects);
    } catch (e) {
      debugPrint('🦢 更新 hit rects 失败: $e');
    }
  }

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);

    _menuAnimController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 250),
    );
    _menuSlideAnimation = Tween<double>(begin: 20, end: 0).animate(
      CurvedAnimation(parent: _menuAnimController, curve: Curves.easeOutCubic),
    );
    _menuFadeAnimation = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(parent: _menuAnimController, curve: Curves.easeOut),
    );

    _hoverAnimController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    );
    _hoverFadeAnimation = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(parent: _hoverAnimController, curve: Curves.easeOut),
    );

    // 说话气泡动画
    _bubbleAnimController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    _bubbleSlideAnimation = Tween<double>(begin: -20, end: 0).animate(
      CurvedAnimation(parent: _bubbleAnimController, curve: Curves.easeOutCubic),
    );
    _bubbleFadeAnimation = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(parent: _bubbleAnimController, curve: Curves.easeOut),
    );

    // 设置引擎回调
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      // 获取屏幕尺寸用于面板自适应
      final mediaQuery = MediaQuery.of(context);
      _screenSize = mediaQuery.size;

      // 获取初始窗口高度（用于关闭面板时恢复）
      try {
        final size = await windowManager.getSize();
        _initialWindowHeight = size.height;
        _currentPanelHeight = size.height;
      } catch (_) {}

      // 设置日记服务的 LLM 回调（用于定时生成日记）
      try {
        final llmManager = context.read<LLMManager>();
        DiaryService.instance.setLlmCallback((systemPrompt, userMessage) async {
          final messages = [
            {'role': 'system', 'content': systemPrompt},
            {'role': 'user', 'content': userMessage},
          ];
          return await llmManager.chatRaw(messages);
        });
      } catch (e) {
        debugPrint('🦢 设置日记 LLM 回调失败: $e');
      }

      final engine = context.read<PetEngine>();

      // 主动搭话回调 → LLM 生成个性化内容
      engine.onProactiveMessage = (message) {
        if (mounted) {
          _generateCareMessage(message);
        }
      };

      // 里程碑回调 → 显示气泡
      engine.onMilestone = (message, type) {
        if (mounted) {
          _showBubble(message);
        }
      };

      // 主动情绪表达回调 → LLM 生成个性化内容
      engine.onEmotionalBehavior = (emotionType, sceneHint) {
        if (mounted) {
          _generateEmotionalBubble(emotionType, sceneHint);
        }
      };

      // 升级回调
      engine.onLevelUp = (newLevel) {
        if (mounted) {
          _showLevelUpNotification(newLevel);
        }
      };

      // 系统托盘菜单回调
      TrayManager.onShowChat = () {
        if (mounted && !_showChat) _togglePanel('chat');
      };
      TrayManager.onShowShop = () {
        if (mounted && !_showShop) _togglePanel('shop');
      };
      TrayManager.onShowSettings = () {
        if (mounted && !_showSettings) _togglePanel('settings');
      };

      // 健康提醒回调 → LLM 生成个性化提醒（message 包含时间段动态提示）
      engine.onHealthReminder = (message) {
        if (mounted) {
          _generateCareMessage('健康提醒：$message');
        }
      };

      // 定时任务执行回调 → LLM 生成个性化内容后通过气泡展示
      final taskManager = context.read<ScheduledTaskManager>();
      taskManager.onExecutePrompt = (prompt, taskTitle) {
        if (!mounted) return;
        _generateTaskBubble(prompt, taskTitle);
      };
      // 初始化定时任务管理器（打开存储、加载任务、启动定时检查）
      taskManager.initialize().catchError((e) {
        debugPrint('🦢 定时任务初始化失败: $e');
      });

      // 将定时任务管理器注入到 SkillManager，让 AI 可以通过对话创建定时任务
      final skillManager = context.read<SkillManager>();
      skillManager.setTaskManager(taskManager);

      // 成就系统回调
      final achievementMgr = context.read<AchievementManager>();
      // 将成就管理器绑定到 PetEngine
      engine.achievementManager = achievementMgr;
      // 初次同步状态
      achievementMgr.syncFromPetState(engine.state);
      // 成就解锁回调 → 播放烟花动画
      achievementMgr.onAchievementUnlocked = (achievement) {
        if (mounted) {
          _showAchievementCelebration(achievement);
        }
      };
    });
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    _menuAnimController.dispose();
    _hoverAnimController.dispose();
    _bubbleAnimController.dispose();
    _bubbleTimer?.cancel();
    _menuHideTimer?.cancel();
    super.dispose();
  }

  /// 显示宠物说话气泡
  void _showBubble(String message) {
    _bubbleTimer?.cancel();
    setState(() {
      _bubbleText = message;
    });
    _bubbleAnimController.forward(from: 0);

    // 5秒后自动消失
    _bubbleTimer = Timer(const Duration(seconds: 5), () {
      if (mounted) {
        _bubbleAnimController.reverse().then((_) {
          if (mounted) {
            setState(() => _bubbleText = null);
          }
        });
      }
    });
  }

  /// 调用 LLM 生成个性化关心语，显示在气泡中
  /// 融合天气、时间、日期、健康状态、最近对话等多维度上下文
  Future<void> _generateCareMessage(String careType) async {
    if (!mounted) return;
    try {
      final engine = context.read<PetEngine>();
      final llmManager = context.read<LLMManager>();
      final memoryManager = context.read<MemoryManager>();

      if (llmManager.isProcessing) return;

      // ═══════════════════════════════════════════
      // 1. 获取天气信息（异步，有缓存不会阻塞）
      // ═══════════════════════════════════════════
      final weather = await WeatherService.instance.getWeather();
      debugPrint('🌤️ 当前天气: ${weather?.brief}');

      // ═══════════════════════════════════════════
      // 2. 获取最近对话（在 await 后重新检查 mounted）
      // ═══════════════════════════════════════════
      List<String> recentUserMessages = [];
      List<String> recentAssistantMessages = [];
      if (!mounted) return;
      try {
        final convManager = context.read<ConversationManager>();
        final currentConv = convManager.currentConversation;
        if (currentConv != null && currentConv.messages.isNotEmpty) {
          // 取最近的几条消息
          final recentMessages = currentConv.messages.reversed.take(6).toList();
          for (final msg in recentMessages) {
            if (msg.isUser && recentUserMessages.length < 3) {
              // 截断过长的消息
              final content = msg.content.length > 50
                  ? '${msg.content.substring(0, 50)}...'
                  : msg.content;
              recentUserMessages.insert(0, content);
            } else if (!msg.isUser && recentAssistantMessages.length < 2) {
              final content = msg.content.length > 50
                  ? '${msg.content.substring(0, 50)}...'
                  : msg.content;
              recentAssistantMessages.insert(0, content);
            }
          }
        }
      } catch (e) {
        debugPrint('🦢 获取最近对话失败: $e');
      }

      // ═══════════════════════════════════════════
      // 3. 构建智能关怀上下文
      // ═══════════════════════════════════════════
      final smartContext = SmartCareContext(
        weather: weather,
        now: DateTime.now(),
        petHealth: engine.health,
        petEnergy: engine.energy,
        petHunger: engine.hunger,
        petMood: engine.happiness,
        companionDays: engine.state.companionDays,
        recentUserMessages: recentUserMessages,
        recentAssistantMessages: recentAssistantMessages,
      );

      final memoryContext = memoryManager.getMemoryContext(careType);
      final emotionalContext = memoryManager.getEmotionalContext();

      // ═══════════════════════════════════════════
      // 4. 使用智能关怀 Prompt
      // ═══════════════════════════════════════════
      final careContext = GoosePrompts.smartCareSystemPrompt(
        smartContext: smartContext.buildFullContext(),
        careType: careType,
        memoryContext: memoryContext,
        emotionalContext: emotionalContext,
      );

      final messages = [
        ChatMessage(
          id: DateTime.now().millisecondsSinceEpoch.toString(),
          role: 'user',
          content: '请根据当前情况说一句关心的话',
          timestamp: DateTime.now(),
        ),
      ];

      final response = await llmManager.chat(
        chatHistory: messages,
        memoryContext: careContext,
      );

      if (mounted && response.text.isNotEmpty) {
        final displayText = response.text.split('\n').first.trim();
        _showBubble(displayText);
      }
    } catch (e) {
      debugPrint('🦢 生成关心语失败: $e');
      if (mounted) {
        final fallbacks = GoosePrompts.healthReminderPrompts;
        _showBubble(fallbacks[DateTime.now().second % fallbacks.length]);
      }
    }
  }

  /// 鹅宝情绪表达 → LLM 生成个性化气泡内容
  /// [emotionType] 情绪类型：happy/sad/upset/seekAttention/hungry
  /// [sceneHint] 场景提示：描述当前情绪产生的原因
  Future<void> _generateEmotionalBubble(String emotionType, String sceneHint) async {
    if (!mounted) return;
    try {
      final engine = context.read<PetEngine>();
      final llmManager = context.read<LLMManager>();
      final memoryManager = context.read<MemoryManager>();

      if (llmManager.isProcessing) return;

      final stateContext = GoosePrompts.getStateContext(
        mood: engine.happiness,
        hunger: engine.hunger,
        energy: engine.energy,
        level: engine.state.level,
        companionDays: engine.state.companionDays,
        companionRhythm: engine.getCompanionRhythm(),
      );

      final memoryContext = memoryManager.getMemoryContext('情绪表达');

      // 构建情绪类型到语气描述的映射
      String toneGuide;
      switch (emotionType) {
        case 'happy':
          toneGuide = '开心、活泼、撒娇，表达喜悦';
          break;
        case 'sad':
        case 'upset':
          toneGuide = '有点委屈、低落，但不失可爱';
          break;
        case 'seekAttention':
          toneGuide = '撒娇、求关注、卖萌';
          break;
        case 'hungry':
          toneGuide = '撒娇、可怜巴巴、求投喂';
          break;
        default:
          toneGuide = '自然、可爱';
      }

      final emotionContext = GoosePrompts.careMessageSystemPrompt(
        stateContext: stateContext,
        memoryContext: memoryContext,
        careType: '情绪表达：$sceneHint（语气：$toneGuide）',
        emotionalContext: memoryManager.getEmotionalContext(),
      );

      final messages = [
        ChatMessage(
          id: DateTime.now().millisecondsSinceEpoch.toString(),
          role: 'user',
          content: '请用鹅宝的口吻，根据当前情绪说一句话（25字以内），不要用引号',
          timestamp: DateTime.now(),
        ),
      ];

      final response = await llmManager.chat(
        chatHistory: messages,
        memoryContext: emotionContext,
      );

      if (mounted && response.text.isNotEmpty) {
        final displayText = response.text.split('\n').first.trim();
        _showBubble(displayText);
      }
    } catch (e) {
      debugPrint('🦢 生成情绪表达失败: $e');
      // 失败时使用简单回退
      if (mounted) {
        final fallbacks = {
          'happy': '嘿嘿~ 鹅宝好开心呀！✨',
          'sad': '呜...鹅宝有点难过...',
          'upset': '鹅宝不开心了哼~',
          'seekAttention': '主人~ 看看鹅宝嘛 🥺',
          'hungry': '主人...鹅宝肚子饿饿...',
        };
        _showBubble(fallbacks[emotionType] ?? '嘎~');
      }
    }
  }

  /// 定时任务触发时，用 LLM 根据任务 prompt 生成气泡内容
  Future<void> _generateTaskBubble(String prompt, String taskTitle) async {
    if (!mounted) return;
    try {
      final engine = context.read<PetEngine>();
      final llmManager = context.read<LLMManager>();
      final memoryManager = context.read<MemoryManager>();

      if (llmManager.isProcessing) return;

      final stateContext = GoosePrompts.getStateContext(
        mood: engine.happiness,
        hunger: engine.hunger,
        energy: engine.energy,
        level: engine.state.level,
        companionDays: engine.state.companionDays,
        companionRhythm: engine.getCompanionRhythm(),
      );
      final memoryContext = memoryManager.getMemoryContext('定时任务');
      final taskContext = GoosePrompts.careMessageSystemPrompt(
        stateContext: stateContext,
        memoryContext: memoryContext,
        careType: '定时任务提醒：$prompt',
        emotionalContext: memoryManager.getEmotionalContext(),
      );

      final messages = [
        ChatMessage(
          id: DateTime.now().millisecondsSinceEpoch.toString(),
          role: 'user',
          content: '请根据任务"$taskTitle"($prompt)，用可爱的语气说一句话提醒或关心主人，30字以内',
          timestamp: DateTime.now(),
        ),
      ];

      final response = await llmManager.chat(
        chatHistory: messages,
        memoryContext: taskContext,
      );

      if (mounted && response.text.isNotEmpty) {
        final displayText = response.text.split('\n').first.trim();
        _showBubble(displayText);
      }
    } catch (e) {
      debugPrint('🦢 定时任务生成气泡失败: $e');
      if (mounted) {
        _showBubble('📋 $taskTitle');
      }
    }
  }

  /// 显示升级通知
  void _showLevelUpNotification(int newLevel) {
    if (!mounted) return;

    showDialog(
      context: context,
      barrierColor: Colors.black38,
      builder: (ctx) => Center(
        child: TweenAnimationBuilder<double>(
          tween: Tween(begin: 0.0, end: 1.0),
          duration: const Duration(milliseconds: 500),
          curve: Curves.elasticOut,
          builder: (context, value, child) {
            return Transform.scale(
              scale: value,
              child: child,
            );
          },
          child: Container(
            width: 280,
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xFFFFF8E1), Color(0xFFFFECB3)],
              ),
              borderRadius: BorderRadius.circular(24),
              boxShadow: [
                BoxShadow(
                  color: Colors.orange.withOpacity(0.3),
                  blurRadius: 20,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('🎉', style: TextStyle(fontSize: 48)),
                const SizedBox(height: 12),
                const Text(
                  '鹅宝升级啦！',
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Color(0xFFFF8F00)),
                ),
                const SizedBox(height: 8),
                Text(
                  'Lv.$newLevel',
                  style: const TextStyle(fontSize: 36, fontWeight: FontWeight.bold, color: Color(0xFFFF6F00)),
                ),
                const SizedBox(height: 8),
                Text(
                  '嘎嘎嘎~ 鹅宝变得更强了！',
                  style: TextStyle(fontSize: 14, color: Colors.orange.shade700),
                ),
                const SizedBox(height: 16),
                ElevatedButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFFF8F00),
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  child: const Text('太棒了！'),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    // 3秒后自动关闭
    Future.delayed(const Duration(seconds: 3), () {
      if (mounted && Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      }
    });
  }

  /// 显示成就达成庆祝动画（烟花）
  void _showAchievementCelebration(Achievement achievement) {
    if (!mounted) return;
    setState(() {
      _showFirework = true;
      _fireworkAchievementName = achievement.name;
      _fireworkAchievementIcon = achievement.icon;
    });

    // 发放成就奖励（金币+经验）
    if (achievement.rewardCoins > 0 || achievement.rewardExp > 0) {
      final engine = context.read<PetEngine>();
      engine.grantAchievementReward(
        coins: achievement.rewardCoins,
        exp: achievement.rewardExp,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final engine = context.watch<PetEngine>();

    // 每次 rebuild 后更新原生层的鼠标穿透区域
    WidgetsBinding.instance.addPostFrameCallback((_) => _updateHitRects());

    return Material(
      type: MaterialType.transparency,
      child: Stack(
        clipBehavior: Clip.none,  // 允许菜单栏和气泡溢出窗口边界
        children: [
          // ══════ 气泡（穿透点击，仅展示） ══════
          if (_bubbleText != null)
            Positioned(
              right: 0,
              bottom: 270, // 往下移动80px
              child: IgnorePointer(
                child: SizedBox(
                  width: _petWindowWidth + 100, // 气泡可以往左溢出
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: Padding(
                      padding: const EdgeInsets.only(right: 0),
                      child: AnimatedBuilder(
                        animation: _bubbleAnimController,
                        builder: (context, child) {
                          return Transform.translate(
                            offset: Offset(
                              _bubbleSlideAnimation.value,
                              _bubbleSlideAnimation.value * 0.5,
                            ),
                            child: Opacity(
                              opacity: _bubbleFadeAnimation.value,
                              child: child,
                            ),
                          );
                        },
                        child: _SpeechBubble(text: _bubbleText!),
                      ),
                    ),
                  ),
                ),
              ),
            ),

          // ══════ 宠物视频（仅视频区域响应点击，其余穿透） ══════
          Positioned(
            right: 35,  // 往左偏移 10px
            bottom: 0, // 底部留出功能栏空间
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              onEnter: (_) => _onHoverEnter(),
              onExit: (_) => _onHoverExit(),
              child: Opacity(
                opacity: engine.opacity,
                child: Transform.scale(
                  scale: engine.scale,
                  child: SizedBox(
                    width: 157,
                    height: 280,
                    child: PetCanvas(
                      key: _petCanvasKey,
                      engine: engine,
                      onTap: _onPetTap,
                      onDoubleTap: _onPetDoubleTap,
                      onDragStart: _onDragStart,
                    ),
                  ),
                ),
              ),
            ),
          ),

          // ══════ 功能栏（居中显示在宠物正下方） ══════
          if (_showMenu)
            Positioned(
              right: 0,
              bottom: 0,
              child: MouseRegion(
                onEnter: (_) => _onMenuHoverEnter(),
                onExit: (_) => _onMenuHoverExit(),
                child: AnimatedBuilder(
                  animation: _hoverFadeAnimation,
                  builder: (context, child) {
                    return Opacity(
                      opacity: _hoverFadeAnimation.value,
                      child: child,
                    );
                  },
                  child: _buildInlineToolbar(),
                ),
              ),
            ),

          // ══════ 聊天面板（始终存活，关闭时隐藏但不销毁 state） ══════
          Positioned(
            left: 0,
            top: 0,
            bottom: 0,
            right: _petWindowWidth,
            child: Offstage(
              offstage: !_showChat,
              child: Row(
                children: [
                  Expanded(
                    child: ChatPanel(
                      key: _chatPanelKey,
                      onClose: () => _togglePanel('chat'),
                      workMode: _chatWorkMode,
                      onToggleMode: _toggleChatMode,
                      isVisible: _showChat,
                      onBackgroundComplete: (message) {
                        if (mounted) _showBubble(message);
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),

          // ══════ 商店面板 ══════
          if (_showShop)
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              right: _petWindowWidth,
              child: ShopPanel(
                onClose: () => _togglePanel('shop'),
                onItemBought: _onShopItemBought,
                onShowBubble: (message) {
                  if (mounted) _showBubble(message);
                },
              ),
            ),

          // ══════ 设置面板 ══════
          if (_showSettings)
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              right: _petWindowWidth,
              child: SettingsPanel(
                onClose: () => _togglePanel('settings'),
              ),
            ),

          // ══════ 属性面板 ══════
          if (_showPetStats)
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              right: _petWindowWidth,
              child: _PetStatsPanel(
                onClose: () => _togglePanel('petStats'),
              ),
            ),

          // ══════ 成就面板 ══════
          if (_showAchievements)
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              right: _petWindowWidth,
              child: AchievementPanel(
                onClose: () => _togglePanel('achievements'),
              ),
            ),

          // ══════ 日记面板 ══════
          if (_showDiary)
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              right: _petWindowWidth,
              child: DiaryPanel(
                onClose: () => _togglePanel('diary'),
              ),
            ),

          // ====== 窗口边缘拖拽resize区域（任意左侧面板打开时） ======
          if (_showChat || _showShop || _showSettings || _showPetStats || _showAchievements || _showDiary) ...[
            // 左边缘拖拽
            Positioned(
              left: 0,
              top: 8,
              bottom: 8,
              child: GestureDetector(
                onPanStart: (_) => windowManager.startResizing(ResizeEdge.left),
                child: MouseRegion(
                  cursor: SystemMouseCursors.resizeLeftRight,
                  child: Container(width: 5, color: Colors.transparent),
                ),
              ),
            ),
            // 左上角拖拽
            Positioned(
              left: 0,
              top: 0,
              child: GestureDetector(
                onPanStart: (_) => windowManager.startResizing(ResizeEdge.topLeft),
                child: MouseRegion(
                  cursor: SystemMouseCursors.resizeUpLeftDownRight,
                  child: Container(width: 10, height: 10, color: Colors.transparent),
                ),
              ),
            ),
            // 左下角拖拽
            Positioned(
              left: 0,
              bottom: 0,
              child: GestureDetector(
                onPanStart: (_) => windowManager.startResizing(ResizeEdge.bottomLeft),
                child: MouseRegion(
                  cursor: SystemMouseCursors.resizeUpRightDownLeft,
                  child: Container(width: 10, height: 10, color: Colors.transparent),
                ),
              ),
            ),
            // 上边缘拖拽
            Positioned(
              left: 8,
              top: 0,
              right: 8,
              child: GestureDetector(
                onPanStart: (_) => windowManager.startResizing(ResizeEdge.top),
                child: MouseRegion(
                  cursor: SystemMouseCursors.resizeUpDown,
                  child: Container(height: 5, color: Colors.transparent),
                ),
              ),
            ),
            // 下边缘拖拽
            Positioned(
              left: 8,
              bottom: 0,
              right: 8,
              child: GestureDetector(
                onPanStart: (_) => windowManager.startResizing(ResizeEdge.bottom),
                child: MouseRegion(
                  cursor: SystemMouseCursors.resizeUpDown,
                  child: Container(height: 5, color: Colors.transparent),
                ),
              ),
            ),
            // 右边缘拖拽（在宠物区域左侧）
            Positioned(
              right: _petWindowWidth,
              top: 8,
              bottom: 8,
              child: GestureDetector(
                onPanStart: (_) => windowManager.startResizing(ResizeEdge.right),
                child: MouseRegion(
                  cursor: SystemMouseCursors.resizeLeftRight,
                  child: Container(width: 5, color: Colors.transparent),
                ),
              ),
            ),
            // 右上角拖拽
            Positioned(
              right: _petWindowWidth,
              top: 0,
              child: GestureDetector(
                onPanStart: (_) => windowManager.startResizing(ResizeEdge.topRight),
                child: MouseRegion(
                  cursor: SystemMouseCursors.resizeUpRightDownLeft,
                  child: Container(width: 10, height: 10, color: Colors.transparent),
                ),
              ),
            ),
            // 右下角拖拽
            Positioned(
              right: _petWindowWidth,
              bottom: 0,
              child: GestureDetector(
                onPanStart: (_) => windowManager.startResizing(ResizeEdge.bottomRight),
                child: MouseRegion(
                  cursor: SystemMouseCursors.resizeUpLeftDownRight,
                  child: Container(width: 10, height: 10, color: Colors.transparent),
                ),
              ),
            ),
          ],

          // 烟花庆祝动画（覆盖在最上层）
          if (_showFirework)
            Positioned.fill(
              child: FireworkCelebration(
                achievementName: _fireworkAchievementName,
                achievementIcon: _fireworkAchievementIcon,
                onComplete: () {
                  if (mounted) {
                    setState(() {
                      _showFirework = false;
                    });
                  }
                },
              ),
            ),
        ],
      ),
    );
  }

  void _onHoverEnter() {
    if (!_isHovering) {
      _isHovering = true;
      _hoverAnimController.forward();
    }
  }

  void _onHoverExit() {
    if (_isHovering) {
      _isHovering = false;
      if (!_showMenu) {
        _hoverAnimController.reverse();
      }
      if (_showMenu && !_isMenuHovering) {
        _scheduleMenuHide();
      }
    }
  }

  /// 延迟隐藏菜单（2秒后执行，可被取消）
  void _scheduleMenuHide() {
    _menuHideTimer?.cancel();
    _menuHideTimer = Timer(const Duration(seconds: 2), () {
      if (mounted && _showMenu && !_isHovering && !_isMenuHovering) {
        _hideMenu();
      }
    });
  }

  /// 取消延迟隐藏菜单
  void _cancelMenuHide() {
    _menuHideTimer?.cancel();
    _menuHideTimer = null;
  }

  /// 鼠标进入菜单区域
  void _onMenuHoverEnter() {
    _isMenuHovering = true;
    _cancelMenuHide();
  }

  /// 鼠标离开菜单区域
  void _onMenuHoverExit() {
    _isMenuHovering = false;
    if (!_isHovering && _showMenu) {
      _scheduleMenuHide();
    }
  }

  /// 单击鹅宝 → 切换功能栏
  void _onPetTap() {
    final engine = context.read<PetEngine>();
    engine.interact('jump');
    _toggleMenu();
  }

  /// 双击鹅宝 → 打开/关闭对话框
  void _onPetDoubleTap() {
    if (_showMenu) _hideMenu();
    _togglePanel('chat');
  }

  /// 统一的向左扩展/收缩窗口方法
  Future<void> _expandWindow(double panelWidth) async {
    try {
      final pos = await windowManager.getPosition();
      final size = await windowManager.getSize();
      final panelHeight = _currentPanelHeight;
      // 保持窗口右下角位置不变
      // 向左扩展：增加窗口宽度，位置向左移动
      // 高度变化：保持底部位置不变
      final heightDiff = panelHeight - size.height;
      final newPos = Offset(pos.dx - panelWidth, pos.dy - heightDiff);
      final newSize = Size(size.width + panelWidth, panelHeight);
      debugPrint('🦢 窗口扩展: 从 ${size.width.toStringAsFixed(0)}x${size.height.toStringAsFixed(0)} 到 ${newSize.width.toStringAsFixed(0)}x${newSize.height.toStringAsFixed(0)}');
      await Future.wait([
        windowManager.setPosition(newPos),
        windowManager.setSize(newSize),
      ]);
      _currentExpandWidth = panelWidth;
    } catch (e) {
      debugPrint('🦢 窗口扩大失败: $e');
    }
  }

  /// 保存面板宽度到本地存储
  Future<void> _savePanelWidth(double width) async {
    await StorageManager.setSetting('panel_width', width);
  }

  /// 从本地存储读取面板宽度
  double _loadPanelWidth(double defaultWidth) {
    return StorageManager.getSetting<double>('panel_width') ?? defaultWidth;
  }

  /// 保存面板高度到本地存储
  Future<void> _savePanelHeight(double height) async {
    await StorageManager.setSetting('panel_height', height);
  }

  /// 从本地存储读取面板高度
  double _loadPanelHeight(double defaultHeight) {
    return StorageManager.getSetting<double>('panel_height') ?? defaultHeight;
  }

  /// 窗口尺寸变化回调 — 用户拖拽边缘时实时保存面板宽度和高度（仅聊天面板）
  @override
  void onWindowResize() async {
    if (!_showChat) return;
    try {
      final size = await windowManager.getSize();
      final panelWidth = size.width - _petWindowWidth;
      if (panelWidth > 0) {
        _currentExpandWidth = panelWidth;
        await _savePanelWidth(panelWidth);
      }
      if (size.height > 0) {
        _currentPanelHeight = size.height;
        await _savePanelHeight(size.height);
      }
    } catch (_) {}
  }

  /// 记住当前面板展开后的高度（用户拖拽调整）
  double _currentPanelHeight = 650;

  Future<void> _shrinkWindow() async {
    if (_currentExpandWidth <= 0) return;
    try {
      final pos = await windowManager.getPosition();
      final size = await windowManager.getSize();
      final shrink = _currentExpandWidth;
      // 保持窗口右下角位置不变
      // 收缩时：向右移动位置，减少窗口宽度
      // 高度恢复到初始高度，保持底部位置不变
      final heightDiff = size.height - _initialWindowHeight;
      final newPos = Offset(pos.dx + shrink, pos.dy + heightDiff);
      final newSize = Size(size.width - shrink, _initialWindowHeight);
      debugPrint('🦢 窗口收缩: 从 ${size.width.toStringAsFixed(0)}x${size.height.toStringAsFixed(0)} 到 ${newSize.width.toStringAsFixed(0)}x${newSize.height.toStringAsFixed(0)}');
      await Future.wait([
        windowManager.setPosition(newPos),
        windowManager.setSize(newSize),
      ]);
      // 操作成功后再更新状态
      _currentExpandWidth = 0;
    } catch (e) {
      debugPrint('🦢 窗口缩小失败: $e');
    }
  }

  /// 防止面板切换时重入
  bool _isPanelToggling = false;

  /// 切换面板（chat / shop / settings），同时调整窗口大小和位置
  /// 同一时间只能打开一个左侧面板
  Future<void> _togglePanel(String panel) async {
    if (_isPanelToggling) return;
    _isPanelToggling = true;

    try {
      final isOpen = panel == 'chat' ? _showChat
          : panel == 'shop' ? _showShop
          : panel == 'petStats' ? _showPetStats
          : panel == 'achievements' ? _showAchievements
          : panel == 'diary' ? _showDiary
          : _showSettings;

      if (isOpen) {
        // 关闭聊天面板前，先保存当前面板宽度和高度（防止 onWindowResize 未触发导致丢失）
        if (panel == 'chat' && _currentExpandWidth > 0) {
          await _savePanelWidth(_currentExpandWidth);
          await _savePanelHeight(_currentPanelHeight);
        }
        // 关闭聊天面板时，如果处于工作模式，停止工作动画
        if (panel == 'chat' && _chatWorkMode && mounted) {
          context.read<PetEngine>().stopWorking();
        }
        // 关闭当前面板：先隐藏面板UI，再收缩窗口，避免面板闪烁
        if (mounted) {
          setState(() {
            if (panel == 'chat') _showChat = false;
            if (panel == 'shop') _showShop = false;
            if (panel == 'settings') _showSettings = false;
            if (panel == 'petStats') _showPetStats = false;
            if (panel == 'achievements') _showAchievements = false;
            if (panel == 'diary') _showDiary = false;
          });
        }
        // 等待一帧，确保UI已移除面板后再收缩窗口
        await Future.delayed(const Duration(milliseconds: 16));
        await _shrinkWindow();
      } else {
        // 先关闭已打开的其他面板
        final hadExpand = _currentExpandWidth > 0;
        if (_showChat || _showShop || _showSettings || _showPetStats || _showAchievements || _showDiary) {
          // 先隐藏旧面板UI
          if (mounted) {
            setState(() {
              _showChat = false;
              _showShop = false;
              _showSettings = false;
              _showPetStats = false;
              _showAchievements = false;
              _showDiary = false;
            });
          }
          // 再收缩窗口，避免旧面板闪烁
          if (hadExpand) {
            await Future.delayed(const Duration(milliseconds: 16));
            await _shrinkWindow();
          }
        }
        // 打开新面板
        if (mounted) {
          setState(() {
            if (panel == 'chat') _showChat = true;
            if (panel == 'shop') _showShop = true;
            if (panel == 'settings') _showSettings = true;
            if (panel == 'petStats') _showPetStats = true;
            if (panel == 'achievements') _showAchievements = true;
            if (panel == 'diary') _showDiary = true;
          });
        }
        // 等待一帧，确保UI已渲染
        await Future.delayed(const Duration(milliseconds: 16));
        // 默认宽度（不同面板使用不同宽度）
        final defaultWidth = panel == 'chat'
            ? (_chatWorkMode ? _chatPanelWorkWidth : _chatPanelWidth)
            : panel == 'diary'
                ? _diaryPanelWidth
                : panel == 'settings'
                    ? _settingsPanelWidth
                    : _shopPanelWidth;
        // 优先使用用户记住的宽度（仅对聊天面板生效）
        final savedWidth = panel == 'chat' ? _loadPanelWidth(defaultWidth) : defaultWidth;
        // 面板高度：优先使用保存的高度，否则使用当前窗口高度（第一次打开时保持高度不变）
        if (panel == 'chat') {
          final savedHeight = _loadPanelHeight(0);
          if (savedHeight > 0) {
            _currentPanelHeight = savedHeight;
          } else {
            // 第一次打开：保持当前窗口高度不变
            final currentSize = await windowManager.getSize();
            _currentPanelHeight = currentSize.height;
          }
        } else {
          _currentPanelHeight = _panelWindowHeight;
        }
        await _expandWindow(savedWidth);

        // 打开聊天面板时，如果处于工作模式，启动工作动画
        if (panel == 'chat' && _chatWorkMode && mounted) {
          context.read<PetEngine>().startWorking();
        }
      }
    } finally {
      _isPanelToggling = false;
    }
  }

  /// 切换聊天模式（休闲/工作）
  Future<void> _toggleChatMode() async {
    if (!_showChat) return;

    // 先保存当前面板宽度和高度
    if (_currentExpandWidth > 0) {
      await _savePanelWidth(_currentExpandWidth);
      await _savePanelHeight(_currentPanelHeight);
    }

    final oldWidth = _currentExpandWidth;
    // 使用用户已保存的面板宽度，而非默认常量
    final defaultWidth = !_chatWorkMode ? _chatPanelWorkWidth : _chatPanelWidth;
    final newWidth = _loadPanelWidth(defaultWidth);
    final diff = newWidth - oldWidth;

    // 切换模式
    final toWorkMode = !_chatWorkMode;

    // 同时更新UI状态和窗口尺寸，减少闪烁
    setState(() {
      _chatWorkMode = toWorkMode;
    });

    try {
      final pos = await windowManager.getPosition();
      await windowManager.setSize(Size(_petWindowWidth + newWidth, _currentPanelHeight));
      await windowManager.setPosition(Offset(pos.dx - diff, pos.dy));
      _currentExpandWidth = newWidth;
    } catch (e) {
      debugPrint('🦢 切换聊天模式失败: $e');
    }

    // 切换到工作模式时，启动工作动画；切回休闲模式时，停止工作动画
    if (mounted) {
      final petEngine = context.read<PetEngine>();
      if (toWorkMode) {
        petEngine.startWorking();
      } else {
        petEngine.stopWorking();
      }
    }
  }

  void _toggleMenu() {
    if (_showMenu) {
      _hideMenu();
    } else {
      setState(() => _showMenu = true);
      _menuAnimController.forward(from: 0);
      // 菜单打开时确保状态条也可见
      _hoverAnimController.forward();
    }
  }

  void _hideMenu() {
    _cancelMenuHide();
    _menuAnimController.reverse().then((_) {
      if (mounted) {
        setState(() => _showMenu = false);
        // 如果鼠标不在上面了，隐藏状态条
        if (!_isHovering && !_isMenuHovering) {
          _hoverAnimController.reverse();
        }
      }
    });
  }

  void _onDragStart() {
    windowManager.startDragging();
  }

  /// 商店购买物品后的回调 → 关闭商店面板，触发宠物动画
  void _onShopItemBought(ShopItem item) {
    // 关闭商店面板让宠物动画可见
    _togglePanel('shop');
  }

  Widget _buildInlineToolbar() {
    return AnimatedBuilder(
      animation: _menuAnimController,
      builder: (context, child) {
        return Transform.translate(
          offset: Offset(0, _menuSlideAnimation.value),
          child: Opacity(
            opacity: _menuFadeAnimation.value,
            child: child,
          ),
        );
      },
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.12),
              blurRadius: 20,
              offset: const Offset(0, 4),
            ),
            BoxShadow(
              color: Colors.white.withOpacity(0.8),
              blurRadius: 4,
              offset: const Offset(0, -1),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _MenuButton(
              icon: '💬',
              label: '聊天',
              onTap: () {
                _hideMenu();
                _togglePanel('chat');
              },
            ),
            _MenuButton(
              icon: '📊',
              label: '属性',
              onTap: () {
                _hideMenu();
                _togglePanel('petStats');
              },
            ),
            _MenuButton(
              icon: '🛍️',
              label: '商店',
              onTap: () {
                _hideMenu();
                _togglePanel('shop');
              },
            ),
            _MenuButton(
              icon: '📔',
              label: '日记',
              onTap: () {
                _hideMenu();
                _togglePanel('diary');
              },
            ),
            _MenuButton(
              icon: '⚙️',
              label: '设置',
              onTap: () {
                _hideMenu();
                _togglePanel('settings');
              },
            ),
          ],
        ),
      ),
    );
  }

}

/// 宠物说话气泡
class _SpeechBubble extends StatelessWidget {
  final String text;
  const _SpeechBubble({required this.text});

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _SpeechBubblePainter(),
      child: Container(
        constraints: const BoxConstraints(
          maxWidth: 220,
          minHeight: 44,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Text(
          text,
          style: const TextStyle(
            fontSize: 14,
            height: 1.4,
            color: Color(0xFF5D4037),
            fontWeight: FontWeight.w400,
            letterSpacing: 0.5, // 字间距增加，更可爱
          ),
        ),
      ),
    );
  }
}

/// 气泡背景绘制（圆角矩形 + 小三角指向右下方宠物）
class _SpeechBubblePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    const radius = 14.0;
    const arrowSize = 10.0;
    final paint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.fill;

    final shadowPaint = Paint()
      ..color = Colors.black.withOpacity(0.08)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6);

    final rrect = RRect.fromRectAndRadius(
      Rect.fromLTWH(0, 0, size.width, size.height),
      const Radius.circular(radius),
    );

    // 阴影
    canvas.drawRRect(rrect.shift(const Offset(0, 2)), shadowPaint);
    // 白色背景
    canvas.drawRRect(rrect, paint);

    // 右下角小三角（指向宠物方向）
    final path = Path()
      ..moveTo(size.width - radius - 5, size.height - 1)
      ..lineTo(size.width - radius - 5 - arrowSize, size.height + arrowSize - 2)
      ..lineTo(size.width - radius + 5, size.height - 1)
      ..close();
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// 宠物属性面板（展示鹅宝详细属性、状态和成长信息）
class _PetStatsPanel extends StatelessWidget {
  final VoidCallback onClose;

  const _PetStatsPanel({required this.onClose});

  @override
  Widget build(BuildContext context) {
    final engine = context.watch<PetEngine>();
    final state = engine.state;

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: const BorderRadius.only(
          topRight: Radius.circular(16),
          bottomRight: Radius.circular(16),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.1),
            blurRadius: 10,
            offset: const Offset(2, 0),
          ),
        ],
      ),
      child: Column(
        children: [
          // 标题栏（可拖动窗口）
          GestureDetector(
            onPanStart: (_) => windowManager.startDragging(),
            behavior: HitTestBehavior.opaque,
            child: Container(
              padding: const EdgeInsets.fromLTRB(20, 16, 12, 8),
              child: Row(
                children: [
                  const Text(
                    '📊 鹅宝属性',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close, size: 18),
                    onPressed: onClose,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),
                ],
              ),
            ),
          ),
          const Divider(height: 1),
          // 属性内容（可滚动）
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 头像卡片
                  _buildProfileCard(state),
                  const SizedBox(height: 16),
                  // 经验条
                  _buildExpBar(state),
                  const SizedBox(height: 16),
                  // 五维属性
                  _buildAttributeSection(engine),
                  const SizedBox(height: 16),
                  // 状态信息
                  _buildStatusSection(state, engine),
                  const SizedBox(height: 16),
                  // 综合评价
                  _buildOverallSection(state),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 头像+基本信息卡片
  Widget _buildProfileCard(PetState state) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFFE3F2FD), Color(0xFFE8F5E9)],
        ),
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.blue.withOpacity(0.08),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        children: [
          // 鹅宝头像
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(32),
              boxShadow: [
                BoxShadow(
                  color: Colors.blue.withOpacity(0.15),
                  blurRadius: 8,
                ),
              ],
            ),
            child: const Center(
              child: Text('🦢', style: TextStyle(fontSize: 36)),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '鹅宝',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF37474F),
                  ),
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: const Color(0xFF4FC3F7).withOpacity(0.2),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        'Lv.${state.level}',
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFF0288D1),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '陪伴 ${state.companionDays} 天',
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.grey.shade600,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    const Text('🪙', style: TextStyle(fontSize: 14)),
                    const SizedBox(width: 4),
                    Text(
                      '${state.coins}',
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFFFF8F00),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 经验值进度条
  Widget _buildExpBar(PetState state) {
    final progress = state.exp / state.expToNextLevel;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.grey.shade50,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text(
                '⭐ 成长经验',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
              ),
              const Spacer(),
              Text(
                '${state.exp} / ${state.expToNextLevel} EXP',
                style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(
              value: progress.clamp(0.0, 1.0),
              minHeight: 10,
              backgroundColor: Colors.grey.shade200,
              valueColor: const AlwaysStoppedAnimation(Color(0xFF4FC3F7)),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '距离 Lv.${state.level + 1} 还需 ${state.expToNextLevel - state.exp} EXP',
            style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
          ),
        ],
      ),
    );
  }

  /// 五维属性详情
  Widget _buildAttributeSection(PetEngine engine) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.grey.shade50,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '🎯 五维属性',
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 12),
          _AttributeBar(
            icon: '❤️',
            label: '心情',
            value: engine.happiness,
            color: Colors.red,
            description: _getMoodDesc(engine.happiness),
          ),
          const SizedBox(height: 10),
          _AttributeBar(
            icon: '🍖',
            label: '饱食度',
            value: engine.hunger,
            color: Colors.orange,
            description: _getHungerDesc(engine.hunger),
          ),
          const SizedBox(height: 10),
          _AttributeBar(
            icon: '💚',
            label: '健康度',
            value: engine.health,
            color: Colors.green,
            description: _getHealthDesc(engine.health),
          ),
          const SizedBox(height: 10),
          _AttributeBar(
            icon: '⚡',
            label: '精力',
            value: engine.energy,
            color: Colors.blue,
            description: _getEnergyDesc(engine.energy),
          ),
          const SizedBox(height: 10),
          _AttributeBar(
            icon: '🧼',
            label: '清洁度',
            value: engine.clean,
            color: Colors.cyan,
            description: _getCleanDesc(engine.clean),
          ),
        ],
      ),
    );
  }

  /// 当前状态信息
  Widget _buildStatusSection(PetState state, PetEngine engine) {
    final emotionText = _getEmotionText(state.emotion);
    final actionText = _getActionText(state.currentAction);

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.grey.shade50,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '🦢 当前状态',
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          _StatusInfoRow(label: '情绪', value: emotionText),
          _StatusInfoRow(label: '动作', value: actionText),
          _StatusInfoRow(label: '心情指数', value: engine.mood),
          _StatusInfoRow(
            label: '朝向',
            value: state.facingRight ? '➡️ 向右' : '⬅️ 向左',
          ),
        ],
      ),
    );
  }

  /// 综合评价
  Widget _buildOverallSection(PetState state) {
    final overall = state.overallHealth;
    final grade = _getGrade(overall);
    final gradeColor = _getGradeColor(overall);
    final advice = _getAdvice(state);

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [gradeColor.withOpacity(0.08), gradeColor.withOpacity(0.03)],
        ),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: gradeColor.withOpacity(0.2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text(
                '📋 综合评价',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
              ),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                decoration: BoxDecoration(
                  color: gradeColor.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  grade,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: gradeColor,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          // 综合分数
          Row(
            children: [
              Text(
                '综合健康度: ${overall.toStringAsFixed(1)}',
                style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
              ),
              const Spacer(),
              Text(
                '${(overall).toStringAsFixed(0)}/100',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: gradeColor,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: (overall / 100).clamp(0.0, 1.0),
              minHeight: 6,
              backgroundColor: Colors.grey.shade200,
              valueColor: AlwaysStoppedAnimation(gradeColor),
            ),
          ),
          if (advice.isNotEmpty) ...[
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.7),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('💡', style: TextStyle(fontSize: 14)),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      advice,
                      style: TextStyle(fontSize: 12, color: Colors.grey.shade700, height: 1.4),
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

  // ---- 描述文本辅助方法 ----

  String _getMoodDesc(double value) {
    if (value > 80) return '超级开心！';
    if (value > 60) return '心情不错~';
    if (value > 40) return '有点无聊...';
    if (value > 20) return '心情低落 😢';
    return '非常难过 😭';
  }

  String _getHungerDesc(double value) {
    if (value > 80) return '吃得饱饱的！';
    if (value > 60) return '还不太饿';
    if (value > 40) return '有点饿了';
    if (value > 20) return '很饿了！';
    return '快饿晕了！😵';
  }

  String _getHealthDesc(double value) {
    if (value > 80) return '非常健康！';
    if (value > 60) return '身体不错';
    if (value > 40) return '有些不舒服';
    if (value > 20) return '需要看医生';
    return '病得很严重！🏥';
  }

  String _getEnergyDesc(double value) {
    if (value > 80) return '精力充沛！';
    if (value > 60) return '还有精神';
    if (value > 40) return '有点累了';
    if (value > 20) return '非常疲惫';
    return '快要睡着了 💤';
  }

  String _getCleanDesc(double value) {
    if (value > 80) return '干干净净！';
    if (value > 60) return '还算整洁';
    if (value > 40) return '有点脏了';
    if (value > 20) return '需要洗澡了';
    return '脏兮兮的！🛁';
  }

  String _getEmotionText(String emotion) {
    switch (emotion) {
      case 'happy': return '😊 开心';
      case 'sad': return '😢 难过';
      case 'excited': return '🤩 兴奋';
      case 'shy': return '😳 害羞';
      case 'angry': return '😤 生气';
      case 'sleepy': return '😴 犯困';
      case 'sick': return '🤒 生病';
      case 'hungry': return '🍽️ 饥饿';
      case 'working': return '💻 工作中';
      case 'thinking': return '🤔 思考';
      default: return '😐 平静';
    }
  }

  String _getActionText(String action) {
    switch (action) {
      case 'idle': return '发呆中...';
      case 'look_around': return '东张西望';
      case 'sit': return '坐着休息';
      case 'yawn': return '打哈欠';
      case 'flap_wings': return '扇翅膀';
      case 'working': return '认真工作';
      case 'eating': return '吃东西';
      case 'bathing': return '洗澡';
      case 'sleep': return '睡觉 💤';
      case 'happy_jump': return '开心地蹦蹦跳';
      case 'shy': return '害羞地低头';
      case 'petted': return '被撸中~';
      case 'cry': return '呜呜哭泣';
      case 'slouch': return '无精打采';
      case 'sigh': return '叹气';
      case 'sick': return '不舒服';
      case 'resting': return '休养中';
      default: return action;
    }
  }

  String _getGrade(double overall) {
    if (overall >= 90) return '🌟 S 完美';
    if (overall >= 80) return '✨ A 优秀';
    if (overall >= 65) return '👍 B 良好';
    if (overall >= 50) return '⚠️ C 一般';
    if (overall >= 30) return '😰 D 较差';
    return '🆘 E 危险';
  }

  Color _getGradeColor(double overall) {
    if (overall >= 90) return const Color(0xFFFF8F00);
    if (overall >= 80) return const Color(0xFF4CAF50);
    if (overall >= 65) return const Color(0xFF2196F3);
    if (overall >= 50) return const Color(0xFFFFA726);
    if (overall >= 30) return const Color(0xFFFF7043);
    return Colors.red;
  }

  String _getAdvice(PetState state) {
    final tips = <String>[];
    if (state.hunger < 30) tips.add('鹅宝很饿了，快去商店买点食物吧！');
    if (state.energy < 30) tips.add('鹅宝精力不足，给它用个元气药水吧！');
    if (state.clean < 30) tips.add('鹅宝需要洗澡了，去商店买个泡泡浴吧！');
    if (state.health < 30) tips.add('鹅宝生病了，快买维生素给它补补！');
    if (state.mood < 30) tips.add('鹅宝心情不好，摸摸头或者买个玩具吧！');
    if (tips.isEmpty) return '鹅宝状态很好，继续保持哦~';
    return tips.join('\n');
  }
}

/// 属性详情进度条
class _AttributeBar extends StatelessWidget {
  final String icon;
  final String label;
  final double value;
  final Color color;
  final String description;

  const _AttributeBar({
    required this.icon,
    required this.label,
    required this.value,
    required this.color,
    required this.description,
  });

  @override
  Widget build(BuildContext context) {
    final isLow = value < 30;
    final displayColor = isLow ? Colors.red : color;

    return Column(
      children: [
        Row(
          children: [
            Text(icon, style: const TextStyle(fontSize: 16)),
            const SizedBox(width: 6),
            SizedBox(
              width: 50,
              child: Text(
                label,
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
              ),
            ),
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: (value / 100).clamp(0.0, 1.0),
                  minHeight: 8,
                  backgroundColor: isLow ? Colors.red.shade50 : Colors.grey.shade200,
                  valueColor: AlwaysStoppedAnimation(displayColor),
                ),
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              width: 38,
              child: Text(
                '${value.toInt()}',
                textAlign: TextAlign.right,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: displayColor,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 2),
        Align(
          alignment: Alignment.centerRight,
          child: Text(
            description,
            style: TextStyle(
              fontSize: 10,
              color: isLow ? Colors.red.shade400 : Colors.grey.shade500,
            ),
          ),
        ),
      ],
    );
  }
}

/// 状态信息行
class _StatusInfoRow extends StatelessWidget {
  final String label;
  final String value;

  const _StatusInfoRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          SizedBox(
            width: 70,
            child: Text(
              label,
              style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
            ),
          ),
        ],
      ),
    );
  }
}

/// 菜单按钮
class _MenuButton extends StatelessWidget {
  final String icon;
  final String label;
  final VoidCallback onTap;

  const _MenuButton({required this.icon, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(icon, style: const TextStyle(fontSize: 18)),
            const SizedBox(height: 1),
            Text(
              label,
              style: const TextStyle(fontSize: 9, color: Color(0xFF616161)),
            ),
          ],
        ),
      ),
    );
  }
}
