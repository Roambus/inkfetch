import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';

class AppStore {
  static const _settingsKey = 'inkfetch.settings.v1';
  static const _historyKey = 'inkfetch.history.v1';
  static const _queueKey = 'inkfetch.queue.v1';
  static const int historyLimit = 80;

  Future<(AppSettings, List<HistoryEntry>, List<String>)> load() async {
    final prefs = await SharedPreferences.getInstance();
    var settings = AppSettings();
    final settingsRaw = prefs.getString(_settingsKey);
    if (settingsRaw != null) {
      try {
        settings = AppSettings.fromJson(
          jsonDecode(settingsRaw) as Map<String, dynamic>,
        );
      } catch (_) {}
    }
    var history = <HistoryEntry>[];
    final historyRaw = prefs.getString(_historyKey);
    if (historyRaw != null) {
      try {
        final list = jsonDecode(historyRaw) as List<dynamic>;
        history = list
            .map((e) => HistoryEntry.fromJson(e as Map<String, dynamic>))
            .toList();
      } catch (_) {}
    }
    var queue = <String>[];
    final queueRaw = prefs.getString(_queueKey);
    if (queueRaw != null) {
      try {
        final list = jsonDecode(queueRaw) as List<dynamic>;
        queue = list.map((e) => e.toString()).where((e) => e.isNotEmpty).toList();
      } catch (_) {}
    }
    return (settings, history, queue);
  }

  Future<void> saveSettings(AppSettings settings) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_settingsKey, jsonEncode(settings.toJson()));
  }

  Future<void> saveHistory(List<HistoryEntry> history) async {
    final prefs = await SharedPreferences.getInstance();
    final trimmed = history.take(historyLimit).toList();
    await prefs.setString(
      _historyKey,
      jsonEncode(trimmed.map((e) => e.toJson()).toList()),
    );
  }

  Future<void> saveQueue(List<String> queue) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_queueKey, jsonEncode(queue));
  }
}
