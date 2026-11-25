#ifndef RUNNER_HOSTS_CHANNEL_H_
#define RUNNER_HOSTS_CHANNEL_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>

#include <memory>

// hosts 写入的 Flutter 通道。
//
// 单独一条通道（app.inkfetch/hosts），与设置存储分开：
// 这条通道的方法带副作用（弹 UAC、改系统文件），
// 混进存储通道会让职责与权限边界都变模糊。
class HostsChannel {
 public:
  explicit HostsChannel(flutter::BinaryMessenger* messenger);
  ~HostsChannel();

  HostsChannel(const HostsChannel&) = delete;
  HostsChannel& operator=(const HostsChannel&) = delete;

 private:
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
};

#endif  // RUNNER_HOSTS_CHANNEL_H_
