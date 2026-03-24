import 'dart:math' show pi, sin, cos, sqrt, max;
import 'package:flutter/material.dart';

// ============================================================
// 🦢 鹅宝 3D 动画引擎
// 纯 Flutter 实现的伪 3D 渲染 + 骨骼动画 + 粒子系统
// ============================================================

/// 3D 向量
class Vec3 {
  final double x, y, z;
  const Vec3(this.x, this.y, this.z);
  static const zero = Vec3(0, 0, 0);

  Vec3 operator +(Vec3 o) => Vec3(x + o.x, y + o.y, z + o.z);
  Vec3 operator -(Vec3 o) => Vec3(x - o.x, y - o.y, z - o.z);
  Vec3 operator *(double s) => Vec3(x * s, y * s, z * s);
  double get length => sqrt(x * x + y * y + z * z);
  Vec3 get normalized {
    final l = length;
    return l > 0 ? Vec3(x / l, y / l, z / l) : Vec3.zero;
  }

  double dot(Vec3 o) => x * o.x + y * o.y + z * o.z;

  /// 绕 Y 轴旋转
  Vec3 rotateY(double angle) {
    final c = cos(angle), s = sin(angle);
    return Vec3(x * c + z * s, y, -x * s + z * c);
  }

  /// 绕 X 轴旋转
  Vec3 rotateX(double angle) {
    final c = cos(angle), s = sin(angle);
    return Vec3(x, y * c - z * s, y * s + z * c);
  }

  /// 绕 Z 轴旋转
  Vec3 rotateZ(double angle) {
    final c = cos(angle), s = sin(angle);
    return Vec3(x * c - y * s, x * s + y * c, z);
  }

  /// 线性插值
  Vec3 lerp(Vec3 to, double t) =>
      Vec3(x + (to.x - x) * t, y + (to.y - y) * t, z + (to.z - z) * t);
}

/// 3D 光源
class Light3D {
  final Vec3 position;
  final Color color;
  final double intensity;
  final double ambient;

  const Light3D({
    this.position = const Vec3(-0.5, -1.0, 0.8),
    this.color = Colors.white,
    this.intensity = 1.0,
    this.ambient = 0.35,
  });

  /// 根据法线计算光照强度 (0~1)
  double calcIntensity(Vec3 normal) {
    final dir = (position * -1).normalized;
    final diff = max(0.0, normal.dot(dir));
    return (ambient + diff * intensity * (1 - ambient)).clamp(0.0, 1.0);
  }

  /// 给颜色施加光照
  Color applyTo(Color base, Vec3 normal) {
    final i = calcIntensity(normal);
    final a = (base.a * 255.0).round().clamp(0, 255);
    final r = (base.r * 255.0).round().clamp(0, 255);
    final g = (base.g * 255.0).round().clamp(0, 255);
    final b = (base.b * 255.0).round().clamp(0, 255);
    return Color.fromARGB(
      a,
      (r * i).round().clamp(0, 255),
      (g * i).round().clamp(0, 255),
      (b * i).round().clamp(0, 255),
    );
  }

  /// 计算高光
  Color calcSpecular(Vec3 normal, Vec3 viewDir, {double shininess = 32.0}) {
    final dir = (position * -1).normalized;
    final reflect = dir - normal * (2 * normal.dot(dir));
    final spec = max(0.0, reflect.dot(viewDir));
    final specPow = _pow(spec, shininess);
    final v = (specPow * intensity * 255).round().clamp(0, 80);
    return Color.fromARGB(v, 255, 255, 255);
  }

  static double _pow(double base, double exp) {
    if (base <= 0) return 0;
    double result = 1;
    for (int i = 0; i < exp.round(); i++) {
      result *= base;
    }
    return result;
  }
}

/// 骨骼节点
class Bone {
  final String name;
  Vec3 position;
  Vec3 rotation; // 欧拉角 (rx, ry, rz)
  Vec3 scale;
  final List<Bone> children;

  Bone({
    required this.name,
    this.position = Vec3.zero,
    this.rotation = Vec3.zero,
    Vec3? scale,
    List<Bone>? children,
  })  : scale = scale ?? const Vec3(1, 1, 1),
        children = children ?? [];

  /// 获取变换后的 2D 偏移（简化投影）
  Offset get offset2D => Offset(position.x, position.y);

  Bone? findBone(String name) {
    if (this.name == name) return this;
    for (final child in children) {
      final found = child.findBone(name);
      if (found != null) return found;
    }
    return null;
  }
}

/// 关键帧
class Keyframe {
  final double time; // 0.0 ~ 1.0
  final Vec3? position;
  final Vec3? rotation;
  final Vec3? scale;
  final Curve curve;

  const Keyframe({
    required this.time,
    this.position,
    this.rotation,
    this.scale,
    this.curve = Curves.easeInOut,
  });
}

/// 骨骼动画轨道
class BoneTrack {
  final String boneName;
  final List<Keyframe> keyframes;

  const BoneTrack({required this.boneName, required this.keyframes});

  /// 在指定时间采样
  ({Vec3? position, Vec3? rotation, Vec3? scale}) sample(double t) {
    if (keyframes.isEmpty) return (position: null, rotation: null, scale: null);
    if (keyframes.length == 1) {
      return (
        position: keyframes[0].position,
        rotation: keyframes[0].rotation,
        scale: keyframes[0].scale,
      );
    }

    // 找到当前帧区间
    int i = 0;
    while (i < keyframes.length - 1 && keyframes[i + 1].time <= t) {
      i++;
    }
    if (i >= keyframes.length - 1) {
      final kf = keyframes.last;
      return (position: kf.position, rotation: kf.rotation, scale: kf.scale);
    }

    final kf0 = keyframes[i];
    final kf1 = keyframes[i + 1];
    final localT = ((t - kf0.time) / (kf1.time - kf0.time)).clamp(0.0, 1.0);
    final curved = kf1.curve.transform(localT);

    return (
      position: kf0.position != null && kf1.position != null
          ? kf0.position!.lerp(kf1.position!, curved)
          : kf1.position,
      rotation: kf0.rotation != null && kf1.rotation != null
          ? kf0.rotation!.lerp(kf1.rotation!, curved)
          : kf1.rotation,
      scale: kf0.scale != null && kf1.scale != null
          ? kf0.scale!.lerp(kf1.scale!, curved)
          : kf1.scale,
    );
  }
}

/// 动画剪辑
class AnimationClip {
  final String name;
  final Duration duration;
  final List<BoneTrack> tracks;
  final bool loop;

  const AnimationClip({
    required this.name,
    required this.duration,
    required this.tracks,
    this.loop = true,
  });
}

/// 3D 动画引擎控制器
class AnimationEngine3D {
  final Map<String, AnimationClip> _clips = {};
  String? _currentClip;
  String? _blendingTo;
  double _blendProgress = 0;
  double _blendDuration = 0.3;
  double _time = 0;
  final Bone skeleton;
  final Light3D light;

  // 当前全局 3D 旋转（用于整体转身等效果）
  Vec3 globalRotation = Vec3.zero;
  Vec3 globalPosition = Vec3.zero;
  double perspectiveStrength = 0.002;

  AnimationEngine3D({
    required this.skeleton,
    this.light = const Light3D(),
  });

  String? get currentClipName => _currentClip;

  void addClip(AnimationClip clip) {
    _clips[clip.name] = clip;
  }

  /// 播放指定动画（带混合过渡）
  void play(String name, {double blendDuration = 0.3}) {
    if (_currentClip == name) return;
    if (_clips.containsKey(name)) {
      if (_currentClip != null) {
        _blendingTo = name;
        _blendProgress = 0;
        _blendDuration = blendDuration;
      } else {
        _currentClip = name;
        _time = 0;
      }
    }
  }

  /// 更新（每帧调用，dt 为秒）
  void update(double dt) {
    final clip = _clips[_currentClip];
    if (clip == null) return;

    final duration = clip.duration.inMilliseconds / 1000.0;
    _time += dt;
    if (clip.loop) {
      _time = _time % duration;
    } else {
      _time = _time.clamp(0, duration);
    }

    final normalizedTime = duration > 0 ? _time / duration : 0.0;

    // 应用当前动画
    _applyClip(clip, normalizedTime);

    // 混合过渡
    if (_blendingTo != null) {
      _blendProgress += dt / _blendDuration;
      if (_blendProgress >= 1.0) {
        _currentClip = _blendingTo;
        _blendingTo = null;
        _blendProgress = 0;
        _time = 0;
      }
    }
  }

  void _applyClip(AnimationClip clip, double t) {
    for (final track in clip.tracks) {
      final bone = skeleton.findBone(track.boneName);
      if (bone == null) continue;

      final sampled = track.sample(t);
      if (sampled.position != null) bone.position = sampled.position!;
      if (sampled.rotation != null) bone.rotation = sampled.rotation!;
      if (sampled.scale != null) bone.scale = sampled.scale!;
    }
  }

  /// 将 3D 点投影到 2D
  Offset project(Vec3 point, Size canvasSize) {
    // 应用全局旋转
    var p = point.rotateY(globalRotation.y).rotateX(globalRotation.x);
    p = p + globalPosition;

    // 透视投影
    final fov = 1.0 + p.z * perspectiveStrength;
    return Offset(
      canvasSize.width / 2 + p.x / fov,
      canvasSize.height / 2 + p.y / fov,
    );
  }

  /// 根据 Z 深度计算缩放（用于3D近大远小）
  double depthScale(double z) {
    return 1.0 / (1.0 + z * perspectiveStrength);
  }
}

// ============================================================
// 预设动画库
// ============================================================

class GooseAnimations {
  static AnimationClip idle() => const AnimationClip(
        name: 'idle',
        duration: Duration(milliseconds: 2500),
        loop: true,
        tracks: [
          // 身体明显呼吸起伏 + 轻微左右摇晃
          BoneTrack(boneName: 'body', keyframes: [
            Keyframe(time: 0.0, position: Vec3(0, 0, 0), rotation: Vec3(0, 0, 0)),
            Keyframe(time: 0.25, position: Vec3(1.5, -5, 0), rotation: Vec3(0.03, 0.02, 0.01), curve: Curves.easeInOut),
            Keyframe(time: 0.5, position: Vec3(0, -7, 0), rotation: Vec3(0.04, 0, 0), curve: Curves.easeInOut),
            Keyframe(time: 0.75, position: Vec3(-1.5, -5, 0), rotation: Vec3(0.03, -0.02, -0.01), curve: Curves.easeInOut),
            Keyframe(time: 1.0, position: Vec3(0, 0, 0), rotation: Vec3(0, 0, 0)),
          ]),
          // 头部活泼晃动 — 好像在四处张望
          BoneTrack(boneName: 'head', keyframes: [
            Keyframe(time: 0.0, rotation: Vec3(0, 0, 0)),
            Keyframe(time: 0.2, rotation: Vec3(0.04, 0.08, 0.04), curve: Curves.easeInOut),
            Keyframe(time: 0.45, rotation: Vec3(-0.03, 0.03, -0.02), curve: Curves.easeInOut),
            Keyframe(time: 0.65, rotation: Vec3(0.02, -0.08, -0.03), curve: Curves.easeInOut),
            Keyframe(time: 0.85, rotation: Vec3(-0.02, -0.04, 0.02), curve: Curves.easeInOut),
            Keyframe(time: 1.0, rotation: Vec3(0, 0, 0)),
          ]),
          // 翅膀呼吸联动 — 幅度加大
          BoneTrack(boneName: 'wing_left', keyframes: [
            Keyframe(time: 0.0, rotation: Vec3(0, 0, 0)),
            Keyframe(time: 0.3, rotation: Vec3(0, -0.05, -0.12), curve: Curves.easeInOut),
            Keyframe(time: 0.7, rotation: Vec3(0, 0.02, 0.03), curve: Curves.easeInOut),
            Keyframe(time: 1.0, rotation: Vec3(0, 0, 0)),
          ]),
          BoneTrack(boneName: 'wing_right', keyframes: [
            Keyframe(time: 0.0, rotation: Vec3(0, 0, 0)),
            Keyframe(time: 0.3, rotation: Vec3(0, 0.05, 0.12), curve: Curves.easeInOut),
            Keyframe(time: 0.7, rotation: Vec3(0, -0.02, -0.03), curve: Curves.easeInOut),
            Keyframe(time: 1.0, rotation: Vec3(0, 0, 0)),
          ]),
          // 呆毛大幅摇摆 — 像弹簧一样弹动
          BoneTrack(boneName: 'ahoge', keyframes: [
            Keyframe(time: 0.0, rotation: Vec3(0, 0, 0)),
            Keyframe(time: 0.15, rotation: Vec3(0, 0, 0.25), curve: Curves.easeOut),
            Keyframe(time: 0.4, rotation: Vec3(0, 0, -0.2), curve: Curves.easeInOut),
            Keyframe(time: 0.6, rotation: Vec3(0, 0, 0.22), curve: Curves.easeInOut),
            Keyframe(time: 0.85, rotation: Vec3(0, 0, -0.18), curve: Curves.easeInOut),
            Keyframe(time: 1.0, rotation: Vec3(0, 0, 0), curve: Curves.easeIn),
          ]),
          // 脚掌也微微动一下（原地踏步感）
          BoneTrack(boneName: 'foot_left', keyframes: [
            Keyframe(time: 0.0, position: Vec3(0, 0, 0)),
            Keyframe(time: 0.4, position: Vec3(0, -2, 0), curve: Curves.easeInOut),
            Keyframe(time: 0.6, position: Vec3(0, 0, 0), curve: Curves.easeInOut),
            Keyframe(time: 1.0, position: Vec3(0, 0, 0)),
          ]),
          BoneTrack(boneName: 'foot_right', keyframes: [
            Keyframe(time: 0.0, position: Vec3(0, 0, 0)),
            Keyframe(time: 0.7, position: Vec3(0, -2, 0), curve: Curves.easeInOut),
            Keyframe(time: 0.9, position: Vec3(0, 0, 0), curve: Curves.easeInOut),
            Keyframe(time: 1.0, position: Vec3(0, 0, 0)),
          ]),
          // 围巾轻微飘动
          BoneTrack(boneName: 'scarf', keyframes: [
            Keyframe(time: 0.0, rotation: Vec3(0, 0, 0)),
            Keyframe(time: 0.35, rotation: Vec3(0, 0.03, 0.02), curve: Curves.easeInOut),
            Keyframe(time: 0.7, rotation: Vec3(0, -0.03, -0.02), curve: Curves.easeInOut),
            Keyframe(time: 1.0, rotation: Vec3(0, 0, 0)),
          ]),
        ],
      );

  static AnimationClip dance() => const AnimationClip(
        name: 'dance',
        duration: Duration(milliseconds: 1600),
        loop: true,
        tracks: [
          // 身体左右摇摆 + 上下弹跳
          BoneTrack(boneName: 'body', keyframes: [
            Keyframe(time: 0.0, position: Vec3(0, 0, 0), rotation: Vec3(0, 0, -0.1)),
            Keyframe(time: 0.25, position: Vec3(8, -12, 0), rotation: Vec3(0, 0.15, 0.1), curve: Curves.easeOut),
            Keyframe(time: 0.5, position: Vec3(0, 0, 0), rotation: Vec3(0, 0, -0.1), curve: Curves.easeIn),
            Keyframe(time: 0.75, position: Vec3(-8, -12, 0), rotation: Vec3(0, -0.15, -0.1), curve: Curves.easeOut),
            Keyframe(time: 1.0, position: Vec3(0, 0, 0), rotation: Vec3(0, 0, -0.1)),
          ]),
          // 头部跟随摇摆
          BoneTrack(boneName: 'head', keyframes: [
            Keyframe(time: 0.0, rotation: Vec3(0, 0, 0.08)),
            Keyframe(time: 0.25, rotation: Vec3(0.05, 0.12, -0.12), curve: Curves.easeOut),
            Keyframe(time: 0.5, rotation: Vec3(0, 0, 0.08)),
            Keyframe(time: 0.75, rotation: Vec3(0.05, -0.12, 0.12), curve: Curves.easeOut),
            Keyframe(time: 1.0, rotation: Vec3(0, 0, 0.08)),
          ]),
          // 翅膀大幅挥舞
          BoneTrack(boneName: 'wing_left', keyframes: [
            Keyframe(time: 0.0, rotation: Vec3(0, 0, 0)),
            Keyframe(time: 0.15, rotation: Vec3(0, -0.3, -0.6), curve: Curves.easeOut),
            Keyframe(time: 0.35, rotation: Vec3(0, 0, 0), curve: Curves.easeIn),
            Keyframe(time: 0.5, rotation: Vec3(0, 0, 0)),
            Keyframe(time: 0.65, rotation: Vec3(0, -0.3, -0.6), curve: Curves.easeOut),
            Keyframe(time: 0.85, rotation: Vec3(0, 0, 0), curve: Curves.easeIn),
            Keyframe(time: 1.0, rotation: Vec3(0, 0, 0)),
          ]),
          BoneTrack(boneName: 'wing_right', keyframes: [
            Keyframe(time: 0.0, rotation: Vec3(0, 0, 0)),
            Keyframe(time: 0.15, rotation: Vec3(0, 0.3, 0.6), curve: Curves.easeOut),
            Keyframe(time: 0.35, rotation: Vec3(0, 0, 0), curve: Curves.easeIn),
            Keyframe(time: 0.5, rotation: Vec3(0, 0, 0)),
            Keyframe(time: 0.65, rotation: Vec3(0, 0.3, 0.6), curve: Curves.easeOut),
            Keyframe(time: 0.85, rotation: Vec3(0, 0, 0), curve: Curves.easeIn),
            Keyframe(time: 1.0, rotation: Vec3(0, 0, 0)),
          ]),
          // 脚交替踏步
          BoneTrack(boneName: 'foot_left', keyframes: [
            Keyframe(time: 0.0, position: Vec3(0, 0, 0)),
            Keyframe(time: 0.25, position: Vec3(0, -5, 0), curve: Curves.easeOut),
            Keyframe(time: 0.5, position: Vec3(0, 0, 0), curve: Curves.easeIn),
            Keyframe(time: 1.0, position: Vec3(0, 0, 0)),
          ]),
          BoneTrack(boneName: 'foot_right', keyframes: [
            Keyframe(time: 0.0, position: Vec3(0, 0, 0)),
            Keyframe(time: 0.5, position: Vec3(0, 0, 0)),
            Keyframe(time: 0.75, position: Vec3(0, -5, 0), curve: Curves.easeOut),
            Keyframe(time: 1.0, position: Vec3(0, 0, 0), curve: Curves.easeIn),
          ]),
        ],
      );

  static AnimationClip jump() => const AnimationClip(
        name: 'jump',
        duration: Duration(milliseconds: 800),
        loop: false,
        tracks: [
          // 身体跳起
          BoneTrack(boneName: 'body', keyframes: [
            Keyframe(time: 0.0, position: Vec3(0, 0, 0), scale: Vec3(1, 1, 1)),
            Keyframe(time: 0.15, position: Vec3(0, 5, 0), scale: Vec3(1.1, 0.85, 1), curve: Curves.easeIn),
            Keyframe(time: 0.45, position: Vec3(0, -40, 0), scale: Vec3(0.9, 1.15, 1), curve: Curves.easeOut),
            Keyframe(time: 0.75, position: Vec3(0, -10, 0), scale: Vec3(1, 1, 1), curve: Curves.easeIn),
            Keyframe(time: 0.9, position: Vec3(0, 4, 0), scale: Vec3(1.08, 0.9, 1), curve: Curves.bounceOut),
            Keyframe(time: 1.0, position: Vec3(0, 0, 0), scale: Vec3(1, 1, 1)),
          ]),
          // 翅膀在空中展开
          BoneTrack(boneName: 'wing_left', keyframes: [
            Keyframe(time: 0.0, rotation: Vec3(0, 0, 0)),
            Keyframe(time: 0.3, rotation: Vec3(-0.3, -0.5, -0.8), curve: Curves.easeOut),
            Keyframe(time: 0.7, rotation: Vec3(-0.1, -0.2, -0.4), curve: Curves.easeInOut),
            Keyframe(time: 1.0, rotation: Vec3(0, 0, 0), curve: Curves.easeIn),
          ]),
          BoneTrack(boneName: 'wing_right', keyframes: [
            Keyframe(time: 0.0, rotation: Vec3(0, 0, 0)),
            Keyframe(time: 0.3, rotation: Vec3(-0.3, 0.5, 0.8), curve: Curves.easeOut),
            Keyframe(time: 0.7, rotation: Vec3(-0.1, 0.2, 0.4), curve: Curves.easeInOut),
            Keyframe(time: 1.0, rotation: Vec3(0, 0, 0), curve: Curves.easeIn),
          ]),
          // 头微微后仰
          BoneTrack(boneName: 'head', keyframes: [
            Keyframe(time: 0.0, rotation: Vec3(0, 0, 0)),
            Keyframe(time: 0.3, rotation: Vec3(-0.15, 0, 0), curve: Curves.easeOut),
            Keyframe(time: 0.7, rotation: Vec3(0.05, 0, 0)),
            Keyframe(time: 1.0, rotation: Vec3(0, 0, 0)),
          ]),
        ],
      );

  static AnimationClip spin() => const AnimationClip(
        name: 'spin',
        duration: Duration(milliseconds: 1200),
        loop: false,
        tracks: [
          // 身体 360° 旋转 + 跳起
          BoneTrack(boneName: 'body', keyframes: [
            Keyframe(time: 0.0, position: Vec3(0, 0, 0), rotation: Vec3(0, 0, 0)),
            Keyframe(time: 0.1, position: Vec3(0, 4, 0), rotation: Vec3(0, 0, 0)),
            Keyframe(time: 0.25, position: Vec3(0, -20, 0), rotation: Vec3(0, pi * 0.5, 0), curve: Curves.easeOut),
            Keyframe(time: 0.5, position: Vec3(0, -25, 0), rotation: Vec3(0, pi, 0), curve: Curves.linear),
            Keyframe(time: 0.75, position: Vec3(0, -20, 0), rotation: Vec3(0, pi * 1.5, 0), curve: Curves.linear),
            Keyframe(time: 0.9, position: Vec3(0, 0, 0), rotation: Vec3(0, pi * 2, 0), curve: Curves.easeIn),
            Keyframe(time: 1.0, position: Vec3(0, 0, 0), rotation: Vec3(0, 0, 0)),
          ]),
          // 翅膀展开
          BoneTrack(boneName: 'wing_left', keyframes: [
            Keyframe(time: 0.0, rotation: Vec3(0, 0, 0)),
            Keyframe(time: 0.2, rotation: Vec3(0, -0.4, -0.9), curve: Curves.easeOut),
            Keyframe(time: 0.8, rotation: Vec3(0, -0.4, -0.9)),
            Keyframe(time: 1.0, rotation: Vec3(0, 0, 0), curve: Curves.easeIn),
          ]),
          BoneTrack(boneName: 'wing_right', keyframes: [
            Keyframe(time: 0.0, rotation: Vec3(0, 0, 0)),
            Keyframe(time: 0.2, rotation: Vec3(0, 0.4, 0.9), curve: Curves.easeOut),
            Keyframe(time: 0.8, rotation: Vec3(0, 0.4, 0.9)),
            Keyframe(time: 1.0, rotation: Vec3(0, 0, 0), curve: Curves.easeIn),
          ]),
        ],
      );

  static AnimationClip wave() => const AnimationClip(
        name: 'wave',
        duration: Duration(milliseconds: 1200),
        loop: false,
        tracks: [
          // 身体微微倾斜
          BoneTrack(boneName: 'body', keyframes: [
            Keyframe(time: 0.0, rotation: Vec3(0, 0, 0)),
            Keyframe(time: 0.2, rotation: Vec3(0, 0.08, 0.05)),
            Keyframe(time: 0.8, rotation: Vec3(0, 0.08, 0.05)),
            Keyframe(time: 1.0, rotation: Vec3(0, 0, 0)),
          ]),
          // 右翅膀挥手
          BoneTrack(boneName: 'wing_right', keyframes: [
            Keyframe(time: 0.0, rotation: Vec3(0, 0, 0)),
            Keyframe(time: 0.15, rotation: Vec3(-0.5, 0.3, 1.2), curve: Curves.easeOut),
            Keyframe(time: 0.3, rotation: Vec3(-0.3, 0.5, 0.7), curve: Curves.easeInOut),
            Keyframe(time: 0.45, rotation: Vec3(-0.5, 0.3, 1.2), curve: Curves.easeInOut),
            Keyframe(time: 0.6, rotation: Vec3(-0.3, 0.5, 0.7), curve: Curves.easeInOut),
            Keyframe(time: 0.75, rotation: Vec3(-0.5, 0.3, 1.2), curve: Curves.easeInOut),
            Keyframe(time: 0.9, rotation: Vec3(0, 0.1, 0.3), curve: Curves.easeIn),
            Keyframe(time: 1.0, rotation: Vec3(0, 0, 0)),
          ]),
          // 头跟随看向挥手方向
          BoneTrack(boneName: 'head', keyframes: [
            Keyframe(time: 0.0, rotation: Vec3(0, 0, 0)),
            Keyframe(time: 0.2, rotation: Vec3(0.05, 0.1, 0.08)),
            Keyframe(time: 0.8, rotation: Vec3(0.05, 0.1, 0.08)),
            Keyframe(time: 1.0, rotation: Vec3(0, 0, 0)),
          ]),
        ],
      );

  static AnimationClip eat() => const AnimationClip(
        name: 'eat',
        duration: Duration(milliseconds: 2000),
        loop: false,
        tracks: [
          // 身体前倾
          BoneTrack(boneName: 'body', keyframes: [
            Keyframe(time: 0.0, rotation: Vec3(0, 0, 0)),
            Keyframe(time: 0.15, rotation: Vec3(0.12, 0, 0), curve: Curves.easeOut),
            Keyframe(time: 0.85, rotation: Vec3(0.12, 0, 0)),
            Keyframe(time: 1.0, rotation: Vec3(0, 0, 0), curve: Curves.easeIn),
          ]),
          // 头上下啄食
          BoneTrack(boneName: 'head', keyframes: [
            Keyframe(time: 0.0, rotation: Vec3(0, 0, 0)),
            Keyframe(time: 0.2, rotation: Vec3(0.2, 0, 0), curve: Curves.easeOut),
            Keyframe(time: 0.3, rotation: Vec3(-0.1, 0, 0), curve: Curves.easeIn),
            Keyframe(time: 0.4, rotation: Vec3(0.2, 0, 0), curve: Curves.easeOut),
            Keyframe(time: 0.5, rotation: Vec3(-0.1, 0, 0), curve: Curves.easeIn),
            Keyframe(time: 0.6, rotation: Vec3(0.2, 0, 0), curve: Curves.easeOut),
            Keyframe(time: 0.7, rotation: Vec3(-0.05, 0, 0), curve: Curves.easeIn),
            Keyframe(time: 0.85, rotation: Vec3(0, 0, 0)),
            Keyframe(time: 1.0, rotation: Vec3(0, 0, 0)),
          ]),
        ],
      );

  static AnimationClip sleep() => const AnimationClip(
        name: 'sleep',
        duration: Duration(milliseconds: 4000),
        loop: true,
        tracks: [
          // 身体缓慢起伏
          BoneTrack(boneName: 'body', keyframes: [
            Keyframe(time: 0.0, position: Vec3(0, 0, 0), scale: Vec3(1, 1, 1)),
            Keyframe(time: 0.5, position: Vec3(0, 2, 0), scale: Vec3(1.03, 0.97, 1), curve: Curves.easeInOut),
            Keyframe(time: 1.0, position: Vec3(0, 0, 0), scale: Vec3(1, 1, 1)),
          ]),
          // 头低垂
          BoneTrack(boneName: 'head', keyframes: [
            Keyframe(time: 0.0, rotation: Vec3(0.15, 0, -0.05)),
            Keyframe(time: 0.5, rotation: Vec3(0.18, 0, -0.08), curve: Curves.easeInOut),
            Keyframe(time: 1.0, rotation: Vec3(0.15, 0, -0.05)),
          ]),
          // 翅膀收紧
          BoneTrack(boneName: 'wing_left', keyframes: [
            Keyframe(time: 0.0, rotation: Vec3(0, 0, 0.08)),
            Keyframe(time: 1.0, rotation: Vec3(0, 0, 0.08)),
          ]),
          BoneTrack(boneName: 'wing_right', keyframes: [
            Keyframe(time: 0.0, rotation: Vec3(0, 0, -0.08)),
            Keyframe(time: 1.0, rotation: Vec3(0, 0, -0.08)),
          ]),
        ],
      );

  static AnimationClip happy() => const AnimationClip(
        name: 'happy',
        duration: Duration(milliseconds: 1000),
        loop: true,
        tracks: [
          // 快速上下蹦跶
          BoneTrack(boneName: 'body', keyframes: [
            Keyframe(time: 0.0, position: Vec3(0, 0, 0)),
            Keyframe(time: 0.25, position: Vec3(3, -15, 0), curve: Curves.easeOut),
            Keyframe(time: 0.5, position: Vec3(0, 0, 0), curve: Curves.easeIn),
            Keyframe(time: 0.75, position: Vec3(-3, -15, 0), curve: Curves.easeOut),
            Keyframe(time: 1.0, position: Vec3(0, 0, 0), curve: Curves.easeIn),
          ]),
          // 翅膀快速拍动
          BoneTrack(boneName: 'wing_left', keyframes: [
            Keyframe(time: 0.0, rotation: Vec3(0, 0, 0)),
            Keyframe(time: 0.15, rotation: Vec3(0, -0.3, -0.7), curve: Curves.easeOut),
            Keyframe(time: 0.35, rotation: Vec3(0, 0, 0), curve: Curves.easeIn),
            Keyframe(time: 0.65, rotation: Vec3(0, -0.3, -0.7), curve: Curves.easeOut),
            Keyframe(time: 0.85, rotation: Vec3(0, 0, 0), curve: Curves.easeIn),
            Keyframe(time: 1.0, rotation: Vec3(0, 0, 0)),
          ]),
          BoneTrack(boneName: 'wing_right', keyframes: [
            Keyframe(time: 0.0, rotation: Vec3(0, 0, 0)),
            Keyframe(time: 0.15, rotation: Vec3(0, 0.3, 0.7), curve: Curves.easeOut),
            Keyframe(time: 0.35, rotation: Vec3(0, 0, 0), curve: Curves.easeIn),
            Keyframe(time: 0.65, rotation: Vec3(0, 0.3, 0.7), curve: Curves.easeOut),
            Keyframe(time: 0.85, rotation: Vec3(0, 0, 0), curve: Curves.easeIn),
            Keyframe(time: 1.0, rotation: Vec3(0, 0, 0)),
          ]),
          // 头开心地晃动
          BoneTrack(boneName: 'head', keyframes: [
            Keyframe(time: 0.0, rotation: Vec3(-0.05, 0, 0)),
            Keyframe(time: 0.25, rotation: Vec3(-0.08, 0.1, 0.05)),
            Keyframe(time: 0.5, rotation: Vec3(-0.05, 0, 0)),
            Keyframe(time: 0.75, rotation: Vec3(-0.08, -0.1, -0.05)),
            Keyframe(time: 1.0, rotation: Vec3(-0.05, 0, 0)),
          ]),
        ],
      );

  static AnimationClip sad() => const AnimationClip(
        name: 'sad',
        duration: Duration(milliseconds: 3000),
        loop: true,
        tracks: [
          // 身体低沉
          BoneTrack(boneName: 'body', keyframes: [
            Keyframe(time: 0.0, position: Vec3(0, 4, 0), rotation: Vec3(0.05, 0, 0)),
            Keyframe(time: 0.5, position: Vec3(0, 5, 0), rotation: Vec3(0.06, 0, -0.02), curve: Curves.easeInOut),
            Keyframe(time: 1.0, position: Vec3(0, 4, 0), rotation: Vec3(0.05, 0, 0)),
          ]),
          // 头低垂
          BoneTrack(boneName: 'head', keyframes: [
            Keyframe(time: 0.0, rotation: Vec3(0.15, 0, -0.05)),
            Keyframe(time: 0.5, rotation: Vec3(0.18, -0.03, -0.08), curve: Curves.easeInOut),
            Keyframe(time: 1.0, rotation: Vec3(0.15, 0, -0.05)),
          ]),
          // 翅膀下垂
          BoneTrack(boneName: 'wing_left', keyframes: [
            Keyframe(time: 0.0, rotation: Vec3(0.1, 0, 0.15)),
            Keyframe(time: 1.0, rotation: Vec3(0.1, 0, 0.15)),
          ]),
          BoneTrack(boneName: 'wing_right', keyframes: [
            Keyframe(time: 0.0, rotation: Vec3(0.1, 0, -0.15)),
            Keyframe(time: 1.0, rotation: Vec3(0.1, 0, -0.15)),
          ]),
        ],
      );

  static AnimationClip fly() => const AnimationClip(
        name: 'fly',
        duration: Duration(milliseconds: 600),
        loop: true,
        tracks: [
          // 身体悬浮上升
          BoneTrack(boneName: 'body', keyframes: [
            Keyframe(time: 0.0, position: Vec3(0, -30, 0)),
            Keyframe(time: 0.5, position: Vec3(0, -35, 0), curve: Curves.easeInOut),
            Keyframe(time: 1.0, position: Vec3(0, -30, 0)),
          ]),
          // 翅膀快速拍打
          BoneTrack(boneName: 'wing_left', keyframes: [
            Keyframe(time: 0.0, rotation: Vec3(-0.3, -0.5, -1.0)),
            Keyframe(time: 0.5, rotation: Vec3(0.1, 0, 0.2), curve: Curves.easeIn),
            Keyframe(time: 1.0, rotation: Vec3(-0.3, -0.5, -1.0), curve: Curves.easeOut),
          ]),
          BoneTrack(boneName: 'wing_right', keyframes: [
            Keyframe(time: 0.0, rotation: Vec3(-0.3, 0.5, 1.0)),
            Keyframe(time: 0.5, rotation: Vec3(0.1, 0, -0.2), curve: Curves.easeIn),
            Keyframe(time: 1.0, rotation: Vec3(-0.3, 0.5, 1.0), curve: Curves.easeOut),
          ]),
          // 头微仰
          BoneTrack(boneName: 'head', keyframes: [
            Keyframe(time: 0.0, rotation: Vec3(-0.1, 0, 0)),
            Keyframe(time: 1.0, rotation: Vec3(-0.1, 0, 0)),
          ]),
          // 脚收起
          BoneTrack(boneName: 'foot_left', keyframes: [
            Keyframe(time: 0.0, position: Vec3(2, -5, 0)),
            Keyframe(time: 1.0, position: Vec3(2, -5, 0)),
          ]),
          BoneTrack(boneName: 'foot_right', keyframes: [
            Keyframe(time: 0.0, position: Vec3(-2, -5, 0)),
            Keyframe(time: 1.0, position: Vec3(-2, -5, 0)),
          ]),
        ],
      );

  /// 获取所有预设动画
  static List<AnimationClip> allClips() => [
        idle(),
        dance(),
        jump(),
        spin(),
        wave(),
        eat(),
        sleep(),
        happy(),
        sad(),
        fly(),
      ];
}

/// 创建鹅宝骨骼
Bone createGooseSkeleton() {
  return Bone(
    name: 'root',
    children: [
      Bone(
        name: 'body',
        position: const Vec3(0, 0, 0),
        children: [
          Bone(name: 'head', position: const Vec3(0, -55, 0), children: [
            Bone(name: 'ahoge', position: const Vec3(0, -40, 0)),
          ]),
          Bone(name: 'wing_left', position: const Vec3(-52, -15, 0)),
          Bone(name: 'wing_right', position: const Vec3(52, -15, 0)),
          Bone(name: 'scarf', position: const Vec3(0, -30, 0)),
          Bone(name: 'foot_left', position: const Vec3(-22, 60, 0)),
          Bone(name: 'foot_right', position: const Vec3(22, 60, 0)),
        ],
      ),
    ],
  );
}
