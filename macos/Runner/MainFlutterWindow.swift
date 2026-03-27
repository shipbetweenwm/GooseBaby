import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  /// Flutter 层传来的可点击矩形区域列表
  private var hitRects: [NSRect] = []
  /// MethodChannel 用于接收 Flutter 的 hit rects
  private var hitTestChannel: FlutterMethodChannel?
  /// 定时器：轮询鼠标位置更新 ignoresMouseEvents
  private var mouseTrackingTimer: Timer?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    // 窗口透明配置
    self.isOpaque = false
    self.backgroundColor = .clear
    self.hasShadow = false
    self.titlebarAppearsTransparent = true
    self.titleVisibility = .hidden
    self.styleMask.insert(.fullSizeContentView)

    // FlutterView 透明
    if let flutterView = flutterViewController.view as? NSView {
      flutterView.wantsLayer = true
      flutterView.layer?.isOpaque = false
      flutterView.layer?.backgroundColor = CGColor.clear
    }

    RegisterGeneratedPlugins(registry: flutterViewController)

    // 设置 MethodChannel 接收 hit rects（复用 Windows 的通道名）
    let engine = flutterViewController.engine
    hitTestChannel = FlutterMethodChannel(
      name: "goose_baby/hit_test",
      binaryMessenger: engine.registrar(forPlugin: "MainFlutterWindow").messenger
    )
    hitTestChannel?.setMethodCallHandler { [weak self] (call, result) in
      guard let self = self else { result(nil); return }
      if call.method == "setHitRects" {
        if let rects = call.arguments as? [[String: Double]] {
          self.hitRects = rects.compactMap { dict in
            guard let left = dict["left"],
                  let top = dict["top"],
                  let right = dict["right"],
                  let bottom = dict["bottom"] else { return nil }
            // Flutter 坐标系：左上角为原点
            // NSRect 坐标系：左下角为原点，需要翻转 y
            let height = self.contentView?.frame.height ?? self.frame.height
            return NSRect(
              x: left,
              y: height - bottom,
              width: right - left,
              height: bottom - top
            )
          }
        }
        result(nil)
      } else {
        result(FlutterMethodNotImplemented)
      }
    }

    // 启动鼠标位置轮询（~60fps）
    mouseTrackingTimer = Timer.scheduledTimer(withTimeInterval: 1.0/60.0, repeats: true) { [weak self] _ in
      self?.updateClickThrough()
    }

    super.awakeFromNib()
  }

  /// 根据鼠标位置判断是否需要穿透点击
  private func updateClickThrough() {
    // 获取鼠标在窗口中的位置
    let mouseLocationInScreen = NSEvent.mouseLocation
    let windowFrame = self.frame
    let mouseInWindow = NSPoint(
      x: mouseLocationInScreen.x - windowFrame.origin.x,
      y: mouseLocationInScreen.y - windowFrame.origin.y
    )

    // 检查鼠标是否在任何 hit rect 内
    var insideHitRect = false
    for rect in hitRects {
      if rect.contains(mouseInWindow) {
        insideHitRect = true
        break
      }
    }

    // 如果没有 hit rects，默认不穿透（兼容旧逻辑）
    if hitRects.isEmpty {
      self.ignoresMouseEvents = false
      return
    }

    // 在 hit rect 内：不穿透（可点击）
    // 在 hit rect 外：穿透（点击到桌面）
    self.ignoresMouseEvents = !insideHitRect
  }

  deinit {
    mouseTrackingTimer?.invalidate()
  }
}
