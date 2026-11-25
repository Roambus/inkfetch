#include "native_store.h"

#include <flutter/standard_method_codec.h>
#include <windows.h>

#include <string>
#include <vector>

#include "utils.h"

namespace {

// 存储根键：HKCU\Software\InkFetch\Store
constexpr wchar_t kStoreRoot[] = L"Software\\InkFetch\\Store";

std::wstring Utf16FromUtf8String(const std::string& text) {
  return Utf16FromUtf8(text);
}

std::string Utf8FromUtf16String(const std::wstring& text) {
  if (text.empty()) return std::string();
  return Utf8FromUtf16(text.c_str());
}

// 把 Dart 传来的 key 转成合法的注册表值名：只保留字母数字与 . _ -，
// 其余字符转义成 %XXXX，避免反斜杠被当成子键分隔符。
std::wstring EscapeKey(const std::string& key) {
  const std::wstring wide = Utf16FromUtf8String(key);
  if (wide.empty()) return L"_";
  std::wstring out;
  out.reserve(wide.size() + 8);
  for (const wchar_t ch : wide) {
    const bool safe = (ch >= L'a' && ch <= L'z') || (ch >= L'A' && ch <= L'Z') ||
                      (ch >= L'0' && ch <= L'9') || ch == L'.' || ch == L'_' ||
                      ch == L'-';
    if (safe) {
      out.push_back(ch);
    } else {
      wchar_t buffer[8];
      swprintf_s(buffer, L"%%%04X", static_cast<unsigned int>(ch) & 0xFFFFu);
      out.append(buffer);
    }
  }
  return out;
}

// EscapeKey 的逆运算：注册表值名还原成 Dart 侧的原始 key。
std::wstring UnescapeKey(const std::wstring& name) {
  std::wstring out;
  out.reserve(name.size());
  for (size_t i = 0; i < name.size();) {
    if (name[i] == L'%' && i + 4 < name.size() + 1 && i + 5 <= name.size()) {
      const std::wstring hex = name.substr(i + 1, 4);
      wchar_t* end = nullptr;
      const unsigned long code = wcstoul(hex.c_str(), &end, 16);
      if (end != nullptr && *end == L'\0') {
        out.push_back(static_cast<wchar_t>(code));
        i += 5;
        continue;
      }
    }
    out.push_back(name[i]);
    i++;
  }
  return out;
}

bool ReadRegString(HKEY root, const std::wstring& name, std::string* out) {
  DWORD type = 0;
  DWORD bytes = 0;
  if (::RegQueryValueExW(root, name.c_str(), nullptr, &type, nullptr, &bytes) !=
      ERROR_SUCCESS) {
    return false;
  }
  if (type != REG_SZ && type != REG_EXPAND_SZ) return false;
  std::vector<wchar_t> buffer(bytes / sizeof(wchar_t) + 2, L'\0');
  if (::RegQueryValueExW(root, name.c_str(), nullptr, &type,
                         reinterpret_cast<LPBYTE>(buffer.data()),
                         &bytes) != ERROR_SUCCESS) {
    return false;
  }
  const size_t length = bytes / sizeof(wchar_t);
  const std::wstring value(
      buffer.data(),
      length > 0 && buffer[length - 1] == L'\0' ? length - 1 : length);
  *out = Utf8FromUtf16String(value);
  return true;
}
bool WriteRegString(HKEY root, const std::wstring& name,
                    const std::string& utf8) {
  const std::wstring wide = Utf16FromUtf8String(utf8);
  const DWORD bytes = static_cast<DWORD>((wide.size() + 1) * sizeof(wchar_t));
  return ::RegSetValueExW(root, name.c_str(), 0, REG_SZ,
                          reinterpret_cast<const BYTE*>(wide.c_str()),
                          bytes) == ERROR_SUCCESS;
}

// 打开存储根键；create 为 false 时不存在就返回 nullptr（不建脏键）。
HKEY OpenStoreRoot(REGSAM access, bool create) {
  if (create) {
    HKEY key = nullptr;
    DWORD disposition = 0;
    if (::RegCreateKeyExW(HKEY_CURRENT_USER, kStoreRoot, 0, nullptr,
                          REG_OPTION_NON_VOLATILE, access, nullptr, &key,
                          &disposition) != ERROR_SUCCESS) {
      return nullptr;
    }
    return key;
  }
  HKEY key = nullptr;
  if (::RegOpenKeyExW(HKEY_CURRENT_USER, kStoreRoot, 0, access, &key) !=
      ERROR_SUCCESS) {
    return nullptr;
  }
  return key;
}

std::string GetStringArg(const flutter::EncodableMap& args, const char* name) {
  const auto it = args.find(flutter::EncodableValue(name));
  if (it == args.end()) return std::string();
  const auto* value = std::get_if<std::string>(&it->second);
  return value ? *value : std::string();
}

const flutter::EncodableMap* MapArgs(
    const flutter::MethodCall<flutter::EncodableValue>& call) {
  return std::get_if<flutter::EncodableMap>(call.arguments());
}

}  // namespace

NativeStore::NativeStore(flutter::BinaryMessenger* messenger)
    : messenger_(messenger) {
  channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger_, "app.inkfetch/store",
      &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) { HandleMethodCall(call, std::move(result)); });
}

NativeStore::~NativeStore() {
  if (channel_) channel_->SetMethodCallHandler(nullptr);
}

void NativeStore::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const auto* args = MapArgs(call);
  if (args == nullptr) {
    result->Error("bad_args", "参数缺失");
    return;
  }
  const std::string method = call.method_name();

  if (method == "read") {
    std::string value;
    HKEY root = OpenStoreRoot(KEY_READ, false);
    const bool found =
        root != nullptr &&
        ReadRegString(root, EscapeKey(GetStringArg(*args, "key")), &value);
    if (root != nullptr) ::RegCloseKey(root);
    if (found) {
      result->Success(flutter::EncodableValue(value));
    } else {
      result->Success(flutter::EncodableValue());
    }
    return;
  }

  if (method == "write") {
    HKEY root = OpenStoreRoot(KEY_READ | KEY_WRITE, true);
    if (root == nullptr) {
      result->Error("registry", "无法打开应用设置存储");
      return;
    }
    const bool ok = WriteRegString(root, EscapeKey(GetStringArg(*args, "key")),
                                   GetStringArg(*args, "value"));
    ::RegCloseKey(root);
    if (ok) {
      result->Success(flutter::EncodableValue());
    } else {
      result->Error("registry", "写入应用设置失败");
    }
    return;
  }

  if (method == "remove") {
    HKEY root = OpenStoreRoot(KEY_READ | KEY_WRITE, false);
    if (root != nullptr) {
      ::RegDeleteValueW(root, EscapeKey(GetStringArg(*args, "key")).c_str());
      ::RegCloseKey(root);
    }
    result->Success(flutter::EncodableValue());
    return;
  }

  if (method == "clear") {
    HKEY root = OpenStoreRoot(KEY_READ | KEY_WRITE, false);
    if (root != nullptr) {
      // 逐项删除而不是删整个根键：根键保留，避免反复创建。
      std::vector<std::wstring> names;
      for (DWORD index = 0;; index++) {
        wchar_t name[1024];
        DWORD name_length = static_cast<DWORD>(std::size(name));
        if (::RegEnumValueW(root, index, name, &name_length, nullptr, nullptr,
                            nullptr, nullptr) != ERROR_SUCCESS) {
          break;
        }
        names.emplace_back(name, name_length);
      }
      for (const auto& name : names) ::RegDeleteValueW(root, name.c_str());
      ::RegCloseKey(root);
    }
    result->Success(flutter::EncodableValue());
    return;
  }

  if (method == "readAll") {
    const std::string prefix = GetStringArg(*args, "prefix");
    flutter::EncodableMap entries;
    HKEY root = OpenStoreRoot(KEY_READ, false);
    if (root != nullptr) {
      for (DWORD index = 0;; index++) {
        wchar_t name[1024];
        DWORD name_length = static_cast<DWORD>(std::size(name));
        DWORD type = 0;
        if (::RegEnumValueW(root, index, name, &name_length, nullptr, &type,
                            nullptr, nullptr) != ERROR_SUCCESS) {
          break;
        }
        if (type != REG_SZ && type != REG_EXPAND_SZ) continue;
        std::string value;
        if (!ReadRegString(root, std::wstring(name, name_length), &value)) {
          continue;
        }
        const std::string key = Utf8FromUtf16String(
            UnescapeKey(std::wstring(name, name_length)));
        if (key.rfind(prefix, 0) != 0) continue;
        entries[flutter::EncodableValue(key)] = flutter::EncodableValue(value);
      }
      ::RegCloseKey(root);
    }
    result->Success(flutter::EncodableValue(entries));
    return;
  }

  result->NotImplemented();
}
