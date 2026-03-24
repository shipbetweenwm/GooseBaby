import 'dart:async';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'video_animation_controller.dart';

/// 宠物视频动画播放器（基于 media_kit，双缓冲无闪烁切换）
///
/// 使用两个 Player 交替工作：
/// - 前台播放器：正在显示的动画
/// - 后台播放器：预加载下一个动画，等第一帧渲染完毕后瞬间切换到前台
///
/// 这样动画切换时不会出现空帧/黑帧闪烁。
class PetVideoPlayer extends StatefulWidget {
  final VideoAnimationController animationController;
  final double width;
  final double height;

  const PetVideoPlayer({
    super.key,
    required this.animationController,
    this.width = 157,
    this.height = 280,
  });

  @override
  State<PetVideoPlayer> createState() => _PetVideoPlayerState();
}

class _PetVideoPlayerState extends State<PetVideoPlayer> {
  // ──── 双缓冲：两组 Player + VideoController ────
  late final Player _playerA;
  late final Player _playerB;
  late final VideoController _videoControllerA;
  late final VideoController _videoControllerB;

  /// 当前前台显示的是 A (true) 还是 B (false)
  bool _showingA = true;

  /// 当前播放的动画名称
  String _currentAnimName = '';

  /// 当前播放的动画序号（用于判断同名动画是否需要重播）
  int _currentAnimSequence = -1;

  /// 是否已有第一帧（首次初始化完成）
  bool _isReady = false;

  /// 是否正在切换动画
  bool _isSwitching = false;

  /// 切换计数器，用于识别"过期"的 completed 事件
  int _switchGeneration = 0;

  /// 当前前台 Player 的 completed 订阅
  StreamSubscription<bool>? _completedSub;

  /// 当前前台 Player 的 position 订阅（用于检测播放完成）
  StreamSubscription<Duration>? _positionSub;

  /// 是否已触发过当前视频的完成回调（防止重复触发）
  bool _completedTriggered = false;

  /// 健康检查定时器：定期检查播放器是否卡住
  Timer? _healthCheckTimer;

  /// idle 交替定时器：偶尔从装萌切到无聊发呆
  Timer? _idleAlternateTimer;

  Player get _foregroundPlayer => _showingA ? _playerA : _playerB;
  Player get _backgroundPlayer => _showingA ? _playerB : _playerA;

  @override
  void initState() {
    super.initState();

    // 创建双 Player
    _playerA = Player();
    _playerB = Player();

    // 配置双 VideoController（启用硬件加速）
    _videoControllerA = VideoController(
      _playerA,
      configuration: const VideoControllerConfiguration(
        enableHardwareAcceleration: true,
      ),
    );
    _videoControllerB = VideoController(
      _playerB,
      configuration: const VideoControllerConfiguration(
        enableHardwareAcceleration: true,
      ),
    );

    // 静音（两个播放器都静音）
    _playerA.setVolume(0);
    _playerB.setVolume(0);

    // 监听动画控制器变化
    widget.animationController.addListener(_onAnimationChanged);

    // 初始化默认动画
    _initCurrentAnimation();

    // 启动健康检查定时器：每 3 秒检查播放器是否卡住
    _healthCheckTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      _performHealthCheck();
    });

    // 启动 idle 交替定时器：每 15-25 秒偶尔从装萌切到无聊发呆
    _startIdleAlternateTimer();
  }

  /// 订阅前台播放器的事件（completed + position）
  /// 双重检测机制：
  /// 1. completed 事件：标准完成信号
  /// 2. position 检测：当 position >= duration - 100ms 时触发完成
  ///    这是对短视频 completed 事件丢失的补救措施
  void _listenForegroundEvents() {
    _completedSub?.cancel();
    _positionSub?.cancel();
    _completedTriggered = false;

    final player = _foregroundPlayer;

    // 订阅 completed 事件
    _completedSub = player.stream.completed.listen(_onPlaybackCompleted);

    // 订阅 position 事件，用于检测播放完成（补救 completed 事件丢失）
    _positionSub = player.stream.position.listen((position) {
      if (_completedTriggered || _isSwitching || !mounted) return;

      final duration = player.state.duration;
      // 只有当 duration 有效（> 0）且 position 接近结尾时才触发
      if (duration.inMilliseconds > 0) {
        final remaining = duration - position;
        // 当剩余时间 <= 100ms 时认为播放完成
        if (remaining.inMilliseconds <= 100) {
          _completedTriggered = true;
          debugPrint('🎬 [position检测] 视频即将结束: $_currentAnimName, pos=${position.inMilliseconds}ms, dur=${duration.inMilliseconds}ms');
          _triggerCompletion();
        }
      }
    });
  }

  /// 触发播放完成回调
  void _triggerCompletion() {
    if (!mounted) return;
    final gen = _switchGeneration;

    Future.microtask(() {
      if (!mounted || _switchGeneration != gen) return;
      debugPrint('🎬 动画播放完成: $_currentAnimName, 通知控制器');
      widget.animationController.onOneShotCompleted();
    });
  }

  @override
  void didUpdateWidget(PetVideoPlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.animationController != widget.animationController) {
      oldWidget.animationController.removeListener(_onAnimationChanged);
      widget.animationController.addListener(_onAnimationChanged);
    }
  }

  @override
  void dispose() {
    _completedSub?.cancel();
    _positionSub?.cancel();
    _healthCheckTimer?.cancel();
    _idleAlternateTimer?.cancel();
    widget.animationController.removeListener(_onAnimationChanged);
    _playerA.dispose();
    _playerB.dispose();
    super.dispose();
  }

  /// 初始化当前动画（首次，使用前台播放器直接加载）
  Future<void> _initCurrentAnimation() async {
    final config = widget.animationController.currentConfig;
    if (config == null) return;

    _currentAnimName = config.name;
    _currentAnimSequence = widget.animationController.animationSequence;
    _switchGeneration++;

    try {
      await _foregroundPlayer.setPlaylistMode(
        config.loop ? PlaylistMode.single : PlaylistMode.none,
      );
      await _foregroundPlayer.open(
        Media('asset:///${config.assetPath}'),
        play: true,
      );

      // 立即标记就绪，让 Video widget 开始渲染
      if (mounted) {
        setState(() => _isReady = true);
      }
      debugPrint('🎬 初始动画已加载: ${config.name}');

      // 视频打开成功后再订阅事件，避免空播放器的瞬态 completed 事件
      _listenForegroundEvents();

      // 确保播放器在下一帧仍然在播放状态
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!mounted) return;
        final gen = _switchGeneration;
        await Future.delayed(const Duration(milliseconds: 500));
        if (!mounted || _switchGeneration != gen) return;
        if (!_foregroundPlayer.state.playing) {
          debugPrint('🎬 初始动画播放器未在播放，主动 play()');
          await _foregroundPlayer.play();
        }
      });
    } catch (e) {
      debugPrint('🎬 初始动画加载失败: $e');
      if (mounted) {
        setState(() => _isReady = true);
        // 即使加载失败也订阅事件，以便后续动画切换能正常工作
        _listenForegroundEvents();
      }
    }
  }

  /// 当动画控制器通知变化时
  void _onAnimationChanged() {
    // 处理循环动画等待退出：将播放器的循环模式改为非循环，
    // 让当前这一遍播完后触发 completed 事件
    if (widget.animationController.isWaitingLoopExit) {
      debugPrint('🎬 [循环退出] 将前台播放器改为非循环模式，等待播完当前一遍');
      _foregroundPlayer.setPlaylistMode(PlaylistMode.none);
      return;
    }

    final config = widget.animationController.currentConfig;
    if (config == null) return;

    final newSeq = widget.animationController.animationSequence;
    // 通过序号判断：即使动画名相同，只要序号不同就表示需要重新播放
    if (config.name == _currentAnimName && newSeq == _currentAnimSequence) return;

    if (!_isSwitching) {
      _switchToAnimation(config);
    }
  }

  /// 播放完成回调（一次性动画播完）
  void _onPlaybackCompleted(bool completed) {
    if (!completed || !mounted) return;

    // 如果已经通过 position 检测触发过，跳过
    if (_completedTriggered) {
      debugPrint('🎬 [completed事件] 已通过position触发，跳过: $_currentAnimName');
      return;
    }

    if (_isSwitching) {
      debugPrint('🎬 忽略切换期间的 completed 事件 (anim=$_currentAnimName)');
      return;
    }

    _completedTriggered = true;
    debugPrint('🎬 [completed事件] 视频播放完成: $_currentAnimName');
    _triggerCompletion();
  }

  /// 双缓冲无闪烁切换动画
  ///
  /// 1. 在后台播放器上 open() 新视频
  /// 2. 等后台播放器第一帧渲染完成
  /// 3. 瞬间切换前台/后台（swap），旧前台停掉
  Future<void> _switchToAnimation(AnimationVideoConfig config) async {
    if (_isSwitching) return;
    _isSwitching = true;
    _switchGeneration++;

    final gen = _switchGeneration;

    try {
      debugPrint('🎬 [双缓冲] 后台预加载: ${config.name} (${config.assetPath}) gen=$gen');

      // ① 在后台播放器上设置循环模式并加载新视频
      final bgPlayer = _backgroundPlayer;

      await bgPlayer.setPlaylistMode(
        config.loop ? PlaylistMode.single : PlaylistMode.none,
      );

      await bgPlayer.open(
        Media('asset:///${config.assetPath}'),
        play: true,
      );

      await bgPlayer.setVolume(0);

      // ② 等待后台播放器第一帧解码（短延迟即可，视频通常在100-300ms内就绪）
      // 避免使用 stream.playing.firstWhere 可能导致的较长等待
      await Future.delayed(const Duration(milliseconds: 200));

      // ③ 检查是否仍然有效（可能在等待期间又触发了新的切换请求）
      if (_switchGeneration != gen || !mounted) {
        debugPrint('🎬 [双缓冲] 切换已过期 (gen=$gen, current=$_switchGeneration)，放弃');
        // 停掉后台播放器，避免资源浪费
        await bgPlayer.pause();
        _isSwitching = false;
        return;
      }

      // ④ 瞬间切换前台/后台！
      _currentAnimName = config.name;
      _currentAnimSequence = widget.animationController.animationSequence;
      final oldForeground = _foregroundPlayer;

      setState(() {
        _showingA = !_showingA;
        _isReady = true;
      });

      // ⑤ 重新订阅新前台播放器的事件
      _listenForegroundEvents();

      // ⑥ 停掉旧的前台播放器（现在变成后台了）
      await oldForeground.pause();

      debugPrint('🎬 [双缓冲] 切换完成: ${config.name} (前台=${_showingA ? "A" : "B"})');
    } catch (e) {
      debugPrint('🎬 [双缓冲] 切换失败: ${config.name} - $e');
    } finally {
      _isSwitching = false;

      // ⑦ 关键修复：检查切换后的前台播放器是否已经播放完成
      // media_kit 的 stream.completed 是 broadcast stream，事件不会被缓存。
      // 如果视频很短（如无聊发呆），可能在 open() 到 subscribe() 之间就播完了，
      // completed=true 事件在无人监听时丢失，导致动画永远卡住。
      // 因此切换完成后主动检查播放器状态，如果已完成则手动触发回调。
      _checkCompletedAfterSwitch();
    }
  }

  /// 切换完成后检查前台播放器是否已经播放完成
  /// 防止短视频在双缓冲切换过程中 completed 事件丢失
  void _checkCompletedAfterSwitch() {
    if (!mounted) return;
    final gen = _switchGeneration;
    // 延迟一帧执行，确保所有状态已更新
    Future.microtask(() async {
      if (!mounted || _switchGeneration != gen || _isSwitching) return;
      if (_completedTriggered) return; // 已经触发过

      final player = _foregroundPlayer;
      final position = player.state.position;
      final duration = player.state.duration;
      final completed = player.state.completed;

      debugPrint('🎬 [双缓冲] 检查播放器状态: $_currentAnimName, completed=$completed, pos=${position.inMilliseconds}ms, dur=${duration.inMilliseconds}ms');

      // 检查是否已完成（通过 completed 状态或 position 接近 duration）
      bool shouldTrigger = completed;
      if (!shouldTrigger && duration.inMilliseconds > 0) {
        final remaining = duration - position;
        shouldTrigger = remaining.inMilliseconds <= 100;
      }

      if (shouldTrigger) {
        _completedTriggered = true;
        debugPrint('🎬 [双缓冲] 检测到视频已完成(切换后), 手动触发: $_currentAnimName');
        widget.animationController.onOneShotCompleted();
      }
    });
  }

  /// 健康检查：定期检测播放器是否卡住
  /// 
  /// 卡住的典型场景：
  /// - one-shot 动画的 completed 事件丢失
  /// - 播放器意外停止播放
  /// - 切换过程中状态不一致
  void _performHealthCheck() {
    if (!mounted || _isSwitching) return;

    final player = _foregroundPlayer;
    final playing = player.state.playing;
    final completed = player.state.completed;
    final position = player.state.position;
    final duration = player.state.duration;
    final controller = widget.animationController;

    // 场景1：one-shot 动画已经播完但 completed 事件丢失
    // 检测条件：控制器认为正在播放 one-shot，但播放器已完成或已停止
    if (controller.isPlayingOneShot && !_completedTriggered) {
      bool isStuck = false;

      if (completed) {
        isStuck = true;
        debugPrint('🎬 [健康检查] 检测到 one-shot 动画已完成但未触发回调: $_currentAnimName');
      } else if (!playing && duration.inMilliseconds > 0) {
        final remaining = duration - position;
        if (remaining.inMilliseconds <= 200) {
          isStuck = true;
          debugPrint('🎬 [健康检查] 检测到 one-shot 动画接近结束但已停止: $_currentAnimName, pos=${position.inMilliseconds}ms, dur=${duration.inMilliseconds}ms');
        }
      }

      if (isStuck) {
        _completedTriggered = true;
        debugPrint('🎬 [健康检查] 强制触发完成回调: $_currentAnimName');
        controller.onOneShotCompleted();
        return;
      }
    }

    // 场景2：循环动画等待退出，但播放器已停止（completed 事件丢失）
    if (controller.isWaitingLoopExit && (completed || !playing)) {
      debugPrint('🎬 [健康检查] 检测到循环退出卡住，强制触发: $_currentAnimName, playing=$playing, completed=$completed');
      _completedTriggered = true;
      controller.onOneShotCompleted();
      return;
    }

    // 场景3：播放器意外停止但不是 completed 状态（异常停止）
    // 如果播放器既没在播放也没完成，且不在切换中，重新启动
    if (!playing && !completed && !_isSwitching && duration.inMilliseconds > 0) {
      debugPrint('🎬 [健康检查] 播放器意外停止，重新 play(): $_currentAnimName, pos=${position.inMilliseconds}ms');
      player.play();
    }
  }

  /// 启动 idle 交替定时器
  /// 定期从装萌(cute)循环切到无聊发呆(idle)，实现交替播放
  void _startIdleAlternateTimer() {
    _idleAlternateTimer?.cancel();
    // 每 20 秒触发一次 idle 交替
    _idleAlternateTimer = Timer.periodic(const Duration(seconds: 20), (_) {
      if (!mounted) return;
      widget.animationController.playIdleRandom();
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!_isReady) {
      return SizedBox(
        width: widget.width,
        height: widget.height,
        child: const Center(
          child: Text(
            '🦢',
            style: TextStyle(
              fontSize: 60,
              decoration: TextDecoration.none,
            ),
          ),
        ),
      );
    }

    // 用 Stack 叠放两层，前台在上（Visibility 控制显隐，不会 dispose）
    // 注意：两层都保持存在以维持 VideoController 的纹理不被销毁
    return SizedBox(
      width: widget.width,
      height: widget.height,
      child: ClipRect(
        child: Transform.scale(
          scale: 1.06,
          child: Stack(
            children: [
              // 播放器 A
              Visibility(
                visible: _showingA,
                maintainState: true,
                maintainAnimation: true,
                maintainSize: true,
                child: _ChromaKeyVideoWidget(
                  videoController: _videoControllerA,
                  width: widget.width,
                  height: widget.height,
                ),
              ),
              // 播放器 B
              Visibility(
                visible: !_showingA,
                maintainState: true,
                maintainAnimation: true,
                maintainSize: true,
                child: _ChromaKeyVideoWidget(
                  videoController: _videoControllerB,
                  width: widget.width,
                  height: widget.height,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 不显示任何视频控件
Widget noVideoControls(VideoState state) {
  return const SizedBox.shrink();
}

/// 绿幕色度键视频组件
///
/// 使用"双层 ColorFiltered"技术精确去除绿幕，保持主体原始色彩。
///
/// 双层方案（从外到内）：
/// 1. 外层：Alpha 增益 —— 对 Alpha 做放大，让边缘更清晰
/// 2. 内层：绿幕检测 —— 用色度差公式计算初步 Alpha
///
/// 原理：绿幕的核心特征是 G 通道远大于 R 和 B 的平均值。
/// 检测公式：A = R*0.5 + G*(-1.0) + B*0.5 + 200
///
/// 注意：不对 R/G/B 通道做任何修改，确保主体颜色完全保真。
class _ChromaKeyVideoWidget extends StatelessWidget {
  final VideoController videoController;
  final double width;
  final double height;

  const _ChromaKeyVideoWidget({
    required this.videoController,
    required this.width,
    required this.height,
  });

  @override
  Widget build(BuildContext context) {
    return ColorFiltered(
      colorFilter: const ColorFilter.matrix(<double>[
        1, 0, 0, 0,   0,    // R 不变
        0, 1, 0, 0,   0,    // G 不变
        0, 0, 1, 0,   0,    // B 不变
        0, 0, 0, 2.5, -200, // A = old_A * 2.5 - 200 (增益+阈值)
      ]),
      child: ColorFiltered(
        colorFilter: const ColorFilter.matrix(<double>[
          1,    0,     0, 0, 0,
          0,    1,     0, 0, 0,
          0,    0,     1, 0, 0,
          0.50, -1.00, 0.50, 0, 200,
        ]),
        child: Video(
          controller: videoController,
          controls: noVideoControls,
          fill: Colors.transparent,
          fit: BoxFit.cover,
          filterQuality: FilterQuality.high,
        ),
      ),
    );
  }
}
