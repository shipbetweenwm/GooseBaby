import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';
import '../models/models.dart';
import 'achievement_manager.dart';

/// 宠物行为引擎
/// 管理鹅宝的状态、行为状态机、属性衰减、金币挂机和物理移动
class PetEngine extends ChangeNotifier {
  PetState _state = const PetState();
  Timer? _behaviorTimer;
  Timer? _decayTimer;
  Timer? _moveTimer;
  Timer? _coinTimer; // 金币挂机定时器
  Timer? _proactiveTimer; // 主动搭话定时器
  Timer? _healthReminderTimer; // 健康提醒定时器（每小时提醒喝水/上厕所）
  final Random _random = Random();

  /// 成就管理器引用（由外部设置，用于触发成就事件）
  AchievementManager? achievementManager;

  // 行为状态机 - 各情绪分组的动作列表
  static const List<String> _idleActions = [
    'idle', 'look_around', 'sit', 'flap_wings',
  ];
  static const List<String> _happyActions = [
    'idle', 'look_around', 'play', 'flap_wings', 'satisfied',
  ];
  static const List<String> _sadActions = [
    'cry', 'slouch', 'sigh',
  ];
  static const List<String> _sickActions = [
    'sick', 'resting',
  ];
  static const List<String> _sleepyActions = [
    'yawn', 'resting', 'sigh',
  ];

  /// 是否正在工作（对话中/AI回复中）
  bool _isWorking = false;
  bool get isWorking => _isWorking;

  PetState get state => _state;

  // ---- 设置项 ----
  bool _autoRoam = true;
  bool _soundEnabled = false;
  bool _notificationEnabled = true;
  bool _healthReminderEnabled = true;
  int _healthReminderInterval = 30; // 健康提醒间隔（分钟），默认30分钟
  bool _alwaysOnTop = true;
  double _opacity = 1.0;
  double _scale = 1.0;

  bool get autoRoam => _autoRoam;
  bool get soundEnabled => _soundEnabled;
  bool get notificationEnabled => _notificationEnabled;
  bool get healthReminderEnabled => _healthReminderEnabled;
  int get healthReminderInterval => _healthReminderInterval;
  bool get alwaysOnTop => _alwaysOnTop;
  double get opacity => _opacity;
  double get scale => _scale;

  /// 主动搭话回调（由 PetWindow 设置）
  void Function(String message)? onProactiveMessage;

  /// 健康提醒回调（由 PetWindow 设置）
  void Function(String message)? onHealthReminder;

  /// 升级回调（由 PetWindow 设置，用于显示升级特效）
  void Function(int newLevel)? onLevelUp;

  // ---- 陪伴节奏感知 ----
  /// 最近一次用户交互时间
  DateTime _lastUserInteraction = DateTime.now();
  /// 本次会话用户消息计数
  int _sessionMessageCount = 0;
  /// 今日是否已经发送过欢迎消息
  bool _welcomeSentToday = false;
  /// 上次在线离开时间（用于判断"回来了"）
  DateTime? _lastOfflineTime;

  DateTime get lastUserInteraction => _lastUserInteraction;
  int get sessionMessageCount => _sessionMessageCount;

  /// 里程碑回调（由 PetWindow 设置）
  void Function(String message, String type)? onMilestone;

  /// 主动情绪表达回调（求关注/闹脾气等）
  void Function(String message, String emotionType)? onEmotionalBehavior;

  // ---- UI 便捷访问器 ----
  double get happiness => _state.mood;
  double get hunger => _state.hunger;
  double get energy => _state.energy;
  double get health => _state.health;
  double get clean => _state.clean;
  int get coins => _state.coins;
  String get mood {
    if (_state.mood > 80) return 'happy';
    if (_state.mood > 60) return 'neutral';
    if (_state.mood > 40) return 'sad';
    if (_state.mood > 20) return 'sleepy';
    return 'angry';
  }
  String? _currentEmote;
  String? get currentEmote => _currentEmote;

  /// 屏幕边界（用于自动漫游）
  double _screenWidth = 1920;
  // ignore: unused_field
  double _screenHeight = 1080;

  void setScreenSize(double width, double height) {
    _screenWidth = width;
    _screenHeight = height;
  }

  PetEngine() {
    _loadState();
    _loadSettings();
    _startEngines();
  }

  /// 加载设置项
  void _loadSettings() {
    try {
      final box = Hive.box('settings');
      _autoRoam = box.get('auto_roam', defaultValue: true) as bool;
      _soundEnabled = box.get('sound_enabled', defaultValue: false) as bool;
      _notificationEnabled = box.get('notification_enabled', defaultValue: true) as bool;
      _healthReminderEnabled = box.get('health_reminder_enabled', defaultValue: true) as bool;
      _healthReminderInterval = box.get('health_reminder_interval', defaultValue: 30) as int;
      _alwaysOnTop = box.get('always_on_top', defaultValue: true) as bool;
      _opacity = (box.get('opacity', defaultValue: 1.0) as num).toDouble();
      _scale = (box.get('scale', defaultValue: 1.0) as num).toDouble();
    } catch (e) {
      debugPrint('🦢 加载设置失败: $e');
    }
  }

  /// 保存设置项
  void _saveSettings() {
    try {
      final box = Hive.box('settings');
      box.put('auto_roam', _autoRoam);
      box.put('sound_enabled', _soundEnabled);
      box.put('notification_enabled', _notificationEnabled);
      box.put('health_reminder_enabled', _healthReminderEnabled);
      box.put('health_reminder_interval', _healthReminderInterval);
      box.put('always_on_top', _alwaysOnTop);
      box.put('opacity', _opacity);
      box.put('scale', _scale);
    } catch (e) {
      debugPrint('🦢 保存设置失败: $e');
    }
  }

  // ---- 设置项更新方法 ----

  void setAutoRoam(bool value) {
    _autoRoam = value;
    _saveSettings();
    notifyListeners();
  }

  void setSoundEnabled(bool value) {
    _soundEnabled = value;
    _saveSettings();
    notifyListeners();
  }

  void setNotificationEnabled(bool value) {
    _notificationEnabled = value;
    _saveSettings();
    notifyListeners();
    // 启用/禁用主动搭话
    if (value) {
      _startProactiveChat();
    } else {
      _proactiveTimer?.cancel();
      _proactiveTimer = null;
    }
  }

  void setHealthReminderEnabled(bool value) {
    _healthReminderEnabled = value;
    _saveSettings();
    notifyListeners();
    if (value) {
      _startHealthReminder();
    } else {
      _healthReminderTimer?.cancel();
      _healthReminderTimer = null;
    }
  }

  void setHealthReminderInterval(int minutes) {
    _healthReminderInterval = minutes.clamp(5, 120);
    _saveSettings();
    _startHealthReminder();
    notifyListeners();
  }

  void setAlwaysOnTop(bool value) {
    _alwaysOnTop = value;
    _saveSettings();
    notifyListeners();
  }

  void setOpacity(double value) {
    _opacity = value.clamp(0.3, 1.0);
    _saveSettings();
    notifyListeners();
  }

  void setScale(double value) {
    _scale = value.clamp(0.5, 1.25);
    _saveSettings();
    notifyListeners();
  }

  /// 加载保存的宠物状态
  void _loadState() {
    final box = Hive.box('pet_state');
    final saved = box.get('pet_state');
    if (saved != null && saved is Map) {
      _state = PetState.fromJson(Map<String, dynamic>.from(saved));
    }
    // 计算陪伴天数
    final firstDay = box.get('first_day');
    if (firstDay == null) {
      box.put('first_day', DateTime.now().toIso8601String());
    } else {
      final days = DateTime.now().difference(DateTime.parse(firstDay)).inDays + 1;
      _state = _state.copyWith(companionDays: days);
    }

    // 记录上次在线时间（用于欢迎语和离线检测）
    final lastOnline = box.get('last_online_time');
    if (lastOnline != null) {
      try {
        _lastOfflineTime = DateTime.parse(lastOnline as String);
      } catch (_) {}
    }

    // 计算离线期间的金币奖励
    _calculateOfflineCoins(box);

    // 延迟触发里程碑和欢迎检测（等 PetWindow 设置回调后）
    Future.delayed(const Duration(seconds: 2), () {
      _checkMilestone();
      _checkWelcomeBack();
    });
  }

  /// 计算离线期间的金币奖励
  void _calculateOfflineCoins(Box box) {
    final lastOnline = box.get('last_online_time');
    if (lastOnline != null) {
      try {
        final lastTime = DateTime.parse(lastOnline as String);
        final offlineMinutes = DateTime.now().difference(lastTime).inMinutes;
        if (offlineMinutes > 1) {
          // 离线每分钟 1 金币，上限 500
          final offlineCoins = offlineMinutes.clamp(0, 500);
          _state = _state.copyWith(coins: _state.coins + offlineCoins);
          debugPrint('🦢 离线 $offlineMinutes 分钟，奖励 $offlineCoins 金币');
        }
      } catch (_) {}
    }
    box.put('last_online_time', DateTime.now().toIso8601String());
  }

  /// 保存宠物状态
  void _saveState() {
    final box = Hive.box('pet_state');
    box.put('pet_state', _state.toJson());
    box.put('last_online_time', DateTime.now().toIso8601String());
  }

  /// 启动所有引擎
  void _startEngines() {
    // 行为切换引擎 - 每5~15秒随机切换行为
    _behaviorTimer = Timer.periodic(const Duration(seconds: 8), (_) {
      _updateBehavior();
    });

    // 属性衰减引擎 - 每60秒衰减
    _decayTimer = Timer.periodic(const Duration(seconds: 60), (_) {
      _decayAttributes();
    });

    // 移动引擎 - 每100ms更新位置
    _moveTimer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      _updatePosition();
    });

    // 金币挂机引擎 - 每30秒+1金币
    _coinTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      _earnCoin();
    });

    // 主动搭话引擎
    if (_notificationEnabled) {
      _startProactiveChat();
    }

    // 健康提醒引擎 - 每小时提醒喝水和上厕所
    if (_healthReminderEnabled) {
      _startHealthReminder();
    }
  }

  /// 启动主动搭话定时器
  void _startProactiveChat() {
    _proactiveTimer?.cancel();
    // 每 5 分钟检查一次是否需要搭话（实际触发取决于陪伴节奏）
    _proactiveTimer = Timer.periodic(const Duration(minutes: 5), (_) {
      if (!_notificationEnabled) return;
      if (_isWorking) return; // 工作中不打扰

      final minutesSinceLastInteraction = DateTime.now().difference(_lastUserInteraction).inMinutes;

      // ── 陪伴节奏感知 ──
      String? careType;

      if (minutesSinceLastInteraction > 120) {
        // 超过 2 小时没互动 → 想念模式（高概率触发）
        if (_random.nextDouble() < 0.7) {
          careType = '主动搭话：主人已经很久没理鹅宝了（$minutesSinceLastInteraction分钟），表达想念，语气略带失落但不要太重，比如"主人好久没理鹅宝了...你在忙吗？"';
        }
      } else if (minutesSinceLastInteraction > 60) {
        // 1-2 小时 → 轻度关心（中等概率）
        if (_random.nextDouble() < 0.4) {
          careType = '主动搭话：主人有一会儿没说话了，轻轻问候一下，不要太打扰';
        }
      } else if (minutesSinceLastInteraction < 15 && _sessionMessageCount > 5) {
        // 用户很活跃 → 减少打扰，偶尔互动
        if (_random.nextDouble() < 0.15) {
          careType = '主动搭话：主人很活跃，鹅宝安静陪着，偶尔说一句轻松的话';
        }
      } else {
        // 正常节奏 → 标准搭话
        if (_random.nextDouble() < 0.3) {
          final hour = DateTime.now().hour;
          if (hour >= 22 || hour < 6) {
            careType = '主动搭话：深夜了，温柔地关心主人，提醒早点休息';
          } else {
            careType = '主动搭话：跟主人随意聊天，可以问问题、分享趣事、撒娇';
          }
        }
      }

      if (careType != null) {
        onProactiveMessage?.call(careType);
      }

      // ── 鹅宝自身状态驱动的搭话 ──
      if (_state.hunger < 30 && _random.nextDouble() < 0.5) {
        Future.delayed(const Duration(seconds: 2), () {
          onProactiveMessage?.call('主人，鹅宝肚子好饿呀...能给我点吃的吗？🥺');
        });
      }
      if (_state.energy < 20 && _random.nextDouble() < 0.5) {
        Future.delayed(const Duration(seconds: 2), () {
          onProactiveMessage?.call('主人，鹅宝好困...需要休息一下了 💤');
        });
      }
    });
  }

  /// 启动健康提醒定时器 - 按可配置间隔提醒喝水和上厕所
  void _startHealthReminder() {
    _healthReminderTimer?.cancel();
    _healthReminderTimer = Timer.periodic(
      Duration(minutes: _healthReminderInterval), (_) {
      if (!_healthReminderEnabled) return;
      if (!_notificationEnabled) return;

      // 根据当前时间段生成动态提醒类型，供 LLM 个性化生成内容
      final hour = DateTime.now().hour;
      String reminderHint;
      if (hour >= 22 || hour < 7) {
        reminderHint = '深夜了，提醒主人早点休息、不要熬夜';
      } else if (hour >= 12 && hour < 14) {
        reminderHint = '午休时间，提醒主人适当休息、闭眼放松';
      } else if (hour < 9) {
        reminderHint = '早上好，提醒主人记得吃早餐、开启活力一天';
      } else {
        reminderHint = '提醒主人喝水、活动、休息、上厕所';
      }
      onHealthReminder?.call(reminderHint);
    });
  }

  /// 挂机赚金币
  void _earnCoin() {
    final bonus = _state.level; // 等级越高，赚得越多
    _state = _state.copyWith(coins: _state.coins + bonus);
    // 记录成就金币事件
    achievementManager?.recordCoinsEarned(bonus);
    _saveState();
    notifyListeners();
  }

  /// 商店购买物品
  bool buyItem(ShopItem item) {
    if (_state.coins < item.price) return false;

    _state = _state.copyWith(
      coins: _state.coins - item.price,
    );
    _saveState();
    notifyListeners();

    // 记录成就事件
    achievementManager?.recordPurchase(item.price);
    achievementManager?.recordItemUse();

    // 立即使用物品
    useItem(item);
    return true;
  }

  /// 使用物品
  void useItem(ShopItem item) {
    _state = _state.copyWith(
      hunger: (_state.hunger + item.hungerBoost).clamp(0, 100),
      mood: (_state.mood + item.moodBoost).clamp(0, 100),
      health: (_state.health + item.healthBoost).clamp(0, 100),
      energy: (_state.energy + item.energyBoost).clamp(0, 100),
      clean: (_state.clean + item.cleanBoost).clamp(0, 100),
      exp: _state.exp + item.expBoost,
    );

    // 根据物品类型触发对应动画
    switch (item.type) {
      case ShopItemType.food:
        // 食物 → 吃零食动画 → 状态机自动跳转到开心跳
        _state = _state.copyWith(currentAction: 'eating', emotion: 'happy');
        _showEmote(item.icon);
        Future.delayed(const Duration(seconds: 5), () => _updateBehavior());
        break;
      case ShopItemType.toy:
        // 玩具 → 玩玩具动画 → 然后开心跳
        _state = _state.copyWith(currentAction: 'play_toy', emotion: 'excited');
        _showEmote(item.icon);
        Future.delayed(const Duration(seconds: 5), () {
          _state = _state.copyWith(currentAction: 'happy_jump', emotion: 'happy');
          notifyListeners();
          Future.delayed(const Duration(seconds: 4), () => _updateBehavior());
        });
        break;
      case ShopItemType.medicine:
        _state = _state.copyWith(currentAction: 'shy', emotion: 'happy');
        _showEmote(item.icon);
        Future.delayed(const Duration(seconds: 2), () => _updateBehavior());
        break;
      case ShopItemType.cleaning:
        // 清洁 → 洗澡动画
        _state = _state.copyWith(currentAction: 'bathing', emotion: 'happy');
        _showEmote(item.icon);
        Future.delayed(const Duration(seconds: 5), () => _updateBehavior());
        break;
    }

    _checkLevelUp();
    _saveState();
    notifyListeners();
  }

  /// 行为状态机 - 根据当前属性决定下一个行为
  void _updateBehavior() {
    // 如果正在工作（对话中），保持工作状态
    if (_isWorking) {
      _state = _state.copyWith(
        currentAction: 'working',
        emotion: 'working',
      );
      notifyListeners();
      return;
    }

    // 偶尔触发主动情绪表达（约 1/3 概率，在正常行为切换时检查）
    if (_random.nextDouble() < 0.33) {
      _checkEmotionalBehavior();
    }

    String nextAction;
    String nextEmotion;

    if (_state.health < 30) {
      // 🤒 生病了（健康度低）→ 病恹恹/困了
      nextEmotion = 'sick';
      nextAction = _sickActions[_random.nextInt(_sickActions.length)];
    } else if (_state.hunger < 20) {
      // 🥺 太饿了 → 哭了/垂头丧气
      nextEmotion = 'hungry';
      nextAction = _sadActions[_random.nextInt(_sadActions.length)];
    } else if (_state.energy < 20) {
      // 😴 太累了 → 直接睡觉
      nextEmotion = 'sleepy';
      nextAction = 'sleep';
    } else if (_state.energy < 40) {
      // 🥱 精力偏低 → 犯困（打哈欠、叹气）
      nextEmotion = 'sleepy';
      nextAction = _sleepyActions[_random.nextInt(_sleepyActions.length)];
    } else if (_state.mood < 30) {
      // 😢 心情差 → 哭泣/无精打采
      nextEmotion = 'sad';
      nextAction = _sadActions[_random.nextInt(_sadActions.length)];
    } else if (_state.clean < 25) {
      // 🛁 太脏了 → 偶尔暗示想洗澡（20%概率触发哭泣，表示不舒服）
      if (_random.nextDouble() < 0.2) {
        nextEmotion = 'sad';
        nextAction = 'sigh';
      } else {
        nextEmotion = 'normal';
        nextAction = _idleActions[_random.nextInt(_idleActions.length)];
      }
    } else if (_state.mood > 80) {
      // 😄 心情很好 → 开心系列（偶尔玩耍/装萌/满足）
      nextEmotion = 'happy';
      nextAction = _happyActions[_random.nextInt(_happyActions.length)];
    } else {
      // 😐 正常状态 → idle 动作（含 look_around、sit 等）
      nextEmotion = _state.mood > 60 ? 'happy' : 'normal';
      nextAction = _idleActions[_random.nextInt(_idleActions.length)];
    }

    _state = _state.copyWith(
      currentAction: nextAction,
      emotion: nextEmotion,
    );
    notifyListeners();
  }

  /// 属性自然衰减
  void _decayAttributes() {
    _state = _state.copyWith(
      hunger: (_state.hunger - 0.5).clamp(0, 100),
      energy: (_state.energy - 0.3).clamp(0, 100),
      clean: (_state.clean - 0.2).clamp(0, 100),
      health: _calculateHealthDecay(),
      mood: _calculateMoodDecay(),
    );
    // 定期同步状态到成就系统
    achievementManager?.syncFromPetState(_state);
    _saveState();
    notifyListeners();
  }

  double _calculateHealthDecay() {
    // 健康度受饱食度和清洁度影响
    double healthChange = -0.1;
    if (_state.hunger < 20) healthChange -= 0.3;
    if (_state.clean < 20) healthChange -= 0.2;
    if (_state.energy < 15) healthChange -= 0.2;
    return (_state.health + healthChange).clamp(0, 100);
  }

  double _calculateMoodDecay() {
    // 心情受饱食度、精力和健康度影响
    double moodChange = -0.2;
    if (_state.hunger < 30) moodChange -= 0.5;
    if (_state.energy < 30) moodChange -= 0.3;
    if (_state.clean < 30) moodChange -= 0.2;
    if (_state.health < 30) moodChange -= 0.3;
    return (_state.mood + moodChange).clamp(0, 100);
  }

  /// 位置更新（闲逛模式）
  void _updatePosition() {
    if (!_autoRoam) return; // 未启用自动漫游

    if (_state.currentAction == 'idle' ||
        _state.currentAction == 'sit' ||
        _state.currentAction == 'sleep') {
      return; // 静止动作不移动
    }

    // 随机移动，有方向性
    if (_random.nextDouble() > 0.6) {
      double dx = (_random.nextDouble() - 0.5) * 6;
      double newX = _state.x + dx;

      // 边界检测 - 限制在窗口内
      final maxX = _screenWidth * 0.3;
      if (newX > maxX) {
        newX = maxX;
        dx = -dx.abs(); // 反弹
      }
      if (newX < -maxX) {
        newX = -maxX;
        dx = dx.abs(); // 反弹
      }

      bool newFacing = dx > 0 ? true : _state.facingRight;
      if (dx.abs() > 0.1) {
        newFacing = dx > 0;
      }
      _state = _state.copyWith(
        x: newX,
        facingRight: newFacing,
      );
      notifyListeners();
    }
  }

  // ---- 用户交互 ----

  /// 通用交互入口（供 UI 层调用）
  void interact(String action) {
    switch (action) {
      case 'pat':
        pat();
        _showEmote('💕');
        break;
      case 'feed':
        feed('bread');
        _showEmote('🍞');
        break;
      case 'sleep':
        _state = _state.copyWith(
          energy: (_state.energy + 30).clamp(0, 100),
          currentAction: 'sleep',
          emotion: 'sleepy',
        );
        _saveState();
        notifyListeners();
        _showEmote('💤');
        Future.delayed(const Duration(seconds: 5), () => _updateBehavior());
        break;
      case 'bath':
        bath();
        _showEmote('🛁');
        break;
      default:
        tap();
        _showEmote('✨');
    }
  }

  void _showEmote(String emote) {
    _currentEmote = emote;
    notifyListeners();
    Future.delayed(const Duration(seconds: 2), () {
      _currentEmote = null;
      notifyListeners();
    });
  }

  /// 点击互动
  void tap() {
    onUserActive(); // 标记用户活跃
    _state = _state.copyWith(
      mood: (_state.mood + 5).clamp(0, 100),
      currentAction: 'happy_jump',
      emotion: 'happy',
      exp: _state.exp + 2,
    );
    _checkLevelUp();
    _saveState();
    notifyListeners();

    // 2秒后恢复正常
    Future.delayed(const Duration(seconds: 2), () {
      _updateBehavior();
    });
  }

  /// 摸头（单击触发开心跳起来动画）
  void pat() {
    onUserActive(); // 标记用户活跃
    _patCount++;
    _state = _state.copyWith(
      mood: (_state.mood + 8).clamp(0, 100),
      currentAction: 'happy_jump',
      emotion: 'happy',
      exp: _state.exp + 3,
    );
    // 连续摸 5 次 → 害羞反应
    if (_patCount >= 5) {
      _patCount = 0;
      _state = _state.copyWith(emotion: 'shy', currentAction: 'shy');
      onEmotionalBehavior?.call('人家会害羞的啦~ 😳', 'shy');
    }
    // 记录成就事件
    achievementManager?.recordPat();
    _checkLevelUp();
    _saveState();
    notifyListeners();

    Future.delayed(const Duration(seconds: 3), () {
      _updateBehavior();
    });
  }
  int _patCount = 0;

  /// 喂食
  void feed(String food) {
    double hungerBoost;
    double moodBoost;
    int expBoost;

    switch (food) {
      case 'bread':
        hungerBoost = 15;
        moodBoost = 5;
        expBoost = 5;
        break;
      case 'fish':
        hungerBoost = 25;
        moodBoost = 10;
        expBoost = 8;
        break;
      case 'cake':
        hungerBoost = 10;
        moodBoost = 20;
        expBoost = 10;
        break;
      default:
        hungerBoost = 10;
        moodBoost = 5;
        expBoost = 3;
    }

    _state = _state.copyWith(
      hunger: (_state.hunger + hungerBoost).clamp(0, 100),
      mood: (_state.mood + moodBoost).clamp(0, 100),
      currentAction: 'eating',
      emotion: 'happy',
      exp: _state.exp + expBoost,
    );
    // 记录成就事件
    achievementManager?.recordFeeding();
    _checkLevelUp();
    _saveState();
    notifyListeners();

    Future.delayed(const Duration(seconds: 3), () {
      _state = _state.copyWith(
        currentAction: 'satisfied',
        emotion: 'happy',
      );
      notifyListeners();
      Future.delayed(const Duration(seconds: 2), () {
        _updateBehavior();
      });
    });
  }

  /// 洗澡
  void bath() {
    _state = _state.copyWith(
      clean: 100,
      mood: (_state.mood + 10).clamp(0, 100),
      currentAction: 'bathing',
      emotion: 'happy',
      exp: _state.exp + 5,
    );
    // 记录成就事件
    achievementManager?.recordBath();
    _checkLevelUp();
    _saveState();
    notifyListeners();

    Future.delayed(const Duration(seconds: 4), () {
      _updateBehavior();
    });
  }

  /// 外部调整心情值（对话情感反馈用）
  void adjustMood(double delta) {
    _state = _state.copyWith(
      mood: (_state.mood + delta).clamp(0, 100),
    );
    _saveState();
    notifyListeners();
  }

  /// AI 对话后更新情绪
  void setEmotion(String emotion) {
    String action = _emotionToAction(emotion);
    // 保护：如果已经停止工作（_isWorking == false），
    // 不允许 emotion 将 action 重新设回 working，否则工作动画不会退出
    if (!_isWorking && action == 'working') {
      action = 'idle';
      emotion = 'normal';
    }
    _state = _state.copyWith(
      emotion: emotion,
      currentAction: action,
    );
    notifyListeners();
  }

  /// 开始工作（对话/AI回复时调用）
  void startWorking() {
    _isWorking = true;
    _state = _state.copyWith(
      currentAction: 'working',
      emotion: 'working',
    );
    notifyListeners();
  }

  /// 停止工作（对话结束/AI回复完成时调用）
  void stopWorking() {
    _isWorking = false;
    _updateBehavior();
  }

  /// 鼠标悬浮触发被撸
  void onMouseHover() {
    if (_isWorking) return; // 工作中不被打断
    _state = _state.copyWith(
      currentAction: 'petted',
      emotion: 'happy',
      mood: (_state.mood + 2).clamp(0, 100),
    );
    notifyListeners();
  }

  /// 鼠标离开，恢复正常行为
  void onMouseLeave() {
    if (_isWorking) return;
    // 延迟一下再恢复，让被撸动画有时间播
    Future.delayed(const Duration(milliseconds: 500), () {
      if (!_isWorking) {
        _updateBehavior();
      }
    });
  }

  String _emotionToAction(String emotion) {
    switch (emotion) {
      case 'happy':
        return 'dance';
      case 'sad':
        return 'cry';            // 伤心 → 哭了动画
      case 'excited':
        return 'jump';
      case 'thinking':
        return 'working';
      case 'working':
        return 'working';
      case 'shy':
        return 'shy';
      case 'angry':
        return 'angry_stomp';    // 生气 → 哭了（气哭）
      case 'proud':
        return 'proud';
      case 'sick':
        return 'sick';           // 生病 → 困了
      case 'hungry':
        return 'cry';            // 饿了 → 哭了
      case 'sleepy':
        return 'yawn';           // 困了 → 犯困动画
      default:
        return 'idle';
    }
  }

  /// 检查升级
  void _checkLevelUp() {
    if (_state.exp >= _state.expToNextLevel) {
      final newLevel = _state.level + 1;
      _state = _state.copyWith(
        level: newLevel,
        exp: _state.exp - _state.expToNextLevel,
        mood: 100,
        currentAction: 'level_up',
        emotion: 'excited',
      );
      // 触发升级回调（UI 层显示特效/弹窗）
      onLevelUp?.call(newLevel);
    }
    // 同步宠物状态到成就系统
    achievementManager?.syncFromPetState(_state);
  }

  /// 发放成就奖励（金币+经验）
  void grantAchievementReward({int coins = 0, int exp = 0}) {
    _state = _state.copyWith(
      coins: _state.coins + coins,
      exp: _state.exp + exp,
    );
    if (exp > 0) _checkLevelUp();
    _saveState();
    notifyListeners();
  }

  /// 用户活跃标记（每次用户发消息/交互时调用）
  void onUserActive() {
    _lastUserInteraction = DateTime.now();
    _sessionMessageCount++;
  }

  /// 获取陪伴节奏描述（注入 prompt）
  String getCompanionRhythm() {
    final minutesSinceLastInteraction = DateTime.now().difference(_lastUserInteraction).inMinutes;
    if (minutesSinceLastInteraction > 120) {
      return '主人已经超过 $minutesSinceLastInteraction 分钟没有和你互动了，你有些想念主人';
    } else if (minutesSinceLastInteraction > 60) {
      return '主人有一段时间没说话了，你在安静地等待';
    } else if (_sessionMessageCount > 10) {
      return '主人今天和你聊了很多，你很开心';
    }
    return '';
  }

  /// 检查陪伴里程碑
  void _checkMilestone() {
    final days = _state.companionDays;
    final box = Hive.box('pet_state');
    final lastMilestoneDay = box.get('last_milestone_day', defaultValue: 0) as int;

    // 避免同一天重复触发
    if (lastMilestoneDay == days) return;

    String? message;
    String type = 'milestone';

    // 里程碑检测
    if (days == 1) {
      message = '今天是我们认识的第一天！鹅宝会好好陪你的！💕';
    } else if (days == 3) {
      message = '认识三天啦~ 鹅宝越来越喜欢主人了！😊';
    } else if (days == 7) {
      message = '已经一周了！主人有没有越来越喜欢鹅宝？🥺';
    } else if (days == 14) {
      message = '两周了！鹅宝觉得和主人越来越默契了鹅~ ✨';
    } else if (days == 30) {
      message = '一个月了！鹅宝觉得自己是世界上最幸福的鹅~ 🎉';
    } else if (days == 50) {
      message = '50天了！主人，谢谢你一直陪着鹅宝 💗';
    } else if (days == 100) {
      message = '100天！！这是鹅宝最珍贵的100天！谢谢主人一直在~ 🎊';
      type = 'bigMilestone';
    } else if (days == 200) {
      message = '200天了...鹅宝已经无法想象没有主人的日子了 🥹';
      type = 'bigMilestone';
    } else if (days == 365) {
      message = '一整年了！一年365天，鹅宝每一天都好开心能陪在你身边！🎂🦢';
      type = 'bigMilestone';
    } else if (days % 100 == 0 && days > 100) {
      message = '已经陪伴主人 $days 天了~ 鹅宝的幸福也增加了 $days 点！💕';
    }

    if (message != null) {
      box.put('last_milestone_day', days);
      onMilestone?.call(message, type);
    }
  }

  /// 检查欢迎回来
  void _checkWelcomeBack() {
    if (_welcomeSentToday) return;
    if (_lastOfflineTime == null) return;

    final offlineMinutes = DateTime.now().difference(_lastOfflineTime!).inMinutes;
    final hour = DateTime.now().hour;

    String? welcomeMessage;

    if (offlineMinutes > 60 * 24) {
      // 超过 1 天没上线
      final offlineDays = (offlineMinutes / (60 * 24)).floor();
      if (offlineDays >= 3) {
        welcomeMessage = '主人！你终于回来了！鹅宝以为你不要我了呜呜... 😭💕';
      } else {
        welcomeMessage = '主人回来啦！鹅宝等你好久了！$offlineDays天不见好想你~ 🥺';
      }
    } else if (offlineMinutes > 60 * 4) {
      // 离开 4 小时以上
      if (hour >= 6 && hour < 12) {
        welcomeMessage = '早安主人~ ☀️ 新的一天又可以陪你了，鹅宝好开心！';
      } else if (hour >= 12 && hour < 18) {
        welcomeMessage = '主人下午好~ 鹅宝在等你回来呢！😊';
      } else {
        welcomeMessage = '主人晚上好~ 你终于来了，鹅宝一直在这里等你鹅~ 🌙';
      }
    }

    if (welcomeMessage != null) {
      _welcomeSentToday = true;
      onMilestone?.call(welcomeMessage, 'welcome');
    }
  }

  /// 检查连续登录天数
  int getConsecutiveLoginDays() {
    final box = Hive.box('pet_state');
    final lastLoginDate = box.get('last_login_date', defaultValue: '') as String;
    final consecutiveDays = box.get('consecutive_login_days', defaultValue: 0) as int;

    final today = DateTime.now();
    final todayStr = '${today.year}-${today.month.toString().padLeft(2, '0')}-${today.day.toString().padLeft(2, '0')}';

    if (lastLoginDate == todayStr) {
      return consecutiveDays;
    }

    // 检查是否是连续日期
    int newConsecutive;
    if (lastLoginDate.isNotEmpty) {
      try {
        final lastDate = DateTime.parse(lastLoginDate);
        final daysDiff = today.difference(lastDate).inDays;
        if (daysDiff == 1) {
          newConsecutive = consecutiveDays + 1;
        } else {
          newConsecutive = 1; // 断签
        }
      } catch (_) {
        newConsecutive = 1;
      }
    } else {
      newConsecutive = 1;
    }

    box.put('last_login_date', todayStr);
    box.put('consecutive_login_days', newConsecutive);
    return newConsecutive;
  }

  /// 鹅宝主动情绪表达（由行为引擎定时触发）
  void _checkEmotionalBehavior() {
    if (_isWorking) return;

    final minutesSinceInteraction = DateTime.now().difference(_lastUserInteraction).inMinutes;

    // 好久没被摸 → 求关注
    if (minutesSinceInteraction > 90 && _random.nextDouble() < 0.2) {
      _state = _state.copyWith(currentAction: 'idle', emotion: 'sad');
      onEmotionalBehavior?.call('主人...摸摸鹅宝嘛~ 🥺', 'seekAttention');
      notifyListeners();
      return;
    }

    // mood 很低持续 → 闹脾气
    if (_state.mood < 25 && _random.nextDouble() < 0.15) {
      _state = _state.copyWith(currentAction: 'slouch', emotion: 'sad');
      onEmotionalBehavior?.call('鹅宝不开心...', 'upset');
      notifyListeners();
      return;
    }

    // mood 很高 → 主动撒娇
    if (_state.mood > 85 && _random.nextDouble() < 0.1) {
      _state = _state.copyWith(currentAction: 'happy_jump', emotion: 'happy');
      onEmotionalBehavior?.call('嘿嘿~ 鹅宝今天好开心呀！', 'happy');
      notifyListeners();
      return;
    }

    // 饿了很久 → 撒娇求吃
    if (_state.hunger < 15 && _random.nextDouble() < 0.25) {
      onEmotionalBehavior?.call('主人...鹅宝肚子咕咕叫了...🥺', 'hungry');
      return;
    }
  }

  @override
  void dispose() {
    _behaviorTimer?.cancel();
    _decayTimer?.cancel();
    _moveTimer?.cancel();
    _coinTimer?.cancel();
    _proactiveTimer?.cancel();
    _saveState();
    super.dispose();
  }
}
