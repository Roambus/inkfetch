import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';

class AppStore {
  static const _settingsKey = 'octofetch.settings.v1';
  static const _historyKey = 'octofetch.history.v1';
  static const int historyLimit = 80;

  Future<(AppSettings, List<HistoryEntry>)> load() async {
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
    return (settings, history);
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
}
