#ifndef RUNNER_PAYLOAD_H_
#define RUNNER_PAYLOAD_H_

#include <windows.h>

#include <string>
#include <vector>

// 单文件版（single-file EXE）支持。
//
// 打包后的 InkFetch.exe = 正常的 Flutter runner + 文件尾部的压缩资源包
// （flutter_windows.dll、data/**）。启动时把资源解到 %TEMP% 下的一个私有
// 隐藏目录，退出时由同程序的 --gc 子进程删掉，下一次启动再兜底清理残留，
// 因此磁盘上不会留下安装目录、也不会在 exe 旁边散落 DLL / data。
//
// 普通的 `flutter run` / `flutter build` 产物没有尾部资源包，
// 这些函数会直接返回 false，runner 走原来的“exe 旁边的 data/”逻辑。
namespace payload {

enum class Mode {
  // 正常启动（可能是单文件版，也可能是普通的开发构建）。
  Run,
  // 只负责删除目录：--gc --dir <目录> --pid <进程号>
  Collect,
  // 打包：--pack <Release 目录> --out <输出 exe>
  Pack,
};

// 解析命令行参数。
Mode ParseMode(const wchar_t* command_line, std::wstring* dir, DWORD* pid,
               std::wstring* release_dir, std::wstring* out_file);

// 打包：把 |release_dir| 里的运行所需文件压进 |out_file|（以自身 exe 为壳）。
bool PackExecutable(const std::wstring& release_dir, const std::wstring& out_file);

// 把内嵌资源解到私有临时目录；成功后 |assets_dir| 为 <目录>\data。
bool ExtractEmbedded(std::wstring* out_dir, std::wstring* assets_dir);

// 安排退出后删除 |dir|：拉起本程序的 --gc 子进程等待本进程结束后清理。
void ScheduleCleanup(const std::wstring& dir);

// 启动时清理上次异常退出留下的目录。
void PruneStale();

// --gc 模式：等 |pid| 结束，然后删除 |dir|。
int RunCollector(const std::wstring& dir, DWORD pid);

}  // namespace payload

#endif  // RUNNER_PAYLOAD_H_
