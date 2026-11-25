import 'dart:convert';

import 'kv_store.dart';
import 'models.dart';

class AppStore {
  static const _settingsKey = 'inkfetch.settings.v1';
  static const _historyKey = 'inkfetch.history.v1';
  static const _queueKey = 'inkfetch.queue.v1';
  static const int historyLimit = 80;

  final KeyValueStore _kv;

  /// 默认按平台选实现：Windows 注册表，其余平台 shared_preferences。
  AppStore({KeyValueStore? store}) : _kv = store ?? defaultKeyValueStore();

  Future<(AppSettings, List<HistoryEntry>, List<String>)> load() async {
    var settings = AppSettings();
    var history = <HistoryEntry>[];
    var queue = <String>[];
    try {
      final settingsRaw = await _kv.read(_settingsKey);
      if (settingsRaw != null) {
        try {
          settings = AppSettings.fromJson(
            jsonDecode(settingsRaw) as Map<String, dynamic>,
          );
        } catch (_) {}
      }
      final historyRaw = await _kv.read(_historyKey);
      if (historyRaw != null) {
        try {
          final list = jsonDecode(historyRaw) as List<dynamic>;
          history = list
              .map((e) => HistoryEntry.fromJson(e as Map<String, dynamic>))
              .toList();
        } catch (_) {}
      }
      final queueRaw = await _kv.read(_queueKey);
      if (queueRaw != null) {
        try {
          final list = jsonDecode(queueRaw) as List<dynamic>;
          queue = list
              .map((e) => e.toString())
              .where((e) => e.isNotEmpty)
              .toList();
        } catch (_) {}
      }
    } catch (_) {}
    return (settings, history, queue);
  }

  Future<void> saveSettings(AppSettings settings) async {
    await _write(_settingsKey, jsonEncode(settings.toJson()));
  }

  Future<void> saveHistory(List<HistoryEntry> history) async {
    final trimmed = history.take(historyLimit).toList();
    await _write(
      _historyKey,
      jsonEncode(trimmed.map((e) => e.toJson()).toList()),
    );
  }

  Future<void> saveQueue(List<String> queue) async {
    await _write(_queueKey, jsonEncode(queue));
  }

  /// 存储失败（例如原生通道不可用）只丢这一份数据，不影响界面。
  Future<void> _write(String key, String value) async {
    try {
      await _kv.write(key, value);
    } catch (_) {}
  }
}
