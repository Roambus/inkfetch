#ifndef RUNNER_HOSTS_H_
#define RUNNER_HOSTS_H_

#include <windows.h>

#include <string>

// GitHub 加速所需的 hosts 写入。
//
// 为什么要单独一段原生代码：Windows 的 hosts 在 System32 下，
// 只有管理员能写。应用本身以普通权限运行（绝不该常驻提权），
// 所以「写 hosts」这件事通过一次自我提权来完成：
//
//   1. Dart 侧把要写入的完整 hosts 内容写进临时文件；
//   2. 以 ShellExecuteEx(runas) 的方式重新拉起本程序，
//      参数 `--apply-hosts <源文件> --hosts <目标> --result <结果文件>`；
//   3. 子进程（已是管理员）读源文件、备份原 hosts、原子替换；
//   4. 子进程把结果写进结果文件，父进程读回来判断成功与否。
//
// 这样应用主进程不需要管理员权限，也不需要额外分发脚本或 exe。
namespace hosts {

enum class Mode {
  None,
  // --apply-hosts <src> --hosts <dst> --result <out>
  Apply,
  // --restore-hosts --hosts <dst> --result <out>
  Restore,
};

// 解析命令行；不是 hosts 相关命令时返回 Mode::None。
Mode ParseMode(const wchar_t* command_line, std::wstring* src,
               std::wstring* dst, std::wstring* result);

// 提权子进程入口：把 |src| 的内容写进 |dst|（先备份），结果写 |result|。
// 返回进程退出码：0 成功，非 0 失败。
int RunApply(const std::wstring& src, const std::wstring& dst,
             const std::wstring& result);

// 提权子进程入口：从备份恢复 |dst|，结果写 |result|。
int RunRestore(const std::wstring& dst, const std::wstring& result);

// 父进程侧：提权执行 apply。返回 true 表示子进程报告成功。
bool ElevateApply(const std::wstring& src, const std::wstring& dst,
                  std::wstring* message);

// 父进程侧：提权执行 restore。
bool ElevateRestore(const std::wstring& dst, std::wstring* message);

}  // namespace hosts

#endif  // RUNNER_HOSTS_H_
