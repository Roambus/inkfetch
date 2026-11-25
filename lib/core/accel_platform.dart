import 'dart:io';

import 'package:flutter/services.dart';

import 'github_accel.dart';
import 'hosts_file.dart';

/// GitHub 加速的平台侧操作。
///
/// 两个平台的落地方式不同，但对外接口一致：
///
/// **Windows** —— 改系统 hosts。需要管理员权限，因此通过一次 UAC 提权
/// 完成（见 windows/runner/hosts.cpp）。启用时写入标记区块，
/// 停用时整段移除并恢复备份。
///
/// **Android** —— 不起 hosts（普通应用无权改），而是起一个只接管
/// DNS 的 VpnService，把 GitHub 域名的解析结果改成我们实测可用的 IP。
/// 首次启用会弹系统的 VPN 授权框。
class AccelPlatform {
  static const MethodChannel _channel = MethodChannel('app.inkfetch/native');

  /// hosts 写入单独一条通道：它带提权副作用，与普通方法分开。
  static const MethodChannel _hostsChannel = MethodChannel('app.inkfetch/hosts');

  /// 是否支持加速（目前仅 Windows 与 Android）。
  static bool get isSupported => Platform.isWindows || Platform.isAndroid;

  /// 当前平台的能力描述，用于界面展示。
  static String get method => Platform.isWindows
      ? '修改系统 hosts'
      : Platform.isAndroid
      ? 'DNS 分流 VPN'
      : '不支持';

  /// 当前生效的加速条目：Windows 读 hosts 区块，Android 读上一次下发的表。
  static Future<List<HostEntry>> currentEntries() async {
    if (Platform.isWindows) {
      final path = windowsHostsPath();
      try {
        final text = await readHostsFile(path);
        return readHostsBlock(text);
      } catch (_) {
        return const [];
      }
    }
    if (Platform.isAndroid) {
      return _androidEntries;
    }
    return const [];
  }

  /// 是否正在加速。
  static Future<bool> isActive() async {
    if (Platform.isWindows) {
      try {
        final text = await readHostsFile(windowsHostsPath());
        return hasHostsBlock(text);
      } catch (_) {
        return false;
      }
    }
    if (Platform.isAndroid) {
      try {
        final active = await _channel.invokeMethod<bool>('accelStatus');
        return active ?? false;
      } catch (_) {
        return false;
      }
    }
    return false;
  }

  /// 启用加速。返回 (是否成功, 给用户看的说明)。
  static Future<(bool, String)> enable(List<HostEntry> entries) async {
    if (entries.isEmpty) return (false, '没有可用的 IP，未启用');

    if (Platform.isWindows) {
      return _enableWindows(entries);
    }
    if (Platform.isAndroid) {
      return _enableAndroid(entries);
    }
    return (false, '当前平台不支持 GitHub 加速');
  }

  /// 停用加速，恢复到启用前的状态。
  static Future<(bool, String)> disable() async {
    if (Platform.isWindows) {
      return _disableWindows();
    }
    if (Platform.isAndroid) {
      try {
        await _channel.invokeMethod<bool>('accelStop');
        _androidEntries = const [];
        return (true, '已关闭 GitHub 加速');
      } catch (error) {
        return (false, '关闭失败：$error');
      }
    }
    return (false, '当前平台不支持 GitHub 加速');
  }

  // ── Windows ────────────────────────────────────────────────────────────

  static Future<(bool, String)> _enableWindows(List<HostEntry> entries) async {
    try {
      final hostsPath = windowsHostsPath();
      final original = await readHostsFile(hostsPath);
      final updated = applyHostsBlock(original, entries);
      if (updated == original) {
        return (true, 'hosts 已是最新，无需改动');
      }

      // 写临时文件，交给提权子进程去替换真正的 hosts。
      // 主进程始终以普通权限运行，不常驻提权。
      final temp = File(
        '${Directory.systemTemp.path}${Platform.pathSeparator}'
        'inkfetch-hosts-${DateTime.now().microsecondsSinceEpoch}.txt',
      );
      await temp.writeAsString(updated, flush: true);
      try {
        final ok = await _hostsChannel.invokeMethod<bool>('applyHosts', {
          'src': temp.path,
          'dst': hostsPath,
        });
        if (ok == true) {
          return (true, '已写入 ${entries.length} 条加速记录');
        }
        return (false, '写入 hosts 失败');
      } finally {
        try {
          await temp.delete();
        } catch (_) {}
      }
    } catch (error) {
      return (false, '启用失败：$error');
    }
  }

  static Future<(bool, String)> _disableWindows() async {
    try {
      final hostsPath = windowsHostsPath();
      final original = await readHostsFile(hostsPath);
      if (!hasHostsBlock(original)) {
        return (true, '当前没有启用加速');
      }
      final restored = stripHostsBlock(original);
      final temp = File(
        '${Directory.systemTemp.path}${Platform.pathSeparator}'
        'inkfetch-hosts-off-${DateTime.now().microsecondsSinceEpoch}.txt',
      );
      await temp.writeAsString('${restored.trimRight()}\n', flush: true);
      try {
        final ok = await _hostsChannel.invokeMethod<bool>('applyHosts', {
          'src': temp.path,
          'dst': hostsPath,
        });
        if (ok == true) return (true, '已移除加速记录');
        return (false, '恢复 hosts 失败');
      } finally {
        try {
          await temp.delete();
        } catch (_) {}
      }
    } catch (error) {
      return (false, '关闭失败：$error');
    }
  }

  // ── Android ────────────────────────────────────────────────────────────

  static List<HostEntry> _androidEntries = const [];

  static Future<(bool, String)> _enableAndroid(List<HostEntry> entries) async {
    try {
      final map = <String, String>{};
      for (final e in entries) {
        map[e.host] = e.ip;
      }
      final ok = await _channel.invokeMethod<bool>('accelStart', {
        'domainIps': map,
        'upstream': '223.5.5.5',
      });
      if (ok == true) {
        _androidEntries = List<HostEntry>.of(entries);
        return (true, '已接管 ${entries.length} 个域名的解析');
      }
      return (false, '启动加速失败');
    } on PlatformException catch (error) {
      // 最常见的两种：用户拒绝授权、被其它 VPN 占用。
      final message = error.message ?? error.code;
      return (false, message);
    } catch (error) {
      return (false, '启动失败：$error');
    }
  }
}

/// Windows hosts 路径见 hosts_file.dart 的 windowsHostsPath()。
