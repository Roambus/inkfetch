import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';

import 'mirrors.dart';
import 'models.dart';
import 'scheduler.dart';

class ProbeOptions {
  final int probeBytes;
  final int concurrency;
  final Duration timeout;
  final int maxTotalConnections;

  const ProbeOptions({
    this.probeBytes = 128 * 1024,
    this.concurrency = 48,
    this.timeout = const Duration(seconds: 3),
    this.maxTotalConnections = 32,
  });
}

SourceProbe _failedProbe(
  SourceCandidate candidate,
  String message, [
  int? status,
]) {
  return SourceProbe(
    id: candidate.id,
    name: candidate.name,
    url: candidate.url,
    lane: candidate.lane,
    status: ProbeStatus.failed,
    httpStatus: status,
    supportsRange: false,
    latencyMs: 0,
    speedBps: 0,
    score: 0,
    maxConns: candidate.maxConns,
    error: message,
    experimental: candidate.experimental,
  );
}

bool _looksLikeHtml(List<int> bytes) {
  final head = utf8
      .decode(bytes.take(160).toList(), allowMalformed: true)
      .toLowerCase()
      .replaceAll('\n', ' ');
  return head.startsWith('<!doctype html') ||
      head.startsWith('<html') ||
      head.contains('<html><head');
}

bool _isHtmlName(String filename) {
  final lower = filename.toLowerCase();
  return lower.endsWith('.html') || lower.endsWith('.htm');
}

Future<List<int>> _readAtMost(
  HttpClientResponse response,
  int limit,
  Duration timeout,
) async {
  final completer = Completer<List<int>>();
  final buffer = <int>[];
  StreamSubscription<List<int>>? sub;
  Timer? timer;

  void finish([Object? error]) {
    timer?.cancel();
    if (completer.isCompleted) return;
    unawaited(sub?.cancel() ?? Future<void>.value());
    if (error != null) {
      completer.completeError(error);
    } else {
      completer.complete(buffer);
    }
  }

  sub = response.listen(
    (chunk) {
      final remain = limit - buffer.length;
      if (remain <= 0) {
        finish();
        return;
      }
      buffer.addAll(chunk.length <= remain ? chunk : chunk.sublist(0, remain));
      if (buffer.length >= limit) finish();
    },
    onError: (Object error) => finish(error),
    onDone: () => finish(),
    cancelOnError: true,
  );
  timer = Timer(timeout, () => finish(TimeoutException('读取响应超时')));
  return completer.future;
}

Future<SourceProbe> _probeOne(
  SourceCandidate candidate,
  ParsedUrl parsed,
  HttpClient client,
  ProbeOptions options,
) async {
  final stopwatch = Stopwatch()..start();
  try {
    final request = await client.getUrl(Uri.parse(candidate.url));
    final rangeEnd = options.probeBytes - 1;
    request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-$rangeEnd');
    request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
    request.headers.set(HttpHeaders.userAgentHeader, 'InkFetch/1.0');
    final response = await request.close();
    final ttfb = stopwatch.elapsed;
    final status = response.statusCode;
    final contentType = response.headers.value(HttpHeaders.contentTypeHeader);
    final contentEncoding = response.headers.value(
      HttpHeaders.contentEncodingHeader,
    );
    final etag = response.headers.value(HttpHeaders.etagHeader);
    final contentLength = int.tryParse(
      response.headers.value(HttpHeaders.contentLengthHeader) ?? '',
    );
    final contentRangeRaw = response.headers.value(
      HttpHeaders.contentRangeHeader,
    );
    final contentRange = contentRangeRaw == null
        ? null
        : parseContentRange(contentRangeRaw);
    final totalSize =
        contentRange?.$3 ??
        (status == HttpStatus.partialContent ? null : contentLength);
    if (status != HttpStatus.ok && status != HttpStatus.partialContent) {
      await response.drain<void>().catchError((_) {});
      return _failedProbe(candidate, 'HTTP $status', status);
    }
    if (status == HttpStatus.partialContent && contentRange == null) {
      await response.drain<void>().catchError((_) {});
      return _failedProbe(candidate, '206 响应缺少 Content-Range，无法校验分片', status);
    }
    if (contentEncoding != null &&
        contentEncoding.toLowerCase() != 'identity') {
      await response.drain<void>().catchError((_) {});
      return _failedProbe(candidate, '镜像返回了压缩响应，无法校验分片', status);
    }
    if (contentRange != null && contentRange.$1 != 0) {
      await response.drain<void>().catchError((_) {});
      return _failedProbe(candidate, '镜像返回了错误的分片起点', status);
    }

    final limit = options.probeBytes;
    final body = await _readAtMost(response, limit, options.timeout);
    final bodyElapsed = stopwatch.elapsed - ttfb;
    if (body.isEmpty) {
      return _failedProbe(candidate, '镜像返回空响应', status);
    }
    final htmlError =
        !_isHtmlName(parsed.filename) &&
        ((contentType?.contains('text/html') ?? false) || _looksLikeHtml(body));
    if (htmlError) {
      return _failedProbe(candidate, '镜像返回了网页错误页而不是文件内容', status);
    }

    final declaredRangeLen = contentRange == null
        ? null
        : contentRange.$2 - contentRange.$1 + 1;
    final rangeConsistent =
        declaredRangeLen != null && declaredRangeLen == body.length;
    final trustedTotal = contentRange == null
        ? totalSize
        : (rangeConsistent ? contentRange.$3 : null);
    final expectedLen = contentRange == null
        ? math.min(trustedTotal ?? limit, limit)
        : math.min(
            declaredRangeLen ?? limit,
            math.min(trustedTotal ?? declaredRangeLen ?? limit, limit),
          );
    final supportsRange =
        status == HttpStatus.partialContent &&
        rangeConsistent &&
        body.length == expectedLen &&
        body.isNotEmpty;
    final bodySeconds = math.max(0.001, bodyElapsed.inMilliseconds / 1000.0);
    final speed = (body.length / bodySeconds).round();
    final latencyPenalty = math.min(0.5, (ttfb.inMilliseconds / 1000.0) * 0.35);
    final rangeFactor = supportsRange ? 1.0 : 0.42;
    final score = speed * (1 - latencyPenalty) * rangeFactor;
    final firstHash = sha256.convert(body).toString();

    return SourceProbe(
      id: candidate.id,
      name: candidate.name,
      url: candidate.url,
      lane: candidate.lane,
      status: supportsRange ? ProbeStatus.healthy : ProbeStatus.noRange,
      httpStatus: status,
      supportsRange: supportsRange,
      totalSize: trustedTotal,
      contentType: contentType,
      etag: etag,
      latencyMs: ttfb.inMilliseconds,
      speedBps: speed,
      firstHash: firstHash,
      score: score,
      maxConns: candidate.maxConns,
      experimental: candidate.experimental,
    );
  } on TimeoutException {
    return _failedProbe(candidate, '探测超时（${options.timeout.inSeconds} 秒）');
  } catch (error) {
    final message = error is SocketException ? '网络连接失败' : error.toString();
    return _failedProbe(candidate, message);
  } finally {
    stopwatch.stop();
  }
}

Future<List<SourceProbe>> _probeBatch(
  List<SourceCandidate> candidates,
  ParsedUrl parsed,
  HttpClient client,
  ProbeOptions options, {
  void Function(int done, int total)? onTick,
}) async {
  final queue = candidates.toList();
  final results = <SourceProbe>[];

  Future<void> worker() async {
    while (true) {
      if (queue.isEmpty) return;
      final candidate = queue.removeAt(0);
      SourceProbe probe;
      try {
        probe = await _probeOne(
          candidate,
          parsed,
          client,
          options,
        ).timeout(options.timeout + const Duration(seconds: 1));
      } on TimeoutException {
        probe = _failedProbe(candidate, '探测超时');
      }
      results.add(probe);
      final done = results.length;
      if (done == candidates.length || done % 8 == 0) {
        onTick?.call(done, candidates.length);
      }
    }
  }

  final workers = List.generate(
    math.min(options.concurrency, candidates.length),
    (_) => worker(),
  );
  await Future.wait(workers);
  return results;
}

SourceProbe? _chooseBaseline(List<SourceProbe> sources) {
  for (final source in sources) {
    if (source.id == 'official' &&
        source.firstHash != null &&
        source.status != ProbeStatus.failed) {
      return source;
    }
  }
  final counts = <String, (int, int?)>{};
  for (final source in sources) {
    if (source.firstHash == null || source.status == ProbeStatus.failed) {
      continue;
    }
    final entry = counts[source.firstHash!] ?? (0, source.totalSize);
    counts[source.firstHash!] = (entry.$1 + 1, entry.$2 ?? source.totalSize);
  }
  String? best;
  int bestCount = -1;
  for (final entry in counts.entries) {
    if (entry.value.$1 > bestCount) {
      bestCount = entry.value.$1;
      best = entry.key;
    }
  }
  if (best == null) return null;
  SourceProbe? match;
  for (final source in sources) {
    if (source.firstHash == best) {
      match = source;
      break;
    }
  }
  return match;
}

Future<String?> _releaseDigest(ParsedUrl parsed) async {
  if (parsed.kind != UrlKind.release) return null;
  final owner = parsed.owner;
  final repo = parsed.repo;
  final tag = parsed.gitRef;
  if (owner == null || repo == null || tag == null) return null;
  final client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 3)
    ..autoUncompress = true
    ..findProxy = ((uri) => HttpClient.findProxyFromEnvironment(uri));
  try {
    final url = Uri.parse(
      'https://api.github.com/repos/$owner/$repo/releases/tags/$tag',
    );
    final request = await client
        .getUrl(url)
        .timeout(const Duration(seconds: 3));
    request.headers.set(
      HttpHeaders.acceptHeader,
      'application/vnd.github+json',
    );
    request.headers.set(HttpHeaders.userAgentHeader, 'InkFetch');
    final response = await request.close().timeout(const Duration(seconds: 3));
    if (response.statusCode != HttpStatus.ok) {
      await response.drain<void>();
      return null;
    }
    final body = await utf8.decoder
        .bind(response)
        .join()
        .timeout(const Duration(seconds: 3));
    final json = jsonDecode(body);
    if (json is! Map<String, dynamic>) return null;
    final assets = json['assets'];
    if (assets is! List) return null;
    for (final asset in assets) {
      if (asset is! Map<String, dynamic>) continue;
      if (asset['name'] != parsed.filename) continue;
      final digest = asset['digest'];
      if (digest is String && digest.startsWith('sha256:')) {
        return digest.substring(7);
      }
    }
    return null;
  } catch (_) {
    return null;
  } finally {
    client.close(force: true);
  }
}

/// 分层探测：先测常用镜像，可用分片源不足时才扩展到长尾与实验源，
/// 避免每次都为 100 多个镜像各花掉一份采样流量。
Future<ProbeReport> probeSources(
  ParsedUrl parsed,
  ProbeOptions options, {
  List<String> disabledMirrors = const [],
  void Function(String message)? onProgress,
}) async {
  final started = Stopwatch()..start();
  final candidates = buildCandidates(parsed, disabledMirrors);
  if (candidates.isEmpty) {
    throw StateError('该链接没有可用的下载源');
  }
  final client = HttpClient()
    ..connectionTimeout = options.timeout
    ..autoUncompress = false
    ..idleTimeout = const Duration(seconds: 15)
    ..userAgent = 'InkFetch/2.0.0'
    ..findProxy = ((uri) => HttpClient.findProxyFromEnvironment(uri));

  const curatedLimit = 16;
  const maxProbed = 48;
  const enoughRangeSources = 4;

  final sources = <SourceProbe>[];
  try {
    final digestFuture = _releaseDigest(parsed);

    final curated = candidates
        .where((c) => !c.experimental && c.priority <= 40)
        .take(curatedLimit)
        .toList();
    final curatedIds = curated.map((c) => c.id).toSet();
    final standard = candidates
        .where((c) => !curatedIds.contains(c.id) && !c.experimental)
        .toList();
    final experimental = candidates
        .where((c) => !curatedIds.contains(c.id) && c.experimental)
        .toList();
    final tiers = [curated, standard, experimental];

    var probed = 0;
    for (var tier = 0; tier < tiers.length; tier++) {
      final remaining = maxProbed - probed;
      if (remaining <= 0) break;
      final batch = tiers[tier].take(remaining).toList();
      if (batch.isEmpty) continue;
      probed += batch.length;
      onProgress?.call(
        '正在测试镜像（第 ${tier + 1} 层，共 ${batch.length} 个）…',
      );
      sources.addAll(
        await _probeBatch(
          batch,
          parsed,
          client,
          options,
          onTick: (done, total) =>
              onProgress?.call('正在测试镜像（第 ${tier + 1} 层）$done/$total…'),
        ),
      );
      final healthy = sources
          .where((s) => s.status == ProbeStatus.healthy && s.supportsRange)
          .length;
      if (healthy >= enoughRangeSources) break;
    }

    onProgress?.call('正在校验各镜像文件一致性…');
    final expectedSha = await digestFuture;

    final baseline = _chooseBaseline(sources);
    if (baseline != null) {
      for (final source in sources) {
        if (source.firstHash == null) continue;
        final sizeOk =
            source.totalSize == null ||
            baseline.totalSize == null ||
            source.totalSize == baseline.totalSize;
        final ok = source.firstHash == baseline.firstHash && sizeOk;
        source.identityOk = ok;
        if (!ok) {
          source.status = ProbeStatus.failed;
          source.score = 0;
          source.error = sizeOk ? '首段内容与基准源不一致，已隔离' : '文件大小与基准源不一致，已隔离';
        }
      }
    }

    sources.sort((a, b) {
      int rank(ProbeStatus status) => switch (status) {
        ProbeStatus.healthy => 0,
        ProbeStatus.noRange => 1,
        ProbeStatus.failed => 2,
      };
      final byRank = rank(a.status).compareTo(rank(b.status));
      if (byRank != 0) return byRank;
      return b.score.compareTo(a.score);
    });

    int? firstKnownSize;
    if (baseline?.totalSize != null) {
      firstKnownSize = baseline!.totalSize;
    } else {
      for (final source in sources) {
        if (source.status != ProbeStatus.failed && source.totalSize != null) {
          firstKnownSize = source.totalSize;
          break;
        }
      }
    }
    final totalSize = firstKnownSize;
    final usableCount = sources
        .where((s) => s.usable && s.status != ProbeStatus.failed)
        .length;
    final rangeCount = sources
        .where(
          (s) => s.usable && s.status == ProbeStatus.healthy && s.supportsRange,
        )
        .length;
    final plan = planThreads(sources, totalSize, options.maxTotalConnections);

    return ProbeReport(
      parsed: parsed,
      sources: sources,
      testedCount: sources.length,
      usableCount: usableCount,
      rangeCount: rangeCount,
      totalSize: totalSize,
      baselineHash: baseline?.firstHash,
      plan: plan,
      expectedSha256: expectedSha,
      probedMs: started.elapsed.inMilliseconds,
    );
  } finally {
    client.close(force: true);
  }
}
