#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>

#include <memory>

#include "hosts_channel.h"
#include "native_store.h"
#include "proxy_channel.h"
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

  // 应用设置 / 断点续传状态的注册表存储通道。
  std::unique_ptr<NativeStore> native_store_;

  // hosts 写入通道（带提权副作用，单独一条通道）。
  std::unique_ptr<HostsChannel> hosts_channel_;

  // Windows 系统代理（PAC）通道：只改当前用户注册表，不需要提权。
  std::unique_ptr<ProxyChannel> proxy_channel_;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
