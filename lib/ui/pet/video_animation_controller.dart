import 'package:flutter/foundation.dart';

/// 动画视频配置项
class AnimationVideoConfig {
  /// 动画名称（唯一标识）
  final String name;

  /// 视频资源路径（assets 下的路径）
  final String assetPath;

  /// 是否循环播放
  final bool loop;

  /// 优先级（数值越大越优先）
  final int priority;

  /// 播放完成后自动跳转到的动画（状态机转换）
  /// 为 null 时回到 defaultAnimation
  final String? nextAnimation;

  const AnimationVideoConfig({
    required this.name,
    required this.assetPath,
    this.loop = true,
    this.priority = 0,
    this.nextAnimation,
  });

  @override
  String toString() => 'AnimationVideoConfig($name, loop=$loop, next=$nextAnimation)';
}

/// 动画状态转换规则
class AnimationTransition {
  /// 来源动画
  final String from;

  /// 目标动画
  final String to;

  /// 触发条件（action 名称）
  final String? triggerAction;

  /// 触发条件（mood 名称）
  final String? triggerMood;

  const AnimationTransition({
    required this.from,
    required this.to,
    this.triggerAction,
    this.triggerMood,
  });
}

/// 视频动画状态机控制器
///
/// 支持：
/// - 可配置的动画注册
/// - 动作/心情 → 动画映射
/// - 动画之间的状态转换（播完后跳转下一个）
/// - 一次性动画播放保护（不被打断）
/// - 外部可配置（JSON 等）
class VideoAnimationController extends ChangeNotifier {
  /// 所有已注册的动画配置
  final Map<String, AnimationVideoConfig> _animations = {};

  /// 动作 -> 动画名称映射
  final Map<String, String> _actionMapping = {};

  /// 心情 -> 动画名称映射
  final Map<String, String> _moodMapping = {};

  /// 当前正在播放的动画名称
  String _currentAnimation = 'cute';

  /// 默认/兜底动画（装萌）
  String _defaultAnimation = 'cute';

  /// 默认动画池（idle 状态下顺序轮流播放：装萌 + 无聊发呆）
  final List<String> _idleAnimationPool = [];

  /// 当前 idle 池索引（用于顺序轮流播放）
  int _idlePoolIndex = 0;

  /// 是否正在播放一次性（非循环）动画
  bool _isPlayingOneShot = false;

  /// 等待队列中的下一个动画名称（一次性动画播完后播放）
  String? _pendingAnimationName;

  /// 是否正在等待循环动画播完当前一遍后退出
  /// 当从循环动画（如 work）切到其他动画时，先让当前一遍播完再切换
  bool _isWaitingLoopExit = false;

  String get currentAnimation => _currentAnimation;
  String get defaultAnimation => _defaultAnimation;
  bool get isPlayingOneShot => _isPlayingOneShot;
  bool get isWaitingLoopExit => _isWaitingLoopExit;
  String? get pendingAnimationName => _pendingAnimationName;
  List<String> get idleAnimationPool => List.unmodifiable(_idleAnimationPool);

  /// 获取当前应播放的视频配置
  AnimationVideoConfig? get currentConfig => _animations[_currentAnimation];

  /// 获取所有已注册的动画名称
  List<String> get animationNames => _animations.keys.toList();

  /// 获取所有动画配置（供外部查看）
  Map<String, AnimationVideoConfig> get animations => Map.unmodifiable(_animations);

  VideoAnimationController() {
    _registerBuiltInAnimations();
    // cute 是循环动画，初始不需要标记 one-shot
    _isPlayingOneShot = false;
  }

  /// 注册内置动画（基于 assets/animations/ 下的全部 11 个文件）
  void _registerBuiltInAnimations() {
    // ═══════════════════════════════════════════════════════
    // 🎬 默认/idle 动画（空闲时交替播放）
    // ═══════════════════════════════════════════════════════

    // 装萌 - 默认兜底动画（循环播放，确保永远不会卡住）
    registerAnimation(const AnimationVideoConfig(
      name: 'cute',
      assetPath: 'assets/animations/装萌.mp4',
      loop: true,
      priority: 0,
    ));

    // 无聊发呆 - idle 池成员，与装萌交替播放
    registerAnimation(const AnimationVideoConfig(
      name: 'idle',
      assetPath: 'assets/animations/无聊发呆.mp4',
      loop: false,
      priority: 0,
    ));

    // 玩玩具 - 通过动作触发的一次性动画（不在默认 idle 池中）
    registerAnimation(const AnimationVideoConfig(
      name: 'play',
      assetPath: 'assets/animations/玩玩具.mp4',
      loop: false,
      priority: 0,
    ));

    // ═══════════════════════════════════════════════════════
    // 🎬 事件触发的一次性动画
    // ═══════════════════════════════════════════════════════

    // 吃零食 - 吃完后跳转到开心跳（吃饱了好开心！）
    registerAnimation(const AnimationVideoConfig(
      name: 'eat',
      assetPath: 'assets/animations/吃零食.mp4',
      loop: false,
      priority: 10,
      nextAnimation: 'jump',
    ));

    // 开心的跳起来 - 高兴事件触发，播完回 idle 池
    registerAnimation(const AnimationVideoConfig(
      name: 'jump',
      assetPath: 'assets/animations/开心的跳起来.mp4',
      loop: false,
      priority: 8,
    ));

    // 被撸了 - 鼠标悬浮/抚摸触发，播完回 idle 池
    registerAnimation(const AnimationVideoConfig(
      name: 'petted',
      assetPath: 'assets/animations/被撸了.mp4',
      loop: false,
      priority: 6,
    ));

    // 洗澡 - 清洁物品触发，洗完后跳转到装萌（洗干净美美的！）
    registerAnimation(const AnimationVideoConfig(
      name: 'bath',
      assetPath: 'assets/animations/洗澡.mp4',
      loop: false,
      priority: 7,
      nextAnimation: 'cute',
    ));

    // 哭了 - 伤心/饥饿/心情低落时播放，哭完回到困了（哭累了）
    registerAnimation(const AnimationVideoConfig(
      name: 'cry',
      assetPath: 'assets/animations/哭了.mp4',
      loop: false,
      priority: 4,
      nextAnimation: 'sleepy',
    ));

    // ═══════════════════════════════════════════════════════
    // 🎬 状态持续型动画
    // ═══════════════════════════════════════════════════════

    // 工作 - 对话/思考时循环播放
    registerAnimation(const AnimationVideoConfig(
      name: 'work',
      assetPath: 'assets/animations/工作.mp4',
      loop: true,
      priority: 9,
    ));

    // 睡觉 - 精力极低时循环播放
    registerAnimation(const AnimationVideoConfig(
      name: 'sleep',
      assetPath: 'assets/animations/睡觉.mp4',
      loop: true,
      priority: 3,
    ));

    // 困了 - 精力偏低/犯困时播放（打哈欠），播完可能进入睡觉
    registerAnimation(const AnimationVideoConfig(
      name: 'sleepy',
      assetPath: 'assets/animations/困了.mp4',
      loop: false,
      priority: 2,
    ));

    // ═══════════════════════════════════════════════════════
    // 🎲 默认动画池：idle 状态下交替播放（装萌 + 无聊发呆）
    // cute 是循环动画，idle 是一次性动画，交替切换
    // ═══════════════════════════════════════════════════════
    _idleAnimationPool.addAll(['cute', 'idle']);

    // ═══════════════════════════════════════════════════════
    // 🗺️ 动作 → 动画 映射
    // ═══════════════════════════════════════════════════════
    _actionMapping.addAll({
      // --- idle 系列 → 走默认动画（cute）---
      'idle': 'cute',
      'look_around': 'cute',
      'sit': 'cute',
      'flap_wings': 'cute',
      'satisfied': 'cute',       // 吃饱/满足 → 装萌（美滋滋）

      // --- 困倦系列 ---
      'yawn': 'sleepy',          // 打哈欠 → 困了动画
      'sleep': 'sleep',          // 睡觉 → 睡觉循环
      'resting': 'sleepy',       // 休息 → 困了

      // --- 悲伤系列 ---
      'cry': 'cry',              // 哭泣 → 哭了动画
      'slouch': 'cry',           // 垂头丧气 → 哭了
      'sigh': 'sleepy',          // 叹气 → 困了（无精打采）

      // --- 工作/思考 ---
      'working': 'work',
      'thinking': 'work',
      'chatting': 'work',

      // --- 生病 → 困了（病恹恹的） ---
      'sick': 'sleepy',

      // --- 清洁/洗澡 ---
      'bathing': 'bath',         // 洗澡 → 洗澡动画

      // --- 生气 → 哭了（气哭了） ---
      'angry_stomp': 'cry',

      // --- 吃相关 → eat（状态机自动跳转 jump） ---
      'eating': 'eat',
      'feed': 'eat',

      // --- 开心/兴奋 ---
      'happy_jump': 'jump',
      'jump': 'jump',
      'dance': 'jump',
      'spin': 'jump',
      'level_up': 'jump',

      // --- 被撸/抚摸 ---
      'petted': 'petted',
      'pat': 'petted',

      // --- 装萌/互动 ---
      'shy': 'cute',
      'proud': 'cute',
      'wave': 'cute',

      // --- 玩耍 ---
      'play': 'play',
      'play_toy': 'play',
    });

    // ═══════════════════════════════════════════════════════
    // 🗺️ 心情 → 动画映射（优先级低于动作映射）
    // ═══════════════════════════════════════════════════════
    _moodMapping.addAll({
      'happy': 'cute',           // 心情好 → 装萌
      'excited': 'jump',         // 很兴奋 → 跳起来
      'normal': 'cute',          // 一般 → 装萌
      'sad': 'cry',              // 伤心 → 哭了
      'sleepy': 'sleepy',        // 困了 → 困了动画
      'angry': 'cry',            // 生气 → 哭了（气哭了）
      'sick': 'sleepy',          // 生病 → 困了
      'working': 'work',         // 工作中 → 工作
      'hungry': 'cry',           // 饿了 → 哭了
    });
  }

  /// 注册一个动画
  void registerAnimation(AnimationVideoConfig config) {
    _animations[config.name] = config;
  }

  /// 注销一个动画
  void unregisterAnimation(String name) {
    if (name != _defaultAnimation) {
      _animations.remove(name);
    }
  }

  /// 设置默认动画
  void setDefaultAnimation(String name) {
    if (_animations.containsKey(name)) {
      _defaultAnimation = name;
    }
  }

  /// 添加动作 -> 动画映射
  void addActionMapping(String action, String animationName) {
    _actionMapping[action] = animationName;
  }

  /// 批量添加动作映射
  void addActionMappings(Map<String, String> mappings) {
    _actionMapping.addAll(mappings);
  }

  /// 添加心情 -> 动画映射
  void addMoodMapping(String mood, String animationName) {
    _moodMapping[mood] = animationName;
  }

  /// 获取动画播放完成后应该跳转的目标动画
  /// 返回 null 表示回到 defaultAnimation
  String getNextAnimation(String currentAnimName) {
    final config = _animations[currentAnimName];
    if (config == null) return _defaultAnimation;
    return config.nextAnimation ?? _defaultAnimation;
  }

  /// 根据 PetEngine 状态更新应播放的动画
  /// 返回是否发生了动画切换
  bool updateFromState({
    required String action,
    required String mood,
    required String emotion,
  }) {
    String targetAnimation = _defaultAnimation;

    // 优先级1：动作映射
    if (_actionMapping.containsKey(action)) {
      final mapped = _actionMapping[action]!;
      if (_animations.containsKey(mapped)) {
        targetAnimation = mapped;
      }
    }

    // 如果动作没有匹配到具体动画，尝试心情映射
    if (targetAnimation == _defaultAnimation && action == 'idle') {
      if (_moodMapping.containsKey(mood)) {
        final mapped = _moodMapping[mood]!;
        if (_animations.containsKey(mapped)) {
          targetAnimation = mapped;
        }
      }
    }

    // 检查目标动画视频是否存在
    if (!_animations.containsKey(targetAnimation)) {
      targetAnimation = _defaultAnimation;
    }

    // 与当前动画相同，不需要切换
    if (targetAnimation == _currentAnimation) {
      return false;
    }

    // 如果目标和当前都在 idle 池中，且当前是循环动画（cute），
    // 不打断循环（让 idle 偶尔通过定时器触发）
    if (_isIdlePoolAnimation(targetAnimation) && _isIdlePoolAnimation(_currentAnimation)) {
      // 当前是 cute（循环播放中），不需要被 idle 状态更新打断
      final currentConfig = _animations[_currentAnimation];
      if (currentConfig != null && currentConfig.loop) {
        return false;
      }
      // 当前是 idle（one-shot 播放中），也不需要被 cute 打断，等播完自然回 cute
      return false;
    }

    // 🔒 一次性动画保护：如果正在播放一次性动画，不允许打断
    // 将目标动画放入等待队列，等播完后再切换
    // 但如果目标动画属于 idle 池且当前也在 idle 池随机播放中，不排队
    // （否则 PetEngine 每 8 秒的 idle 状态更新会不断把 'idle' 排入队列，
    //  导致 onOneShotCompleted 总是从排队动画取到 'idle'，跳过池随机选择）
    if (_isPlayingOneShot) {
      if (_isIdlePoolAnimation(targetAnimation) && _isIdlePoolAnimation(_currentAnimation)) {
        // 当前在 idle 池随机播放中，目标也是 idle 池的，不需要排队
        return false;
      }
      if (_pendingAnimationName != targetAnimation) {
        _pendingAnimationName = targetAnimation;
        debugPrint('🎬 动画排队(状态): $targetAnimation (等待 $_currentAnimation 播完)');
      }
      return false;
    }

    // 🔒 循环动画优雅退出：如果当前是循环动画（如 work）且目标不是循环动画，
    // 不立即切断，让当前循环播完一遍后再切换到目标动画。
    // 如果目标也是循环动画（如 sleep→work），说明是高优先级切换，立即执行。
    // 例外：idle 池中的动画（如无聊发呆）可以被立即打断，不需要等待循环完成。
    final currentConfig = _animations[_currentAnimation];
    final targetConfig = _animations[targetAnimation];
    final targetIsLoop = targetConfig != null && targetConfig.loop;
    final currentIsIdlePool = _isIdlePoolAnimation(_currentAnimation);
    if (currentConfig != null && currentConfig.loop && !targetIsLoop && !_isWaitingLoopExit && !currentIsIdlePool) {
      _isWaitingLoopExit = true;
      _pendingAnimationName = targetAnimation;
      debugPrint('🎬 循环动画等待播完: $_currentAnimation -> $targetAnimation (等待当前循环结束)');
      notifyListeners(); // 通知 PetVideoPlayer 修改循环模式
      return false;
    }

    // 如果已经在等待循环退出，只更新目标动画
    if (_isWaitingLoopExit) {
      _pendingAnimationName = targetAnimation;
      return false;
    }

    final oldAnimation = _currentAnimation;
    _currentAnimation = targetAnimation;
    _animationSequence++;
    final config = _animations[targetAnimation];
    _isPlayingOneShot = config != null && !config.loop;
    _pendingAnimationName = null;
    debugPrint('🎬 动画切换: $oldAnimation -> $targetAnimation (action=$action, mood=$mood, seq=$_animationSequence)');
    notifyListeners();
    return true;
  }

  /// 请求播放指定动画
  /// 如果当前有一次性动画正在播放，会排入队列等待播完后再切换
  void playAnimation(String name) {
    if (!_animations.containsKey(name)) return;
    if (name == _currentAnimation) return;

    // 🔒 一次性动画保护
    if (_isPlayingOneShot) {
      if (_pendingAnimationName != name) {
        _pendingAnimationName = name;
        debugPrint('🎬 动画排队(手动): $name (等待 $_currentAnimation 播完)');
      }
      return;
    }

    // 🔒 循环动画优雅退出（只在目标不是循环动画时等待）
    final currentConfig = _animations[_currentAnimation];
    final targetConfig = _animations[name];
    final targetIsLoop = targetConfig != null && targetConfig.loop;
    if (currentConfig != null && currentConfig.loop && !targetIsLoop && !_isWaitingLoopExit) {
      _isWaitingLoopExit = true;
      _pendingAnimationName = name;
      debugPrint('🎬 循环动画等待播完(手动): $_currentAnimation -> $name');
      notifyListeners();
      return;
    }

    if (_isWaitingLoopExit) {
      _pendingAnimationName = name;
      return;
    }

    _currentAnimation = name;
    _animationSequence++;
    final config = _animations[name];
    _isPlayingOneShot = config != null && !config.loop;
    _pendingAnimationName = null;
    debugPrint('🎬 播放动画: $name (seq=$_animationSequence)');
    notifyListeners();
  }

  /// 检查某个动画是否属于默认动画池
  bool _isIdlePoolAnimation(String name) {
    return _idleAnimationPool.contains(name);
  }

  /// 自增的动画播放序号，每次切换动画时递增
  /// 用于 PetVideoPlayer 判断"名称相同但需要重新播放"的情况
  int _animationSequence = 0;
  int get animationSequence => _animationSequence;

  /// 通知控制器当前一次性动画已播放完毕
  /// 由 PetVideoPlayer 在检测到播放完成时调用
  void onOneShotCompleted() {
    // 处理循环动画等待退出的情况（循环模式改为非循环后播完一遍触发 completed）
    if (_isWaitingLoopExit) {
      _isWaitingLoopExit = false;
      final completedName = _currentAnimation;

      if (_pendingAnimationName != null) {
        final pendingName = _pendingAnimationName!;
        _pendingAnimationName = null;
        debugPrint('🎬 循环动画播完退出: $completedName -> $pendingName');

        if (_animations.containsKey(pendingName)) {
          _currentAnimation = pendingName;
          _animationSequence++;
          final pendingConfig = _animations[pendingName];
          _isPlayingOneShot = pendingConfig != null && !pendingConfig.loop;
          notifyListeners();
          return;
        }
      }

      // 没有待切换动画，回到默认动画（cute 循环播放）
      debugPrint('🎬 循环动画播完退出: $completedName -> 默认动画: $_defaultAnimation');
      _currentAnimation = _defaultAnimation;
      _animationSequence++;
      _isPlayingOneShot = false; // cute 是循环动画
      notifyListeners();
      return;
    }

    if (!_isPlayingOneShot) return;

    final completedName = _currentAnimation;
    _isPlayingOneShot = false;

    // 优先级1：状态机跳转（nextAnimation）
    // 如果动画自身配置了明确的 nextAnimation（如 eat→jump），
    // 则优先执行状态机跳转，不被外部排队的动画覆盖
    final config = _animations[completedName];
    if (config != null && config.nextAnimation != null) {
      final nextAnimName = config.nextAnimation!;
      debugPrint('🎬 一次性动画完成: $completedName, 状态机跳转: $nextAnimName');

      if (_animations.containsKey(nextAnimName)) {
        _currentAnimation = nextAnimName;
        _animationSequence++;
        final nextConfig = _animations[nextAnimName];
        _isPlayingOneShot = nextConfig != null && !nextConfig.loop;
        // 清空排队动画，让状态机优先
        _pendingAnimationName = null;
        notifyListeners();
        return;
      }
    }

    // 优先级2：排队等待的动画（外部通过 updateFromState 或 playAnimation 排入）
    // 但如果排队动画属于 idle 池且刚播完的也在 idle 池中，跳过走默认
    if (_pendingAnimationName != null) {
      final pendingName = _pendingAnimationName!;
      _pendingAnimationName = null;

      final pendingIsIdlePool = _isIdlePoolAnimation(pendingName);
      final completedIsIdlePool = _isIdlePoolAnimation(completedName);

      if (pendingIsIdlePool && completedIsIdlePool) {
        // 跳过，让下面的默认逻辑处理
        debugPrint('🎬 一次性动画完成: $completedName, 排队动画 $pendingName 属于 idle 池，走默认');
      } else if (_animations.containsKey(pendingName)) {
        debugPrint('🎬 一次性动画完成: $completedName, 切换到排队动画: $pendingName');
        _currentAnimation = pendingName;
        _animationSequence++;
        final pendingConfig = _animations[pendingName];
        _isPlayingOneShot = pendingConfig != null && !pendingConfig.loop;
        notifyListeners();
        return;
      }
    }

    // 优先级3：回到默认动画（cute 循环播放）
    // 无论刚播完的是什么 one-shot 动画，都回到 cute 循环
    // cute 是循环动画，不会触发 completed，所以不会再卡死
    debugPrint('🎬 一次性动画完成: $completedName -> 回到默认动画: $_defaultAnimation');
    _currentAnimation = _defaultAnimation;
    _animationSequence++;
    final defaultConfig = _animations[_defaultAnimation];
    _isPlayingOneShot = defaultConfig != null && !defaultConfig.loop;
    notifyListeners();
  }

  /// 回到默认动画（cute 循环播放）
  void playDefault() {
    if (_currentAnimation == _defaultAnimation) return;
    playAnimation(_defaultAnimation);
  }

  /// 偶尔触发 idle 池中的非默认动画（如无聊发呆），实现交替播放
  /// 由外部定时器调用，让宠物偶尔从装萌切到无聊发呆
  void playIdleRandom() {
    // 只有在播放默认循环动画（cute）时才触发
    if (_currentAnimation != _defaultAnimation) return;
    if (_isPlayingOneShot) return;
    if (_isWaitingLoopExit) return;

    // 从 idle 池中选一个非 cute 的动画
    final nonDefaultIdle = _idleAnimationPool.where((n) => n != _defaultAnimation).toList();
    if (nonDefaultIdle.isEmpty) return;

    final nextIdle = nonDefaultIdle[_idlePoolIndex % nonDefaultIdle.length];
    _idlePoolIndex = (_idlePoolIndex + 1) % nonDefaultIdle.length;

    debugPrint('🎬 idle 交替触发: $_currentAnimation -> $nextIdle');

    // cute 是循环动画，需要等播完当前一遍再切换
    _isWaitingLoopExit = true;
    _pendingAnimationName = nextIdle;
    notifyListeners(); // 通知 PetVideoPlayer 改为非循环模式
  }
}
