import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'kv_store.dart';

/// 一条可续传的下载状态。
class ResumeRecord {
  final String destPath;
  final Map<String, dynamic> payload;

  const ResumeRecord(this.destPath, this.payload);
}

/// 断点续传状态的存储抽象。Windows 写注册表，Android / 测试写 `.octopart` 旁挂文件。
abstract class ResumeStore {
  /// 读取某个目标文件的续传状态，没有则返回 null。
  Future<Map<String, dynamic>?> load(String destPath);

  /// 保存续传状态，payload 是完整的 sidecar JSON。
  Future<void> save(String destPath, Map<String, dynamic> payload);

  /// 下载完成或用户清理时删掉这条状态。
  Future<void> remove(String destPath);

  /// 列出可续传的任务；[root] 只对文件实现有意义（扫描该目录）。
  Future<List<ResumeRecord>> listIncomplete({String? root});
}

/// 默认实现：Windows 走注册表，其余平台继续用下载目录里的 `.octopart`。
ResumeStore defaultResumeStore() =>
    Platform.isWindows ? const RegistryResumeStore() : const FileResumeStore();

/// 文件实现：状态写在 `$destPath.octopart`，与旧版本完全一致。
class FileResumeStore implements ResumeStore {
  const FileResumeStore();

  static const String suffix = '.octopart';

  @override
  Future<Map<String, dynamic>?> load(String destPath) async {
    final file = File('$destPath$suffix');
    try {
      if (!await file.exists()) return null;
      final json = jsonDecode(await file.readAsString());
      if (json is! Map<String, dynamic>) return null;
      return json;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> save(String destPath, Map<String, dynamic> payload) async {
    await File('$destPath$suffix')
        .writeAsString(jsonEncode(payload), flush: false);
  }

  @override
  Future<void> remove(String destPath) async {
    try {
      await File('$destPath$suffix').delete();
    } catch (_) {}
  }

  @override
  Future<List<ResumeRecord>> listIncomplete({String? root}) async {
    final records = <ResumeRecord>[];
    if (root == null || root.isEmpty) return records;
    final dir = Directory(root);
    if (!await dir.exists()) return records;
    try {
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is! File) continue;
        final path = entity.path;
        if (!path.endsWith(suffix)) continue;
        try {
          final json = jsonDecode(await entity.readAsString());
          if (json is! Map<String, dynamic>) continue;
          final destPath = path.substring(0, path.length - suffix.length);
          records.add(ResumeRecord(destPath, json));
        } catch (_) {}
      }
    } catch (_) {}
    return records;
  }
}

/// 注册表实现（仅 Windows）：键为 `resume.` + 目标路径的 SHA-1，
/// 值为同一份 sidecar JSON（额外带 destPath，枚举时用来还原文件名）。
class RegistryResumeStore implements ResumeStore {
  const RegistryResumeStore({KeyValueStore? store})
    : _kv = store ?? const ChannelKeyValueStore();

  final KeyValueStore _kv;

  static const String keyPrefix = 'resume.';

  /// 目标文件的绝对路径 → 注册表键。
  static String keyFor(String destPath) =>
      '$keyPrefix${sha1.convert(utf8.encode(destPath))}';

  @override
  Future<Map<String, dynamic>?> load(String destPath) async {
    try {
      final raw = await _kv.read(keyFor(destPath));
      if (raw == null || raw.isEmpty) return null;
      final json = jsonDecode(raw);
      if (json is! Map<String, dynamic>) return null;
      return json;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> save(String destPath, Map<String, dynamic> payload) async {
    await _kv.write(
      keyFor(destPath),
      jsonEncode({...payload, 'destPath': destPath}),
    );
  }

  @override
  Future<void> remove(String destPath) async {
    try {
      await _kv.remove(keyFor(destPath));
    } catch (_) {}
  }

  @override
  Future<List<ResumeRecord>> listIncomplete({String? root}) async {
    final records = <ResumeRecord>[];
    Map<String, String> all;
    try {
      all = await _kv.readAll(prefix: keyPrefix);
    } catch (_) {
      return records;
    }
    for (final entry in all.entries) {
      if (!entry.key.startsWith(keyPrefix)) continue;
      try {
        final json = jsonDecode(entry.value);
        if (json is! Map<String, dynamic>) continue;
        final destPath = json['destPath'] as String?;
        if (destPath == null || destPath.isEmpty) continue;
        // 目标文件已被删除（用户手动清理或换了保存位置），状态也一并丢掉。
        if (!await File(destPath).exists()) {
          try {
            await _kv.remove(entry.key);
          } catch (_) {}
          continue;
        }
        records.add(ResumeRecord(destPath, json));
      } catch (_) {}
    }
    return records;
  }
}
