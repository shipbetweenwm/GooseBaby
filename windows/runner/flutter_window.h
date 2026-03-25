#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <memory>
#include <mutex>
#include <vector>

#include "win32_window.h"

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  // ── Click-through support (public for static callback access) ──
public:
  // Active content rectangles (in logical pixels, relative to window).
  // Mouse clicks outside these rects pass through to the desktop.
  struct HitRect {
    double left, top, right, bottom;
  };
  std::vector<HitRect> hit_rects_;
  std::mutex hit_rects_mutex_;

private:
  // MethodChannel for receiving hit rects from Flutter.
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> hit_channel_;

  // Flutter child window handle (for subclassing)
  HWND flutter_child_hwnd_ = nullptr;
  
  // Timer ID for polling mouse position
  static const UINT_PTR kMousePollTimerId = 1;
  
  void SetupHitTestChannel();
  static LRESULT CALLBACK FlutterChildWndProc(HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam, UINT_PTR uIdSubclass, DWORD_PTR dwRefData);
  static VOID CALLBACK MousePollTimerProc(HWND hwnd, UINT msg, UINT_PTR timerId, DWORD time);
  void UpdateClickThroughState();
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
