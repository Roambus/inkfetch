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
  HANDLE file = ::CreateFileW(path.c_str(), GENERIC_WRITE, 0, nullptr,
                              CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) return false;
  DWORD written = 0;
  bool ok = true;
  if (!data.empty()) {
    ok = ::WriteFile(file, data.data(), static_cast<DWORD>(data.size()),
                     &written, nullptr) != FALSE &&
         written == data.size();
  }
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

// 原子替换：先写临时文件，再 MoveFileEx 覆盖目标。
// 直接截断重写 hosts，中途失败会留一个空 hosts，整台机器域名解析全崩。
bool ReplaceFileAtomically(const std::wstring& target,
                           const std::string& data) {
  const std::wstring temp = target + kTempSuffix;
  if (!WriteAllBytes(temp, data)) {
    ::DeleteFileW(temp.c_str());
    return false;
  }
  if (!::MoveFileExW(temp.c_str(), target.c_str(),
                     MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH)) {
    ::DeleteFileW(temp.c_str());
    return false;
  }
  return true;
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

// 以 runas 提权重启自身。
bool ShellExecuteElevated(const std::wstring& arguments,
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
    ::WaitForSingleObject(info.hProcess, 60 * 1000);
    ::CloseHandle(info.hProcess);
  }
  return true;
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
  ::DeleteFileW(backup.c_str());
  WriteResult(result, true, L"已恢复原始 hosts");
  return 0;
}

bool ElevateApply(const std::wstring& src, const std::wstring& dst,
                  std::wstring* message) {
  const std::wstring result_path = MakeTempResultPath();
  if (result_path.empty()) {
    if (message) *message = L"无法创建临时文件";
    return false;
  }
  const std::wstring args = L"--apply-hosts --hosts-src \"" + src +
                            L"\" --hosts-dst \"" + dst +
                            L"\" --hosts-result \"" + result_path + L"\"";
  std::wstring error;
  const bool started = ShellExecuteElevated(args, &error);
  const std::wstring report = started ? ReadResult(result_path) : error;
  ::DeleteFileW(result_path.c_str());
  if (message) *message = report;
  return started && report.rfind(L"OK", 0) == 0;
}

bool ElevateRestore(const std::wstring& dst, std::wstring* message) {
  const std::wstring result_path = MakeTempResultPath();
  if (result_path.empty()) {
    if (message) *message = L"无法创建临时文件";
    return false;
  }
  const std::wstring args = L"--restore-hosts --hosts-dst \"" + dst +
                            L"\" --hosts-result \"" + result_path + L"\"";
  std::wstring error;
  const bool started = ShellExecuteElevated(args, &error);
  const std::wstring report = started ? ReadResult(result_path) : error;
  ::DeleteFileW(result_path.c_str());
  if (message) *message = report;
  return started && report.rfind(L"OK", 0) == 0;
}

}  // namespace hosts
