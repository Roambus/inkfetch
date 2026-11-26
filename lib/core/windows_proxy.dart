import 'dart:io';

import 'package:flutter/services.dart';

/// Windows 系统代理（PAC 模式）的读写。
///
/// 为什么用 PAC 而不是普通代理：用户的诉求是「只针对 GitHub，
/// 其他流量还是走默认网络」。普通代理会把所有站点都推给中转，
/// 既影响其它上网，也浪费服务器带宽。PAC 能让 Windows 按域名
/// 精确决定走不走代理。
///
/// 写入位置是当前用户的 IE/系统代理设置（HKCU），不需要管理员权限：
/// `HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings`
/// 里的 `AutoConfigURL` 值。
///
/// 停用时删除该值并恢复我们改动前的状态——不改动用户原本的代理配置。
class WindowsProxy {
  static const MethodChannel _channel = MethodChannel('app.inkfetch/proxy');

  static bool get isSupported => Platform.isWindows;

  /// PAC 文件地址（放在自己的服务器上）。
  static const String pacUrl =
      'https://www.roambus.me/inkfetch-gh.pac';

  /// 读取当前是否已启用我们的 PAC。
  static Future<bool> isEnabled() async {
    if (!isSupported) return false;
    try {
      final value = await _channel.invokeMethod<String>('getAutoConfigUrl');
      return value != null && value == pacUrl;
    } catch (_) {
      return false;
    }
  }

  /// 启用 PAC。
  ///
  /// 会先记下原有的 AutoConfigURL，停用时恢复，
  /// 避免把用户自己配的 PAC 弄丢。
  static Future<(bool, String)> enable() async {
    if (!isSupported) return (false, '当前平台不支持');
    try {
      final ok = await _channel.invokeMethod<bool>('setAutoConfigUrl', {
        'url': pacUrl,
      });
      if (ok == true) {
        return (true, '已启用中转（仅 GitHub 域名走代理）');
      }
      return (false, '设置系统代理失败');
    } catch (error) {
      return (false, '设置系统代理失败：$error');
    }
  }

  /// 停用 PAC，恢复到启用前。
  static Future<(bool, String)> disable() async {
    if (!isSupported) return (false, '当前平台不支持');
    try {
      final ok = await _channel.invokeMethod<bool>('restoreAutoConfigUrl');
      if (ok == true) return (true, '已关闭中转，网络恢复默认');
      return (false, '恢复系统代理失败');
    } catch (error) {
      return (false, '恢复系统代理失败：$error');
    }
  }
}
