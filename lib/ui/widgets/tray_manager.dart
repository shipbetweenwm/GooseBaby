import 'dart:io' show Platform, exit;
import 'package:flutter/foundation.dart';
import 'package:system_tray/system_tray.dart';
import 'package:window_manager/window_manager.dart';

/// 系统托盘管理器
/// 管理 Windows/macOS 系统托盘图标和右键菜单
class TrayManager {
  static SystemTray? _systemTray;
  static bool _isVisible = true;

  /// 回调 —— 由 PetWindow 设置
  static VoidCallback? onShowShop;
  static VoidCallback? onShowSettings;
  static VoidCallback? onShowChat;

  /// 当前是否可见
  static bool get isVisible => _isVisible;

  /// 初始化系统托盘
  static Future<void> initialize() async {
    if (kIsWeb) {
      debugPrint('🦢 Web 平台不支持系统托盘');
      return;
    }

    try {
      _systemTray = SystemTray();

      // 获取托盘图标路径
      final iconPath = _getTrayIconPath();

      // 初始化托盘图标（不显示文字，只显示图标）
      await _systemTray!.initSystemTray(
        title: '',
        iconPath: iconPath,
        toolTip: '🦢 鹅宝',
      );

      // 构建右键菜单
      await _buildContextMenu();

      // 点击托盘图标事件处理
      // macOS: 单击弹菜单（macOS 习惯），右击显示窗口
      // Windows: 单击显示窗口，右击弹菜单
      _systemTray!.registerSystemTrayEventHandler((eventName) {
        if (eventName == kSystemTrayEventClick) {
          if (Platform.isMacOS) {
            _systemTray!.popUpContextMenu();
          } else {
            _toggleVisibility();
          }
        } else if (eventName == kSystemTrayEventRightClick) {
          if (Platform.isMacOS) {
            _toggleVisibility();
          } else {
            _systemTray!.popUpContextMenu();
          }
        }
      });

      debugPrint('🦢 系统托盘初始化完成');
    } catch (e) {
      debugPrint('🦢 系统托盘初始化失败: $e');
    }
  }

  /// 构建右键菜单
  static Future<void> _buildContextMenu() async {
    final menu = Menu();
    await menu.buildFrom([
      MenuItemLabel(
        label: _isVisible ? '🙈 隐藏鹅宝' : '🦢 显示鹅宝',
        onClicked: (_) => _toggleVisibility(),
      ),
      MenuSeparator(),
      MenuItemLabel(
        label: '💬 打开聊天',
        onClicked: (_) {
          _ensureVisible();
          onShowChat?.call();
        },
      ),
      MenuItemLabel(
        label: '🛍️ 打开商店',
        onClicked: (_) {
          _ensureVisible();
          onShowShop?.call();
        },
      ),
      MenuItemLabel(
        label: '⚙️ 设置',
        onClicked: (_) {
          _ensureVisible();
          onShowSettings?.call();
        },
      ),
      MenuSeparator(),
      MenuItemLabel(
        label: '❌ 退出鹅宝',
        onClicked: (_) => exitApp(),
      ),
    ]);

    await _systemTray!.setContextMenu(menu);
  }

  /// 获取托盘图标路径
  /// Windows 使用 .ico，macOS 使用 .png
  /// system_tray 包在 macOS 上会自动从 asset bundle 读取并转 base64
  static String _getTrayIconPath() {
    if (Platform.isWindows) {
      return 'assets/images/tray_icon.ico';
    }
    return 'assets/images/tray_icon.png';
  }

  /// 切换窗口显示/隐藏
  static Future<void> _toggleVisibility() async {
    try {
      if (_isVisible) {
        await windowManager.hide();
        _isVisible = false;
      } else {
        await windowManager.show();
        await windowManager.focus();
        _isVisible = true;
      }
      // 更新菜单文字（显示/隐藏动态切换）
      await _rebuildMenu();
    } catch (e) {
      debugPrint('🦢 切换窗口可见性失败: $e');
    }
  }

  /// 外部通知：窗口已被隐藏（如点击 X 按钮）
  static void notifyHidden() {
    _isVisible = false;
    _rebuildMenu();
    _updateTooltipForHidden();
  }

  /// 外部通知：窗口已恢复显示（如 CUA 操作结束后）
  static Future<void> notifyShown() async {
    if (!_isVisible) {
      _isVisible = true;
      await _rebuildMenu();
    }
  }

  /// 确保窗口可见
  static Future<void> _ensureVisible() async {
    try {
      if (!_isVisible) {
        await windowManager.show();
        await windowManager.focus();
        _isVisible = true;
        await _rebuildMenu();
      }
    } catch (e) {
      debugPrint('🦢 显示窗口失败: $e');
    }
  }

  /// 重新构建右键菜单（更新显示/隐藏文字）
  static Future<void> _rebuildMenu() async {
    try {
      if (_systemTray != null) {
        await _buildContextMenu();
      }
    } catch (e) {
      debugPrint('🦢 重建菜单失败: $e');
    }
  }

  /// 隐藏后更新提示文字
  static Future<void> _updateTooltipForHidden() async {
    try {
      await _systemTray?.setToolTip('🦢 鹅宝在这里～ 点击显示');
    } catch (_) {}
  }

  /// 更新托盘提示文字
  static Future<void> updateTooltip(String tooltip) async {
    try {
      await _systemTray?.setToolTip(tooltip);
    } catch (e) {
      debugPrint('🦢 更新托盘提示失败: $e');
    }
  }

  /// 退出应用（先隐藏窗口避免闪屏，再关闭）
  static Future<void> exitApp() async {
    try {
      debugPrint('🦢 用户选择退出鹅宝');
      // 先隐藏窗口，视觉上立即消失
      await windowManager.hide();
      await Future.delayed(const Duration(milliseconds: 50));
      await destroy();
      await windowManager.setPreventClose(false);
      await windowManager.close();
    } catch (_) {}
    exit(0);
  }

  /// 销毁托盘
  static Future<void> destroy() async {
    try {
      await _systemTray?.destroy();
      _systemTray = null;
    } catch (e) {
      debugPrint('🦢 销毁托盘失败: $e');
    }
  }
}
