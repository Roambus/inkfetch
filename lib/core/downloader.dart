import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';

import 'models.dart';

const int _maxAttempts = 9;
const int _maxSiteErrors = 4;
const int _minTailPart = 128 * 1024;
const Duration _sampleInterval = Duration(milliseconds: 300);

class _Part {
  final int chunk;
  final int start;
  final int end;

  const _Part(this.chunk, this.start, this.end);

  int get length => end - start + 1;
}

class DownloadResult {
  final bool success;
  final bool cancelled;
  final String? error;
  final String destPath;
  final String filename;
  final int total;
  final int elapsedMs;
  final String? sha256;
  final String? expectedSha256;
  final int averageSpeedBps;
  final List<SiteProgress> sites;

  const DownloadResult({
    required this.success,
    required this.cancelled,
    this.error,
    required this.destPath,
    required this.filename,
    required this.total,
    required this.elapsedMs,
    this.sha256,
    this.expectedSha256,
    required this.averageSpeedBps,
    required this.sites,
  });
}

class _PauseSignal implements Exception {}

class _AbortSignal implements Exception {}

(int, int, int?)? _parseContentRange(String value) {
  if (!value.startsWith('bytes ')) return null;
  final rest = value.substring(6);
  final slash = rest.indexOf('/');
  if (slash < 0) return null;
  final rangePart = rest.substring(0, slash);
  final totalPart = rest.substring(slash + 1);
  final dash = rangePart.indexOf('-');
  if (dash < 0) return null;
  final start = int.tryParse(rangePart.substring(0, dash).trim());
  final end = int.tryParse(rangePart.substring(dash + 1).trim());
  if (start == null || end == null) return null;
  final total = totalPart.trim() == '*' ? null : int.tryParse(totalPart.trim());
  return (start, end, total);
}

class _ChunkFailure implements Exception {
  final String message;
  _ChunkFailure(this.message);
  @override
  String toString() => message;
}

class AsyncMutex {
  bool _locked = false;
  final List<Completer<void>> _waiters = [];

  Future<T> run<T>(Future<T> Function() action) async {
    if (_locked) {
      final waiter = Completer<void>();
      _waiters.add(waiter);
      await waiter.future;
    }
    _locked = true;
    try {
      return await action();
    } finally {
      if (_waiters.isNotEmpty) {
        _waiters.removeAt(0).complete();
      } else {
        _locked = false;
      }
    }
  }
}

class _WorkerState {
  final int siteIndex;
  final SiteAllocation site;
  int activeChunk = -1;
  int activeWritten = 0;
  int currentStart = 0;

  _WorkerState(this.siteIndex, this.site);

  int get written => activeWritten;
}

class DownloadJob {
  final String taskId;
  final ParsedUrl parsed;
  final ProbeReport report;
  final String destPath;
  final int maxConnections;
  final bool verifySha;
  final void Function(DownloadSnapshot snapshot) onUpdate;

  final Stopwatch _clock = Stopwatch();
  HttpClient? _client;
  RandomAccessFile? _raf;
  final AsyncMutex _writeMutex = AsyncMutex();

  int _total = 0;
  int _chunkSize = 0;
  int _chunkCount = 0;
  int _completedBytes = 0;
  int _sessionBytes = 0;
  List<int> _chunkMap = [];
  final Set<int> _completedChunkSet = {};
  final List<int> _chunkDoneBytes = [];

  final List<_Part> _queue = [];
  final List<int> _attempts = [];

  final List<SiteAllocation> _sites = [];
  final List<SiteProgress> _siteProgress = [];
  final Map<int, SiteProgress> _progressByIndex = {};

  int _inflightBytes = 0;
  int _lastSampleBytes = 0;
  int _currentSpeed = 0;
  Timer? _sampleTimer;

  bool _paused = false;
  bool _abort = false;
  bool _cancelled = false;
  String? _fatalError;
  bool _verifying = false;
  String? _sidecarPath;
  Timer? _sidecarTimer;
  Future<void> _sidecarPending = Future<void>.value();
  DateTime _lastSidecarWrite = DateTime.fromMillisecondsSinceEpoch(0);

  DownloadJob({
    required this.taskId,
    required this.parsed,
    required this.report,
    required this.destPath,
    required this.maxConnections,
    required this.verifySha,
    required this.onUpdate,
  });

  bool get isPaused => _paused;
  bool get running => _running;
  bool _running = false;

  void pause() {
    if (!_running) return;
    _paused = true;
    _emit(DownloadPhase.paused);
  }

  void resume() {
    if (!_running || !_paused) return;
    _paused = false;
    _emit(DownloadPhase.downloading);
  }

  void cancel() {
    if (!_running) return;
    _cancelled = true;
    _abort = true;
    try {
      _client?.close(force: true);
    } catch (_) {}
    _emit(DownloadPhase.cancelled);
  }

  Future<DownloadResult> run() async {
    _running = true;
    _clock.start();
    final plan = report.plan;
    _total = report.totalSize ?? 0;
    _chunkSize = plan.chunkSize;
    _chunkCount = plan.chunkCount;
    _sites.addAll(plan.sites);
    _chunkMap = List<int>.filled(_chunkCount, 0);
    _chunkDoneBytes
      ..clear()
      ..addAll(List<int>.filled(_chunkCount, 0));
    _attempts.addAll(List<int>.filled(_chunkCount, 0));
    for (var i = 0; i < _sites.length; i++) {
      final progress = SiteProgress(
        id: _sites[i].id,
        name: _sites[i].name,
        lane: _sites[i].lane,
        connections: _sites[i].connections,
      );
      _siteProgress.add(progress);
      _progressByIndex[i] = progress;
    }

    _emit(DownloadPhase.downloading);

    try {
      if (_sites.isEmpty || plan.totalConnections == 0) {
        throw _ChunkFailure('没有可用下载源，无法开始下载');
      }
      if (report.plan.singleStream || _total == 0) {
        await _runSingleStream();
      } else {
        await _runChunked();
      }
      if (_cancelled) {
        return _result(false, cancelled: true, error: '下载已取消');
      }
      if (_fatalError != null) {
        return _result(false, error: _fatalError);
      }
      if (_completedBytes < _total && _total > 0) {
        return _result(false, error: '部分分片下载失败，请重试');
      }

      _raf?.closeSync();
      _raf = null;
      _stopTimers();
      await _sidecarPending;
      try {
        if (_sidecarPath != null) await File(_sidecarPath!).delete();
      } catch (_) {}

      String? hash;
      if (verifySha) {
        _verifying = true;
        _emit(DownloadPhase.verifying);
        try {
          hash = await _hashFile(destPath);
        } catch (error) {
          return _result(false, error: '校验文件失败：$error');
        }
        final expected = report.expectedSha256;
        if (expected != null &&
            expected.isNotEmpty &&
            hash.toLowerCase() != expected.toLowerCase()) {
          return _result(false, error: 'SHA-256 校验失败：镜像文件可能被篡改', sha256: hash);
        }
      }
      _completedBytes = _total;
      _emit(DownloadPhase.completed, sha256: hash);
      return _result(true, sha256: hash);
    } catch (error) {
      if (_cancelled) {
        return _result(false, cancelled: true, error: '下载已取消');
      }
      final message = _friendly(error);
      _fatalError = message;
      _emit(DownloadPhase.failed, error: message);
      return _result(false, error: message);
    } finally {
      _running = false;
      _stopTimers();
      try {
        await _raf?.close();
      } catch (_) {}
      _raf = null;
      if (_cancelled) {
        await _cleanupCancelled();
      }
      try {
        _client?.close(force: true);
      } catch (_) {}
      _client = null;
    }
  }

  Future<void> _runChunked() async {
    final file = File(destPath);
    final sidecar = _loadSidecar(file);
    final completed = sidecar?.$1 ?? <int>{};
    final resuming = completed.isNotEmpty;
    final openMode = resuming ? FileMode.append : FileMode.write;
    _raf = await file.open(mode: openMode);
    if (resuming) {
      final length = await file.length();
      if (length != _total) {
        completed.clear();
      }
    }
    await _raf!.truncate(_total);
    _sidecarPath = '$destPath.octopart';

    for (var i = 0; i < _chunkCount; i++) {
      if (completed.contains(i)) {
        _chunkMap[i] = 1;
        _completedChunkSet.add(i);
        _chunkDoneBytes[i] = _chunkLength(i);
        _completedBytes += _chunkLength(i);
      } else {
        final start = i * _chunkSize;
        _queue.add(_Part(i, start, start + _chunkLength(i) - 1));
      }
    }
    if (_queue.isEmpty) {
      return;
    }

    _client = _createClient();
    _startSampling();
    _startSidecarTimer();

    final alive = <int>[];
    for (var i = 0; i < _sites.length; i++) {
      alive.add(i);
    }

    var pass = 0;
    while (pass < 3 && _queue.isNotEmpty && !_abort) {
      final workerSites = <int>[];
      for (final siteIndex in alive) {
        final connections = math.max(
          1,
          math.min(maxConnections, _sites[siteIndex].connections),
        );
        for (var c = 0; c < connections; c++) {
          workerSites.add(siteIndex);
        }
      }
      if (workerSites.isEmpty) break;
      final workerCount = workerSites.length;
      final workers = <Future<void>>[];
      final activeSites = <int>{...alive};
      for (final siteIndex in workerSites) {
        if (_abort) break;
        workers.add(_workerLoop(siteIndex, activeSites, workerCount));
      }
      await Future.wait(workers);
      if (_abort) break;
      alive
        ..clear()
        ..addAll(activeSites.where((i) => !_siteDisabled(i)));
      pass++;
    }

    await _raf?.flush();
    if (_queue.isNotEmpty && !_cancelled) {
      throw _ChunkFailure(
        _fatalError ?? '还剩 ${_queue.length} 个分片未能完成，可能是镜像限流，请稍后重试',
      );
    }
  }

  Future<void> _workerLoop(
    int siteIndex,
    Set<int> activeSites,
    int workerCount,
  ) async {
    final worker = _WorkerState(siteIndex, _sites[siteIndex]);
    while (!_abort) {
      if (_queue.isEmpty) return;
      if (_paused) {
        await _idleWhilePaused();
        continue;
      }
      final part = _takePart(workerCount);
      final chunkIndex = part.chunk;
      final attempts = _attempts[chunkIndex];
      if (attempts >= _maxAttempts) {
        _fatalError = '分片 #$chunkIndex 重试次数过多，下载失败';
        _abort = true;
        return;
      }
      worker.activeChunk = chunkIndex;
      worker.activeWritten = 0;
      worker.currentStart = part.start;
      _chunkMap[chunkIndex] = siteIndex + 1;
      try {
        final written = await _downloadChunk(worker, part);
        _inflightBytes = math.max(0, _inflightBytes - written);
        _completedBytes += written;
        _sessionBytes += written;
        _chunkDoneBytes[chunkIndex] += written;
        _chunkMap[chunkIndex] = siteIndex + 1;
        final progress = _progressByIndex[siteIndex]!;
        progress.bytes += written;
        worker.activeChunk = -1;
        worker.activeWritten = 0;
        if (_chunkDoneBytes[chunkIndex] >= _chunkLength(chunkIndex)) {
          _completedChunkSet.add(chunkIndex);
          _maybeWriteSidecar();
        }
      } on _PauseSignal {
        _inflightBytes = math.max(0, _inflightBytes - worker.activeWritten);
        _queue.insert(0, part);
        worker.activeChunk = -1;
        worker.activeWritten = 0;
        await _idleWhilePaused();
      } on _AbortSignal {
        return;
      } catch (error) {
        _inflightBytes = math.max(0, _inflightBytes - worker.activeWritten);
        worker.activeChunk = -1;
        worker.activeWritten = 0;
        _attempts[chunkIndex] += 1;
        _chunkMap[chunkIndex] = -1 - siteIndex;
        final progress = _progressByIndex[siteIndex]!;
        progress.errors += 1;
        progress.speedBps = 0;
        if (progress.errors >= _maxSiteErrors) {
          progress.disabled = true;
          activeSites.remove(siteIndex);
          _queue.insert(0, part);
          return;
        }
        if (_attempts[chunkIndex] >= _maxAttempts) {
          _fatalError = '分片 #$chunkIndex 重试次数过多：${_friendly(error)}';
          _abort = true;
          return;
        }
        _queue.insert(0, part);
        await Future<void>.delayed(const Duration(milliseconds: 150));
      }
    }
  }

  _Part _takePart(int workerCount) {
    final part = _queue.removeAt(0);
    if (_queue.length < workerCount && part.length > 2 * _minTailPart) {
      final mid = part.start + part.length ~/ 2;
      _queue.insert(0, _Part(part.chunk, mid, part.end));
      return _Part(part.chunk, part.start, mid - 1);
    }
    return part;
  }

  Future<int> _downloadChunk(_WorkerState worker, _Part part) async {
    final start = part.start;
    final end = part.end;
    final expected = part.length;
    final client = _client!;
    final request = await client.getUrl(Uri.parse(worker.site.url));
    request.headers.set(HttpHeaders.rangeHeader, 'bytes=$start-$end');
    request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
    request.headers.set(HttpHeaders.userAgentHeader, 'OctoFetch/1.0');
    final response = await request.close().timeout(const Duration(seconds: 40));
    if (response.statusCode != HttpStatus.partialContent) {
      await response.drain<void>().catchError((_) {});
      throw _ChunkFailure('镜像未返回分片响应（HTTP ${response.statusCode}）');
    }
    final encoding = response.headers.value(HttpHeaders.contentEncodingHeader);
    if (encoding != null && encoding.toLowerCase() != 'identity') {
      await response.drain<void>().catchError((_) {});
      throw _ChunkFailure('镜像返回了压缩响应，分片数据不可信');
    }
    final contentRange = response.headers.value(HttpHeaders.contentRangeHeader);
    final parsedRange = contentRange == null
        ? null
        : _parseContentRange(contentRange);
    if (parsedRange == null ||
        parsedRange.$1 != start ||
        parsedRange.$2 != end ||
        (parsedRange.$3 != null && parsedRange.$3 != _total)) {
      await response.drain<void>().catchError((_) {});
      throw _ChunkFailure('分片范围不匹配');
    }
    final contentLength = int.tryParse(
      response.headers.value(HttpHeaders.contentLengthHeader) ?? '',
    );
    if (contentLength != null && contentLength != expected) {
      await response.drain<void>().catchError((_) {});
      throw _ChunkFailure('镜像返回了错误的响应长度');
    }

    var written = 0;
    try {
      await for (final chunk in response.timeout(const Duration(seconds: 35))) {
        if (_abort) throw _AbortSignal();
        if (_paused) throw _PauseSignal();
        if (_cancelled) throw _AbortSignal();
        if (chunk.isEmpty) continue;
        final remain = expected - written;
        if (remain <= 0) break;
        final take = chunk.length <= remain ? chunk : chunk.sublist(0, remain);
        final offset = start + written;
        await _writeMutex.run(() async {
          await _raf!.setPosition(offset);
          await _raf!.writeFrom(take);
        });
        written += take.length;
        worker.activeWritten = written;
        _inflightBytes += take.length;
        _chunkMap[part.chunk] = worker.siteIndex + 1;
        if (written >= expected) break;
      }
    } on TimeoutException {
      throw _ChunkFailure('读取超时，镜像连接已停滞');
    }
    if (written != expected) {
      throw _ChunkFailure('分片数据不完整（$written/$expected 字节）');
    }
    return written;
  }

  Future<void> _runSingleStream() async {
    _client = _createClient();
    final file = File(destPath);
    _raf = await file.open(mode: FileMode.write);
    _startSampling();
    _emit(DownloadPhase.downloading);

    final sources =
        report.sources
            .where((s) => s.usable && s.status != ProbeStatus.failed)
            .toList()
          ..sort((a, b) => b.score.compareTo(a.score));
    if (sources.isEmpty) {
      throw _ChunkFailure('没有可用下载源');
    }

    for (final source in sources) {
      if (_abort) break;
      int written = 0;
      try {
        await _raf!.setPosition(0);
        final request = await _client!.getUrl(Uri.parse(source.url));
        request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
        request.headers.set(HttpHeaders.userAgentHeader, 'OctoFetch/1.0');
        final response = await request.close().timeout(
          const Duration(seconds: 40),
        );
        if (response.statusCode != HttpStatus.ok &&
            response.statusCode != HttpStatus.partialContent) {
          await response.drain<void>().catchError((_) {});
          continue;
        }
        final encoding = response.headers.value(
          HttpHeaders.contentEncodingHeader,
        );
        if (encoding != null && encoding.toLowerCase() != 'identity') {
          await response.drain<void>().catchError((_) {});
          continue;
        }
        if (_total == 0 && response.contentLength > 0) {
          _total = response.contentLength;
        }
        await for (final chunk in response.timeout(
          const Duration(seconds: 35),
        )) {
          if (_abort) throw _AbortSignal();
          if (_paused) {
            await _idleWhilePaused();
          }
          if (chunk.isEmpty) continue;
          await _writeMutex.run(() => _raf!.writeFrom(chunk));
          written += chunk.length;
          _completedBytes = written;
          _sessionBytes = written;
        }
        if (_total > 0 && written < _total) {
          continue;
        }
        if (_total == 0) _total = written;
        return;
      } on _AbortSignal {
        rethrow;
      } catch (_) {
        continue;
      }
    }
    if (_abort && _cancelled) {
      throw _AbortSignal();
    }
    throw _ChunkFailure('所有下载源单流下载均失败');
  }

  HttpClient _createClient() {
    return HttpClient()
      ..connectionTimeout = const Duration(seconds: 20)
      ..idleTimeout = const Duration(seconds: 30)
      ..maxConnectionsPerHost = 12
      ..autoUncompress = false
      ..userAgent = 'OctoFetch/1.0'
      ..findProxy = ((uri) => HttpClient.findProxyFromEnvironment(uri));
  }

  Future<void> _idleWhilePaused() async {
    while (_paused && !_abort) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    if (_abort) throw _AbortSignal();
  }

  bool _siteDisabled(int index) => _progressByIndex[index]?.disabled ?? true;

  int _chunkLength(int index) {
    final start = index * _chunkSize;
    return math.min(_chunkSize, _total - start);
  }

  (Set<int>, String?)? _loadSidecar(File file) {
    final sidecar = File('${file.path}.octopart');
    if (!sidecar.existsSync()) return null;
    try {
      final json =
          jsonDecode(sidecar.readAsStringSync()) as Map<String, dynamic>;
      if (json['url'] != parsed.normalized) return null;
      if (json['total'] != _total) return null;
      if (json['chunkSize'] != _chunkSize) return null;
      if (json['chunkCount'] != _chunkCount) return null;
      final list = (json['completed'] as List<dynamic>? ?? [])
          .map((e) => e as int)
          .where((index) => index >= 0 && index < _chunkCount)
          .toSet();
      return (list, sidecar.path);
    } catch (_) {
      return null;
    }
  }

  void _startSidecarTimer() {
    _sidecarTimer?.cancel();
    _sidecarTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      unawaited(_flushAndPersist());
    });
  }

  Future<void> _flushAndPersist() async {
    final raf = _raf;
    if (raf == null) return;
    try {
      await _writeMutex.run(() => raf.flush());
    } catch (_) {}
    _maybeWriteSidecar(force: true);
  }

  void _maybeWriteSidecar({bool force = false}) {
    final path = _sidecarPath;
    if (path == null) return;
    final now = DateTime.now();
    if (!force && now.difference(_lastSidecarWrite).inSeconds < 2) return;
    _lastSidecarWrite = now;
    final completed = <int>[];
    for (final index in _completedChunkSet) {
      completed.add(index);
    }
    completed.sort();
    final payload = jsonEncode({
      'version': 1,
      'url': parsed.normalized,
      'total': _total,
      'etag': report.sources.isNotEmpty ? report.sources.first.etag : null,
      'chunkSize': _chunkSize,
      'chunkCount': _chunkCount,
      'completed': completed,
    });
    try {
      _sidecarPending = _sidecarPending.then((_) async {
        try {
          await File(path).writeAsString(payload, flush: false);
        } catch (_) {}
      });
    } catch (_) {}
  }

  void _startSampling() {
    _lastSampleBytes = _completedBytes;
    _sampleTimer?.cancel();
    _sampleTimer = Timer.periodic(_sampleInterval, (_) {
      final downloaded = _downloadedNow();
      final delta = downloaded - _lastSampleBytes;
      _lastSampleBytes = downloaded;
      _currentSpeed = math
          .max(0, (delta / _sampleInterval.inMilliseconds) * 1000)
          .round();
      for (var i = 0; i < _siteProgress.length; i++) {
        final progress = _siteProgress[i];
        if (progress.disabled) continue;
        final bytes = progress.bytes;
        final oldBytes = _siteLastSample[i] ?? bytes;
        _siteLastSample[i] = bytes;
        final siteSpeed = math
            .max(
              0,
              ((bytes - oldBytes) / _sampleInterval.inMilliseconds) * 1000,
            )
            .round();
        progress.speedBps = siteSpeed;
      }
      if (!_verifying && !_cancelled && _fatalError == null) {
        _emit(_paused ? DownloadPhase.paused : DownloadPhase.downloading);
      }
    });
  }

  final Map<int, int> _siteLastSample = {};

  void _stopTimers() {
    _sampleTimer?.cancel();
    _sampleTimer = null;
    _sidecarTimer?.cancel();
    _sidecarTimer = null;
  }

  int _downloadedNow() {
    return (_completedBytes + _inflightBytes)
        .clamp(0, _total > 0 ? _total : 1 << 62)
        .toInt();
  }

  void _emit(DownloadPhase phase, {String? error, String? sha256}) {
    final downloaded = _total > 0 ? _downloadedNow() : _sessionBytes;
    final elapsedMs = _clock.elapsedMilliseconds;
    final speed = _currentSpeed;
    final remaining = math.max(0, _total - downloaded);
    int? eta;
    if (speed > 0 && _total > 0) {
      eta = remaining ~/ speed;
    }
    onUpdate(
      DownloadSnapshot(
        taskId: taskId,
        phase: phase,
        filename: parsed.filename,
        destPath: destPath,
        downloaded: downloaded,
        total: _total,
        speedBps: speed,
        etaSecs: eta,
        elapsedMs: elapsedMs,
        sites: _siteProgress
            .map(
              (s) => SiteProgress(
                id: s.id,
                name: s.name,
                lane: s.lane,
                connections: s.connections,
                speedBps: s.speedBps,
                bytes: s.bytes,
                errors: s.errors,
                disabled: s.disabled,
              ),
            )
            .toList(),
        chunkMap: _chunkMap,
        chunkSize: _chunkSize,
        sha256: sha256,
        error: error ?? _fatalError,
        savedUri: null,
        progress: _total > 0
            ? (downloaded / _total).clamp(0.0, 1.0).toDouble()
            : (phase == DownloadPhase.completed ? 1.0 : 0.0),
      ),
    );
  }

  DownloadResult _result(
    bool success, {
    bool cancelled = false,
    String? error,
    String? sha256,
  }) {
    _clock.stop();
    final elapsed = _clock.elapsedMilliseconds;
    final avg = success && elapsed > 0
        ? (_total / math.max(0.001, elapsed / 1000.0)).round()
        : (_sessionBytes / math.max(0.001, elapsed / 1000.0)).round();
    return DownloadResult(
      success: success,
      cancelled: cancelled,
      error: error,
      destPath: destPath,
      filename: parsed.filename,
      total: _total,
      elapsedMs: elapsed,
      sha256: sha256,
      expectedSha256: report.expectedSha256,
      averageSpeedBps: success ? avg : 0,
      sites: _siteProgress,
    );
  }

  Future<void> _cleanupCancelled() async {
    _stopTimers();
    await _sidecarPending;
    try {
      await File(destPath).delete();
    } catch (_) {}
    try {
      if (_sidecarPath != null) await File(_sidecarPath!).delete();
    } catch (_) {}
  }

  String _friendly(Object error) {
    if (error is _ChunkFailure) return error.message;
    if (error is SocketException) return '网络连接中断';
    if (error is TimeoutException) return '下载超时';
    if (error is _AbortSignal) return '下载已中止';
    if (error is HttpException) return '镜像请求失败';
    return '下载失败：$error';
  }

  static Future<String> _hashFile(String path) async {
    return Isolate.run(() async {
      final sink = _DigestSink();
      final input = sha256.startChunkedConversion(sink);
      final file = File(path);
      await for (final chunk in file.openRead()) {
        input.add(chunk);
      }
      input.close();
      return sink.value?.toString() ?? '';
    });
  }
}

class _DigestSink implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}
