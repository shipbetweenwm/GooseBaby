import 'dart:async';
import 'dart:math' show Random, pi, sin, cos;
import 'package:flutter/material.dart';
import '../../core/pet_engine.dart';
import 'animation_engine_3d.dart';
import 'particle_system.dart';

/// 鹅宝桌面画布 - 3D 动画引擎版
class PetCanvas extends StatefulWidget {
  final PetEngine engine;
  final VoidCallback? onTap;
  final VoidCallback? onDoubleTap;
  final Function(DragUpdateDetails)? onDrag;

  const PetCanvas({
    super.key,
    required this.engine,
    this.onTap,
    this.onDoubleTap,
    this.onDrag,
  });

  @override
  State<PetCanvas> createState() => _PetCanvasState();
}

class _PetCanvasState extends State<PetCanvas> with TickerProviderStateMixin {
  // 3D 动画引擎
  late AnimationEngine3D _engine3D;
  late AnimationController _frameController;

  // 粒子系统
  late ParticleSystem _particleSystem;
  late ParticleSystem _ambientParticles; // 环境粒子

  // 动画控制器
  late AnimationController _bounceController;
  late Animation<double> _bounceAnimation;

  // 3D 交互旋转
  double _interactRotY = 0;
  double _targetRotY = 0;

  // 眨眼
  Timer? _blinkTimer;
  bool _isBlinking = false;
  final _random = Random();

  // 当前动画状态
  String _currentAnimation = 'idle';
  String _lastMood = '';

  // 自主行为系统
  Timer? _autoBehaviorTimer;
  double _idleTime = 0; // idle 状态累积时间
  static const double _autoBehaviorInterval = 5.0; // 每5秒尝试自发行为
  bool _isDoingAutoBehavior = false;

  // 时间追踪
  DateTime _lastFrame = DateTime.now();

  @override
  void initState() {
    super.initState();

    // 初始化 3D 引擎
    _engine3D = AnimationEngine3D(
      skeleton: createGooseSkeleton(),
      light: const Light3D(
        position: Vec3(-0.6, -0.8, 0.7),
        intensity: 1.1,
        ambient: 0.38,
      ),
    );

    // 注册所有动画
    for (final clip in GooseAnimations.allClips()) {
      _engine3D.addClip(clip);
    }
    _engine3D.play('idle');

    // 粒子系统
    _particleSystem = ParticleSystem(GooseParticleEffects.sparkles());
    _ambientParticles = ParticleSystem(GooseParticleEffects.bubbles(y: 40));

    // 帧更新控制器（60fps）
    _frameController = AnimationController(
      vsync: this,
      duration: const Duration(days: 365), // 永久运行
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

    // 随机眨眼
    _startBlinking();

    // 监听引擎
    widget.engine.addListener(_onEngineUpdate);

    // 启动环境粒子
    _ambientParticles.start();

    // 自主行为系统 - 让鹅宝自己动起来！
    _startAutoBehavior();
  }

  // ====== 自主行为系统 ======
  void _startAutoBehavior() {
    _autoBehaviorTimer?.cancel();
    _autoBehaviorTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => _tickAutoBehavior(),
    );
  }

  void _tickAutoBehavior() {
    if (!mounted) return;

    // 如果当前在 idle 状态，累计空闲时间
    if (_currentAnimation == 'idle') {
      _idleTime += 1.0;
    } else {
      _idleTime = 0;
    }

    // 空闲超过一定时间后，随机触发自发行为
    if (_idleTime >= _autoBehaviorInterval && !_isDoingAutoBehavior) {
      _idleTime = 0;
      _triggerRandomBehavior();
    }
  }

  void _triggerRandomBehavior() {
    _isDoingAutoBehavior = true;

    // 随机选择一个自发行为（带权重）
    final behaviors = <_AutoBehavior>[
      _AutoBehavior('wave', 1800, 20),        // 挥手
      _AutoBehavior('dance', 3200, 15),        // 跳舞
      _AutoBehavior('jump', 1000, 18),         // 跳跃
      _AutoBehavior('happy', 2000, 15),        // 开心蹦跶
      _AutoBehavior('spin', 1400, 8),          // 转圈
      _AutoBehavior('fly', 2000, 8),           // 飞行
      _AutoBehavior('_wiggle', 1500, 16),      // 原地扭动（特殊）
    ];

    // 加权随机
    final totalWeight = behaviors.fold<int>(0, (s, b) => s + b.weight);
    var roll = _random.nextInt(totalWeight);
    _AutoBehavior chosen = behaviors.last;
    for (final b in behaviors) {
      roll -= b.weight;
      if (roll < 0) {
        chosen = b;
        break;
      }
    }

    // 执行行为
    if (chosen.name == '_wiggle') {
      // 原地扭动：随机小幅旋转 + 粒子
      _targetRotY = (_random.nextDouble() - 0.5) * 0.5;
      _particleSystem.setConfig(GooseParticleEffects.sparkles());
      _particleSystem.burst(8);
      Future.delayed(Duration(milliseconds: chosen.durationMs), () {
        if (mounted) {
          _targetRotY = 0;
          _isDoingAutoBehavior = false;
        }
      });
    } else {
      _engine3D.play(chosen.name, blendDuration: 0.3);
      _currentAnimation = chosen.name;
      _updateParticleEffect(chosen.name);

      // 行为结束后回到 idle
      Future.delayed(Duration(milliseconds: chosen.durationMs), () {
        if (mounted) {
          _engine3D.play('idle', blendDuration: 0.5);
          _currentAnimation = 'idle';
          _particleSystem.stop();
          _isDoingAutoBehavior = false;
        }
      });
    }
  }

  void _startBlinking() {
    _blinkTimer?.cancel();
    _blinkTimer = Timer.periodic(
      Duration(seconds: 2 + _random.nextInt(4)),
      (_) {
        if (mounted) {
          setState(() => _isBlinking = true);
          Future.delayed(const Duration(milliseconds: 150), () {
            if (mounted) setState(() => _isBlinking = false);
          });
        }
      },
    );
  }

  void _onFrame() {
    if (!mounted) return;

    final now = DateTime.now();
    final dt = (now.difference(_lastFrame).inMicroseconds / 1000000.0)
        .clamp(0.0, 0.05); // 限制最大 dt 防止跳帧
    _lastFrame = now;

    // 更新 3D 引擎
    _engine3D.update(dt);

    // 更新粒子
    _particleSystem.update(dt);
    _ambientParticles.update(dt);

    // 平滑旋转过渡
    _interactRotY += (_targetRotY - _interactRotY) * 0.08;
    _engine3D.globalRotation = Vec3(0, _interactRotY, 0);

    // 根据心情切换动画
    _updateAnimationFromMood();

    setState(() {});
  }

  void _updateAnimationFromMood() {
    final mood = widget.engine.mood;
    final action = widget.engine.state.currentAction;

    if (mood == _lastMood) return;
    _lastMood = mood;

    String targetAnim;
    switch (action) {
      case 'dance':
      case 'spin':
        targetAnim = action;
        break;
      case 'eating':
      case 'satisfied':
        targetAnim = 'eat';
        break;
      case 'sleep':
        targetAnim = 'sleep';
        break;
      case 'jump':
      case 'happy_jump':
      case 'level_up':
        targetAnim = 'jump';
        break;
      default:
        switch (mood) {
          case 'happy':
          case 'excited':
            targetAnim = 'happy';
            break;
          case 'sad':
            targetAnim = 'sad';
            break;
          case 'sleepy':
            targetAnim = 'sleep';
            break;
          default:
            targetAnim = 'idle';
        }
    }

    if (targetAnim != _currentAnimation) {
      _currentAnimation = targetAnim;
      _engine3D.play(targetAnim, blendDuration: 0.4);
      _updateParticleEffect(targetAnim);
    }
  }

  void _updateParticleEffect(String animation) {
    _particleSystem.stop();
    _particleSystem.clear();

    switch (animation) {
      case 'happy':
        _particleSystem.setConfig(GooseParticleEffects.happyStars());
        _particleSystem.start();
        break;
      case 'dance':
        _particleSystem.setConfig(GooseParticleEffects.danceNotes());
        _particleSystem.start();
        break;
      case 'sad':
        _particleSystem.setConfig(GooseParticleEffects.sadTears());
        _particleSystem.start();
        break;
      case 'sleep':
        _particleSystem.setConfig(GooseParticleEffects.sleepZzz());
        _particleSystem.start();
        break;
      case 'eat':
        _particleSystem.setConfig(GooseParticleEffects.eatCrumbs());
        _particleSystem.start();
        break;
      case 'jump':
        _particleSystem.setConfig(GooseParticleEffects.sparkles());
        _particleSystem.burst(20);
        break;
      case 'spin':
        _particleSystem.setConfig(GooseParticleEffects.sparkles());
        _particleSystem.start();
        break;
    }
  }

  void _onEngineUpdate() {
    if (mounted) {
      _lastMood = ''; // 强制重新检查
    }
  }

  @override
  void dispose() {
    _frameController.dispose();
    _bounceController.dispose();
    _blinkTimer?.cancel();
    _autoBehaviorTimer?.cancel();
    widget.engine.removeListener(_onEngineUpdate);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        _bounceController.forward().then((_) => _bounceController.reverse());
        // 点击时发射粒子
        _particleSystem.setConfig(GooseParticleEffects.loveHearts());
        _particleSystem.burst(12);
        // 轻微 3D 旋转
        _targetRotY = (_random.nextDouble() - 0.5) * 0.3;
        Future.delayed(const Duration(milliseconds: 800), () {
          if (mounted) _targetRotY = 0;
        });
        widget.onTap?.call();
      },
      onDoubleTap: () {
        // 双击时播放特殊动画
        _engine3D.play('spin', blendDuration: 0.2);
        _currentAnimation = 'spin';
        _particleSystem.setConfig(GooseParticleEffects.levelUpFireworks());
        _particleSystem.burst(40);
        widget.onDoubleTap?.call();
      },
      onPanUpdate: (details) {
        // 拖拽实现 3D 旋转
        _targetRotY = (details.localPosition.dx - 100) / 100 * 0.3;
        widget.onDrag?.call(details);
      },
      onPanEnd: (_) {
        _targetRotY = 0;
      },
      child: AnimatedBuilder(
        animation: _bounceAnimation,
        builder: (context, child) {
          return Transform.scale(
            scale: _bounceAnimation.value,
            child: SizedBox(
              width: 220,
              height: 280,
              child: CustomPaint(
                size: const Size(220, 280),
                painter: _GooseBaby3DPainter(
                  engine3D: _engine3D,
                  mood: widget.engine.mood,
                  isBlinking: _isBlinking,
                  particles: _particleSystem.particles,
                  ambientParticles: _ambientParticles.particles,
                ),
                child: Stack(
                  children: [
                    if (widget.engine.currentEmote != null)
                      Positioned(
                        top: 5,
                        right: 10,
                        child: _EmoteBubble3D(emote: widget.engine.currentEmote!),
                      ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

// ============================================================
// 🎨 3D 鹅宝画师
// ============================================================

class _GooseBaby3DPainter extends CustomPainter {
  final AnimationEngine3D engine3D;
  final String mood;
  final bool isBlinking;
  final List<Particle> particles;
  final List<Particle> ambientParticles;

  _GooseBaby3DPainter({
    required this.engine3D,
    required this.mood,
    required this.isBlinking,
    required this.particles,
    required this.ambientParticles,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height * 0.55;

    canvas.save();
    canvas.translate(cx, cy);

    final skeleton = engine3D.skeleton;
    final body = skeleton.findBone('body')!;
    final head = skeleton.findBone('head')!;
    final wingL = skeleton.findBone('wing_left')!;
    final wingR = skeleton.findBone('wing_right')!;
    final footL = skeleton.findBone('foot_left')!;
    final footR = skeleton.findBone('foot_right')!;
    final ahoge = skeleton.findBone('ahoge')!;
    final scarf = skeleton.findBone('scarf')!;

    // 全局变换
    final bodyPos = body.position;
    final bodyRot = body.rotation;
    final bodyScale = body.scale;

    // 计算 3D 旋转产生的透视偏移
    final rotY = bodyRot.y + engine3D.globalRotation.y;
    final perspOffsetX = sin(rotY) * 15;
    final perspScale = 1.0 - (sin(rotY).abs() * 0.08);

    canvas.translate(bodyPos.x + perspOffsetX, bodyPos.y);
    canvas.scale(bodyScale.x * perspScale, bodyScale.y);

    // 光照方向（随 3D 旋转变化）
    final light = engine3D.light;

    // === 环境粒子（背景层）===
    canvas.save();
    canvas.translate(-cx, -cy);
    ParticleRenderer.render(canvas, ambientParticles);
    canvas.restore();

    // === 1. 地面阴影（3D 透视阴影）===
    _drawShadow3D(canvas, size, rotY);

    // === 2. 脚掌 ===
    _drawFeet3D(canvas, footL, footR, rotY, light);

    // === 3. 身体主体（3D 渐变）===
    _drawBody3D(canvas, bodyRot, light);

    // === 4. 白色肚皮 ===
    _drawBelly3D(canvas, rotY, light);

    // === 5. 后翅膀（远离视角侧）===
    if (rotY > 0) {
      _drawWing3D(canvas, wingL, -1, rotY, light);
    } else {
      _drawWing3D(canvas, wingR, 1, rotY, light);
    }

    // === 6. 围巾（3D 遮挡效果）===
    _drawScarf3D(canvas, scarf, rotY, light);

    // === 7. 近侧翅膀 ===
    if (rotY > 0) {
      _drawWing3D(canvas, wingR, 1, rotY, light);
    } else {
      _drawWing3D(canvas, wingL, -1, rotY, light);
    }

    // === 8. 头部（3D）===
    _drawHead3D(canvas, head, rotY, light);

    // === 9. 眼睛（3D 定位）===
    _drawEyes3D(canvas, head, rotY, light);

    // === 10. 嘴巴 ===
    _drawBeak3D(canvas, head, rotY, light);

    // === 11. 腮红 ===
    _drawBlush3D(canvas, head, rotY);

    // === 12. 呆毛 ===
    _drawAhoge3D(canvas, head, ahoge, rotY, light);

    // === 粒子特效（前景层）===
    ParticleRenderer.render(canvas, particles);

    canvas.restore();
  }

  /// 3D 地面阴影
  void _drawShadow3D(Canvas canvas, Size size, double rotY) {
    final shadowPaint = Paint()
      ..color = Colors.black.withOpacity(0.1)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8);

    // 阴影随旋转偏移
    final shadowOffset = sin(rotY) * 8;
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(shadowOffset, 72),
        width: 110 * (1 - sin(rotY).abs() * 0.2),
        height: 20,
      ),
      shadowPaint,
    );
  }

  /// 3D 脚掌
  void _drawFeet3D(Canvas canvas, Bone footL, Bone footR, double rotY, Light3D light) {
    final footColor = const Color(0xFFFF9800);
    final normal = Vec3(0, -1, 0).rotateY(rotY);
    final litColor = light.applyTo(footColor, normal);

    for (final foot in [footL, footR]) {
      final side = foot.name == 'foot_left' ? -1.0 : 1.0;
      final footX = side * 22 + foot.position.x;
      final footY = 62 + foot.position.y;

      // 3D 遮挡：脚在旋转方向的另一侧变小
      final depthScale = 1.0 - (side * sin(rotY)).clamp(0.0, 0.5) * 0.4;

      canvas.save();
      canvas.translate(footX, footY);
      canvas.scale(depthScale, depthScale);

      final paint = Paint()
        ..color = litColor
        ..style = PaintingStyle.fill;
      final outline = Paint()
        ..color = const Color(0xFFE65100)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5;

      final path = Path();
      path.moveTo(0, -6);
      path.quadraticBezierTo(-14, 8, -16, 10);
      path.quadraticBezierTo(-10, 14, 0, 12);
      path.quadraticBezierTo(10, 14, 16, 10);
      path.quadraticBezierTo(14, 8, 0, -6);
      path.close();

      canvas.drawPath(path, paint);
      canvas.drawPath(path, outline);
      canvas.restore();
    }
  }

  /// 3D 身体
  void _drawBody3D(Canvas canvas, Vec3 bodyRot, Light3D light) {
    final rotY = bodyRot.y + engine3D.globalRotation.y;

    // 身体法线（朝前方，随旋转变化）
    final bodyNormal = Vec3(sin(rotY) * 0.3, -0.2, cos(rotY)).normalized;

    // 主体渐变（3D 光照）
    final baseColor = const Color(0xFFF0F0F0);
    final litColor = light.applyTo(baseColor, bodyNormal);
    final darkSide = light.applyTo(const Color(0xFFD8D8D8),
        Vec3(-bodyNormal.x, bodyNormal.y, -bodyNormal.z));

    // 3D 身体渐变 - 光照侧亮，阴影侧暗
    final gradientCenter = Alignment(sin(rotY) * 0.5 - 0.2, -0.3);

    final bodyGradient = Paint()
      ..shader = RadialGradient(
        center: gradientCenter,
        radius: 1.0,
        colors: [
          Colors.white,
          litColor,
          darkSide,
        ],
        stops: const [0.0, 0.45, 1.0],
      ).createShader(
        Rect.fromCenter(center: const Offset(0, -5), width: 140, height: 160),
      )
      ..style = PaintingStyle.fill;

    final bodyOutline = Paint()
      ..color = Color.lerp(const Color(0xFFBDBDBD), const Color(0xFF9E9E9E),
          sin(rotY).abs())!
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0;

    // 蛋形身体路径
    final bodyPath = Path();
    bodyPath.moveTo(0, -50);
    bodyPath.cubicTo(75, -50, 72, 35, 52, 60);
    bodyPath.quadraticBezierTo(0, 72, -52, 60);
    bodyPath.cubicTo(-72, 35, -75, -50, 0, -50);
    bodyPath.close();

    canvas.drawPath(bodyPath, bodyGradient);
    canvas.drawPath(bodyPath, bodyOutline);

    // 身体高光条（3D 光照反射）
    final highlightPath = Path();
    final hlX = -15 + sin(rotY) * 20;
    highlightPath.moveTo(hlX - 15, -35);
    highlightPath.quadraticBezierTo(hlX - 20, -15, hlX - 10, 5);
    final highlightPaint = Paint()
      ..color = Colors.white.withOpacity(0.35)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 8
      ..strokeCap = StrokeCap.round
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6);
    canvas.drawPath(highlightPath, highlightPaint);
  }

  /// 3D 肚皮
  void _drawBelly3D(Canvas canvas, double rotY, Light3D light) {
    final bellyOffset = sin(rotY) * 5;

    final bellyPaint = Paint()
      ..shader = RadialGradient(
        center: Alignment(sin(rotY) * 0.3 - 0.1, -0.2),
        radius: 0.9,
        colors: [
          Colors.white,
          const Color(0xFFFFFDE7),
          const Color(0xFFFFF8E1),
        ],
        stops: const [0.0, 0.6, 1.0],
      ).createShader(
        Rect.fromCenter(center: Offset(bellyOffset, 10), width: 90, height: 100),
      )
      ..style = PaintingStyle.fill;

    final bellyPath = Path();
    bellyPath.moveTo(bellyOffset, -35);
    bellyPath.cubicTo(
      bellyOffset + 42, -30,
      bellyOffset + 48, 40,
      bellyOffset + 30, 52,
    );
    bellyPath.quadraticBezierTo(bellyOffset, 60, bellyOffset - 30, 52);
    bellyPath.cubicTo(
      bellyOffset - 48, 40,
      bellyOffset - 42, -30,
      bellyOffset, -35,
    );
    bellyPath.close();

    canvas.drawPath(bellyPath, bellyPaint);
  }

  /// 3D 翅膀
  void _drawWing3D(Canvas canvas, Bone wing, double side, double rotY, Light3D light) {
    final wingRot = wing.rotation;
    final wingAngle = wingRot.z * side + wingRot.y * 0.5;

    // 3D 深度计算
    final depth = side * sin(rotY);
    final depthScale = 1.0 - depth.abs() * 0.3;
    final xOffset = side * 52 + sin(rotY) * side * 10;

    canvas.save();
    canvas.translate(xOffset, -15 + wing.position.y);
    canvas.scale(depthScale, 1.0);
    canvas.rotate(wingAngle);

    // 翅膀颜色受光照影响
    final wingNormal = Vec3(side * cos(wingAngle), 0, sin(wingAngle)).normalized;
    final wingColor = light.applyTo(const Color(0xFFE0E0E0), wingNormal);
    final wingHighlight = light.calcSpecular(wingNormal, const Vec3(0, 0, 1));

    final paint = Paint()
      ..color = wingColor
      ..style = PaintingStyle.fill;
    final stroke = Paint()
      ..color = const Color(0xFFBDBDBD)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8;

    final path = Path();
    path.moveTo(0, -22);
    path.cubicTo(side * 24, -20, side * 32, 16, side * 20, 34);
    path.cubicTo(side * 14, 42, side * 2, 38, 0, 28);
    path.cubicTo(-side * 5, 16, -side * 6, -12, 0, -22);
    path.close();

    canvas.drawPath(path, paint);
    canvas.drawPath(path, stroke);

    // 翅膀高光
    if (wingHighlight.alpha > 10) {
      final hlPaint = Paint()
        ..color = wingHighlight
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4);
      canvas.drawOval(
        Rect.fromCenter(
          center: Offset(side * 10, 5),
          width: 20,
          height: 30,
        ),
        hlPaint,
      );
    }

    canvas.restore();
  }

  /// 3D 围巾
  void _drawScarf3D(Canvas canvas, Bone scarf, double rotY, Light3D light) {
    final scarfY = -32.0;
    final scarfOffset = sin(rotY) * 3;

    // 围巾法线
    final scarfNormal = Vec3(sin(rotY) * 0.2, -0.5, 0.8).normalized;
    final scarfColor = light.applyTo(const Color(0xFFE53935), scarfNormal);

    final scarfPaint = Paint()
      ..color = scarfColor
      ..style = PaintingStyle.fill;
    final scarfHighlight = Paint()
      ..color = light.applyTo(const Color(0xFFEF5350), scarfNormal)
      ..style = PaintingStyle.fill;
    final scarfOutline = Paint()
      ..color = const Color(0xFFC62828)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;

    // 围巾主体（随 3D 旋转弯曲）
    final scarfPath = Path();
    scarfPath.moveTo(-48 + scarfOffset, scarfY - 3);
    scarfPath.quadraticBezierTo(-30 + scarfOffset, scarfY - 8, scarfOffset, scarfY - 6);
    scarfPath.quadraticBezierTo(30 + scarfOffset, scarfY - 8, 48 + scarfOffset, scarfY - 3);
    scarfPath.quadraticBezierTo(50 + scarfOffset, scarfY + 6, 45 + scarfOffset, scarfY + 10);
    scarfPath.quadraticBezierTo(25 + scarfOffset, scarfY + 14, scarfOffset, scarfY + 10);
    scarfPath.quadraticBezierTo(-25 + scarfOffset, scarfY + 14, -45 + scarfOffset, scarfY + 10);
    scarfPath.quadraticBezierTo(-50 + scarfOffset, scarfY + 6, -48 + scarfOffset, scarfY - 3);
    scarfPath.close();

    canvas.drawPath(scarfPath, scarfPaint);

    // 围巾高光
    final hlPath = Path();
    hlPath.moveTo(-20 + scarfOffset, scarfY - 4);
    hlPath.quadraticBezierTo(scarfOffset, scarfY - 6, 20 + scarfOffset, scarfY - 4);
    hlPath.quadraticBezierTo(scarfOffset, scarfY + 2, -20 + scarfOffset, scarfY - 4);
    canvas.drawPath(hlPath, scarfHighlight);

    canvas.drawPath(scarfPath, scarfOutline);

    // 围巾尾巴（3D 摆动）
    final tailX = 20 + scarfOffset + sin(rotY) * 5;
    final tailPath = Path();
    tailPath.moveTo(tailX, scarfY + 8);
    tailPath.quadraticBezierTo(tailX + 8, scarfY + 22, tailX + 2, scarfY + 38);
    tailPath.quadraticBezierTo(tailX + 4, scarfY + 42, tailX + 8, scarfY + 38);
    tailPath.quadraticBezierTo(tailX + 18, scarfY + 20, tailX + 10, scarfY + 6);
    tailPath.close();

    canvas.drawPath(tailPath, scarfPaint);
    canvas.drawPath(tailPath, scarfOutline);
  }

  /// 3D 头部
  void _drawHead3D(Canvas canvas, Bone head, double rotY, Light3D light) {
    final headY = -55.0 + head.position.y;
    final headRotX = head.rotation.x;
    final headRotZ = head.rotation.z;
    final headOffset = sin(rotY) * 4 + sin(headRotZ) * 3;

    // 头部法线
    final headNormal = Vec3(
      sin(rotY) * 0.4 + sin(headRotZ) * 0.2,
      -0.5 + sin(headRotX) * 0.3,
      0.7,
    ).normalized;

    final headPaint = Paint()
      ..shader = RadialGradient(
        center: Alignment(-0.2 + sin(rotY) * 0.3, -0.4),
        radius: 0.9,
        colors: [
          Colors.white,
          light.applyTo(const Color(0xFFF5F5F5), headNormal),
          light.applyTo(const Color(0xFFE8E8E8), Vec3(-headNormal.x, headNormal.y, -headNormal.z)),
        ],
        stops: const [0.0, 0.5, 1.0],
      ).createShader(
        Rect.fromCenter(center: Offset(headOffset, headY), width: 100, height: 90),
      )
      ..style = PaintingStyle.fill;

    final headOutline = Paint()
      ..color = const Color(0xFFBDBDBD)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0;

    canvas.save();
    canvas.translate(headOffset, headY);
    canvas.rotate(headRotZ * 0.3);

    // 头部椭圆
    canvas.drawOval(
      Rect.fromCenter(center: Offset.zero, width: 96, height: 82),
      headPaint,
    );
    canvas.drawOval(
      Rect.fromCenter(center: Offset.zero, width: 96, height: 82),
      headOutline,
    );

    // 头顶 3D 高光（位置随旋转变化）
    final hlX = -10 + sin(rotY) * 15;
    final highlightPaint = Paint()
      ..color = Colors.white.withOpacity(0.65)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3);
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(hlX, -22),
        width: 30,
        height: 14,
      ),
      highlightPaint,
    );

    // 环形光泽（3D 反射）
    final rimColor = light.calcSpecular(headNormal, const Vec3(0, 0, 1), shininess: 16);
    if (rimColor.alpha > 5) {
      final rimPaint = Paint()
        ..color = rimColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3);
      canvas.drawArc(
        Rect.fromCenter(center: Offset(hlX, 0), width: 85, height: 75),
        -pi * 0.8,
        pi * 0.5,
        false,
        rimPaint,
      );
    }

    canvas.restore();
  }

  /// 3D 眼睛
  void _drawEyes3D(Canvas canvas, Bone head, double rotY, Light3D light) {
    final headY = -55.0 + head.position.y;
    final headOffset = sin(rotY) * 4 + sin(head.rotation.z) * 3;
    final eyeY = headY + 2;

    // 眼睛间距随 3D 旋转变化（近大远小）
    for (final side in [-1.0, 1.0]) {
      // 3D 透视偏移
      final perspX = side * 18 + sin(rotY) * 5;
      final eyeScale = 1.0 - (side * sin(rotY)).clamp(0.0, 0.6) * 0.3;
      final eyeX = headOffset + perspX;

      if (eyeScale < 0.3) continue; // 太远的眼睛不画

      canvas.save();
      canvas.translate(eyeX, eyeY);
      canvas.scale(eyeScale, 1.0);

      if (isBlinking) {
        // 眨眼
        final blinkPaint = Paint()
          ..color = Colors.black87
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.5
          ..strokeCap = StrokeCap.round;
        final blinkPath = Path();
        blinkPath.moveTo(-7, 0);
        blinkPath.quadraticBezierTo(0, 4, 7, 0);
        canvas.drawPath(blinkPath, blinkPaint);
        canvas.restore();
        continue;
      }

      switch (mood) {
        case 'happy':
        case 'excited':
          _drawHappyEye3D(canvas);
          break;
        case 'sad':
          _drawSadEye3D(canvas, side);
          break;
        case 'sleepy':
          _drawSleepyEye3D(canvas);
          break;
        case 'angry':
          _drawAngryEye3D(canvas, side);
          break;
        default:
          _drawNormalEye3D(canvas, side, rotY);
      }

      canvas.restore();
    }
  }

  void _drawNormalEye3D(Canvas canvas, double side, double rotY) {
    // 眼白 — 3D 球形高光
    final whitePaint = Paint()
      ..shader = const RadialGradient(
        center: Alignment(-0.2, -0.3),
        radius: 0.8,
        colors: [Colors.white, Color(0xFFF5F5F5)],
      ).createShader(Rect.fromCenter(center: Offset.zero, width: 24, height: 26));
    final whiteOutline = Paint()
      ..color = const Color(0xFF424242)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8;

    canvas.drawOval(
      Rect.fromCenter(center: Offset.zero, width: 22, height: 24),
      whitePaint,
    );
    canvas.drawOval(
      Rect.fromCenter(center: Offset.zero, width: 22, height: 24),
      whiteOutline,
    );

    // 瞳孔 - 跟随 3D 旋转方向
    final pupilX = sin(rotY) * 3 + side * 1.5;
    final pupilPaint = Paint()
      ..shader = RadialGradient(
        center: const Alignment(-0.3, -0.3),
        radius: 0.8,
        colors: [
          const Color(0xFF1A1A1A),
          const Color(0xFF333333),
        ],
      ).createShader(
        Rect.fromCircle(center: Offset(pupilX, 1), radius: 8),
      );
    canvas.drawCircle(Offset(pupilX, 1), 7.5, pupilPaint);

    // 高光（双光点，QQ 风格）
    final shinePaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.fill;
    canvas.drawCircle(Offset(pupilX - 2.5, -2.5), 3.0, shinePaint);
    canvas.drawCircle(Offset(pupilX + 2, 3), 1.5, shinePaint);
  }

  void _drawHappyEye3D(Canvas canvas) {
    final paint = Paint()
      ..color = const Color(0xFF212121)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.0
      ..strokeCap = StrokeCap.round;

    final path = Path();
    path.moveTo(-8, 2);
    path.quadraticBezierTo(0, -8, 8, 2);
    canvas.drawPath(path, paint);
  }

  void _drawSadEye3D(Canvas canvas, double side) {
    _drawNormalEye3D(canvas, side, 0);

    // 泪珠（3D 透明效果）
    final tearPaint = Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Color(0x8064B5F6), Color(0xFF2196F3)],
      ).createShader(Rect.fromLTWH(side * 4, 8, 8, 14));
    final tearPath = Path();
    tearPath.moveTo(side * 6, 10);
    tearPath.quadraticBezierTo(side * 6 - 3, 18, side * 6, 20);
    tearPath.quadraticBezierTo(side * 6 + 3, 18, side * 6, 10);
    canvas.drawPath(tearPath, tearPaint);
  }

  void _drawSleepyEye3D(Canvas canvas) {
    final paint = Paint()
      ..color = const Color(0xFF212121)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(const Offset(-7, 0), const Offset(7, 0), paint);
  }

  void _drawAngryEye3D(Canvas canvas, double side) {
    _drawNormalEye3D(canvas, side, 0);

    // 怒眉
    final browPaint = Paint()
      ..color = const Color(0xFF212121)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.8
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(Offset(-side * 8, -14), Offset(side * 6, -16), browPaint);
  }

  /// 3D 嘴巴
  void _drawBeak3D(Canvas canvas, Bone head, double rotY, Light3D light) {
    final headY = -55.0 + head.position.y;
    final headOffset = sin(rotY) * 4 + sin(head.rotation.z) * 3;
    final beakY = headY + 15;
    final beakX = headOffset + sin(rotY) * 2;

    // 嘴巴法线
    final beakNormal = Vec3(sin(rotY) * 0.3, 0, 0.9).normalized;
    final beakColor = light.applyTo(const Color(0xFFFF9800), beakNormal);

    final beakPaint = Paint()
      ..color = beakColor
      ..style = PaintingStyle.fill;
    final beakOutline = Paint()
      ..color = const Color(0xFFE65100)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    final beakHighlight = Paint()
      ..color = light.applyTo(const Color(0xFFFFB74D), beakNormal)
      ..style = PaintingStyle.fill;

    // 上嘴
    final upperPath = Path();
    upperPath.moveTo(beakX - 14, beakY);
    upperPath.quadraticBezierTo(beakX, beakY - 6, beakX + 14, beakY);
    upperPath.quadraticBezierTo(beakX, beakY + 5, beakX - 14, beakY);
    upperPath.close();
    canvas.drawPath(upperPath, beakPaint);
    canvas.drawPath(upperPath, beakOutline);

    // 上嘴高光
    final hlPath = Path();
    hlPath.moveTo(beakX - 8, beakY - 1);
    hlPath.quadraticBezierTo(beakX, beakY - 4, beakX + 8, beakY - 1);
    hlPath.quadraticBezierTo(beakX, beakY + 1, beakX - 8, beakY - 1);
    canvas.drawPath(hlPath, beakHighlight);

    // 下嘴（根据心情变化）
    if (mood == 'happy' || mood == 'excited') {
      final lowerPath = Path();
      lowerPath.moveTo(beakX - 10, beakY + 2);
      lowerPath.quadraticBezierTo(beakX, beakY + 12, beakX + 10, beakY + 2);
      canvas.drawPath(lowerPath, beakPaint);
      canvas.drawPath(lowerPath, beakOutline);

      // 舌头
      final tonguePaint = Paint()
        ..color = const Color(0xFFEF5350)
        ..style = PaintingStyle.fill;
      final tonguePath = Path();
      tonguePath.moveTo(beakX - 5, beakY + 5);
      tonguePath.quadraticBezierTo(beakX, beakY + 10, beakX + 5, beakY + 5);
      canvas.drawPath(tonguePath, tonguePaint);
    } else if (mood == 'sad') {
      final sadPath = Path();
      sadPath.moveTo(beakX - 8, beakY + 3);
      sadPath.quadraticBezierTo(beakX, beakY - 1, beakX + 8, beakY + 3);
      final sadPaint = Paint()
        ..color = const Color(0xFFE65100)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5;
      canvas.drawPath(sadPath, sadPaint);
    }
  }

  /// 3D 腮红
  void _drawBlush3D(Canvas canvas, Bone head, double rotY) {
    if (mood == 'happy' || mood == 'excited' || mood == 'neutral') {
      final headY = -55.0 + head.position.y;
      final headOffset = sin(rotY) * 4;
      final blushY = headY + 6;

      final blushOpacity = mood == 'neutral' ? 0.35 : 0.65;
      final blushPaint = Paint()
        ..color = const Color(0xFFFFCDD2).withOpacity(blushOpacity)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4);

      // 两侧腮红（3D 透视缩放）
      for (final side in [-1.0, 1.0]) {
        final blushScale = 1.0 - (side * sin(rotY)).clamp(0.0, 0.6) * 0.4;
        if (blushScale < 0.3) continue;

        canvas.drawOval(
          Rect.fromCenter(
            center: Offset(headOffset + side * 32, blushY),
            width: 16 * blushScale,
            height: 10 * blushScale,
          ),
          blushPaint,
        );
      }
    }
  }

  /// 3D 呆毛
  void _drawAhoge3D(Canvas canvas, Bone head, Bone ahoge, double rotY, Light3D light) {
    final headY = -55.0 + head.position.y;
    final headOffset = sin(rotY) * 4 + sin(head.rotation.z) * 3;
    final ahogeBase = headY - 35;
    final wiggle = sin(ahoge.rotation.z * 10) * 5;

    final paint = Paint()
      ..color = light.applyTo(const Color(0xFFE0E0E0),
          Vec3(sin(rotY) * 0.5 + wiggle * 0.02, -0.8, 0.5).normalized)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.8
      ..strokeCap = StrokeCap.round;

    final path = Path();
    path.moveTo(headOffset, ahogeBase + 12);
    path.cubicTo(
      headOffset - 5, ahogeBase,
      headOffset + 8 + wiggle, ahogeBase - 15,
      headOffset + 3 + wiggle, ahogeBase - 24,
    );
    canvas.drawPath(path, paint);

    // 呆毛尖端发光球
    final tipGlow = Paint()
      ..color = Colors.white.withOpacity(0.5)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3);
    canvas.drawCircle(Offset(headOffset + 3 + wiggle, ahogeBase - 24), 3.5, tipGlow);

    final tipPaint = Paint()
      ..color = const Color(0xFFBDBDBD)
      ..style = PaintingStyle.fill;
    canvas.drawCircle(Offset(headOffset + 3 + wiggle, ahogeBase - 24), 2.5, tipPaint);
  }

  @override
  bool shouldRepaint(covariant _GooseBaby3DPainter oldDelegate) => true;
}

// ============================================================
// 3D 表情气泡
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

// ============================================================
// 自主行为配置
// ============================================================

class _AutoBehavior {
  final String name;
  final int durationMs;
  final int weight;
  const _AutoBehavior(this.name, this.durationMs, this.weight);
}
