#include "payload.h"

#include <windows.h>
#include <compressapi.h>
#include <delayimp.h>

#include <algorithm>
#include <cstdio>
#include <string>
#include <vector>

namespace payload {
namespace {

// 尾部标记：最后 40 字节 = 标记(16) + 资源偏移(8) + 压缩长度(8) + 解压后长度(8)
constexpr char kMagic[16] = "INKFETCH-SFX-1";
constexpr size_t kFooterSize = 40;

// 解压后的私有目录名前缀，放在 %TEMP% 下（系统会自行清理），
// 不会出现在 exe 旁边、下载目录或 AppData 里。
constexpr wchar_t kTempPrefix[] = L"InkFetch-";

// 延迟加载的引擎 DLL 名。
constexpr wchar_t kEngineDll[] = L"flutter_windows.dll";

// 当前实例解压出来的目录，供延迟加载钩子定位引擎 DLL。
std::wstring g_extracted_dir;

// ---------- 基础 I/O ----------

bool ReadFileBytes(const std::wstring& path, std::vector<BYTE>* out) {
  HANDLE handle = ::CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ,
                                nullptr, OPEN_EXISTING, 0, nullptr);
  if (handle == INVALID_HANDLE_VALUE) return false;
  LARGE_INTEGER size{};
  if (!::GetFileSizeEx(handle, &size)) {
    ::CloseHandle(handle);
    return false;
  }
  out->resize(static_cast<size_t>(size.QuadPart));
  DWORD read = 0;
  size_t total = 0;
  while (total < out->size()) {
    const DWORD want = static_cast<DWORD>(
        std::min<size_t>(out->size() - total, 1u << 20));
    if (!::ReadFile(handle, out->data() + total, want, &read, nullptr) ||
        read == 0) {
      ::CloseHandle(handle);
      return false;
    }
    total += read;
  }
  ::CloseHandle(handle);
  return true;
}

bool WriteFileBytes(const std::wstring& path, const BYTE* data, size_t size) {
  HANDLE handle =
      ::CreateFileW(path.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS,
                    FILE_ATTRIBUTE_NORMAL, nullptr);
  if (handle == INVALID_HANDLE_VALUE) return false;
  size_t written = 0;
  bool ok = true;
  while (written < size) {
    const DWORD want = static_cast<DWORD>(
        std::min<size_t>(size - written, 1u << 20));
    DWORD done = 0;
    if (!::WriteFile(handle, data + written, want, &done, nullptr)) {
      ok = false;
      break;
    }
    written += done;
  }
  ::CloseHandle(handle);
  return ok;
}

void EnsureDirectory(const std::wstring& path) {
  ::CreateDirectoryW(path.c_str(), nullptr);
}

std::wstring SelfPath() {
  wchar_t buffer[MAX_PATH * 4];
  const DWORD length = ::GetModuleFileNameW(nullptr, buffer,
                                            static_cast<DWORD>(std::size(buffer)));
  return std::wstring(buffer, length);
}

std::wstring TempRoot() {
  wchar_t buffer[MAX_PATH * 4];
  const DWORD length = ::GetTempPathW(static_cast<DWORD>(std::size(buffer)),
                                      buffer);
  std::wstring root(buffer, length);
  while (!root.empty() && root.back() == L'\\') root.pop_back();
  return root;
}

// ---------- 压缩（Windows 自带 Compression API，不依赖任何外部工具） ----------

bool CompressBuffer(const std::vector<BYTE>& input, std::vector<BYTE>* output) {
  COMPRESSOR_HANDLE compressor = nullptr;
  if (!::CreateCompressor(COMPRESS_ALGORITHM_LZMS, nullptr, &compressor)) {
    return false;
  }
  output->assign(input.size() + input.size() / 8 + 262144, 0);
  SIZE_T produced = 0;
  const BOOL ok =
      ::Compress(compressor, input.data(), input.size(), output->data(),
                 output->size(), &produced);
  ::CloseCompressor(compressor);
  if (!ok) {
    output->clear();
    return false;
  }
  output->resize(produced);
  return true;
}

bool DecompressBuffer(const BYTE* input, size_t input_size, size_t raw_size,
                      std::vector<BYTE>* output) {
  DECOMPRESSOR_HANDLE decompressor = nullptr;
  if (!::CreateDecompressor(COMPRESS_ALGORITHM_LZMS, nullptr, &decompressor)) {
    return false;
  }
  output->assign(raw_size + 4096, 0);
  SIZE_T produced = 0;
  const BOOL ok = ::Decompress(decompressor, input, input_size, output->data(),
                               output->size(), &produced);
  ::CloseDecompressor(decompressor);
  if (!ok) {
    output->clear();
    return false;
  }
  output->resize(produced);
  return true;
}

// ---------- 归档格式（解压后的裸数据） ----------
// u32 文件数，随后每个文件：u32 路径长度 + 路径(UTF-8) + u64 长度 + 内容
struct ArchiveEntry {
  std::string path;
  std::wstring disk_path;
  size_t offset = 0;
  uint64_t size = 0;
};

void PutU32(std::vector<BYTE>* buffer, uint32_t value) {
  for (int i = 0; i < 4; i++) {
    buffer->push_back(static_cast<BYTE>((value >> (i * 8)) & 0xFF));
  }
}

void PutU64(std::vector<BYTE>* buffer, uint64_t value) {
  for (int i = 0; i < 8; i++) {
    buffer->push_back(static_cast<BYTE>((value >> (i * 8)) & 0xFF));
  }
}

bool TakeU32(const std::vector<BYTE>& buffer, size_t* cursor, uint32_t* value) {
  if (*cursor + 4 > buffer.size()) return false;
  uint32_t result = 0;
  for (int i = 0; i < 4; i++) {
    result |= static_cast<uint32_t>(buffer[*cursor + i]) << (i * 8);
  }
  *cursor += 4;
  *value = result;
  return true;
}

bool TakeU64(const std::vector<BYTE>& buffer, size_t* cursor, uint64_t* value) {
  if (*cursor + 8 > buffer.size()) return false;
  uint64_t result = 0;
  for (int i = 0; i < 8; i++) {
    result |= static_cast<uint64_t>(buffer[*cursor + i]) << (i * 8);
  }
  *cursor += 8;
  *value = result;
  return true;
}

// 归档内的路径统一用 '/'，并去掉首尾分隔符。
std::string NormalizeRelative(const std::wstring& relative) {
  std::string utf8;
  const int needed = ::WideCharToMultiByte(
      CP_UTF8, 0, relative.data(), static_cast<int>(relative.size()), nullptr, 0,
      nullptr, nullptr);
  if (needed <= 0) return utf8;
  utf8.resize(static_cast<size_t>(needed));
  ::WideCharToMultiByte(CP_UTF8, 0, relative.data(),
                        static_cast<int>(relative.size()), utf8.data(), needed,
                        nullptr, nullptr);
  std::replace(utf8.begin(), utf8.end(), '\\', '/');
  while (!utf8.empty() && utf8.front() == '/') utf8.erase(utf8.begin());
  return utf8;
}

// 递归收集 release 目录下的文件。
void CollectFiles(const std::wstring& root, const std::wstring& relative,
                  std::vector<std::pair<std::string, std::wstring>>* files) {
  const std::wstring pattern =
      relative.empty() ? (root + L"\\*") : (root + L"\\" + relative + L"\\*");
  WIN32_FIND_DATAW data{};
  HANDLE find = ::FindFirstFileW(pattern.c_str(), &data);
  if (find == INVALID_HANDLE_VALUE) return;
  do {
    const std::wstring name = data.cFileName;
    if (name == L"." || name == L"..") continue;
    const std::wstring child_relative =
        relative.empty() ? name : relative + L"\\" + name;
    if ((data.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0) {
      CollectFiles(root, child_relative, files);
      continue;
    }
    files->emplace_back(NormalizeRelative(child_relative),
                        root + L"\\" + child_relative);
  } while (::FindNextFileW(find, &data));
  ::FindClose(find);
}

// ---------- 目录删除 ----------

void DeleteTree(const std::wstring& dir) {
  const std::wstring pattern = dir + L"\\*";
  WIN32_FIND_DATAW data{};
  HANDLE find = ::FindFirstFileW(pattern.c_str(), &data);
  if (find != INVALID_HANDLE_VALUE) {
    do {
      const std::wstring name = data.cFileName;
      if (name == L"." || name == L"..") continue;
      const std::wstring child = dir + L"\\" + name;
      if ((data.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0) {
        DeleteTree(child);
      } else {
        ::SetFileAttributesW(child.c_str(), FILE_ATTRIBUTE_NORMAL);
        ::DeleteFileW(child.c_str());
      }
    } while (::FindNextFileW(find, &data));
    ::FindClose(find);
  }
  ::SetFileAttributesW(dir.c_str(), FILE_ATTRIBUTE_NORMAL);
  ::RemoveDirectoryW(dir.c_str());
}

void DeleteTreeWithRetry(const std::wstring& dir, int attempts) {
  for (int i = 0; i < attempts; i++) {
    DeleteTree(dir);
    if (::GetFileAttributesW(dir.c_str()) == INVALID_FILE_ATTRIBUTES) return;
    ::Sleep(200);
  }
}

bool IsProcessAlive(DWORD pid) {
  HANDLE process = ::OpenProcess(SYNCHRONIZE, FALSE, pid);
  if (process == nullptr) return false;
  const DWORD wait = ::WaitForSingleObject(process, 0);
  ::CloseHandle(process);
  return wait == WAIT_TIMEOUT;
}

}  // namespace

// ---------- 延迟加载钩子 ----------
// 单文件版里引擎 DLL 被解到临时目录，静态导入改成延迟加载后按绝对路径
// LoadLibrary 即可；普通构建没有资源包时返回 nullptr，走系统默认搜索。
extern "C" FARPROC WINAPI DelayLoadHook(unsigned reason,
                                        PDelayLoadInfo info) {
  if (reason != dliNotePreLoadLibrary) return nullptr;
  if (info == nullptr || info->szDll == nullptr) return nullptr;
  if (::_stricmp(info->szDll, "flutter_windows.dll") != 0) return nullptr;
  if (g_extracted_dir.empty()) return nullptr;
  const std::wstring full = g_extracted_dir + L"\\" + kEngineDll;
  if (::GetFileAttributesW(full.c_str()) == INVALID_FILE_ATTRIBUTES) {
    return nullptr;
  }
  HMODULE module = ::LoadLibraryW(full.c_str());
  return reinterpret_cast<FARPROC>(module);
}

// 供 winmain 安装延迟加载钩子。
extern "C" {
PfnDliHook __pfnDliNotifyHook2 = DelayLoadHook;
}

Mode ParseMode(const wchar_t* command_line, std::wstring* dir, DWORD* pid,
               std::wstring* release_dir, std::wstring* out_file) {
  int argc = 0;
  wchar_t** argv = ::CommandLineToArgvW(command_line, &argc);
  if (argv == nullptr) return Mode::Run;
  Mode mode = Mode::Run;
  for (int i = 1; i < argc; i++) {
    const std::wstring arg = argv[i];
    const bool has_next = (i + 1) < argc;
    if (arg == L"--gc") {
      mode = Mode::Collect;
    } else if (arg == L"--dir" && has_next) {
      if (dir != nullptr) *dir = argv[++i];
    } else if (arg == L"--pid" && has_next) {
      if (pid != nullptr) *pid = static_cast<DWORD>(_wtoi(argv[++i]));
    } else if (arg == L"--pack") {
      mode = Mode::Pack;
    } else if (arg == L"--release" && has_next) {
      if (release_dir != nullptr) *release_dir = argv[++i];
    } else if (arg == L"--out" && has_next) {
      if (out_file != nullptr) *out_file = argv[++i];
    }
  }
  ::LocalFree(argv);
  return mode;
}

bool PackExecutable(const std::wstring& release_dir,
                    const std::wstring& out_file) {
  std::vector<std::pair<std::string, std::wstring>> files;
  CollectFiles(release_dir, L"", &files);
  if (files.empty()) return false;

  // 1) 拼出裸归档
  std::vector<BYTE> archive;
  PutU32(&archive, static_cast<uint32_t>(files.size()));
  for (const auto& entry : files) {
    std::vector<BYTE> content;
    if (!ReadFileBytes(entry.second, &content)) return false;
    PutU32(&archive, static_cast<uint32_t>(entry.first.size()));
    archive.insert(archive.end(), entry.first.begin(), entry.first.end());
    PutU64(&archive, content.size());
    archive.insert(archive.end(), content.begin(), content.end());
  }

  // 2) 整体压缩
  std::vector<BYTE> compressed;
  if (!CompressBuffer(archive, &compressed)) return false;

  // 3) 用自身 exe 做壳：复制自身 + 追加资源 + 尾部索引
  std::vector<BYTE> self;
  if (!ReadFileBytes(SelfPath(), &self)) return false;
  // 去掉本 exe 上可能已有的尾部（对同一个 exe 重复打包时保持幂等）。
  if (self.size() > kFooterSize &&
      memcmp(self.data() + self.size() - kFooterSize, kMagic,
             sizeof(kMagic)) == 0) {
    size_t cursor = self.size() - kFooterSize + sizeof(kMagic);
    uint64_t offset = 0;
    if (TakeU64(self, &cursor, &offset) && offset <= self.size()) {
      self.resize(static_cast<size_t>(offset));
    }
  }

  std::vector<BYTE> output;
  output.reserve(self.size() + compressed.size() + kFooterSize);
  output.insert(output.end(), self.begin(), self.end());
  const uint64_t data_offset = output.size();
  output.insert(output.end(), compressed.begin(), compressed.end());
  const BYTE* magic = reinterpret_cast<const BYTE*>(kMagic);
  output.insert(output.end(), magic, magic + sizeof(kMagic));
  PutU64(&output, data_offset);
  PutU64(&output, compressed.size());
  PutU64(&output, archive.size());

  return WriteFileBytes(out_file, output.data(), output.size());
}

bool ExtractEmbedded(std::wstring* out_dir, std::wstring* assets_dir) {
  std::vector<BYTE> self;
  if (!ReadFileBytes(SelfPath(), &self)) return false;
  if (self.size() <= kFooterSize) return false;
  const size_t footer_offset = self.size() - kFooterSize;
  // 尾部没有标记 = 普通构建（exe 旁边就是 data\），不按单文件版处理。
  if (memcmp(self.data() + footer_offset, kMagic, sizeof(kMagic)) != 0) {
    return false;
  }
  size_t cursor = footer_offset + sizeof(kMagic);
  uint64_t data_offset = 0;
  uint64_t data_size = 0;
  uint64_t raw_size = 0;
  if (!TakeU64(self, &cursor, &data_offset) || !TakeU64(self, &cursor, &data_size) ||
      !TakeU64(self, &cursor, &raw_size)) {
    return false;
  }
  if (data_offset + data_size > footer_offset) return false;

  std::vector<BYTE> archive;
  if (!DecompressBuffer(self.data() + data_offset,
                        static_cast<size_t>(data_size),
                        static_cast<size_t>(raw_size), &archive)) {
    return false;
  }

  // 私有临时目录：%TEMP%\InkFetch-<pid>-<计数>
  const std::wstring root = TempRoot();
  wchar_t name[64];
  swprintf_s(name, L"%s%lu-%llu", kTempPrefix,
             static_cast<unsigned long>(::GetCurrentProcessId()),
             static_cast<unsigned long long>(::GetTickCount64()));
  const std::wstring dir = root + L"\\" + name;
  ::CreateDirectoryW(dir.c_str(), nullptr);
  if (::GetFileAttributesW(dir.c_str()) == INVALID_FILE_ATTRIBUTES) return false;
  ::SetFileAttributesW(dir.c_str(), FILE_ATTRIBUTE_HIDDEN);

  // 解包
  size_t pos = 0;
  uint32_t count = 0;
  if (!TakeU32(archive, &pos, &count)) {
    DeleteTree(dir);
    return false;
  }

  for (uint32_t i = 0; i < count; i++) {
    uint32_t name_length = 0;
    if (!TakeU32(archive, &pos, &name_length) ||
        pos + name_length > archive.size()) {
      DeleteTree(dir);
      return false;
    }
    std::string relative(reinterpret_cast<const char*>(archive.data() + pos),
                         name_length);
    pos += name_length;
    uint64_t size = 0;
    if (!TakeU64(archive, &pos, &size) || pos + size > archive.size()) {
      DeleteTree(dir);
      return false;
    }

    std::wstring wide(relative.begin(), relative.end());
    std::replace(wide.begin(), wide.end(), L'/', L'\\');
    const std::wstring target = dir + L"\\" + wide;
    // 逐级创建父目录（不包含文件名本身）。
    for (size_t index = dir.size() + 1; index < target.size(); index++) {
      if (target[index] == L'\\') {
        const std::wstring partial = target.substr(0, index);
        if (partial.size() > dir.size()) EnsureDirectory(partial);
      }
    }
    if (!WriteFileBytes(target, archive.data() + pos,
                        static_cast<size_t>(size))) {
      DeleteTree(dir);
      return false;
    }
    pos += static_cast<size_t>(size);
  }

  g_extracted_dir = dir;

  if (out_dir != nullptr) *out_dir = dir;
  if (assets_dir != nullptr) *assets_dir = dir + L"\\data";
  return true;
}

void ScheduleCleanup(const std::wstring& dir) {
  if (dir.empty()) return;
  const std::wstring self = SelfPath();
  wchar_t command[4096];
  swprintf_s(command, L"\"%s\" --gc --dir \"%s\" --pid %lu", self.c_str(),
             dir.c_str(), static_cast<unsigned long>(::GetCurrentProcessId()));
  STARTUPINFOW startup{};
  startup.cb = sizeof(startup);
  PROCESS_INFORMATION process{};
  const BOOL ok = ::CreateProcessW(self.c_str(), command, nullptr, nullptr,
                                   FALSE, CREATE_NO_WINDOW, nullptr, nullptr,
                                   &startup, &process);
  if (ok) {
    ::CloseHandle(process.hThread);
    ::CloseHandle(process.hProcess);
  }
}

void PruneStale() {
  const std::wstring root = TempRoot();
  const std::wstring pattern = root + L"\\" + kTempPrefix + L"*";
  WIN32_FIND_DATAW data{};
  HANDLE find = ::FindFirstFileW(pattern.c_str(), &data);
  if (find == INVALID_HANDLE_VALUE) return;
  do {
    if ((data.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) == 0) continue;
    const std::wstring name = data.cFileName;
    const size_t dash = name.find(L'-', std::wcslen(kTempPrefix));
    if (dash == std::wstring::npos) continue;
    const DWORD pid =
        static_cast<DWORD>(_wtoi(name.c_str() + dash + 1));
    if (pid != 0 && IsProcessAlive(pid)) continue;
    DeleteTreeWithRetry(root + L"\\" + name, 3);
  } while (::FindNextFileW(find, &data));
  ::FindClose(find);
}

int RunCollector(const std::wstring& dir, DWORD pid) {
  if (dir.empty()) return 0;
  // 目录已经不在了（上一次清理成功、或系统已清掉 %TEMP%），直接退出，
  // 不要为一个不存在的目标挂着进程。
  if (::GetFileAttributesW(dir.c_str()) == INVALID_FILE_ATTRIBUTES) return 0;
  if (pid != 0) {
    // 等主进程真正结束再删，避免把还在用的 DLL / 资源删掉。
    //
    // 这里必须设上限：PID 会被系统复用，若拿到的正好是另一个长期存在的
    // 进程，INFINITE 会让清理进程永远活着——它自己就是从 exe 启动的，
    // 于是 exe 被它锁住，用户重装/覆盖时就会「文件被占用」。
    HANDLE process = ::OpenProcess(SYNCHRONIZE, FALSE, pid);
    if (process != nullptr) {
      // 主进程最多再活这么久；超时就认为它已经不需要这些文件了。
      ::WaitForSingleObject(process, 5 * 60 * 1000);
      ::CloseHandle(process);
    }
  }
  DeleteTreeWithRetry(dir, 20);
  return 0;
}

}  // namespace payload


