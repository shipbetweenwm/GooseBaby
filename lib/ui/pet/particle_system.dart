import 'dart:math' show Random, pi, sin, cos;
import 'package:flutter/material.dart';

// ============================================================
// 🦢 鹅宝 3D 粒子特效系统
// ============================================================

/// 粒子类型
enum ParticleType {
  star,      // ⭐ 星星
  heart,     // ❤️ 爱心
  sparkle,   // ✨ 闪光
  bubble,    // 🫧 气泡
  note,      // 🎵 音符
  snow,      // ❄️ 雪花
  rain,      // 🌧 雨滴
  leaf,      // 🍃 树叶
  fire,      // 🔥 火焰
  zzz,       // 💤 睡眠
  tear,      // 😢 泪滴
  food,      // 🍖 食物碎屑
}

/// 单个粒子
class Particle {
  double x, y, z;          // 3D 位置
  double vx, vy, vz;       // 3D 速度
  double life;             // 剩余生命（0~1）
  double maxLife;          // 最大生命
  double size;             // 大小
  double rotation;         // 旋转角度
  double rotationSpeed;    // 旋转速度
  double opacity;          // 不透明度
  Color color;
  ParticleType type;

  Particle({
    this.x = 0,
    this.y = 0,
    this.z = 0,
    this.vx = 0,
    this.vy = 0,
    this.vz = 0,
    this.life = 1.0,
    this.maxLife = 1.0,
    this.size = 8,
    this.rotation = 0,
    this.rotationSpeed = 0,
    this.opacity = 1.0,
    required this.color,
    required this.type,
  });

  double get lifePercent => (life / maxLife).clamp(0.0, 1.0);
}

/// 粒子发射器配置
class ParticleEmitterConfig {
  final ParticleType type;
  final int maxParticles;
  final double emitRate;        // 每秒发射数量
  final double minLife;
  final double maxLife;
  final double minSize;
  final double maxSize;
  final double minSpeed;
  final double maxSpeed;
  final double gravity;
  final double spread;          // 发射扩散角度
  final double emitX, emitY;   // 发射位置
  final List<Color> colors;
  final bool fadeOut;
  final bool scaleDown;
  final bool is3D;             // 启用 3D 深度变化

  const ParticleEmitterConfig({
    required this.type,
    this.maxParticles = 50,
    this.emitRate = 10,
    this.minLife = 0.5,
    this.maxLife = 2.0,
    this.minSize = 4,
    this.maxSize = 12,
    this.minSpeed = 20,
    this.maxSpeed = 80,
    this.gravity = 0,
    this.spread = pi,
    this.emitX = 0,
    this.emitY = 0,
    this.colors = const [Colors.white],
    this.fadeOut = true,
    this.scaleDown = false,
    this.is3D = true,
  });
}

/// 粒子系统
class ParticleSystem {
  final List<Particle> _particles = [];
  final Random _random = Random();
  double _emitAccum = 0;
  bool _active = false;
  ParticleEmitterConfig _config;

  ParticleSystem(this._config);

  List<Particle> get particles => _particles;
  bool get isActive => _active;

  void setConfig(ParticleEmitterConfig config) {
    _config = config;
  }

  void start() {
    _active = true;
    _emitAccum = 0;
  }

  void stop() {
    _active = false;
  }

  void clear() {
    _particles.clear();
    _active = false;
  }

  /// 一次性发射一批粒子
  void burst(int count, {double? x, double? y}) {
    for (int i = 0; i < count && _particles.length < _config.maxParticles; i++) {
      _particles.add(_createParticle(x: x, y: y));
    }
  }

  /// 每帧更新
  void update(double dt) {
    // 发射新粒子
    if (_active) {
      _emitAccum += _config.emitRate * dt;
      while (_emitAccum >= 1.0 && _particles.length < _config.maxParticles) {
        _particles.add(_createParticle());
        _emitAccum -= 1.0;
      }
    }

    // 更新已有粒子
    for (int i = _particles.length - 1; i >= 0; i--) {
      final p = _particles[i];
      p.life -= dt;
      if (p.life <= 0) {
        _particles.removeAt(i);
        continue;
      }

      // 物理更新
      p.vy += _config.gravity * dt * 100;
      p.x += p.vx * dt;
      p.y += p.vy * dt;
      p.z += p.vz * dt;
      p.rotation += p.rotationSpeed * dt;

      // 生命周期效果
      if (_config.fadeOut) {
        p.opacity = p.lifePercent;
      }
      if (_config.scaleDown) {
        p.size = p.size * (0.98 + p.lifePercent * 0.02);
      }
    }
  }

  Particle _createParticle({double? x, double? y}) {
    final angle = (_random.nextDouble() - 0.5) * _config.spread - pi / 2;
    final speed = _config.minSpeed +
        _random.nextDouble() * (_config.maxSpeed - _config.minSpeed);
    final life = _config.minLife +
        _random.nextDouble() * (_config.maxLife - _config.minLife);
    final size = _config.minSize +
        _random.nextDouble() * (_config.maxSize - _config.minSize);
    final color = _config.colors[_random.nextInt(_config.colors.length)];

    return Particle(
      x: (x ?? _config.emitX) + (_random.nextDouble() - 0.5) * 20,
      y: (y ?? _config.emitY) + (_random.nextDouble() - 0.5) * 10,
      z: _config.is3D ? (_random.nextDouble() - 0.5) * 40 : 0,
      vx: cos(angle) * speed,
      vy: sin(angle) * speed,
      vz: _config.is3D ? (_random.nextDouble() - 0.5) * 30 : 0,
      life: life,
      maxLife: life,
      size: size,
      rotation: _random.nextDouble() * pi * 2,
      rotationSpeed: (_random.nextDouble() - 0.5) * 4,
      color: color,
      type: _config.type,
    );
  }
}

/// 粒子渲染器 - 将粒子画到 Canvas 上
class ParticleRenderer {
  static void render(Canvas canvas, List<Particle> particles) {
    for (final p in particles) {
      canvas.save();

      // 3D 深度缩放
      final depthScale = 1.0 / (1.0 + p.z * 0.005);
      final drawX = p.x * depthScale;
      final drawY = p.y * depthScale;
      final drawSize = p.size * depthScale;

      canvas.translate(drawX, drawY);
      canvas.rotate(p.rotation);

      final paint = Paint()
        ..color = p.color.withOpacity((p.opacity * depthScale).clamp(0.0, 1.0));

      switch (p.type) {
        case ParticleType.star:
          _drawStar(canvas, drawSize, paint);
          break;
        case ParticleType.heart:
          _drawHeart(canvas, drawSize, paint);
          break;
        case ParticleType.sparkle:
          _drawSparkle(canvas, drawSize, paint);
          break;
        case ParticleType.bubble:
          _drawBubble(canvas, drawSize, paint);
          break;
        case ParticleType.note:
          _drawNote(canvas, drawSize, paint);
          break;
        case ParticleType.snow:
          _drawSnow(canvas, drawSize, paint);
          break;
        case ParticleType.rain:
          _drawRain(canvas, drawSize, paint);
          break;
        case ParticleType.leaf:
          _drawLeaf(canvas, drawSize, paint);
          break;
        case ParticleType.fire:
          _drawFire(canvas, drawSize, paint, p.lifePercent);
          break;
        case ParticleType.zzz:
          _drawZzz(canvas, drawSize, paint, p.lifePercent);
          break;
        case ParticleType.tear:
          _drawTear(canvas, drawSize, paint);
          break;
        case ParticleType.food:
          _drawFood(canvas, drawSize, paint);
          break;
      }

      canvas.restore();
    }
  }

  /// ⭐ 五角星
  static void _drawStar(Canvas canvas, double size, Paint paint) {
    final path = Path();
    for (int i = 0; i < 5; i++) {
      final outerAngle = (i * 72 - 90) * pi / 180;
      final innerAngle = ((i * 72) + 36 - 90) * pi / 180;
      final outer = Offset(cos(outerAngle) * size, sin(outerAngle) * size);
      final inner = Offset(cos(innerAngle) * size * 0.4, sin(innerAngle) * size * 0.4);
      if (i == 0) {
        path.moveTo(outer.dx, outer.dy);
      } else {
        path.lineTo(outer.dx, outer.dy);
      }
      path.lineTo(inner.dx, inner.dy);
    }
    path.close();

    // 发光效果
    final glowPaint = Paint()
      ..color = paint.color.withOpacity(paint.color.opacity * 0.3)
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, size * 0.5);
    canvas.drawPath(path, glowPaint);
    canvas.drawPath(path, paint);
  }

  /// ❤️ 爱心
  static void _drawHeart(Canvas canvas, double size, Paint paint) {
    final path = Path();
    path.moveTo(0, size * 0.3);
    path.cubicTo(
      -size, -size * 0.3,
      -size * 0.5, -size,
      0, -size * 0.5,
    );
    path.cubicTo(
      size * 0.5, -size,
      size, -size * 0.3,
      0, size * 0.3,
    );
    path.close();

    final glowPaint = Paint()
      ..color = paint.color.withOpacity(paint.color.opacity * 0.4)
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, size * 0.4);
    canvas.drawPath(path, glowPaint);
    canvas.drawPath(path, paint);
  }

  /// ✨ 十字闪光
  static void _drawSparkle(Canvas canvas, double size, Paint paint) {
    paint.strokeWidth = size * 0.2;
    paint.strokeCap = StrokeCap.round;
    paint.style = PaintingStyle.stroke;

    // 十字
    canvas.drawLine(Offset(0, -size), Offset(0, size), paint);
    canvas.drawLine(Offset(-size, 0), Offset(size, 0), paint);
    // 斜十字（小一些）
    final s = size * 0.6;
    canvas.drawLine(Offset(-s, -s), Offset(s, s), paint);
    canvas.drawLine(Offset(s, -s), Offset(-s, s), paint);

    // 中心发光
    final glowPaint = Paint()
      ..color = paint.color.withOpacity(paint.color.opacity * 0.6)
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, size * 0.8);
    canvas.drawCircle(Offset.zero, size * 0.3, glowPaint);
  }

  /// 🫧 气泡
  static void _drawBubble(Canvas canvas, double size, Paint paint) {
    // 气泡轮廓
    final outlinePaint = Paint()
      ..color = paint.color.withOpacity(paint.color.opacity * 0.5)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    canvas.drawCircle(Offset.zero, size, outlinePaint);

    // 内部渐变
    final fillPaint = Paint()
      ..shader = RadialGradient(
        center: const Alignment(-0.3, -0.3),
        radius: 0.8,
        colors: [
          paint.color.withOpacity(paint.color.opacity * 0.15),
          paint.color.withOpacity(paint.color.opacity * 0.05),
        ],
      ).createShader(Rect.fromCircle(center: Offset.zero, radius: size));
    canvas.drawCircle(Offset.zero, size, fillPaint);

    // 高光
    final highlightPaint = Paint()
      ..color = Colors.white.withOpacity(paint.color.opacity * 0.7);
    canvas.drawCircle(Offset(-size * 0.3, -size * 0.3), size * 0.25, highlightPaint);
  }

  /// 🎵 音符
  static void _drawNote(Canvas canvas, double size, Paint paint) {
    // 音符头
    canvas.drawOval(
      Rect.fromCenter(center: Offset(0, size * 0.3), width: size * 0.8, height: size * 0.6),
      paint,
    );
    // 音符杆
    final stemPaint = Paint()
      ..color = paint.color
      ..strokeWidth = size * 0.12
      ..style = PaintingStyle.stroke;
    canvas.drawLine(
      Offset(size * 0.35, size * 0.2),
      Offset(size * 0.35, -size * 0.7),
      stemPaint,
    );
    // 音符旗
    final flagPath = Path();
    flagPath.moveTo(size * 0.35, -size * 0.7);
    flagPath.quadraticBezierTo(size * 0.9, -size * 0.5, size * 0.5, -size * 0.1);
    canvas.drawPath(flagPath, stemPaint);
  }

  /// ❄️ 雪花
  static void _drawSnow(Canvas canvas, double size, Paint paint) {
    paint.strokeWidth = size * 0.15;
    paint.strokeCap = StrokeCap.round;
    paint.style = PaintingStyle.stroke;

    for (int i = 0; i < 6; i++) {
      final angle = i * pi / 3;
      final dx = cos(angle) * size;
      final dy = sin(angle) * size;
      canvas.drawLine(Offset.zero, Offset(dx, dy), paint);
      // 小分支
      final bx = cos(angle) * size * 0.6;
      final by = sin(angle) * size * 0.6;
      final branchAngle1 = angle + pi / 6;
      final branchAngle2 = angle - pi / 6;
      final branchSize = size * 0.3;
      canvas.drawLine(
        Offset(bx, by),
        Offset(bx + cos(branchAngle1) * branchSize, by + sin(branchAngle1) * branchSize),
        paint,
      );
      canvas.drawLine(
        Offset(bx, by),
        Offset(bx + cos(branchAngle2) * branchSize, by + sin(branchAngle2) * branchSize),
        paint,
      );
    }
  }

  /// 🌧 雨滴
  static void _drawRain(Canvas canvas, double size, Paint paint) {
    final path = Path();
    path.moveTo(0, -size);
    path.quadraticBezierTo(size * 0.5, 0, 0, size);
    path.quadraticBezierTo(-size * 0.5, 0, 0, -size);
    path.close();
    canvas.drawPath(path, paint);
  }

  /// 🍃 树叶
  static void _drawLeaf(Canvas canvas, double size, Paint paint) {
    final path = Path();
    path.moveTo(0, -size);
    path.cubicTo(size * 0.8, -size * 0.5, size * 0.8, size * 0.5, 0, size);
    path.cubicTo(-size * 0.8, size * 0.5, -size * 0.8, -size * 0.5, 0, -size);
    path.close();
    canvas.drawPath(path, paint);

    // 叶脉
    final veinPaint = Paint()
      ..color = paint.color.withOpacity(paint.color.opacity * 0.5)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.8;
    canvas.drawLine(Offset(0, -size * 0.8), Offset(0, size * 0.8), veinPaint);
  }

  /// 🔥 火焰
  static void _drawFire(Canvas canvas, double size, Paint paint, double life) {
    final fireColor = Color.lerp(
      const Color(0xFFFF6600),
      const Color(0xFFFFCC00),
      life,
    )!;

    final path = Path();
    path.moveTo(0, size);
    path.quadraticBezierTo(-size * 0.6, 0, -size * 0.2, -size * 0.5);
    path.quadraticBezierTo(0, -size, size * 0.2, -size * 0.5);
    path.quadraticBezierTo(size * 0.6, 0, 0, size);
    path.close();

    final firePaint = Paint()
      ..color = fireColor.withOpacity(paint.color.opacity);
    final glowPaint = Paint()
      ..color = fireColor.withOpacity(paint.color.opacity * 0.3)
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, size * 0.6);
    canvas.drawPath(path, glowPaint);
    canvas.drawPath(path, firePaint);
  }

  /// 💤 zzZ
  static void _drawZzz(Canvas canvas, double size, Paint paint, double life) {
    final textPainter = TextPainter(
      text: TextSpan(
        text: 'Z',
        style: TextStyle(
          color: paint.color,
          fontSize: size * 1.5,
          fontWeight: FontWeight.bold,
          fontStyle: FontStyle.italic,
        ),
      ),
      textDirection: TextDirection.ltr,
    );
    textPainter.layout();
    textPainter.paint(canvas, Offset(-textPainter.width / 2, -textPainter.height / 2));
  }

  /// 😢 泪滴
  static void _drawTear(Canvas canvas, double size, Paint paint) {
    final path = Path();
    path.moveTo(0, -size);
    path.quadraticBezierTo(size * 0.5, 0, 0, size * 0.8);
    path.quadraticBezierTo(-size * 0.5, 0, 0, -size);
    path.close();

    final tearPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          const Color(0xFF82B1FF).withOpacity(paint.color.opacity),
          const Color(0xFF448AFF).withOpacity(paint.color.opacity),
        ],
      ).createShader(Rect.fromCenter(center: Offset.zero, width: size, height: size * 2));
    canvas.drawPath(path, tearPaint);

    // 高光
    final hlPaint = Paint()
      ..color = Colors.white.withOpacity(paint.color.opacity * 0.6);
    canvas.drawCircle(Offset(-size * 0.15, -size * 0.3), size * 0.15, hlPaint);
  }

  /// 🍖 食物碎屑
  static void _drawFood(Canvas canvas, double size, Paint paint) {
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(center: Offset.zero, width: size, height: size * 0.7),
        Radius.circular(size * 0.15),
      ),
      paint,
    );
  }
}

// ============================================================
// 预设粒子特效
// ============================================================

class GooseParticleEffects {
  /// 开心时的星星 + 爱心
  static ParticleEmitterConfig happyStars({double x = 0, double y = -40}) =>
      ParticleEmitterConfig(
        type: ParticleType.star,
        maxParticles: 30,
        emitRate: 8,
        minLife: 0.8,
        maxLife: 1.5,
        minSize: 4,
        maxSize: 10,
        minSpeed: 30,
        maxSpeed: 80,
        gravity: -0.5,
        spread: pi * 0.8,
        emitX: x,
        emitY: y,
        colors: const [
          Color(0xFFFFD700),
          Color(0xFFFFA726),
          Color(0xFFFFEE58),
          Color(0xFFFFFF8D),
        ],
        fadeOut: true,
      );

  /// 爱心飘散
  static ParticleEmitterConfig loveHearts({double x = 0, double y = -30}) =>
      ParticleEmitterConfig(
        type: ParticleType.heart,
        maxParticles: 20,
        emitRate: 5,
        minLife: 1.0,
        maxLife: 2.5,
        minSize: 5,
        maxSize: 14,
        minSpeed: 15,
        maxSpeed: 50,
        gravity: -0.3,
        spread: pi * 0.6,
        emitX: x,
        emitY: y,
        colors: const [
          Color(0xFFFF4081),
          Color(0xFFE91E63),
          Color(0xFFF48FB1),
          Color(0xFFFF80AB),
        ],
        fadeOut: true,
      );

  /// 闪光环绕
  static ParticleEmitterConfig sparkles({double x = 0, double y = 0}) =>
      ParticleEmitterConfig(
        type: ParticleType.sparkle,
        maxParticles: 25,
        emitRate: 12,
        minLife: 0.3,
        maxLife: 0.8,
        minSize: 3,
        maxSize: 8,
        minSpeed: 10,
        maxSpeed: 40,
        gravity: 0,
        spread: pi * 2,
        emitX: x,
        emitY: y,
        colors: const [
          Color(0xFFFFFFFF),
          Color(0xFFE1F5FE),
          Color(0xFFFFF9C4),
          Color(0xFFF3E5F5),
        ],
        fadeOut: true,
      );

  /// 睡觉时的 Z 字
  static ParticleEmitterConfig sleepZzz({double x = 30, double y = -60}) =>
      ParticleEmitterConfig(
        type: ParticleType.zzz,
        maxParticles: 8,
        emitRate: 1.5,
        minLife: 2.0,
        maxLife: 3.5,
        minSize: 6,
        maxSize: 14,
        minSpeed: 8,
        maxSpeed: 15,
        gravity: -0.2,
        spread: pi * 0.3,
        emitX: x,
        emitY: y,
        colors: const [
          Color(0xFF90CAF9),
          Color(0xFFBBDEFB),
          Color(0xFF64B5F6),
        ],
        fadeOut: true,
      );

  /// 伤心时的泪滴
  static ParticleEmitterConfig sadTears({double x = 0, double y = -40}) =>
      ParticleEmitterConfig(
        type: ParticleType.tear,
        maxParticles: 15,
        emitRate: 3,
        minLife: 1.0,
        maxLife: 2.0,
        minSize: 3,
        maxSize: 7,
        minSpeed: 20,
        maxSpeed: 50,
        gravity: 1.5,
        spread: pi * 0.4,
        emitX: x,
        emitY: y,
        colors: const [
          Color(0xFF82B1FF),
          Color(0xFF448AFF),
          Color(0xFF64B5F6),
        ],
        fadeOut: true,
      );

  /// 吃饭时的食物碎屑
  static ParticleEmitterConfig eatCrumbs({double x = 0, double y = -20}) =>
      ParticleEmitterConfig(
        type: ParticleType.food,
        maxParticles: 20,
        emitRate: 10,
        minLife: 0.5,
        maxLife: 1.5,
        minSize: 2,
        maxSize: 5,
        minSpeed: 20,
        maxSpeed: 60,
        gravity: 2.0,
        spread: pi * 0.8,
        emitX: x,
        emitY: y,
        colors: const [
          Color(0xFFFFCC80),
          Color(0xFFFFAB40),
          Color(0xFFFF9800),
          Color(0xFFFFE0B2),
        ],
        fadeOut: true,
      );

  /// 跳舞时的音符
  static ParticleEmitterConfig danceNotes({double x = 0, double y = -50}) =>
      ParticleEmitterConfig(
        type: ParticleType.note,
        maxParticles: 15,
        emitRate: 4,
        minLife: 1.5,
        maxLife: 3.0,
        minSize: 6,
        maxSize: 12,
        minSpeed: 15,
        maxSpeed: 40,
        gravity: -0.3,
        spread: pi * 0.7,
        emitX: x,
        emitY: y,
        colors: const [
          Color(0xFFE040FB),
          Color(0xFF7C4DFF),
          Color(0xFF536DFE),
          Color(0xFF40C4FF),
        ],
        fadeOut: true,
      );

  /// 升级时的烟花
  static ParticleEmitterConfig levelUpFireworks({double x = 0, double y = -30}) =>
      ParticleEmitterConfig(
        type: ParticleType.sparkle,
        maxParticles: 60,
        emitRate: 0, // 只用 burst
        minLife: 0.5,
        maxLife: 1.5,
        minSize: 3,
        maxSize: 10,
        minSpeed: 60,
        maxSpeed: 150,
        gravity: 0.8,
        spread: pi * 2,
        emitX: x,
        emitY: y,
        colors: const [
          Color(0xFFFF4081),
          Color(0xFFFFD740),
          Color(0xFF69F0AE),
          Color(0xFF40C4FF),
          Color(0xFFE040FB),
          Color(0xFFFF6E40),
        ],
        fadeOut: true,
        is3D: true,
      );

  /// 气泡上升
  static ParticleEmitterConfig bubbles({double x = 0, double y = 20}) =>
      ParticleEmitterConfig(
        type: ParticleType.bubble,
        maxParticles: 20,
        emitRate: 3,
        minLife: 2.0,
        maxLife: 4.0,
        minSize: 4,
        maxSize: 14,
        minSpeed: 10,
        maxSpeed: 30,
        gravity: -0.5,
        spread: pi * 0.4,
        emitX: x,
        emitY: y,
        colors: const [
          Color(0xFFB3E5FC),
          Color(0xFF81D4FA),
          Color(0xFF4FC3F7),
          Color(0xFFE1F5FE),
        ],
        fadeOut: true,
        is3D: true,
      );
}
