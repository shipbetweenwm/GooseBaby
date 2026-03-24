import 'dart:math' show Random, pi, sin, cos;
import 'package:flutter/material.dart';

/// 🎆 烟花庆祝全屏动画
/// 当成就达成时，在整个窗口上层播放华丽的烟花动画
class FireworkCelebration extends StatefulWidget {
  /// 成就名称（显示在中间）
  final String achievementName;

  /// 成就图标
  final String achievementIcon;

  /// 动画结束回调
  final VoidCallback? onComplete;

  const FireworkCelebration({
    super.key,
    required this.achievementName,
    required this.achievementIcon,
    this.onComplete,
  });

  @override
  State<FireworkCelebration> createState() => _FireworkCelebrationState();
}

class _FireworkCelebrationState extends State<FireworkCelebration>
    with TickerProviderStateMixin {
  late AnimationController _mainController;
  late AnimationController _textController;
  late Animation<double> _textScale;
  late Animation<double> _textOpacity;

  final List<_Firework> _fireworks = [];
  final List<_FireworkParticle> _particles = [];
  final Random _random = Random();

  @override
  void initState() {
    super.initState();

    // 主动画控制器（控制粒子更新，4秒）
    _mainController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 4000),
    );

    // 文字动画控制器
    _textController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );

    _textScale = TweenSequence<double>([
      TweenSequenceItem(tween: Tween(begin: 0.0, end: 1.2), weight: 60),
      TweenSequenceItem(tween: Tween(begin: 1.2, end: 1.0), weight: 40),
    ]).animate(CurvedAnimation(
      parent: _textController,
      curve: Curves.easeOutBack,
    ));

    _textOpacity = Tween<double>(begin: 0, end: 1).animate(CurvedAnimation(
      parent: _textController,
      curve: const Interval(0.0, 0.5, curve: Curves.easeIn),
    ));

    _mainController.addListener(_tick);
    _mainController.addStatusListener((status) {
      if (status == AnimationStatus.completed) {
        widget.onComplete?.call();
      }
    });

    // 启动
    _mainController.forward();
    // 延迟 400ms 后显示文字
    Future.delayed(const Duration(milliseconds: 400), () {
      if (mounted) _textController.forward();
    });

    // 分批发射烟花
    _scheduleLaunches();
  }

  void _scheduleLaunches() {
    // 第一波：3 个烟花，立即发射
    for (int i = 0; i < 3; i++) {
      Future.delayed(Duration(milliseconds: i * 150), () {
        if (mounted) _launchFirework();
      });
    }
    // 第二波：3 个烟花，800ms 后发射
    for (int i = 0; i < 3; i++) {
      Future.delayed(Duration(milliseconds: 800 + i * 200), () {
        if (mounted) _launchFirework();
      });
    }
    // 第三波：4 个烟花，1800ms 后发射
    for (int i = 0; i < 4; i++) {
      Future.delayed(Duration(milliseconds: 1800 + i * 150), () {
        if (mounted) _launchFirework();
      });
    }
  }

  void _launchFirework() {
    if (!mounted) return;
    // 发射位置随机在屏幕宽度范围内
    final size = MediaQuery.of(context).size;
    final startX = _random.nextDouble() * size.width;
    final targetX = startX + (_random.nextDouble() - 0.5) * 100;
    final targetY = size.height * (0.15 + _random.nextDouble() * 0.35);

    final color = _randomFireworkColor();

    _fireworks.add(_Firework(
      startX: startX,
      startY: size.height,
      targetX: targetX,
      targetY: targetY,
      color: color,
      trailLife: 0.6 + _random.nextDouble() * 0.4,
      speed: 400 + _random.nextDouble() * 200,
    ));
  }

  Color _randomFireworkColor() {
    final colors = [
      const Color(0xFFFF4081), // 粉红
      const Color(0xFFFFD740), // 金色
      const Color(0xFF69F0AE), // 翠绿
      const Color(0xFF40C4FF), // 天蓝
      const Color(0xFFE040FB), // 紫色
      const Color(0xFFFF6E40), // 橙红
      const Color(0xFFFFFF00), // 亮黄
      const Color(0xFF00E5FF), // 青色
      const Color(0xFFFF1744), // 红色
      const Color(0xFF76FF03), // 亮绿
    ];
    return colors[_random.nextInt(colors.length)];
  }

  void _tick() {
    if (!mounted) return;

    const dt = 1.0 / 60.0;

    // 更新烟花（上升阶段）
    for (int i = _fireworks.length - 1; i >= 0; i--) {
      final fw = _fireworks[i];
      fw.progress += dt * fw.speed / 400;

      if (fw.progress >= 1.0) {
        // 到达目标 → 爆炸
        _explode(fw);
        _fireworks.removeAt(i);
      }
    }

    // 更新粒子
    for (int i = _particles.length - 1; i >= 0; i--) {
      final p = _particles[i];
      p.life -= dt;
      if (p.life <= 0) {
        _particles.removeAt(i);
        continue;
      }
      p.vy += p.gravity * dt * 100;
      p.x += p.vx * dt;
      p.y += p.vy * dt;
      p.opacity = (p.life / p.maxLife).clamp(0.0, 1.0);
      p.size *= 0.997; // 逐渐缩小
    }

    setState(() {});
  }

  void _explode(_Firework fw) {
    // 主爆炸粒子：向四面八方散射
    final particleCount = 40 + _random.nextInt(30);
    for (int i = 0; i < particleCount; i++) {
      final angle = _random.nextDouble() * pi * 2;
      final speed = 50 + _random.nextDouble() * 200;
      final life = 0.8 + _random.nextDouble() * 1.5;
      final size = 2.0 + _random.nextDouble() * 4;

      // 颜色微调
      final hueShift = (_random.nextDouble() - 0.5) * 30;
      final hsv = HSVColor.fromColor(fw.color);
      final adjustedColor = hsv
          .withHue((hsv.hue + hueShift) % 360)
          .withSaturation((hsv.saturation * (0.7 + _random.nextDouble() * 0.3)).clamp(0.0, 1.0))
          .toColor();

      _particles.add(_FireworkParticle(
        x: fw.targetX,
        y: fw.targetY,
        vx: cos(angle) * speed,
        vy: sin(angle) * speed,
        life: life,
        maxLife: life,
        size: size,
        color: adjustedColor,
        gravity: 0.8 + _random.nextDouble() * 0.5,
        opacity: 1.0,
      ));
    }

    // 内圈闪光粒子
    for (int i = 0; i < 15; i++) {
      final angle = _random.nextDouble() * pi * 2;
      final speed = 20 + _random.nextDouble() * 60;
      _particles.add(_FireworkParticle(
        x: fw.targetX,
        y: fw.targetY,
        vx: cos(angle) * speed,
        vy: sin(angle) * speed,
        life: 0.3 + _random.nextDouble() * 0.5,
        maxLife: 0.8,
        size: 4 + _random.nextDouble() * 6,
        color: Colors.white,
        gravity: 0.2,
        opacity: 1.0,
      ));
    }
  }

  @override
  void dispose() {
    _mainController.removeListener(_tick);
    _mainController.dispose();
    _textController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Stack(
        children: [
          // 烟花粒子渲染（无遮罩，直接在透明背景上绘制）
          CustomPaint(
            size: Size.infinite,
            painter: _FireworkPainter(
              fireworks: _fireworks,
              particles: _particles,
            ),
          ),

          // 成就文字（居中）
          Center(
            child: AnimatedBuilder(
              animation: _textController,
              builder: (_, child) {
                return Opacity(
                  opacity: _textOpacity.value,
                  child: Transform.scale(
                    scale: _textScale.value,
                    child: child,
                  ),
                );
              },
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 20),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.45),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: Colors.amber.withOpacity(0.6),
                    width: 2,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.amber.withOpacity(0.2),
                      blurRadius: 30,
                      spreadRadius: 5,
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      widget.achievementIcon,
                      style: const TextStyle(fontSize: 48),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      '🏆 成就达成！',
                      style: TextStyle(
                        fontSize: 16,
                        color: Colors.amber,
                        fontWeight: FontWeight.bold,
                        shadows: [
                          Shadow(color: Colors.black, blurRadius: 4),
                        ],
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      widget.achievementName,
                      style: const TextStyle(
                        fontSize: 22,
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        shadows: [
                          Shadow(color: Colors.black, blurRadius: 6),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 烟花实体（上升阶段）
class _Firework {
  double startX, startY;
  double targetX, targetY;
  Color color;
  double progress = 0;
  double trailLife;
  double speed;

  _Firework({
    required this.startX,
    required this.startY,
    required this.targetX,
    required this.targetY,
    required this.color,
    required this.trailLife,
    required this.speed,
  });

  double get currentX => startX + (targetX - startX) * progress;
  double get currentY => startY + (targetY - startY) * progress;
}

/// 烟花爆炸粒子
class _FireworkParticle {
  double x, y;
  double vx, vy;
  double life, maxLife;
  double size;
  Color color;
  double gravity;
  double opacity;

  _FireworkParticle({
    required this.x,
    required this.y,
    required this.vx,
    required this.vy,
    required this.life,
    required this.maxLife,
    required this.size,
    required this.color,
    required this.gravity,
    required this.opacity,
  });
}

/// 烟花绘制器
class _FireworkPainter extends CustomPainter {
  final List<_Firework> fireworks;
  final List<_FireworkParticle> particles;

  _FireworkPainter({required this.fireworks, required this.particles});

  @override
  void paint(Canvas canvas, Size size) {
    // 绘制上升中的烟花尾迹
    for (final fw in fireworks) {
      final trail = Paint()
        ..color = fw.color.withOpacity(0.8)
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round
        ..style = PaintingStyle.stroke;

      // 尾迹线段
      final prevProgress = (fw.progress - 0.1).clamp(0.0, 1.0);
      final prevX = fw.startX + (fw.targetX - fw.startX) * prevProgress;
      final prevY = fw.startY + (fw.targetY - fw.startY) * prevProgress;
      canvas.drawLine(
        Offset(prevX, prevY),
        Offset(fw.currentX, fw.currentY),
        trail,
      );

      // 烟花头部发光点
      final headGlow = Paint()
        ..color = Colors.white.withOpacity(0.9)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4);
      canvas.drawCircle(Offset(fw.currentX, fw.currentY), 3, headGlow);
    }

    // 绘制爆炸粒子
    for (final p in particles) {
      final paint = Paint()
        ..color = p.color.withOpacity(p.opacity.clamp(0.0, 1.0));

      // 发光效果
      final glowPaint = Paint()
        ..color = p.color.withOpacity((p.opacity * 0.4).clamp(0.0, 1.0))
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, p.size * 1.5);

      canvas.drawCircle(Offset(p.x, p.y), p.size * 1.2, glowPaint);
      canvas.drawCircle(Offset(p.x, p.y), p.size, paint);

      // 白色高光核心
      if (p.size > 2) {
        final corePaint = Paint()
          ..color = Colors.white.withOpacity((p.opacity * 0.6).clamp(0.0, 1.0));
        canvas.drawCircle(Offset(p.x, p.y), p.size * 0.3, corePaint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}
