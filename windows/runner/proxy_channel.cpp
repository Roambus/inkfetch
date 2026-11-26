#include "proxy_channel.h"

#include <flutter/standard_method_codec.h>

// wininet.h 依赖 windows.h 里的基础类型，必须先包含。
#include <windows.h>

#include <wininet.h>

#include <string>

#include "utils.h"

namespace {

constexpr char kChannelName[] = "app.inkfetch/proxy";

// 当前用户的 IE/系统代理设置。
constexpr wchar_t kInternetSettings[] =
    L"Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings";
// 我们把原始值备份在这里，停用时恢复。
constexpr wchar_t kBackupKey[] =
    L"Software\\InkFetch\\ProxyBackup";

std::string ReadRegString(HKEY root, const wchar_t* subkey,
                          const wchar_t* name) {
  HKEY key = nullptr;
  if (::RegOpenKeyExW(root, subkey, 0, KEY_READ, &key) != ERROR_SUCCESS) {
    return std::string();
  }
  DWORD type = 0;
  DWORD size = 0;
  std::string result;
  if (::RegQueryValueExW(key, name, nullptr, &type, nullptr, &size) ==
          ERROR_SUCCESS &&
      type == REG_SZ && size > 0) {
    std::wstring buffer(size / sizeof(wchar_t) + 1, L'\0');
    if (::RegQueryValueExW(key, name, nullptr, &type,
                           reinterpret_cast<LPBYTE>(buffer.data()),
                           &size) == ERROR_SUCCESS) {
      while (!buffer.empty() && buffer.back() == L'\0') buffer.pop_back();
      result = Utf8FromUtf16(buffer.c_str());
    }
  }
  ::RegCloseKey(key);
  return result;
}

bool WriteRegString(HKEY root, const wchar_t* subkey, const wchar_t* name,
                    const std::wstring& value) {
  HKEY key = nullptr;
  if (::RegCreateKeyExW(root, subkey, 0, nullptr, 0, KEY_WRITE, nullptr, &key,
                        nullptr) != ERROR_SUCCESS) {
    return false;
  }
  const DWORD size =
      static_cast<DWORD>((value.size() + 1) * sizeof(wchar_t));
  const LSTATUS status = ::RegSetValueExW(
      key, name, 0, REG_SZ, reinterpret_cast<const BYTE*>(value.c_str()),
      size);
  ::RegCloseKey(key);
  return status == ERROR_SUCCESS;
}

bool DeleteRegValue(HKEY root, const wchar_t* subkey, const wchar_t* name) {
  HKEY key = nullptr;
  if (::RegOpenKeyExW(root, subkey, 0, KEY_SET_VALUE, &key) !=
      ERROR_SUCCESS) {
    return true;  // 键不存在，等于已经删掉了
  }
  const LSTATUS status = ::RegDeleteValueW(key, name);
  ::RegCloseKey(key);
  return status == ERROR_SUCCESS || status == ERROR_FILE_NOT_FOUND;
}

// 通知系统代理设置已变更。
//
// 不通知的话，新设置要等目标程序重新读注册表才生效，
// 浏览器可能还按旧配置走，用户会以为「点了没反应」。
void NotifyProxyChanged() {
  ::InternetSetOptionW(nullptr, INTERNET_OPTION_SETTINGS_CHANGED, nullptr, 0);
  ::InternetSetOptionW(nullptr, INTERNET_OPTION_REFRESH, nullptr, 0);
}

}  // namespace

ProxyChannel::ProxyChannel(flutter::BinaryMessenger* messenger) {
  channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, kChannelName, &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) { HandleMethodCall(call, std::move(result)); });
}

ProxyChannel::~ProxyChannel() = default;

void ProxyChannel::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const std::string method = call.method_name();

  if (method == "getAutoConfigUrl") {
    const std::string value =
        ReadRegString(HKEY_CURRENT_USER, kInternetSettings, L"AutoConfigURL");
    if (value.empty()) {
      result->Success(flutter::EncodableValue());
    } else {
      result->Success(flutter::EncodableValue(value));
    }
    return;
  }

  if (method == "setAutoConfigUrl") {
    const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
    if (args == nullptr) {
      result->Error("bad_args", "缺少参数");
      return;
    }
    const auto it = args->find(flutter::EncodableValue(std::string("url")));
    if (it == args->end()) {
      result->Error("bad_args", "缺少 url");
      return;
    }
    const auto* url = std::get_if<std::string>(&it->second);
    if (url == nullptr || url->empty()) {
      result->Error("bad_args", "url 为空");
      return;
    }

    // 备份原始值（可能是空字符串，也要记下来，才知道原本是"没配"）。
    const std::string previous =
        ReadRegString(HKEY_CURRENT_USER, kInternetSettings, L"AutoConfigURL");
    WriteRegString(HKEY_CURRENT_USER, kBackupKey, L"original",
                   Utf16FromUtf8(previous));
    WriteRegString(HKEY_CURRENT_USER, kBackupKey, L"hadValue",
                   previous.empty() ? L"0" : L"1");

    const bool ok = WriteRegString(HKEY_CURRENT_USER, kInternetSettings,
                                   L"AutoConfigURL", Utf16FromUtf8(*url));
    NotifyProxyChanged();
    if (ok) {
      result->Success(flutter::EncodableValue(true));
    } else {
      result->Error("write_failed", "写入注册表失败");
    }
    return;
  }

  if (method == "restoreAutoConfigUrl") {
    const std::string had =
        ReadRegString(HKEY_CURRENT_USER, kBackupKey, L"hadValue");
    if (had == "1") {
      const std::string previous =
          ReadRegString(HKEY_CURRENT_USER, kBackupKey, L"original");
      WriteRegString(HKEY_CURRENT_USER, kInternetSettings, L"AutoConfigURL",
                     Utf16FromUtf8(previous));
    } else {
      // 原本没有配置，就删掉我们写的那个值，恢复成"未设置"。
      DeleteRegValue(HKEY_CURRENT_USER, kInternetSettings, L"AutoConfigURL");
    }
    // 清理备份
    ::RegDeleteKeyW(HKEY_CURRENT_USER, kBackupKey);
    NotifyProxyChanged();
    result->Success(flutter::EncodableValue(true));
    return;
  }

  result->NotImplemented();
}
