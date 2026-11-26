#include "hosts.h"

#include <shellapi.h>
#include <shlobj.h>

#include <cstdio>
#include <string>
#include <vector>

#include "utils.h"

namespace hosts {
namespace {

constexpr wchar_t kBackupSuffix[] = L".inkfetch.bak";
constexpr wchar_t kTempSuffix[] = L".inkfetch.tmp";

std::wstring SelfPath() {
  wchar_t buffer[MAX_PATH];
  const DWORD len = ::GetModuleFileNameW(nullptr, buffer, MAX_PATH);
  if (len == 0 || len == MAX_PATH) return std::wstring();
  return std::wstring(buffer, len);
}

bool ReadAllBytes(const std::wstring& path, std::string* out) {
  HANDLE file = ::CreateFileW(path.c_str(), GENERIC_READ,
                              FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr,
                              OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) return false;
  LARGE_INTEGER size{};
  if (!::GetFileSizeEx(file, &size)) {
    ::CloseHandle(file);
    return false;
  }
  out->resize(static_cast<size_t>(size.QuadPart));
  DWORD read = 0;
  bool ok = true;
  if (!out->empty()) {
    ok = ::ReadFile(file, out->data(), static_cast<DWORD>(out->size()), &read,
                    nullptr) != FALSE &&
         read == out->size();
  }
  ::CloseHandle(file);
  return ok;
}

bool WriteAllBytes(const std::wstring& path, const std::string& data) {
  // 共享标志很重要：hosts 常被 DNS Client 服务、杀毒软件同时打开，
  // 不给 FILE_SHARE_READ|WRITE 就会直接失败（实测返回错误 5）。
  HANDLE file = ::CreateFileW(path.c_str(), GENERIC_WRITE,
                              FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr,
                              CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) return false;
  DWORD written = 0;
  bool ok = true;
  if (!data.empty()) {
    ok = ::WriteFile(file, data.data(), static_cast<DWORD>(data.size()),
                     &written, nullptr) != FALSE &&
         written == data.size();
  }
  // 强制刷盘：hosts 这种关键文件必须落盘后再返回，
  // 否则紧接着的替换操作可能读到旧内容。
  ::FlushFileBuffers(file);
  ::CloseHandle(file);
  return ok;
}

// 把结果写成一行文本，父进程读它判断成败。
void WriteResult(const std::wstring& path, bool ok,
                 const std::wstring& message) {
  const std::wstring line = (ok ? L"OK " : L"ERR ") + message;
  const std::string utf8 = Utf8FromUtf16(line.c_str());
  WriteAllBytes(path, utf8);
}

bool PathExists(const std::wstring& path) {
  const DWORD attr = ::GetFileAttributesW(path.c_str());
  return attr != INVALID_FILE_ATTRIBUTES;
}

// 写入 hosts。
//
// 这里用两种策略，按可靠性排序：
//
//   1. **原地重写**（首选）：hosts 是被 DNS Client 服务与安全软件
//      长期打开的特殊文件，用 MoveFileEx 替换句柄会失败——
//      实测正是这样返回「写入失败（可能被杀毒软件拦截）」。
//      原地重写不需要替换句柄，兼容性最好。
//   2. 原子替换（兜底）：先写临时文件再替换。只在原地重写失败时用，
//      因为它对占用更敏感，但胜在不会留下半截文件。
//
// 无论走哪条，写完都清一次 DNS 缓存，否则系统可能还用旧的解析结果。
bool ReplaceFileAtomically(const std::wstring& target,
                           const std::string& data) {
  // ── 策略 1：原地重写 ──
  // 打开时给足共享标志，允许其它进程同时持有该文件。
  HANDLE file = ::CreateFileW(target.c_str(), GENERIC_WRITE,
                              FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr,
                              CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file != INVALID_HANDLE_VALUE) {
    // 显式截断，避免旧内容比新内容长时留下尾巴。
    ::SetFilePointer(file, 0, nullptr, FILE_BEGIN);
    ::SetEndOfFile(file);
    DWORD written = 0;
    bool ok = true;
    if (!data.empty()) {
      ok = ::WriteFile(file, data.data(), static_cast<DWORD>(data.size()),
                       &written, nullptr) != FALSE &&
           written == data.size();
    }
    ::FlushFileBuffers(file);
    ::CloseHandle(file);
    if (ok) {
      ::SetFileAttributesW(target.c_str(), FILE_ATTRIBUTE_NORMAL);
      return true;
    }
  }

  // ── 策略 2：写临时文件后替换 ──
  const std::wstring temp = target + kTempSuffix;
  if (!WriteAllBytes(temp, data)) {
    ::DeleteFileW(temp.c_str());
    return false;
  }
  // 替换前先确保目标可写（有些安全软件会把 hosts 设成只读）。
  ::SetFileAttributesW(target.c_str(), FILE_ATTRIBUTE_NORMAL);
  if (!::MoveFileExW(temp.c_str(), target.c_str(),
                     MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH)) {
    ::DeleteFileW(temp.c_str());
    return false;
  }
  return true;
}

// 清空 DNS 解析缓存，让新 hosts 立即生效。
//
// 不刷新的话，浏览器可能还在用缓存里的旧结果，用户会以为「没生效」。
void FlushDnsCache() {
  // 直接调用系统 API，避免依赖 ipconfig 进程。
  using DnsFlushProc = int(WINAPI*)(void);
  HMODULE dnsapi = ::LoadLibraryW(L"dnsapi.dll");
  if (dnsapi != nullptr) {
    auto flush = reinterpret_cast<DnsFlushProc>(
        ::GetProcAddress(dnsapi, "DnsFlushResolverCache"));
    if (flush != nullptr) flush();
    ::FreeLibrary(dnsapi);
  }
}

// 判断当前进程是否已经是管理员。提权后的子进程会走到这里返回 true。
bool IsElevated() {
  HANDLE token = nullptr;
  if (!::OpenProcessToken(::GetCurrentProcess(), TOKEN_QUERY, &token)) {
    return false;
  }
  TOKEN_ELEVATION elevation{};
  DWORD size = sizeof(elevation);
  const bool ok = ::GetTokenInformation(token, TokenElevation, &elevation,
                                        sizeof(elevation), &size) != FALSE;
  ::CloseHandle(token);
  return ok && elevation.TokenIsElevated != 0;
}

// 以 runas 提权重启自身，等待结束并返回**子进程退出码**。
//
// 早期实现靠「子进程写一个结果文件、父进程读回来」判断成败，
// 这在提权场景下是错的：提权后进程身份变了，GetTempPathW 返回的
// 是管理员的 TEMP（例如 C:\Windows\Temp），而父进程仍在用普通用户的
// TEMP 路径去读，于是永远读不到结果，明明写成功也报「失败」。
//
// 退出码不依赖任何文件路径，是这里唯一可靠的信号。
bool ShellExecuteElevated(const std::wstring& arguments, DWORD* exit_code,
                          std::wstring* error) {
  const std::wstring self = SelfPath();
  if (self.empty()) {
    if (error) *error = L"拿不到自身路径";
    return false;
  }
  SHELLEXECUTEINFOW info{};
  info.cbSize = sizeof(info);
  info.fMask = SEE_MASK_NOCLOSEPROCESS | SEE_MASK_NOASYNC;
  info.lpVerb = L"runas";
  info.lpFile = self.c_str();
  info.lpParameters = arguments.c_str();
  info.nShow = SW_HIDE;

  if (!::ShellExecuteExW(&info)) {
    const DWORD code = ::GetLastError();
    if (error) {
      // ERROR_CANCELLED：用户在 UAC 弹框上点了「否」。
      *error = (code == ERROR_CANCELLED) ? L"用户取消了管理员授权"
                                          : L"无法启动提权进程";
    }
    return false;
  }
  if (info.hProcess != nullptr) {
    ::WaitForSingleObject(info.hProcess, 90 * 1000);
    DWORD code = 1;
    ::GetExitCodeProcess(info.hProcess, &code);
    ::CloseHandle(info.hProcess);
    if (exit_code != nullptr) *exit_code = code;
  }
  return true;
}

// 把退出码翻译成给用户看的话。
//
// 退出码定义与 hosts::RunApply / RunRestore 里的 return 一一对应；
// 这样即使结果文件读不到，也能说清楚是哪一步出的问题。
std::wstring DescribeExitCode(DWORD code) {
  switch (code) {
    case 0:
      return L"已写入 hosts";
    case 1:
      return L"没有管理员权限";
    case 2:
      return L"读不到待写入的内容";
    case 3:
      return L"待写入的内容为空";
    case 4:
      return L"备份原 hosts 失败（可能被安全软件占用）";
    case 5:
      return L"写入 hosts 失败（可能被杀毒软件拦截）";
    default:
      return L"提权进程异常退出（代码 " + std::to_wstring(code) + L"）";
  }
}

std::wstring DescribeRestoreExitCode(DWORD code) {
  switch (code) {
    case 0:
      return L"已恢复原始 hosts";
    case 1:
      return L"没有管理员权限";
    case 2:
      return L"没有找到备份文件";
    case 3:
      return L"读不到备份文件";
    case 4:
      return L"恢复 hosts 失败";
    default:
      return L"提权进程异常退出（代码 " + std::to_wstring(code) + L"）";
  }
}

std::wstring ReadResult(const std::wstring& path) {
  std::string data;
  if (!ReadAllBytes(path, &data)) return std::wstring();
  return Utf16FromUtf8(data);
}

std::wstring MakeTempResultPath() {
  wchar_t temp_dir[MAX_PATH];
  const DWORD len = ::GetTempPathW(MAX_PATH, temp_dir);
  if (len == 0 || len >= MAX_PATH) return std::wstring();
  wchar_t name[64];
  swprintf_s(name, L"inkfetch-hosts-%lu-%llu.txt",
             static_cast<unsigned long>(::GetCurrentProcessId()),
             static_cast<unsigned long long>(::GetTickCount64()));
  return std::wstring(temp_dir) + name;
}

}  // namespace

Mode ParseMode(const wchar_t* command_line, std::wstring* src,
               std::wstring* dst, std::wstring* result) {
  int argc = 0;
  wchar_t** argv = ::CommandLineToArgvW(command_line, &argc);
  if (argv == nullptr) return Mode::None;
  Mode mode = Mode::None;
  for (int i = 1; i < argc; i++) {
    const std::wstring arg = argv[i];
    const bool has_next = (i + 1) < argc;
    if (arg == L"--apply-hosts") {
      mode = Mode::Apply;
    } else if (arg == L"--restore-hosts") {
      mode = Mode::Restore;
    } else if (arg == L"--hosts-src" && has_next) {
      if (src != nullptr) *src = argv[++i];
    } else if (arg == L"--hosts-dst" && has_next) {
      if (dst != nullptr) *dst = argv[++i];
    } else if (arg == L"--hosts-result" && has_next) {
      if (result != nullptr) *result = argv[++i];
    }
  }
  ::LocalFree(argv);
  return mode;
}

int RunApply(const std::wstring& src, const std::wstring& dst,
             const std::wstring& result) {
  if (!IsElevated()) {
    WriteResult(result, false, L"没有管理员权限，无法写入 hosts");
    return 1;
  }
  std::string content;
  if (!ReadAllBytes(src, &content)) {
    WriteResult(result, false, L"读不到待写入的 hosts 内容");
    return 2;
  }
  if (content.empty()) {
    WriteResult(result, false, L"待写入的 hosts 内容为空");
    return 3;
  }

  // 先把现有 hosts 备份一份，出问题可以还原。
  std::string existing;
  if (ReadAllBytes(dst, &existing) && !existing.empty()) {
    if (!WriteAllBytes(dst + kBackupSuffix, existing)) {
      WriteResult(result, false, L"备份原 hosts 失败，已放弃写入");
      return 4;
    }
  }

  if (!ReplaceFileAtomically(dst, content)) {
    WriteResult(result, false, L"写入 hosts 失败（可能被杀毒软件拦截）");
    return 5;
  }
  FlushDnsCache();
  WriteResult(result, true, L"已写入 hosts");
  return 0;
}

int RunRestore(const std::wstring& dst, const std::wstring& result) {
  if (!IsElevated()) {
    WriteResult(result, false, L"没有管理员权限，无法恢复 hosts");
    return 1;
  }
  const std::wstring backup = dst + kBackupSuffix;
  if (!PathExists(backup)) {
    WriteResult(result, false, L"没有找到备份文件，无需恢复");
    return 2;
  }
  std::string content;
  if (!ReadAllBytes(backup, &content)) {
    WriteResult(result, false, L"读不到备份文件");
    return 3;
  }
  if (!ReplaceFileAtomically(dst, content)) {
    WriteResult(result, false, L"恢复 hosts 失败");
    return 4;
  }
  FlushDnsCache();
  ::DeleteFileW(backup.c_str());
  WriteResult(result, true, L"已恢复原始 hosts");
  return 0;
}

bool ElevateApply(const std::wstring& src, const std::wstring& dst,
                  std::wstring* message) {
  // 结果文件仍然写，但只作为补充信息（它能给出更具体的中文原因）。
  // 判成败一律以退出码为准——提权后 TEMP 会变，父进程读不到那个文件。
  const std::wstring result_path = MakeTempResultPath();
  const std::wstring args = L"--apply-hosts --hosts-src \"" + src +
                            L"\" --hosts-dst \"" + dst +
                            L"\" --hosts-result \"" + result_path + L"\"";
  std::wstring error;
  DWORD exit_code = 1;
  const bool started = ShellExecuteElevated(args, &exit_code, &error);
  if (!started) {
    if (message) *message = error;
    if (!result_path.empty()) ::DeleteFileW(result_path.c_str());
    return false;
  }

  // 优先用结果文件里的具体原因（能区分「备份失败」和「写入被拦」）。
  std::wstring report;
  if (!result_path.empty()) {
    report = ReadResult(result_path);
    ::DeleteFileW(result_path.c_str());
  }
  if (report.empty()) {
    report = DescribeExitCode(exit_code);
  } else if (report.rfind(L"ERR ", 0) == 0) {
    report = report.substr(4);
  } else if (report.rfind(L"OK ", 0) == 0) {
    report = report.substr(3);
  }
  if (message) *message = report;
  return exit_code == 0;
}

bool ElevateRestore(const std::wstring& dst, std::wstring* message) {
  const std::wstring result_path = MakeTempResultPath();
  const std::wstring args = L"--restore-hosts --hosts-dst \"" + dst +
                            L"\" --hosts-result \"" + result_path + L"\"";
  std::wstring error;
  DWORD exit_code = 1;
  const bool started = ShellExecuteElevated(args, &exit_code, &error);
  if (!started) {
    if (message) *message = error;
    if (!result_path.empty()) ::DeleteFileW(result_path.c_str());
    return false;
  }
  std::wstring report;
  if (!result_path.empty()) {
    report = ReadResult(result_path);
    ::DeleteFileW(result_path.c_str());
  }
  if (report.empty()) {
    report = DescribeRestoreExitCode(exit_code);
  } else if (report.rfind(L"ERR ", 0) == 0) {
    report = report.substr(4);
  } else if (report.rfind(L"OK ", 0) == 0) {
    report = report.substr(3);
  }
  if (message) *message = report;
  return exit_code == 0;
}

}  // namespace hosts
