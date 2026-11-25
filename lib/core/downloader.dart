import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';

import 'models.dart';
import 'resume_store.dart';
import 'scheduler.dart';

const int _maxAttempts = 9;
const int _maxSiteErrors = 4;
// 分片可以一直拆到这么小（拆完每片至少 2 倍）。结尾时连接数会从几十条
// 掉到一两条，靠「抢尾」把最后几个分片继续摊给所有空闲连接。
const int _minTailPart = 16 * 1024;
const Duration _sampleInterval = Duration(milliseconds: 300);

class _Part {
  final int chunk;
  final int start;
  /// 本片可写到哪个字节（含）。结尾时会被别的线程「抢尾」往下压。
  int end;
  /// 已写入的字节数，从 start 起算；只有持有者会改。
  int written = 0;

  _Part(this.chunk, this.start, this.end);

  int get length => end - start + 1;
  int get remaining => end - start + 1 - written;
  /// 还没写的那段是否够长，值得再对半切给空闲线程。
  bool get canSplit => remaining > 2 * _minTailPart;
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

  /// 是否与 GitHub 官方 digest 比对通过。
  final bool shaVerified;

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
    this.shaVerified = false,
  });
}

class _PauseSignal implements Exception {}

class _AbortSignal implements Exception {}

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

  /// 断点续传状态写到哪里：Windows 注入注册表实现，其他平台用默认的文件实现。
  final ResumeStore resumeStore;

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
  /// 正在被某个线程下载的分片，结尾时供空闲线程「抢尾」。
  final Set<_Part> _inFlight = {};
  final List<int> _attempts = [];

  final List<SiteAllocation> _sites = [];
  final List<SiteProgress> _siteProgress = [];
  final Map<int, SiteProgress> _progressByIndex = {};
  final Map<int, int> _passErrors = {};

  int _inflightBytes = 0;
  int _lastSampleBytes = 0;
  int _currentSpeed = 0;
  Timer? _sampleTimer;

  bool _paused = false;
  bool _abort = false;
  bool _cancelled = false;
  String? _fatalError;
  bool _verifying = false;
  bool _shaVerified = false;
  bool _resumeActive = false;
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
    this.resumeStore = const FileResumeStore(),
  });

  bool get isPaused => _paused;
  bool get running => _running;
  bool _running = false;

  void pause() {
    if (!_running) return;
    _paused = true;
    unawaited(_flushAndPersist());
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
        if (expected != null && expected.isNotEmpty) {
          if (hash.toLowerCase() != expected.toLowerCase()) {
            await _deleteResume();
            return _result(
              false,
              error: 'SHA-256 校验失败：镜像文件可能被篡改',
              sha256: hash,
            );
          }
          _shaVerified = true;
        }
      }
      _completedBytes = _total;
      _emit(DownloadPhase.completed, sha256: hash);
      await _deleteResume();
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
    final completed = await _loadResume();
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
    _resumeActive = true;

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

    final alive = <int>{for (var i = 0; i < _sites.length; i++) i};

    var pass = 0;
    while (pass < 4 && _queue.isNotEmpty && !_abort) {
      // 每轮重新启用被限流的镜像，并按本轮实测速度重新分配连接数，
      // 避免一次失败就永久丢弃某个源。
      for (final index in alive) {
        _progressByIndex[index]?.disabled = false;
      }
      _passErrors.clear();
      final workerSites = _planPassWorkers(alive);
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
        ..addAll(activeSites);
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
      if (_paused) {
        await _idleWhilePaused();
        continue;
      }
      // 队列里没有待下的分片时先试着从别人手里抢一条尾巴，
      // 抢不到才退出——否则结尾只剩一两条连接在啃最后几百 KB。
      final part = _queue.isNotEmpty ? _takePart(workerCount) : _stealTail();
      if (part == null) return;
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
      _inFlight.add(part);
      try {
        final written = await _downloadChunk(worker, part);
        _inflightBytes = math.max(0, _inflightBytes - written);
        // 只计入「本次新增」的字节：part.written 里可能已经有上一轮的进度。
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
        }
      } on _PauseSignal {
        _inflightBytes = math.max(0, _inflightBytes - worker.activeWritten);
        // 暂停前已经落盘的字节也要记账：重试/继续时会从 part.written 接着下，
        // 不再重下这一段，若不在这里入账，总进度会永远差一截。
        _creditPartial(chunkIndex, siteIndex, worker.activeWritten);
        _queue.insert(0, part);
        worker.activeChunk = -1;
        worker.activeWritten = 0;
        await _idleWhilePaused();
      } on _AbortSignal {
        return;
      } catch (error) {
        _inflightBytes = math.max(0, _inflightBytes - worker.activeWritten);
        // 同理：这次失败前写进文件的字节是有效的，要先记上。
        _creditPartial(chunkIndex, siteIndex, worker.activeWritten);
        worker.activeChunk = -1;
        worker.activeWritten = 0;
        _attempts[chunkIndex] += 1;
        _chunkMap[chunkIndex] = -1 - siteIndex;
        final progress = _progressByIndex[siteIndex]!;
        progress.errors += 1;
        progress.speedBps = 0;
        final passErrors = (_passErrors[siteIndex] ?? 0) + 1;
        _passErrors[siteIndex] = passErrors;
        // 只在本轮内停用，下一轮会重新启用并按实测速度重新配权。
        if (passErrors >= _maxSiteErrors) {
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
      } finally {
        _inFlight.remove(part);
      }
    }
  }

  /// 把「已经写进文件、但本次请求还没成功结束」的字节计入总进度。
  /// 这些字节不会因为重试被重下（part.written 会跳过它们），
  /// 所以必须在这里入账一次。
  void _creditPartial(int chunkIndex, int siteIndex, int bytes) {
    if (bytes <= 0) return;
    _completedBytes += bytes;
    _sessionBytes += bytes;
    _chunkDoneBytes[chunkIndex] = math.min(
      _chunkLength(chunkIndex),
      _chunkDoneBytes[chunkIndex] + bytes,
    );
    final progress = _progressByIndex[siteIndex];
    if (progress != null) progress.bytes += bytes;
    if (_chunkDoneBytes[chunkIndex] >= _chunkLength(chunkIndex)) {
      _completedChunkSet.add(chunkIndex);
    }
  }

  _Part _takePart(int workerCount) {
    final part = _queue.removeAt(0);
    if (_queue.length < workerCount && part.canSplit) {
      final mid = part.start + part.written + (part.remaining ~/ 2);
      _queue.insert(0, _Part(part.chunk, mid, part.end));
      // 收窄自己而不是另建一个：这样 part.written 的进度不会丢，
      // 否则重试过的分片会被从头再写一遍、字节数也会重复统计。
      part.end = mid - 1;
    }
    return part;
  }

  /// 从正在下载的分片里挑最长的一条，把它的后半段抢过来自己下。
  /// 结尾阶段队列是空的，但还有几十条连接闲着——让它们去抢尾巴，
  /// 最后那点数据才能并行收口。
  _Part? _stealTail() {
    _Part? donor;
    for (final part in _inFlight) {
      if (!part.canSplit) continue;
      if (donor == null || part.remaining > donor.remaining) donor = part;
    }
    if (donor == null) return null;
    final mid = donor.start + donor.written + (donor.remaining ~/ 2);
    final tail = _Part(donor.chunk, mid, donor.end);
    // 持有者写到这里就会停手，把后半段彻底让出来。
    donor.end = mid - 1;
    return tail;
  }

  Future<int> _downloadChunk(_WorkerState worker, _Part part) async {
    final start = part.start + part.written;
    // end 是活的：空闲线程可能在我们开始之后把后半段抢走，
    // 所以只在发请求时读一次，抢尾发生在发请求之前即可。
    final end = part.end;
    final expected = end - start + 1;
    if (expected <= 0) return 0;
    final client = _client!;
    final request = await client.getUrl(Uri.parse(worker.site.url));
    request.headers.set(HttpHeaders.rangeHeader, 'bytes=$start-$end');
    request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
    request.headers.set(HttpHeaders.userAgentHeader, 'InkFetch/1.0');
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
        : parseContentRange(contentRange);
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
        // 每块都重新读 part.end：别的线程可能已经把尾巴抢走了。
        // 注意 remain 是「这一段还剩多少」，written 是「本次已写多少」，
        // 两者不能混用。
        final remain = (part.end - start + 1) - written;
        if (remain <= 0) break;
        final take = chunk.length <= remain ? chunk : chunk.sublist(0, remain);
        final offset = start + written;
        await _writeMutex.run(() async {
          await _raf!.setPosition(offset);
          await _raf!.writeFrom(take);
        });
        written += take.length;
        part.written = (start - part.start) + written;
        worker.activeWritten = written;
        _inflightBytes += take.length;
        _chunkMap[part.chunk] = worker.siteIndex + 1;
      }
    } on TimeoutException {
      throw _ChunkFailure('读取超时，镜像连接已停滞');
    }
    // 被抢尾时提前收手是正常结束，不算数据不完整：
    // 只要 part.end 被压下来了，少写的那部分就归抢尾的线程。
    final truncated = part.end < end;
    if (!truncated && written < expected) {
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
        request.headers.set(HttpHeaders.userAgentHeader, 'InkFetch/1.0');
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
      ..userAgent = 'InkFetch/1.0'
      ..findProxy = ((uri) => HttpClient.findProxyFromEnvironment(uri));
  }

  Future<void> _idleWhilePaused() async {
    while (_paused && !_abort) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    if (_abort) throw _AbortSignal();
  }

  List<int> _planPassWorkers(Set<int> alive) {
    final indexes = alive.toList()..sort();
    if (indexes.isEmpty) return const [];
    final target = math.max(indexes.length, report.plan.totalConnections);
    final caps = [
      for (final index in indexes)
        math.max(1, math.min(maxConnections, _sites[index].maxConns)),
    ];
    final weights = [
      for (final index in indexes)
        math.max(
          1.0,
          _progressByIndex[index]!.speedBps > 0
              ? _progressByIndex[index]!.speedBps.toDouble()
              : (_sites[index].speedBps > 0
                    ? _sites[index].speedBps.toDouble()
                    : _sites[index].score),
        ),
    ];
    final quotas = allocate(target, weights, caps);
    return [
      for (var i = 0; i < indexes.length; i++)
        for (var c = 0; c < quotas[i]; c++) indexes[i],
    ];
  }

  int _chunkLength(int index) {
    final start = index * _chunkSize;
    return math.min(_chunkSize, _total - start);
  }

  Future<Set<int>> _loadResume() async {
    try {
      final json = await resumeStore.load(destPath);
      if (json == null) return <int>{};
      if (json['url'] != parsed.normalized) return <int>{};
      if (json['total'] != _total) return <int>{};
      if (json['chunkSize'] != _chunkSize) return <int>{};
      if (json['chunkCount'] != _chunkCount) return <int>{};
      return (json['completed'] as List<dynamic>? ?? [])
          .map((e) => (e as num).toInt())
          .where((index) => index >= 0 && index < _chunkCount)
          .toSet();
    } catch (_) {
      return <int>{};
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
    } catch (_) {
      return;
    }
    // 只有刷盘成功后才记录分片状态，避免重启后读到“已完成但未落盘”的分片。
    _maybePersistResume(force: true);
  }

  void _maybePersistResume({bool force = false}) {
    if (!_resumeActive) return;
    final now = DateTime.now();
    if (!force && now.difference(_lastSidecarWrite).inSeconds < 2) return;
    _lastSidecarWrite = now;
    final completed = <int>[];
    for (final index in _completedChunkSet) {
      completed.add(index);
    }
    completed.sort();
    final payload = <String, dynamic>{
      'version': 1,
      'url': parsed.normalized,
      'total': _total,
      'etag': report.sources.isNotEmpty ? report.sources.first.etag : null,
      'chunkSize': _chunkSize,
      'chunkCount': _chunkCount,
      'completed': completed,
    };
    try {
      _sidecarPending = _sidecarPending.then((_) async {
        try {
          await resumeStore.save(destPath, payload);
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
        shaVerified: _shaVerified,
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
      shaVerified: _shaVerified,
    );
  }

  Future<void> _deleteResume() async {
    // 完成或校验失败都要清干净：顺带清掉上一轮留在同一个目标路径上的旧状态。
    try {
      await resumeStore.remove(destPath);
    } catch (_) {}
  }

  /// 取消或失败后仍在磁盘上的部分文件与状态由用户显式清理。
  Future<void> _cleanupCancelled() async {
    _stopTimers();
    try {
      await _writeMutex.run(() => _raf?.flush() ?? Future<void>.value());
    } catch (_) {}
    _maybePersistResume(force: true);
    await _sidecarPending;
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
