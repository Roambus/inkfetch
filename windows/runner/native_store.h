#ifndef RUNNER_NATIVE_STORE_H_
#define RUNNER_NATIVE_STORE_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>

#include <memory>
#include <string>

// 应用状态存储：把设置、下载记录、队列与断点续传状态写进 HKCU 注册表，
// 而不是落到磁盘上的文件里。这样单文件版运行时不会在
// %APPDATA% / 下载目录 里留下任何散落的 JSON。
class NativeStore {
 public:
  explicit NativeStore(flutter::BinaryMessenger* messenger);
  ~NativeStore();

  NativeStore(const NativeStore&) = delete;
  NativeStore& operator=(const NativeStore&) = delete;

 private:
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  flutter::BinaryMessenger* messenger_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
};

#endif  // RUNNER_NATIVE_STORE_H_
