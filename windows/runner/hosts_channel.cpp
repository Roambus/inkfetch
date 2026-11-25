#include "hosts_channel.h"

#include <flutter/standard_method_codec.h>

#include <string>

#include "hosts.h"
#include "utils.h"

namespace {

constexpr char kChannelName[] = "app.inkfetch/hosts";

std::wstring GetStringArg(const flutter::EncodableMap& args, const char* key) {
  const auto it = args.find(flutter::EncodableValue(std::string(key)));
  if (it == args.end()) return std::wstring();
  const auto* value = std::get_if<std::string>(&it->second);
  if (value == nullptr) return std::wstring();
  return Utf16FromUtf8(*value);
}

}  // namespace

HostsChannel::HostsChannel(flutter::BinaryMessenger* messenger) {
  channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, kChannelName,
      &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) { HandleMethodCall(call, std::move(result)); });
}

HostsChannel::~HostsChannel() = default;

void HostsChannel::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());

  if (call.method_name() == "applyHosts") {
    if (args == nullptr) {
      result->Error("bad_args", "缺少参数");
      return;
    }
    const std::wstring src = GetStringArg(*args, "src");
    const std::wstring dst = GetStringArg(*args, "dst");
    if (src.empty() || dst.empty()) {
      result->Error("bad_args", "缺少 src 或 dst");
      return;
    }
    std::wstring message;
    const bool ok = hosts::ElevateApply(src, dst, &message);
    if (ok) {
      result->Success(flutter::EncodableValue(true));
    } else {
      // 把子进程/系统给的具体原因带回 Dart，界面上要能说清楚
      // 到底是「用户点了取消」还是「写入被拦截」。
      result->Error("apply_failed", Utf8FromUtf16(message.c_str()));
    }
    return;
  }

  if (call.method_name() == "restoreHosts") {
    if (args == nullptr) {
      result->Error("bad_args", "缺少参数");
      return;
    }
    const std::wstring dst = GetStringArg(*args, "dst");
    if (dst.empty()) {
      result->Error("bad_args", "缺少 dst");
      return;
    }
    std::wstring message;
    const bool ok = hosts::ElevateRestore(dst, &message);
    if (ok) {
      result->Success(flutter::EncodableValue(true));
    } else {
      result->Error("restore_failed", Utf8FromUtf16(message.c_str()));
    }
    return;
  }

  result->NotImplemented();
}
