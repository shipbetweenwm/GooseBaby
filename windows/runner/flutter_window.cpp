#include "flutter_window.h"

#include <dwmapi.h>
#include <windowsx.h>
#include <optional>
#include <fstream>
#include <commctrl.h>

#include "flutter/generated_plugin_registrant.h"

// Helper to log debug info to file (in temp directory, no admin required)
static void DebugLog(const char* msg) {
  char tempPath[MAX_PATH];
  GetTempPathA(MAX_PATH, tempPath);
  std::string logPath = std::string(tempPath) + "goosebaby_debug.log";
  std::ofstream f(logPath, std::ios::app);
  if (f.is_open()) {
    f << msg << std::endl;
  }
}

// Global pointer to FlutterWindow instance for use in static callback
static FlutterWindow* g_flutter_window = nullptr;

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  // Clear debug log file at startup
  char tempPath[MAX_PATH];
  GetTempPathA(MAX_PATH, tempPath);
  std::string logPath = std::string(tempPath) + "goosebaby_debug.log";
  std::ofstream(logPath, std::ios::trunc);
  DebugLog("=== FlutterWindow::OnCreate ===");

  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());

  // Setup the MethodChannel for receiving hit-test rectangles from Flutter.
  SetupHitTestChannel();

  // Transparency is handled by DWM composition on the parent window
  // (DwmExtendFrameIntoClientArea with -1 margins in win32_window.cpp).
  // Do NOT add WS_EX_LAYERED to the Flutter child window.
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  // Store Flutter child window handle
  flutter_child_hwnd_ = flutter_controller_->view()->GetNativeWindow();
  
  // Set global pointer for timer callback
  g_flutter_window = this;

  // ── Click-through via timer polling ──
  // Poll mouse position every 16ms (~60fps) and dynamically toggle WS_EX_TRANSPARENT
  // This is the standard approach for desktop pet applications
  SetTimer(GetHandle(), kMousePollTimerId, 16, MousePollTimerProc);
  DebugLog("Started mouse poll timer");

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::SetupHitTestChannel() {
  hit_channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(),
      "goose_baby/hit_test",
      &flutter::StandardMethodCodec::GetInstance());

  hit_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        if (call.method_name() == "setHitRects") {
          // Expect a list of maps: [{left, top, right, bottom}, ...]
          const auto* args = std::get_if<flutter::EncodableList>(call.arguments());
          if (args) {
            std::vector<HitRect> new_rects;
            for (const auto& item : *args) {
              const auto* map = std::get_if<flutter::EncodableMap>(&item);
              if (map) {
                HitRect r{};
                auto it_l = map->find(flutter::EncodableValue("left"));
                auto it_t = map->find(flutter::EncodableValue("top"));
                auto it_r = map->find(flutter::EncodableValue("right"));
                auto it_b = map->find(flutter::EncodableValue("bottom"));
                if (it_l != map->end()) r.left = std::get<double>(it_l->second);
                if (it_t != map->end()) r.top = std::get<double>(it_t->second);
                if (it_r != map->end()) r.right = std::get<double>(it_r->second);
                if (it_b != map->end()) r.bottom = std::get<double>(it_b->second);
                new_rects.push_back(r);
              }
            }
            {
              std::lock_guard<std::mutex> lock(hit_rects_mutex_);
              hit_rects_ = std::move(new_rects);
              // Debug log to file
              DebugLog("Native received hit rects:");
              for (const auto& r : hit_rects_) {
                char buf[128];
                snprintf(buf, sizeof(buf), "  rect: L=%.0f T=%.0f R=%.0f B=%.0f",
                         r.left, r.top, r.right, r.bottom);
                DebugLog(buf);
              }
            }
            result->Success();
          } else {
            result->Error("INVALID_ARGS", "Expected list of rect maps");
          }
        } else {
          result->NotImplemented();
        }
      });
}

void FlutterWindow::OnDestroy() {
  // Kill the mouse poll timer
  KillTimer(GetHandle(), kMousePollTimerId);
  DebugLog("Killed mouse poll timer");
  
  g_flutter_window = nullptr;

  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

// Timer callback to poll mouse position and update WS_EX_TRANSPARENT
VOID CALLBACK FlutterWindow::MousePollTimerProc(HWND hwnd, UINT msg, UINT_PTR timerId, DWORD time) {
  if (!g_flutter_window) {
    return;
  }
  g_flutter_window->UpdateClickThroughState();
}

// Check if mouse is inside any hit rect and update WS_EX_TRANSPARENT accordingly
void FlutterWindow::UpdateClickThroughState() {
  HWND hwnd = GetHandle();
  if (!hwnd) return;

  // Get mouse position in screen coordinates
  POINT pt;
  GetCursorPos(&pt);
  
  // Convert to window client coordinates
  ScreenToClient(hwnd, &pt);

  // Get DPI scale factor
  UINT dpi = GetDpiForWindow(hwnd);
  double scale = dpi / 96.0;
  double lx = pt.x / scale;
  double ly = pt.y / scale;

  bool inside = false;
  {
    std::lock_guard<std::mutex> lock(hit_rects_mutex_);
    for (const auto& r : hit_rects_) {
      if (lx >= r.left && lx < r.right && ly >= r.top && ly < r.bottom) {
        inside = true;
        break;
      }
    }
  }

  // Get current extended window style
  LONG_PTR exStyle = GetWindowLongPtr(hwnd, GWL_EXSTYLE);
  
  if (inside) {
    // Mouse is inside hit rect: remove WS_EX_TRANSPARENT to receive mouse events
    if (exStyle & WS_EX_TRANSPARENT) {
      SetWindowLongPtr(hwnd, GWL_EXSTYLE, exStyle & ~WS_EX_TRANSPARENT);
      DebugLog("Timer: inside hit rect, removed WS_EX_TRANSPARENT");
    }
  } else {
    // Mouse is outside hit rect: add WS_EX_TRANSPARENT for click-through
    if (!(exStyle & WS_EX_TRANSPARENT)) {
      SetWindowLongPtr(hwnd, GWL_EXSTYLE, exStyle | WS_EX_TRANSPARENT);
      DebugLog("Timer: outside hit rect, added WS_EX_TRANSPARENT");
    }
  }
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
