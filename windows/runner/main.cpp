#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <memory>
#include <string>
#include <vector>

#include "flutter_window.h"
#include "payload.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // 打包与清理是构建 / 收尾用的命令，不需要窗口和 Flutter 引擎。
  std::wstring cleanup_dir;
  std::wstring release_dir;
  std::wstring out_file;
  DWORD cleanup_pid = 0;
  const payload::Mode mode = payload::ParseMode(
      ::GetCommandLineW(), &cleanup_dir, &cleanup_pid, &release_dir, &out_file);
  if (mode == payload::Mode::Pack) {
    if (release_dir.empty() || out_file.empty()) return 2;
    return payload::PackExecutable(release_dir, out_file) ? 0 : 3;
  }
  if (mode == payload::Mode::Collect) {
    return payload::RunCollector(cleanup_dir, cleanup_pid);
  }

  // 单文件版：把内嵌的引擎 DLL 与 data\ 解到私有临时目录；
  // 普通构建（exe 旁边就是 data\）没有内嵌资源，这里返回 false。
  payload::PruneStale();
  std::wstring extracted_dir;
  std::wstring assets_dir;
  const bool bundled = payload::ExtractEmbedded(&extracted_dir, &assets_dir);
  // 立刻挂上清理子进程：它等本进程结束（正常退出、崩溃、被强杀都算）后
  // 删除临时目录，因此任何退出路径都不会留下解压出来的文件。
  if (bundled) payload::ScheduleCleanup(extracted_dir);

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  std::unique_ptr<flutter::DartProject> project;
  if (bundled) {
    project = std::make_unique<flutter::DartProject>(
        assets_dir, extracted_dir + L"\\data\\icudtl.dat",
        extracted_dir + L"\\data\\app.so");
  } else {
    project = std::make_unique<flutter::DartProject>(L"data");
  }

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project->set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(*project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  // Window title: "Mo Qu" (Chinese brand name), written as Unicode escapes
  // so the source stays ASCII-safe regardless of the compiler code page.
  if (!window.Create(L"\u58A8\u53D6", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  // 临时目录由前面挂上的 --gc 子进程在本进程结束后删除。
  return EXIT_SUCCESS;
}
