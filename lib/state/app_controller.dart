import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../core/downloader.dart';
import '../core/format.dart';
import '../core/mirrors.dart';
import '../core/models.dart';
import '../core/platform.dart';
import '../core/probe.dart';
import '../core/resume_store.dart';
import '../core/storage.dart';
import '../core/update_check.dart';
import '../core/url_parser.dart';

class AppController extends ChangeNotifier {
  final AppStore _store = AppStore();

  /// Windows 上续传状态写注册表，其他平台仍旧写下载目录里的 `.octopart`。
  final ResumeStore _resume = defaultResumeStore();
  bool get _registryResume => _resume is RegistryResumeStore;

  AppSettings settings = AppSettings();
  List<HistoryEntry> history = [];
  bool initialized = false;
  int tabIndex = 0;

  /// 下载区内部的三个分段：0 下载、1 进行中、2 历史。
  ///
  /// 「下载 / 任务 / 记录」原本是三个顶级页，实际是一件事的三个阶段，
  /// 现在收进同一个页面用标签切换，这个字段记住当前看的是哪一段。
  int downloadSection = 0;


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

  /// 等待下载的链接队列，应用重启后仍会恢复。
  List<String> queuedUrls = [];

  /// 可以续传的未完成任务，应用重启后仍会恢复。
  List<IncompleteTask> incompleteTasks = [];

  bool copyingToFolder = false;
  double copyProgress = 0.0;

  String? _androidInternalDir;
  String? lastFolderUri;

  int noticeSeq = 0;
  String? notice;

  /// ── 版本检查状态 ────────────────────────────────────────────
  /// 启动后延迟检查一次，不阻塞首屏。结果放在这里，弹窗由 AppShell 决定。
  UpdateCheckResult? updateResult;
  bool checkingUpdate = false;

  /// 当前应该弹出来的更新：线上比本地新，且用户没跳过这个版本。
  /// 只读计算，不是存储字段——跳过状态存在 settings 里。
  UpdateCheckResult? get pendingUpdate {
    final result = updateResult;
    if (result == null || !result.hasUpdate) return null;
    if (settings.skippedVersion == result.latest) return null;
    return result;
  }

  int _taskSeq = 0;
  bool _queueRunning = false;
  bool _copyCancelled = false;
  StreamSubscription<Map<String, dynamic>>? _nativeSub;

  bool get isAndroid => NativeBridge.isAndroid;

  bool get busy => probing || downloading;

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
    _listenNativeEvents();
    try {
      final (loadedSettings, loadedHistory, loadedQueue) = await _store.load();
      settings = loadedSettings;
      history = loadedHistory;
      queuedUrls = loadedQueue;
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
    await refreshIncompleteTasks();
    // 首屏之后再查版本：它不影响任何本地功能，不该跟启动抢时间。
    unawaited(Future<void>.delayed(const Duration(seconds: 2), () async {
      if (!_disposed) await checkUpdate();
    }));
  }

  void _listenNativeEvents() {
    if (!isAndroid) return;
    _nativeSub = NativeBridge.nativeEvents.listen(
      (event) {
        if (event['type'] != 'copyProgress') return;
        final done = (event['done'] as num?)?.toDouble() ?? 0.0;
        final total = (event['total'] as num?)?.toDouble() ?? 0.0;
        copyProgress = total > 0
            ? (done / total).clamp(0.0, 1.0).toDouble()
            : 0.0;
        _safeNotify();
      },
      onError: (_) {},
    );
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

  /// 切换下载区内的分段（下载 / 进行中 / 历史）。
  void setDownloadSection(int index) {
    final clamped = index.clamp(0, 2);
    if (downloadSection == clamped) return;
    downloadSection = clamped;
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
      final tested = await probeSources(
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
      report = tested;
      reportUrl = parsedUrl.normalized;
      _probedAt = DateTime.now();
      probeMessage = '';
      if (!silent) {
        final plan = tested.plan;
        _emitNotice(
          '测试完成：${tested.usableCount} 个可用源，'
          '${plan.totalConnections} 条连接',
        );
      }
      return tested;
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

  String _newTaskId() {
    _taskSeq = (_taskSeq + 1) % 100000;
    return 'task-${DateTime.now().millisecondsSinceEpoch}-$_taskSeq';
  }

  Future<void> startDownload() async {
    if (probing) return;
    if (downloading) {
      // 正在下载时再次点击，把链接加入队列而不是直接丢弃。
      final trimmed = urlInput.trim();
      if (trimmed.isNotEmpty) _enqueue(trimmed);
      return;
    }

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

    final taskId = _newTaskId();
    final startedAt = DateTime.now();
    final filename = current.parsed.filename;

    downloading = true;
    _safeNotify();
    snapshot = DownloadSnapshot(
      taskId: taskId,
      phase: DownloadPhase.downloading,
      filename: filename,
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
    // 开始下载就切到「进行中」那一段。三页合并后不再跳顶级导航，
    // 只在同一个页面内换标签。
    downloadSection = 1;
    _safeNotify();

    String destPath;
    try {
      destPath = await _prepareDestination(filename);
    } catch (error) {
      // 不能只弹一条提示：下载状态必须切换到失败，否则界面会永远停在“下载中”。
      downloading = false;
      snapshot = snapshot?.copyWith(
        phase: DownloadPhase.failed,
        error: '无法创建下载目录：$error',
      );
      _emitNotice('无法创建下载目录：$error');
      _safeNotify();
      await refreshIncompleteTasks();
      unawaited(_startNextQueued());
      return;
    }

    snapshot = snapshot?.copyWith(destPath: destPath);
    _safeNotify();

    final job = DownloadJob(
      taskId: taskId,
      parsed: current.parsed,
      report: current,
      destPath: destPath,
      maxConnections: settings.maxConnections,
      verifySha: settings.verifySha,
      resumeStore: _resume,
      onUpdate: (value) {
        snapshot = value;
        _safeNotify();
      },
    );
    _job = job;
    lastFolderUri = settings.androidTreeUri;

    if (isAndroid) {
      unawaited(NativeBridge.startDownloadNotification(title: filename));
    }

    DownloadResult result;
    try {
      result = await job.run();
    } catch (error) {
      result = DownloadResult(
        success: false,
        cancelled: false,
        error: _friendly(error),
        destPath: destPath,
        filename: filename,
        total: current.totalSize ?? 0,
        elapsedMs: 0,
        averageSpeedBps: 0,
        sites: const [],
      );
    } finally {
      if (isAndroid) unawaited(NativeBridge.stopDownloadNotification());
      _job = null;
    }

    var finalPath = destPath;
    String? savedUri;
    var saveNote = result.error;

    if (result.success && isAndroid && settings.androidTreeUri != null) {
      _copyCancelled = false;
      copyingToFolder = true;
      copyProgress = 0.0;
      _safeNotify();
      SavedFile? saved;
      try {
        saved = await NativeBridge.saveToTree(
          srcPath: destPath,
          treeUri: settings.androidTreeUri!,
          fileName: filename,
        );
      } finally {
        copyingToFolder = false;
        copyProgress = 0.0;
      }
      if (saved != null) {
        finalPath = '${settings.androidTreeName ?? '已选文件夹'}/${saved.name}';
        savedUri = saved.uri;
        try {
          await File(destPath).delete();
        } catch (_) {}
      } else if (_copyCancelled) {
        saveNote = '已取消复制，文件保留在应用目录';
        _emitNotice(saveNote);
      } else {
        saveNote = '复制到所选文件夹失败，文件暂存在应用目录';
        _emitNotice(saveNote);
      }
    }

    final completed = result.success;
    final entry = HistoryEntry(
      taskId: taskId,
      filename: filename,
      url: current.parsed.normalized,
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
      createdAt: startedAt,
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
        shaVerified: result.shaVerified,
      );
    }
    downloading = false;
    if (result.cancelled) {
      _emitNotice('下载已取消，未完成的分片已保留，可在下方继续');
    } else if (completed) {
      _emitNotice(
        '下载完成：${humanBytes(result.total)}，'
        '${humanSpeed(result.averageSpeedBps)}',
      );
    } else {
      _emitNotice(result.error ?? '下载失败');
    }
    _safeNotify();

    await refreshIncompleteTasks();
    unawaited(_startNextQueued());
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
    if (await _hasResume(candidate)) {
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

  /// 目标路径上是否已有可续传状态：注册表实现查键，文件实现查 `.octopart`。
  Future<bool> _hasResume(String destPath) async {
    return await _resume.load(destPath) != null;
  }

  void _enqueue(String url) {
    final trimmed = url.trim();
    if (trimmed.isEmpty) return;
    if (queuedUrls.contains(trimmed)) {
      _emitNotice('该链接已在下载队列中');
      return;
    }
    if (!queuedUrls.contains(trimmed)) {
      queuedUrls.add(trimmed);
      unawaited(_store.saveQueue(queuedUrls));
      _emitNotice('已加入下载队列（第 ${queuedUrls.length} 个）');
    }
  }

  Future<void> _startNextQueued() async {
    if (_queueRunning || downloading || probing || queuedUrls.isEmpty) return;
    _queueRunning = true;
    try {
      while (queuedUrls.isNotEmpty && !downloading && !_disposed) {
        final next = queuedUrls.removeAt(0);
        unawaited(_store.saveQueue(queuedUrls));
        urlInput = next;
        report = null;
        reportUrl = null;
        parsed = null;
        probeError = null;
        probeMessage = '';
        _safeNotify();
        await startDownload();
      }
    } finally {
      _queueRunning = false;
      _safeNotify();
    }
  }

  Future<void> cancelQueued(int index) async {
    if (index < 0 || index >= queuedUrls.length) return;
    final removed = queuedUrls.removeAt(index);
    await _store.saveQueue(queuedUrls);
    _emitNotice('已移出队列：${_basename(removed)}');
  }

  Future<void> clearQueue() async {
    if (queuedUrls.isEmpty) return;
    queuedUrls.clear();
    await _store.saveQueue(queuedUrls);
    _emitNotice('下载队列已清空');
  }

  Future<void> refreshIncompleteTasks() async {
    final roots = <String>{};
    if (isAndroid) {
      final dir = _androidInternalDir;
      if (dir != null && dir.isNotEmpty) roots.add(dir);
    } else {
      final dir = settings.downloadDir;
      if (dir != null && dir.isNotEmpty) roots.add(dir);
    }
    final tasks = <IncompleteTask>[];
    // Windows 上状态在注册表里，直接枚举所有 `resume.*` 键；
    // 其他平台仍旧扫下载目录里的 `.octopart` 文件。
    final records = _registryResume
        ? await _resume.listIncomplete()
        : <ResumeRecord>[
            for (final root in roots)
              ...await _resume.listIncomplete(root: root),
          ];
    for (final record in records) {
      try {
        final json = record.payload;
        final url = json['url'] as String?;
        final total = json['total'] as int? ?? 0;
        final chunkSize = json['chunkSize'] as int? ?? 0;
        final chunkCount = json['chunkCount'] as int? ?? 0;
        final completed = (json['completed'] as List<dynamic>? ?? [])
            .map((e) => (e as num).toInt())
            .toList();
        if (url == null || url.isEmpty || total <= 0) continue;
        final destPath = record.destPath;
        // 下载过程中的临时状态文件也属于未完成任务，但当前任务单独展示。
        tasks.add(
          IncompleteTask(
            url: url,
            destPath: destPath,
            filename: _basename(destPath),
            total: total,
            downloaded: _completedBytes(completed, chunkSize, total),
            chunkCount: chunkCount,
            completedChunks: completed.length,
          ),
        );
      } catch (_) {}
    }
    tasks.sort((a, b) => a.filename.compareTo(b.filename));
    incompleteTasks = tasks;
    _safeNotify();
  }

  int _completedBytes(List<int> indexes, int chunkSize, int total) {
    if (chunkSize <= 0) return 0;
    var sum = 0;
    for (final index in indexes) {
      final start = index * chunkSize;
      if (start >= total) continue;
      sum += math.min(chunkSize, total - start);
    }
    return sum;
  }

  Future<void> resumeIncomplete(IncompleteTask task) async {
    if (downloading) {
      _enqueue(task.url);
      return;
    }
    urlInput = task.url;
    report = null;
    reportUrl = null;
    parsed = null;
    probeError = null;
    probeMessage = '';
    _safeNotify();
    await startDownload();
  }

  Future<void> deleteIncomplete(IncompleteTask task) async {
    if (downloading) return;
    try {
      await File(task.destPath).delete();
    } catch (_) {}
    await _resume.remove(task.destPath);
    await refreshIncompleteTasks();
    _emitNotice('已删除未完成文件');
  }

  Future<void> deleteCurrentPartial() async {
    if (downloading) return;
    final current = snapshot;
    if (current == null || current.destPath.isEmpty) return;
    final path = current.destPath;
    try {
      await File(path).delete();
    } catch (_) {}
    await _resume.remove(path);
    snapshot = null;
    await refreshIncompleteTasks();
    _emitNotice('已删除未完成文件');
  }

  Future<void> cancelFolderCopy() async {
    if (!isAndroid || !copyingToFolder) return;
    _copyCancelled = true;
    await NativeBridge.cancelFolderCopy();
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

  /// ── 版本检查 ────────────────────────────────────────────────

  /// 检查线上版本。
  ///
  /// 不 await 在首屏路径上：网络慢的时候不能让窗口空着等一个 JSON。
  /// 失败什么也不做——用户开的是下载器，不是来排障网络连通的。
  Future<void> checkUpdate({bool manual = false}) async {
    if (checkingUpdate) return;
    checkingUpdate = true;
    if (manual) {
      _emitNotice('正在检查更新…');
    }
    _safeNotify();
    try {
      final result = await checkForUpdate();
      updateResult = result;
      if (result.ok) {
        settings.lastUpdateCheck = DateTime.now().toIso8601String();
        await _store.saveSettings(settings);
        if (manual) {
          if (result.hasUpdate) {
            _emitNotice('发现新版本 ${result.latest}');
          } else {
            _emitNotice('已是最新版本 ${result.current}');
          }
        }
      } else if (manual) {
        _emitNotice('检查更新失败，请稍后再试');
      }
    } finally {
      checkingUpdate = false;
      _safeNotify();
    }
  }

  /// 用户选择「跳过这个版本」。只跳过当前这一个，下个版本仍会提示。
  Future<void> skipUpdateVersion() async {
    final result = updateResult;
    if (result == null) return;
    settings.skippedVersion = result.latest;
    await _store.saveSettings(settings);
    _safeNotify();
  }

  /// 清掉跳过记录，下次启动会重新提示（设置页「恢复更新提示」用）。
  Future<void> clearSkippedVersion() async {
    settings.skippedVersion = null;
    await _store.saveSettings(settings);
    _safeNotify();
  }

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

  String _basename(String path) {
    final slash = path.lastIndexOf(Platform.pathSeparator);
    final alt = path.lastIndexOf('/');
    final index = math.max(slash, alt);
    return index < 0 ? path : path.substring(index + 1);
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
    unawaited(_nativeSub?.cancel() ?? Future<void>.value());
    super.dispose();
  }
}
