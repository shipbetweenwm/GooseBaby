import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  override func applicationDidFinishLaunching(_ notification: Notification) {
    // 延迟执行，确保 Flutter 引擎和 FlutterView 完全初始化后再设置透明
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
      if let window = NSApplication.shared.mainWindow {
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false

        // 递归设置所有子 view 的 layer 为透明
        self.makeViewTransparent(window.contentView)
      }
    }
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
