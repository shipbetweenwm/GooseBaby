import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  private var transparencyApplied = false

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    // 返回 false：窗口隐藏后应用不退出，系统托盘继续驻留
    return false
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  override func applicationDidFinishLaunching(_ notification: Notification) {
    // 延迟确保 Flutter 引擎完全初始化
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
      self.applyTransparency()
    }
  }

  private func applyTransparency() {
    if transparencyApplied { return }
    guard let window = NSApplication.shared.windows.first else {
      // 窗口还没创建，稍后重试
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
        self.applyTransparency()
      }
      return
    }
    window.isOpaque = false
    window.backgroundColor = .clear
    window.hasShadow = false
    makeViewTransparent(window.contentView)
    transparencyApplied = true
  }

  private func makeViewTransparent(_ view: NSView?) {
    guard let view = view else { return }
    view.wantsLayer = true
    view.layer?.isOpaque = false
    view.layer?.backgroundColor = CGColor.clear
    for subview in view.subviews {
      makeViewTransparent(subview)
    }
  }
}
