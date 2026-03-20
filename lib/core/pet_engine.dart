import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';
import '../models/models.dart';

/// 宠物行为引擎
/// 管理鹅宝的状态、行为状态机、属性衰减和物理移动
class PetEngine extends ChangeNotifier {
  PetState _state = const PetState();
  Timer? _behaviorTimer;
  Timer? _decayTimer;
  Timer? _moveTimer;
  final Random _random = Random();

  // 行为状态机
  static const List<String> _idleActions = [
    'idle', 'look_around', 'sit', 'yawn', 'flap_wings',
  ];
  static const List<String> _happyActions = [
    'dance', 'jump', 'spin',
  ];
  static const List<String> _sadActions = [
    'cry', 'slouch', 'sigh',
  ];

  PetState get state => _state;

  // ---- UI 便捷访问器 ----
  double get happiness => _state.mood;
  double get hunger => _state.hunger;
  double get energy => _state.energy;
  String get mood {
    if (_state.mood > 80) return 'happy';
    if (_state.mood > 60) return 'neutral';
    if (_state.mood > 40) return 'sad';
    if (_state.mood > 20) return 'sleepy';
    return 'angry';
  }
  String? _currentEmote;
  String? get currentEmote => _currentEmote;

  PetEngine() {
    _loadState();
    _startEngines();
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
  }

  /// 保存宠物状态
  void _saveState() {
    final box = Hive.box('pet_state');
    box.put('pet_state', _state.toJson());
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
  }

  /// 行为状态机 - 根据当前属性决定下一个行为
  void _updateBehavior() {
    String nextAction;
    String nextEmotion;

    if (_state.hunger < 20) {
      // 太饿了
      nextEmotion = 'hungry';
      nextAction = _sadActions[_random.nextInt(_sadActions.length)];
    } else if (_state.energy < 20) {
      // 太累了
      nextEmotion = 'sleepy';
      nextAction = 'sleep';
    } else if (_state.mood > 80) {
      // 心情好
      nextEmotion = 'happy';
      nextAction = _random.nextDouble() > 0.5
          ? _happyActions[_random.nextInt(_happyActions.length)]
          : _idleActions[_random.nextInt(_idleActions.length)];
    } else if (_state.mood < 30) {
      // 心情差
      nextEmotion = 'sad';
      nextAction = _sadActions[_random.nextInt(_sadActions.length)];
    } else {
      // 正常状态
      nextEmotion = 'normal';
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
      mood: _calculateMoodDecay(),
    );
    _saveState();
    notifyListeners();
  }

  double _calculateMoodDecay() {
    // 心情受饱食度和精力影响
    double moodChange = -0.2;
    if (_state.hunger < 30) moodChange -= 0.5;
    if (_state.energy < 30) moodChange -= 0.3;
    if (_state.clean < 30) moodChange -= 0.2;
    return (_state.mood + moodChange).clamp(0, 100);
  }

  /// 位置更新（闲逛模式）
  void _updatePosition() {
    if (_state.currentAction == 'idle' ||
        _state.currentAction == 'sit' ||
        _state.currentAction == 'sleep') {
      return; // 静止动作不移动
    }

    // 随机小幅度移动
    if (_random.nextDouble() > 0.7) {
      double dx = (_random.nextDouble() - 0.5) * 4;
      bool newFacing = dx > 0 ? true : _state.facingRight;
      if (dx.abs() > 0.1) {
        newFacing = dx > 0;
      }
      _state = _state.copyWith(
        x: _state.x + dx,
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

  /// 摸头
  void pat() {
    _state = _state.copyWith(
      mood: (_state.mood + 8).clamp(0, 100),
      currentAction: 'shy',
      emotion: 'shy',
      exp: _state.exp + 3,
    );
    _checkLevelUp();
    _saveState();
    notifyListeners();

    Future.delayed(const Duration(seconds: 3), () {
      _updateBehavior();
    });
  }

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
    _checkLevelUp();
    _saveState();
    notifyListeners();

    Future.delayed(const Duration(seconds: 4), () {
      _updateBehavior();
    });
  }

  /// AI 对话后更新情绪
  void setEmotion(String emotion) {
    _state = _state.copyWith(
      emotion: emotion,
      currentAction: _emotionToAction(emotion),
    );
    notifyListeners();
  }

  String _emotionToAction(String emotion) {
    switch (emotion) {
      case 'happy':
        return 'dance';
      case 'sad':
        return 'slouch';
      case 'excited':
        return 'jump';
      case 'thinking':
        return 'thinking';
      case 'shy':
        return 'shy';
      case 'angry':
        return 'angry_stomp';
      case 'proud':
        return 'proud';
      default:
        return 'idle';
    }
  }

  /// 检查升级
  void _checkLevelUp() {
    if (_state.exp >= _state.expToNextLevel) {
      _state = _state.copyWith(
        level: _state.level + 1,
        exp: _state.exp - _state.expToNextLevel,
        mood: 100,
        currentAction: 'level_up',
        emotion: 'excited',
      );
    }
  }

  @override
  void dispose() {
    _behaviorTimer?.cancel();
    _decayTimer?.cancel();
    _moveTimer?.cancel();
    _saveState();
    super.dispose();
  }
}
