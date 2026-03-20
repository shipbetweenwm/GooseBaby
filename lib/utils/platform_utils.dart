import 'package:flutter/foundation.dart';

/// 平台工具类 - Web 安全版本
class PlatformUtils {
  PlatformUtils._();

  /// 是否是macOS
  static bool get isMacOS {
    if (kIsWeb) return false;
    return _nativePlatform == 'macos';
  }

  /// 是否是Windows
  static bool get isWindows {
    if (kIsWeb) return false;
    return _nativePlatform == 'windows';
  }

  /// 是否是桌面平台
  static bool get isDesktop {
    if (kIsWeb) return false;
    return isMacOS || isWindows || _nativePlatform == 'linux';
  }

  /// 获取平台名称
  static String get platformName {
    if (kIsWeb) return 'Web';
    if (isMacOS) return 'macOS';
    if (isWindows) return 'Windows';
    return 'Unknown';
  }

  /// 获取应用数据目录（仅桌面平台可用）
  static String get appDataDir {
    if (kIsWeb) return '';
    return _getNativeAppDataDir();
  }

  /// 获取屏幕信息（Debug用）
  static Map<String, dynamic> getSystemInfo() {
    if (kIsWeb) {
      return {'platform': 'Web'};
    }
    return _getNativeSystemInfo();
  }

  /// 打开URL
  static Future<void> openUrl(String url) async {
    if (kIsWeb) return;
    try {
      await _nativeOpenUrl(url);
    } catch (e) {
      debugPrint('打开URL失败: $e');
    }
  }

  /// 确保目录存在（仅桌面平台）
  static Future<void> ensureDirectory(String path) async {
    if (kIsWeb || path.isEmpty) return;
    await _nativeEnsureDirectory(path);
  }

  // ---- 内部实现（使用条件延迟加载） ----

  static String get _nativePlatform {
    try {
      return defaultTargetPlatform.name.toLowerCase();
    } catch (e) {
      return 'unknown';
    }
  }

  static String _getNativeAppDataDir() {
    // 桌面平台会由 Hive 自动管理目录
    return 'goose_baby_data';
  }

  static Map<String, dynamic> _getNativeSystemInfo() {
    return {
      'platform': platformName,
      'processors': 'N/A',
    };
  }

  static Future<void> _nativeOpenUrl(String url) async {
    // 桌面平台需要完整 Xcode/MSVC 才能使用 dart:io
    debugPrint('openUrl: $url');
  }

  static Future<void> _nativeEnsureDirectory(String path) async {
    // 由 Hive 自动管理
  }
}
