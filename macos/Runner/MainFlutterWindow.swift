import Cocoa
import FlutterMacOS
import CoreGraphics
import ImageIO

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

    // 截图 MethodChannel：使用原生 CoreGraphics 截取屏幕，无需外部命令
    let screenshotChannel = FlutterMethodChannel(
      name: "goose_baby/screenshot",
      binaryMessenger: engine.registrar(forPlugin: "MainFlutterWindow").messenger
    )
    screenshotChannel.setMethodCallHandler { [weak self] (call, result) in
      guard let _ = self else { result(FlutterError(code: "NO_WINDOW", message: "Window not available", details: nil)); return }
      if call.method == "captureScreen" {
        guard let args = call.arguments as? [String: Any],
              let filePath = args["filePath"] as? String else {
          result(FlutterError(code: "INVALID_ARGS", message: "Missing filePath", details: nil))
          return
        }
        self?.captureScreen(to: filePath, result: result)
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

  /// 原生截图：使用 CoreGraphics 捕获屏幕内容
  /// CGWindowListCreateImage 在应用进程内调用，继承应用的屏幕录制权限
  private func captureScreen(to filePath: String, result: @escaping FlutterResult) {
    // 截取整个屏幕（排除自身窗口），使用 .bestResolution 获取原始 Retina 像素
    let windowID = CGWindowID(self.windowNumber)
    guard let cgImage = CGWindowListCreateImage(
      .infinite,
      .optionOnScreenOnly,
      windowID,  // 排除自身窗口，不截到鹅宝
      .bestResolution
    ) else {
      result(FlutterError(code: "CAPTURE_FAILED", message: "CGWindowListCreateImage returned null (Screen Recording permission required)", details: nil))
      return
    }

    // 获取主屏幕的**逻辑分辨率**（points，非物理像素）
    let mainScreen = NSScreen.main
    let logicalWidth = mainScreen?.frame.width ?? CGFloat(cgImage.width)
    let logicalHeight = mainScreen?.frame.height ?? CGFloat(cgImage.height)
    let physicalWidth = CGFloat(cgImage.width)
    let physicalHeight = CGFloat(cgImage.height)
    let scaleFactor = physicalWidth / logicalWidth

    // 关键：将 Retina 物理像素截图缩放到逻辑分辨率
    // 这样视觉模型看到的图片尺寸与鼠标坐标范围完全一致，
    // 模型报告的坐标可以直接用于 mouse_click，无需手动除以 scaleFactor
    let scaledImage: CGImage
    if scaleFactor > 1.0 {
      let colorSpace = cgImage.colorSpace ?? CGColorSpaceCreateDeviceRGB()
      let ctx = CGContext(
        data: nil,
        width: Int(logicalWidth),
        height: Int(logicalHeight),
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      )!
      ctx.interpolationQuality = .high
      ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: logicalWidth, height: logicalHeight))
      scaledImage = ctx.makeImage()!
    } else {
      scaledImage = cgImage
    }

    // 转换为 PNG 并写入文件
    let url = URL(fileURLWithPath: filePath)
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
      result(FlutterError(code: "WRITE_FAILED", message: "Failed to create image destination", details: nil))
      return
    }
    CGImageDestinationAddImage(dest, scaledImage, nil)
    let success = CGImageDestinationFinalize(dest)

    if success {
      result([
        "logicalWidth": Int(logicalWidth),
        "logicalHeight": Int(logicalHeight),
        "physicalWidth": Int(physicalWidth),
        "physicalHeight": Int(physicalHeight),
        "scaleFactor": Double(scaleFactor),
      ])
    } else {
      result(FlutterError(code: "WRITE_FAILED", message: "Failed to write PNG file", details: nil))
    }
  }

  deinit {
    mouseTrackingTimer?.invalidate()
  }
}
