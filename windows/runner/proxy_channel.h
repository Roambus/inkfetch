#ifndef RUNNER_PROXY_CHANNEL_H_
#define RUNNER_PROXY_CHANNEL_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>

#include <memory>

// Windows 系统代理（PAC）的读写通道。
//
// 单独一条通道（app.inkfetch/proxy），与 hosts 写入分开：
// 这条只改当前用户的注册表项，不需要管理员权限，
// 职责与权限边界都和 hosts 那边不同。
class ProxyChannel {
 public:
  explicit ProxyChannel(flutter::BinaryMessenger* messenger);
  ~ProxyChannel();

  ProxyChannel(const ProxyChannel&) = delete;
  ProxyChannel& operator=(const ProxyChannel&) = delete;

 private:
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
};

#endif  // RUNNER_PROXY_CHANNEL_H_
