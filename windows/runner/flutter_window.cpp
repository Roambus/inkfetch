#include "flutter_window.h"

#include <dwmapi.h>
#include <windows.h>

#include <optional>

#include "flutter/generated_plugin_registrant.h"

namespace {

// 标题栏跟随系统的明暗设置，与界面默认的「跟随系统」一致。
// 否则 Windows 默认会用系统强调色（常常是亮蓝）刷标题栏，
// 和这套墨色界面撞得很难看。
bool SystemPrefersDark() {
  HKEY key = nullptr;
  if (::RegOpenKeyExW(
          HKEY_CURRENT_USER,
          L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize",
          0, KEY_READ, &key) != ERROR_SUCCESS) {
    return false;
  }
  DWORD value = 1;
  DWORD size = sizeof(value);
  DWORD type = 0;
  const bool ok =
      ::RegQueryValueExW(key, L"AppsUseLightTheme", nullptr, &type,
                         reinterpret_cast<LPBYTE>(&value), &size) ==
      ERROR_SUCCESS;
  ::RegCloseKey(key);
  // 取不到时按浅色处理（Windows 默认）。
  return ok && value == 0;
}

// DWMWA_* 编号：20 = 深色模式（Win10 20H1+，旧系统为 19）、
// 35 = 标题栏底色、36 = 标题文字色、34 = 边框色（Win11 22000+）。
void ApplyTitleBarTheme(HWND window) {
  const bool dark = SystemPrefersDark();

  BOOL dark_mode = dark ? TRUE : FALSE;
  if (FAILED(::DwmSetWindowAttribute(window, 20, &dark_mode,
                                     sizeof(dark_mode)))) {
    ::DwmSetWindowAttribute(window, 19, &dark_mode, sizeof(dark_mode));
  }

  const COLORREF caption = dark ? RGB(0x0C, 0x0E, 0x10)   // 墨池
                                : RGB(0xF0, 0xF1, 0xEC);  // 宣纸
  const COLORREF text = dark ? RGB(0xE9, 0xE6, 0xDE) : RGB(0x14, 0x17, 0x1A);
  const COLORREF border = dark ? RGB(0x26, 0x2B, 0x30) : RGB(0xD9, 0xDC, 0xD2);
  ::DwmSetWindowAttribute(window, 35, &caption, sizeof(caption));
  ::DwmSetWindowAttribute(window, 36, &text, sizeof(text));
  ::DwmSetWindowAttribute(window, 34, &border, sizeof(border));
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
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
  // 设置、下载记录、队列与断点续传状态走注册表，避免在磁盘上留下散落文件。
  native_store_ = std::make_unique<NativeStore>(
      flutter_controller_->engine()->messenger());
  hosts_channel_ = std::make_unique<HostsChannel>(
      flutter_controller_->engine()->messenger());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  ApplyTitleBarTheme(GetHandle());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  hosts_channel_ = nullptr;
  native_store_ = nullptr;
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
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

