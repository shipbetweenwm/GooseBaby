import 'dart:async';
import 'dart:math' show pi, sin;
import 'package:flutter/material.dart';
import '../../core/pet_engine.dart';
import 'particle_system.dart';
import 'video_animation_controller.dart';
import 'pet_video_player.dart';

/// 鹅宝桌面画布 - MP4 视频动画版
class PetCanvas extends StatefulWidget {
  final PetEngine engine;
  final VoidCallback? onTap;
  final VoidCallback? onDoubleTap;
  final VoidCallback? onDragStart;

  const PetCanvas({
    super.key,
    required this.engine,
    this.onTap,
    this.onDoubleTap,
    this.onDragStart,
  });

  @override
  State<PetCanvas> createState() => _PetCanvasState();
}

class _PetCanvasState extends State<PetCanvas> with TickerProviderStateMixin {
  // 视频动画控制器
  late VideoAnimationController _videoAnimController;

  // 粒子系统（保留）
  late ParticleSystem _particleSystem;
  late ParticleSystem _ambientParticles;

  // 动画控制器
  late AnimationController _bounceController;
  late Animation<double> _bounceAnimation;
  late AnimationController _frameController;

  // 当前动画状态跟踪
  String _lastAction = '';
  String _lastMood = '';
  String _lastVideoAnimation = '';
  int _lastVideoSequence = -1;

  // 时间追踪（粒子系统用）
  DateTime _lastFrame = DateTime.now();

  // 鼠标悬停"被撸"检测
  Timer? _hoverTimer;
  bool _isPettedPlaying = false;

  @override
  void initState() {
    super.initState();

    // 初始化视频动画控制器
    _videoAnimController = VideoAnimationController();

    // 粒子系统（保留原有的粒子特效）
    _particleSystem = ParticleSystem(GooseParticleEffects.sparkles());
    _ambientParticles = ParticleSystem(GooseParticleEffects.bubbles(y: 40));

    // 帧更新控制器（用于粒子系统更新）
    _frameController = AnimationController(
      vsync: this,
      duration: const Duration(days: 365),
    )..addListener(_onFrame);
    _frameController.repeat();

    // 弹跳动画
    _bounceController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    );
    _bounceAnimation = Tween<double>(begin: 1.0, end: 1.15).animate(
      CurvedAnimation(parent: _bounceController, curve: Curves.elasticOut),
    );

    // 监听引擎状态变化
    widget.engine.addListener(_onEngineUpdate);

    // 启动环境粒子
    _ambientParticles.start();
  }

  void _onFrame() {
    if (!mounted) return;

    final now = DateTime.now();
    final dt = (now.difference(_lastFrame).inMicroseconds / 1000000.0)
        .clamp(0.0, 0.05);
    _lastFrame = now;

    // 更新粒子
    _particleSystem.update(dt);
    _ambientParticles.update(dt);

    // 检查引擎状态并更新视频
    _updateVideoFromState();

    setState(() {});
  }

  void _updateVideoFromState() {
    // 如果正在播放被撸动画（鼠标悬停触发），不要被引擎状态覆盖
    if (_isPettedPlaying) {
      _syncParticleEffect();
      return;
    }

    final action = widget.engine.state.currentAction;
    final mood = widget.engine.mood;
    final emotion = widget.engine.state.emotion;

    // 只跳过完全没变化的情况，但仍检查内部动画转换
    if (action == _lastAction && mood == _lastMood) {
      _syncParticleEffect();
      return;
    }

    // 先尝试切换动画，只有切换成功才更新缓存
    // 这样如果一次性动画还在播放（updateFromState 返回 false），
    // 下一帧还会继续尝试，直到动画播完可以切换时才更新缓存
    final switched = _videoAnimController.updateFromState(
      action: action,
      mood: mood,
      emotion: emotion,
    );

    if (switched) {
      // 切换成功，更新缓存
      _lastAction = action;
      _lastMood = mood;
      _updateParticleEffect(_videoAnimController.currentAnimation);
      _lastVideoAnimation = _videoAnimController.currentAnimation;
      _lastVideoSequence = _videoAnimController.animationSequence;
    } else if (!_videoAnimController.isPlayingOneShot && !_videoAnimController.isWaitingLoopExit) {
      // 没有切换但也不是因为一次性动画保护或循环退出等待（可能是目标动画和当前相同）
      // 此时也更新缓存，避免重复判断
      _lastAction = action;
      _lastMood = mood;
      _syncParticleEffect();
    }
    // 如果是一次性动画保护或循环退出等待导致没切换，不更新缓存，下一帧继续尝试
  }

  /// 同步粒子效果（当动画因内部状态机转换而改变时，如 eat→idle→cute）
  void _syncParticleEffect() {
    final anim = _videoAnimController.currentAnimation;
    final seq = _videoAnimController.animationSequence;
    if (anim != _lastVideoAnimation || seq != _lastVideoSequence) {
      _lastVideoAnimation = anim;
      _lastVideoSequence = seq;
      _updateParticleEffect(anim);
    }
  }

  void _updateParticleEffect(String animation) {
    _particleSystem.stop();
    _particleSystem.clear();

    switch (animation) {
      case 'cute':
        _particleSystem.setConfig(GooseParticleEffects.happyStars());
        _particleSystem.start();
        break;
      case 'eat':
        _particleSystem.setConfig(GooseParticleEffects.eatCrumbs());
        _particleSystem.start();
        break;
      case 'jump':
        _particleSystem.setConfig(GooseParticleEffects.levelUpFireworks());
        _particleSystem.burst(25);
        break;
      case 'petted':
        // 被撸时发射爱心粒子
        _particleSystem.setConfig(GooseParticleEffects.loveHearts());
        _particleSystem.burst(15);
        break;
      case 'work':
        // 工作时发射小气泡（思考中）
        _particleSystem.setConfig(GooseParticleEffects.bubbles(y: 30));
        _particleSystem.start();
        break;
      case 'sleep':
        // 睡觉时发射小气泡（zzz）
        _particleSystem.setConfig(GooseParticleEffects.bubbles(y: 20));
        _particleSystem.start();
        break;
      case 'bath':
        // 洗澡时发射泡泡粒子
        _particleSystem.setConfig(GooseParticleEffects.bubbles(y: 35));
        _particleSystem.start();
        break;
      case 'cry':
        // 哭泣时发射小水滴（泪水）
        _particleSystem.setConfig(GooseParticleEffects.sparkles());
        _particleSystem.burst(10);
        break;
      case 'sleepy':
        // 犯困时发射少量气泡（哈欠）
        _particleSystem.setConfig(GooseParticleEffects.bubbles(y: 15));
        _particleSystem.burst(5);
        break;
      case 'play':
        // 玩耍时发射星星
        _particleSystem.setConfig(GooseParticleEffects.happyStars());
        _particleSystem.start();
        break;
      case 'idle':
      default:
        // idle 状态不播放持续粒子
        break;
    }
  }

  void _onEngineUpdate() {
    if (!mounted) return;
    // 引擎状态变化时，强制清空缓存让 _updateVideoFromState 重新评估
    // 这确保即使在一次性动画播放期间，引擎状态变化也会被记录并排队
    final action = widget.engine.state.currentAction;
    final mood = widget.engine.mood;
    if (action != _lastAction || mood != _lastMood) {
      _lastAction = ''; // 清空缓存，强制下一帧重新检查
      _lastMood = '';
    }
  }

  @override
  void dispose() {
    _hoverTimer?.cancel();
    _frameController.dispose();
    _bounceController.dispose();
    _videoAnimController.dispose();
    widget.engine.removeListener(_onEngineUpdate);
    super.dispose();
  }

  /// 鼠标进入宠物区域 → 启动3秒计时器
  void _onMouseEnter(PointerEvent event) {
    _hoverTimer?.cancel();
    _isPettedPlaying = false;
    _hoverTimer = Timer(const Duration(seconds: 3), () {
      if (mounted && !_isPettedPlaying) {
        _isPettedPlaying = true;
        debugPrint('🐾 鼠标悬停3秒，播放被撸了动画');
        // 临时清除缓存，让 _updateVideoFromState 不会立即覆盖
        _lastAction = '';
        _lastMood = '';
        _videoAnimController.playAnimation('petted');
        // 被撸时发射爱心粒子
        _particleSystem.setConfig(GooseParticleEffects.loveHearts());
        _particleSystem.burst(15);
        // 监听被撸动画播放完成，重置标志
        _waitForPettedComplete();
      }
    });
  }

  /// 等待被撸动画播放完成后重置 _isPettedPlaying
  void _waitForPettedComplete() {
    void listener() {
      if (_videoAnimController.currentAnimation != 'petted') {
        _videoAnimController.removeListener(listener);
        _isPettedPlaying = false;
        _lastAction = '';
        _lastMood = '';
        debugPrint('🐾 被撸动画播放完成，恢复状态驱动');
      }
    }
    _videoAnimController.addListener(listener);
  }

  /// 鼠标离开宠物区域 → 取消计时器
  void _onMouseExit(PointerEvent event) {
    _hoverTimer?.cancel();
    _hoverTimer = null;
    // 注意：如果被撸动画正在播放中（一次性动画），不要立即重置 _isPettedPlaying
    // 让它播放完成后由 _waitForPettedComplete 的 listener 自动重置
    // 只有在被撸动画还没开始播放时（计时器还没触发）才需要重置
    if (!_videoAnimController.isPlayingOneShot ||
        _videoAnimController.currentAnimation != 'petted') {
      _isPettedPlaying = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: _onMouseEnter,
      onExit: _onMouseExit,
      child: GestureDetector(
      onTap: () {
        // 点击时取消悬停计时，避免点击后又触发被撸
        _hoverTimer?.cancel();
        _bounceController.forward().then((_) => _bounceController.reverse());
        // 点击时发射粒子
        _particleSystem.setConfig(GooseParticleEffects.loveHearts());
        _particleSystem.burst(12);
        widget.onTap?.call();
      },
      onDoubleTap: () {
        // 双击时取消悬停计时
        _hoverTimer?.cancel();
        // 双击用于打开/关闭聊天面板，不在这里播放动画避免闪现
        widget.onDoubleTap?.call();
      },
      onPanStart: (_) {
        widget.onDragStart?.call();
      },
      child: AnimatedBuilder(
        animation: _bounceAnimation,
        builder: (context, child) {
          return Transform.scale(
            scale: _bounceAnimation.value,
            child: SizedBox(
              width: 157,
              height: 280,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  // 环境粒子（底层）
                  Positioned.fill(
                    child: CustomPaint(
                      painter: _ParticleOnlyPainter(
                        particles: _ambientParticles.particles,
                      ),
                    ),
                  ),

                  // 视频动画（中间层）
                  PetVideoPlayer(
                    animationController: _videoAnimController,
                    width: 157,
                    height: 280,
                  ),

                  // 交互粒子（顶层）
                  Positioned.fill(
                    child: CustomPaint(
                      painter: _ParticleOnlyPainter(
                        particles: _particleSystem.particles,
                      ),
                    ),
                  ),

                  // 表情气泡
                  if (widget.engine.currentEmote != null)
                    Positioned(
                      top: 5,
                      right: 10,
                      child: _EmoteBubble3D(emote: widget.engine.currentEmote!),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    ),
    );
  }
}

// ============================================================
// 仅渲染粒子的 Painter（不再绘制角色）
// ============================================================

class _ParticleOnlyPainter extends CustomPainter {
  final List<Particle> particles;

  _ParticleOnlyPainter({required this.particles});

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.translate(size.width / 2, size.height * 0.55);
    ParticleRenderer.render(canvas, particles);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _ParticleOnlyPainter oldDelegate) => true;
}

// ============================================================
// 3D 表情气泡（保留原有实现）
// ============================================================

class _EmoteBubble3D extends StatefulWidget {
  final String emote;
  const _EmoteBubble3D({required this.emote});

  @override
  State<_EmoteBubble3D> createState() => _EmoteBubble3DState();
}

class _EmoteBubble3DState extends State<_EmoteBubble3D>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _scaleAnim;
  late Animation<double> _opacityAnim;
  late Animation<double> _floatAnim;
  late Animation<double> _rotateAnim;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2500),
    );
    _scaleAnim = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.elasticOut),
    );
    _opacityAnim = Tween<double>(begin: 1.0, end: 0.0).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0.65, 1.0, curve: Curves.easeOut),
      ),
    );
    _floatAnim = Tween<double>(begin: 0.0, end: -25.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOut),
    );
    _rotateAnim = Tween<double>(begin: 0.0, end: 0.1).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
    );
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return Transform.translate(
          offset: Offset(0, _floatAnim.value),
          child: Transform.rotate(
            angle: sin(_controller.value * pi * 3) * _rotateAnim.value,
            child: Opacity(
              opacity: _opacityAnim.value,
              child: Transform.scale(
                scale: _scaleAnim.value,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [Colors.white, Color(0xFFF3E5F5)],
                    ),
                    borderRadius: BorderRadius.circular(18),
                    boxShadow: [
                      BoxShadow(
                        color: const Color(0xFF7C4DFF).withOpacity(0.15),
                        blurRadius: 12,
                        offset: const Offset(0, 4),
                      ),
                      BoxShadow(
                        color: Colors.white.withOpacity(0.8),
                        blurRadius: 6,
                        offset: const Offset(-2, -2),
                      ),
                    ],
                    border: Border.all(
                      color: const Color(0xFFE1BEE7),
                      width: 1.5,
                    ),
                  ),
                  child: Text(
                    widget.emote,
                    style: const TextStyle(fontSize: 26),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
