import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../core/downloader.dart';
import '../core/format.dart';
import '../core/mirrors.dart';
import '../core/models.dart';
import '../core/platform.dart';
import '../core/probe.dart';
import '../core/storage.dart';
import '../core/url_parser.dart';

class AppController extends ChangeNotifier {
  final AppStore _store = AppStore();

  AppSettings settings = AppSettings();
  List<HistoryEntry> history = [];
  bool initialized = false;
  int tabIndex = 0;

  String urlInput = '';
  ParsedUrl? parsed;
  ProbeReport? report;
  String? reportUrl;
  bool probing = false;
  String probeMessage = '';
  String? probeError;
  DateTime? _probedAt;

  DownloadJob? _job;
  DownloadSnapshot? snapshot;
  bool downloading = false;
  bool _disposed = false;

  String? _androidInternalDir;
  String? lastFolderUri;

  int noticeSeq = 0;
  String? notice;

  bool get isAndroid => NativeBridge.isAndroid;

  bool get busy => probing || downloading;

  bool get canDownload =>
      !busy && (report != null || urlInput.trim().isNotEmpty);

  String get destinationLabel {
    if (isAndroid) {
      final tree = settings.androidTreeName;
      if (tree != null && tree.isNotEmpty) return tree;
      return '应用专属目录（建议选择保存文件夹）';
    }
    return settings.downloadDir ?? '未设置';
  }

  String? get destinationSubLabel {
    if (isAndroid) {
      if (settings.androidTreeUri != null) return '下载完成后自动复制到所选文件夹';
      return '卸载应用会删除文件，可在设置中选择文件夹';
    }
    return settings.downloadDir;
  }

  Future<void> init() async {
    try {
      final (loadedSettings, loadedHistory) = await _store.load();
      settings = loadedSettings;
      history = loadedHistory;
      if (NativeBridge.isDesktop &&
          (settings.downloadDir == null || settings.downloadDir!.isEmpty)) {
        settings.downloadDir = await NativeBridge.defaultDownloadDir();
      }
      if (isAndroid) {
        _androidInternalDir = await NativeBridge.defaultDownloadDir();
        if (_androidInternalDir == null || _androidInternalDir!.isEmpty) {
          final docs = await getApplicationDocumentsDirectory();
          _androidInternalDir = docs.path;
        }
      }
    } catch (_) {}
    initialized = true;
    _safeNotify();
  }

  void _safeNotify() {
    if (!_disposed) notifyListeners();
  }

  void _emitNotice(String message) {
    notice = message;
    noticeSeq++;
    _safeNotify();
  }

  void setTab(int index) {
    if (tabIndex == index) return;
    tabIndex = index;
    _safeNotify();
  }

  void setUrl(String value) {
    if (urlInput == value) return;
    urlInput = value;
    if (report != null && value.trim() != report!.parsed.original.trim()) {
      report = null;
      reportUrl = null;
      parsed = null;
      probeError = null;
      probeMessage = '';
    }
    _safeNotify();
  }

  Future<ProbeReport?> probe({bool silent = false, bool force = false}) async {
    if (probing || downloading) return null;
    if (!force && report != null && reportUrl != null && _probedAt != null) {
      try {
        final current = parseGitHubUrl(urlInput);
        if (current.normalized == reportUrl &&
            DateTime.now().difference(_probedAt!).inMinutes < 2) {
          if (!silent) _emitNotice('已使用最近 2 分钟的测试结果');
          return report;
        }
      } catch (_) {}
    }
    probeError = null;
    report = null;
    reportUrl = null;
    parsed = null;
    probeMessage = '正在解析链接…';
    probing = true;
    _safeNotify();

    try {
      final parsedUrl = parseGitHubUrl(urlInput);
      parsed = parsedUrl;
      _safeNotify();
      final outcome = await probeSources(
        parsedUrl,
        ProbeOptions(
          maxTotalConnections: settings.maxConnections,
          probeBytes: settings.deepProbeAll ? 1024 * 1024 : 128 * 1024,
        ),
        disabledMirrors: settings.disabledMirrors,
        onProgress: (message) {
          probeMessage = message;
          _safeNotify();
        },
      );
      report = outcome.report;
      reportUrl = parsedUrl.normalized;
      _probedAt = DateTime.now();
      probeMessage = '';
      if (!silent) {
        final plan = outcome.report.plan;
        _emitNotice(
          '测试完成：${outcome.report.usableCount} 个可用源，'
          '${plan.totalConnections} 条连接',
        );
      }
      return outcome.report;
    } catch (error) {
      probeError = error is UrlParseException
          ? error.message
          : _friendly(error);
      probeMessage = '';
      if (!silent) _emitNotice(probeError!);
      return null;
    } finally {
      probing = false;
      _safeNotify();
    }
  }

  Future<void> startDownload() async {
    if (downloading || probing) return;
    ProbeReport? current = report;
    if (current == null || reportUrl != parsed?.normalized) {
      current = await probe(silent: true);
      if (current == null) {
        _emitNotice(probeError ?? '请先输入有效的 GitHub 链接');
        return;
      }
    }
    if (current.plan.totalConnections == 0 || current.plan.sites.isEmpty) {
      _emitNotice('没有可用下载源，请稍后重试或关闭部分镜像限制');
      return;
    }

    downloading = true;
    _safeNotify();
    snapshot = DownloadSnapshot(
      taskId: 'task-${DateTime.now().millisecondsSinceEpoch}',
      phase: DownloadPhase.downloading,
      filename: current.parsed.filename,
      destPath: '',
      downloaded: 0,
      total: current.totalSize ?? 0,
      speedBps: 0,
      etaSecs: null,
      elapsedMs: 0,
      sites: current.plan.sites
          .map(
            (s) => SiteProgress(
              id: s.id,
              name: s.name,
              lane: s.lane,
              connections: s.connections,
            ),
          )
          .toList(),
      chunkMap: List<int>.filled(current.plan.chunkCount, 0),
      chunkSize: current.plan.chunkSize,
      sha256: null,
      error: null,
      savedUri: null,
      progress: 0,
    );
    tabIndex = 1;
    _safeNotify();

    String destPath;
    try {
      destPath = await _prepareDestination(current.parsed.filename);
    } catch (error) {
      downloading = false;
      _emitNotice('无法创建下载目录：$error');
      _safeNotify();
      return;
    }

    final taskId = 'task-${DateTime.now().millisecondsSinceEpoch}';
    final job = DownloadJob(
      taskId: taskId,
      parsed: current.parsed,
      report: current,
      destPath: destPath,
      maxConnections: settings.maxConnections,
      verifySha: settings.verifySha,
      onUpdate: (value) {
        snapshot = value;
        _safeNotify();
      },
    );
    _job = job;
    lastFolderUri = settings.androidTreeUri;

    DownloadResult result;
    try {
      result = await job.run();
    } catch (error) {
      result = DownloadResult(
        success: false,
        cancelled: false,
        error: _friendly(error),
        destPath: destPath,
        filename: current.parsed.filename,
        total: current.totalSize ?? 0,
        elapsedMs: 0,
        averageSpeedBps: 0,
        sites: const [],
      );
    }

    var finalPath = destPath;
    String? savedUri;
    var saveNote = result.error;
    if (result.success && isAndroid && settings.androidTreeUri != null) {
      final saved = await NativeBridge.saveToTree(
        srcPath: destPath,
        treeUri: settings.androidTreeUri!,
        fileName: current.parsed.filename,
      );
      if (saved != null) {
        finalPath = '${settings.androidTreeName ?? '已选文件夹'}/${saved.name}';
        savedUri = saved.uri;
        try {
          await File(destPath).delete();
        } catch (_) {}
      } else {
        saveNote = '复制到所选文件夹失败，文件暂存在应用目录';
        _emitNotice(saveNote);
      }
    }

    final completed = result.success;
    final entry = HistoryEntry(
      taskId: taskId,
      filename: current.parsed.filename,
      url: urlInput.trim(),
      destPath: finalPath,
      savedUri: savedUri,
      folderUri: settings.androidTreeUri,
      total: result.total,
      downloaded: result.success ? result.total : (snapshot?.downloaded ?? 0),
      speedBps: result.averageSpeedBps,
      sha256: result.sha256,
      status: result.cancelled
          ? 'cancelled'
          : (completed ? 'completed' : 'failed'),
      createdAt: DateTime.now(),
      finishedAt: DateTime.now(),
      error: result.cancelled ? null : saveNote,
    );
    history.insert(0, entry);
    if (history.length > AppStore.historyLimit) {
      history = history.sublist(0, AppStore.historyLimit);
    }
    unawaited(_store.saveHistory(history));

    if (snapshot != null) {
      snapshot = snapshot!.copyWith(
        destPath: finalPath,
        savedUri: savedUri,
        error: result.error,
      );
    }
    downloading = false;
    _job = null;
    if (result.cancelled) {
      _emitNotice('下载已取消');
    } else if (completed) {
      _emitNotice(
        '下载完成：${humanBytes(result.total)}，'
        '${humanSpeed(result.averageSpeedBps)}',
      );
    } else {
      _emitNotice(result.error ?? '下载失败');
    }
    _safeNotify();
  }

  Future<String> _prepareDestination(String filename) async {
    String root;
    if (isAndroid) {
      root = _androidInternalDir ?? settings.androidTreeUri ?? '';
      if (root.isEmpty) {
        final docs = await getApplicationDocumentsDirectory();
        root = docs.path;
      }
      await Directory(root).create(recursive: true);
      return '$root${Platform.pathSeparator}$filename';
    }
    root = settings.downloadDir ?? '';
    if (root.isEmpty) {
      root = await NativeBridge.defaultDownloadDir() ?? '';
    }
    if (root.isEmpty) {
      root = (await getApplicationDocumentsDirectory()).path;
      settings.downloadDir = root;
      unawaited(_store.saveSettings(settings));
    }
    await Directory(root).create(recursive: true);
    final base = filename;
    final dot = base.lastIndexOf('.');
    var candidate = '$root${Platform.pathSeparator}$base';
    if (await File('$candidate.octopart').exists()) {
      return candidate;
    }
    var counter = 1;
    while (await File(candidate).exists()) {
      final name = dot > 0
          ? '${base.substring(0, dot)} ($counter)${base.substring(dot)}'
          : '$base ($counter)';
      candidate = '$root${Platform.pathSeparator}$name';
      counter++;
    }
    return candidate;
  }

  void pauseDownload() {
    _job?.pause();
    _safeNotify();
  }

  void resumeDownload() {
    _job?.resume();
    _safeNotify();
  }

  void cancelDownload() {
    _job?.cancel();
    _safeNotify();
  }

  void clearTask() {
    if (downloading) return;
    snapshot = null;
    report = null;
    reportUrl = null;
    parsed = null;
    probeError = null;
    _safeNotify();
  }

  bool _firstFolderPromptDone = false;

  Future<void> promptFolderOnFirstLaunch() async {
    if (!isAndroid || !initialized || _firstFolderPromptDone) return;
    final tree = settings.androidTreeUri;
    if (tree != null && tree.isNotEmpty) return;
    _firstFolderPromptDone = true;
    await pickDownloadDirectory();
  }

  Future<void> pickDownloadDirectory() async {
    final picked = await NativeBridge.pickDirectory();
    if (picked == null) {
      _emitNotice('已取消选择');
      return;
    }
    if (isAndroid) {
      settings.androidTreeUri = picked.treeUri;
      settings.androidTreeName = picked.name;
    } else {
      settings.downloadDir = picked.path;
    }
    await _store.saveSettings(settings);
    _emitNotice('保存位置已更新');
    _safeNotify();
  }

  Future<void> resetDownloadDirectory() async {
    if (isAndroid) {
      settings.androidTreeUri = null;
      settings.androidTreeName = null;
    } else {
      settings.downloadDir = await NativeBridge.defaultDownloadDir();
    }
    await _store.saveSettings(settings);
    _emitNotice('已恢复默认保存位置');
    _safeNotify();
  }

  Future<void> setMaxConnections(int value) async {
    settings.maxConnections = value.clamp(4, 48).toInt();
    await _store.saveSettings(settings);
    _safeNotify();
  }

  Future<void> setTheme(String theme) async {
    settings.theme = theme;
    await _store.saveSettings(settings);
    _safeNotify();
  }

  Future<void> setVerifySha(bool value) async {
    settings.verifySha = value;
    await _store.saveSettings(settings);
    _safeNotify();
  }

  Future<void> setDeepProbe(bool value) async {
    settings.deepProbeAll = value;
    await _store.saveSettings(settings);
    _safeNotify();
  }

  Future<void> toggleMirror(String id, bool enabled) async {
    final disabled = settings.disabledMirrors.toList();
    if (enabled) {
      disabled.remove(id);
    } else if (!disabled.contains(id)) {
      disabled.add(id);
    }
    settings.disabledMirrors = disabled;
    await _store.saveSettings(settings);
    _safeNotify();
  }

  Future<void> resetMirrors() async {
    settings.disabledMirrors = [];
    await _store.saveSettings(settings);
    _emitNotice('镜像已全部启用');
    _safeNotify();
  }

  int get enabledMirrorCount =>
      builtinMirrors.length - settings.disabledMirrors.length;

  Future<void> clearHistory() async {
    history.clear();
    await _store.saveHistory(history);
    _emitNotice('历史记录已清空');
    _safeNotify();
  }

  Future<void> deleteHistoryEntry(HistoryEntry entry) async {
    history.removeWhere((e) => e.taskId == entry.taskId);
    await _store.saveHistory(history);
    _safeNotify();
  }

  Future<void> openHistoryFile(HistoryEntry entry) async {
    final ok = await NativeBridge.openFile(
      uri: entry.savedUri,
      path: entry.destPath,
    );
    if (!ok) _emitNotice('无法打开文件，请确认文件仍然存在');
  }

  Future<void> openHistoryFolder(HistoryEntry entry) async {
    final ok = await NativeBridge.openFolder(
      treeUri: entry.folderUri,
      path: isAndroid ? null : entry.destPath,
    );
    if (!ok) _emitNotice('无法打开文件夹');
  }

  Future<void> openCurrentFile() async {
    final current = snapshot;
    if (current == null || current.destPath.isEmpty) return;
    final ok = await NativeBridge.openFile(
      uri: current.savedUri,
      path: current.destPath,
    );
    if (!ok) _emitNotice('无法打开文件');
  }

  Future<void> openCurrentFolder() async {
    final current = snapshot;
    if (current == null) return;
    final ok = await NativeBridge.openFolder(
      treeUri: lastFolderUri,
      path: isAndroid ? null : current.destPath,
    );
    if (!ok) _emitNotice('无法打开文件夹');
  }

  String _friendly(Object error) {
    final text = error.toString();
    if (text.contains('SocketException') || text.contains('网络')) {
      return '网络连接失败，请检查网络后重试';
    }
    if (text.contains('TimeoutException')) return '请求超时，请重试';
    if (text.startsWith('Exception: ')) return text.substring(11);
    return text;
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
