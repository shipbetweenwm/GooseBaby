import 'package:flutter/foundation.dart';

/// 系统托盘管理（仅桌面平台可用）
class TrayManager {
  /// 初始化系统托盘
  static Future<void> initialize() async {
    if (kIsWeb) {
      debugPrint('🦢 Web 平台不支持系统托盘');
      return;
    }

    try {
      // 桌面平台的托盘初始化需要 dart:io
      // 仅在桌面构建时实际可用
      debugPrint('🦢 系统托盘初始化...');
    } catch (e) {
      debugPrint('🦢 系统托盘初始化失败: $e');
    }
  }

  /// 更新托盘提示文字
  static Future<void> updateTooltip(String tooltip) async {
    // 仅桌面平台可用
  }

  /// 销毁托盘
  static Future<void> destroy() async {
    // 仅桌面平台可用
  }
}
