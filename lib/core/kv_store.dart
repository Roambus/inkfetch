import 'dart:io';

import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Windows runner 里的原生存储通道，数据落在 HKCU\Software\InkFetch\Store。
const String kStoreChannel = 'app.inkfetch/store';

/// 键值存储抽象：Windows 写注册表，其他平台继续用 shared_preferences。
abstract class KeyValueStore {
  Future<String?> read(String key);

  Future<void> write(String key, String value);

  Future<void> remove(String key);

  Future<void> clear();

  Future<Map<String, String>> readAll({String? prefix});
}

/// shared_preferences 实现，Android / Linux / macOS 行为保持不变。
class PrefsKeyValueStore implements KeyValueStore {
  const PrefsKeyValueStore();

  @override
  Future<String?> read(String key) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(key);
  }

  @override
  Future<void> write(String key, String value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(key, value);
  }

  @override
  Future<void> remove(String key) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(key);
  }

  @override
  Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
  }

  @override
  Future<Map<String, String>> readAll({String? prefix}) async {
    final prefs = await SharedPreferences.getInstance();
    return {
      for (final key in prefs.getKeys())
        if (prefix == null || key.startsWith(prefix))
          key: prefs.getString(key) ?? '',
    };
  }
}

/// 原生注册表实现，只在 Windows 上可用。
class ChannelKeyValueStore implements KeyValueStore {
  const ChannelKeyValueStore();

  static const MethodChannel _channel = MethodChannel(kStoreChannel);

  @override
  Future<String?> read(String key) {
    return _channel.invokeMethod<String>('read', {'key': key});
  }

  @override
  Future<void> write(String key, String value) {
    return _channel.invokeMethod<void>('write', {'key': key, 'value': value});
  }

  @override
  Future<void> remove(String key) {
    return _channel.invokeMethod<void>('remove', {'key': key});
  }

  @override
  Future<void> clear() {
    return _channel.invokeMethod<void>('clear');
  }

  @override
  Future<Map<String, String>> readAll({String? prefix}) async {
    final result = await _channel.invokeMapMethod<String, String>('readAll', {
      'prefix': prefix,
    });
    return result ?? const {};
  }
}

/// Windows 走注册表，其余平台保持 shared_preferences。
KeyValueStore defaultKeyValueStore() => Platform.isWindows
    ? const ChannelKeyValueStore()
    : const PrefsKeyValueStore();
