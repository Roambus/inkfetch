import 'dart:math' as math;

import 'models.dart';

const int kMinChunk = 256 * 1024;
const int kMaxChunk = 1024 * 1024;
const int kMaxSites = 8;
const int kMaxTotalConnections = 48;
const int kMaxChunkCount = 8192;

int totalConnectionsFor(int size, int maxTotal) {
  final base = switch (size) {
    < 1 * 1024 * 1024 => 4,
    < 8 * 1024 * 1024 => 16,
    < 64 * 1024 * 1024 => 32,
    < 512 * 1024 * 1024 => 40,
    _ => 48,
  };
  return math.min(base, math.max(1, maxTotal));
}

int chunkSizeFor(int size, int connections) {
  if (size <= 0) return kMinChunk;
  final targetChunks = math.max(1, connections) * 6;
  var chunk = (size + targetChunks - 1) ~/ targetChunks;
  chunk = chunk.clamp(kMinChunk, kMaxChunk);
  final chunks = (size + chunk - 1) ~/ chunk;
  if (chunks > kMaxChunkCount) {
    chunk = (size + kMaxChunkCount - 1) ~/ kMaxChunkCount;
  }
  return math.max(1, chunk);
}

List<int> allocate(int total, List<double> weights, List<int> caps) {
  final n = weights.length;
  if (n == 0) return [];
  final capTotal = caps.fold<int>(0, (sum, c) => sum + c);
  final effectiveTotal = math.max(n, math.min(total, capTotal));
  final sumWeights = weights.fold<double>(
    0,
    (sum, w) => sum + (w.isFinite && w > 0 ? w : 1.0),
  );
  final normalized = weights
      .map((w) => (w.isFinite && w > 0 ? w : 1.0) / math.max(sumWeights, 1e-9))
      .toList();

  final quotas = List<int>.filled(n, 0);
  for (var i = 0; i < n; i++) {
    quotas[i] = math.min(caps[i], effectiveTotal * normalized[i]).floor();
  }

  for (var i = 0; i < n; i++) {
    if (quotas[i] == 0) {
      int victim = -1;
      for (var j = 0; j < n; j++) {
        if (j != i &&
            quotas[j] > 1 &&
            (victim == -1 || quotas[j] > quotas[victim])) {
          victim = j;
        }
      }
      if (victim != -1) {
        quotas[victim] -= 1;
        quotas[i] = 1;
      } else {
        quotas[i] = math.min(quotas[i], caps[i]);
      }
    }
  }

  var assigned = quotas.fold<int>(0, (a, b) => a + b);
  while (assigned < effectiveTotal) {
    int? best;
    double bestDeficit = double.negativeInfinity;
    for (var i = 0; i < n; i++) {
      if (quotas[i] >= caps[i]) continue;
      final deficit = effectiveTotal * normalized[i] - quotas[i];
      if (deficit > bestDeficit) {
        bestDeficit = deficit;
        best = i;
      }
    }
    if (best == null) break;
    quotas[best] += 1;
    assigned += 1;
  }

  assigned = quotas.fold<int>(0, (a, b) => a + b);
  while (assigned > effectiveTotal) {
    int? smallest;
    for (var i = 0; i < n; i++) {
      if (quotas[i] > 1 && (smallest == null || quotas[i] < quotas[smallest])) {
        smallest = i;
      }
    }
    if (smallest == null) break;
    quotas[smallest] -= 1;
    assigned -= 1;
  }
  return quotas;
}

bool _usable(SourceProbe source) =>
    source.usable && source.status != ProbeStatus.failed;

ThreadPlan planThreads(
  List<SourceProbe> sources,
  int? totalSize,
  int maxTotal,
) {
  final size = totalSize ?? 0;
  final rangeSources = sources
      .where((s) => _usable(s) && s.supportsRange)
      .toList();

  if (rangeSources.isEmpty) {
    SourceProbe? fallback;
    for (final source in sources) {
      if (!_usable(source)) continue;
      if (fallback == null || source.score > fallback.score) {
        fallback = source;
      }
    }
    if (fallback != null) {
      return ThreadPlan(
        totalConnections: 1,
        chunkSize: size > 0 ? size : kMinChunk,
        chunkCount: size > 0 ? 1 : 0,
        sites: [
          SiteAllocation(
            id: fallback.id,
            name: fallback.name,
            url: fallback.url,
            lane: fallback.lane,
            connections: 1,
            score: fallback.score,
            speedBps: fallback.speedBps,
            maxConns: fallback.maxConns,
          ),
        ],
        singleStream: true,
        reason: size > 0 ? '可用源不支持 Range，使用单流下载' : '未获取到文件大小，使用单流下载',
      );
    }
    return const ThreadPlan(
      totalConnections: 0,
      chunkSize: 0,
      chunkCount: 0,
      sites: [],
      singleStream: false,
      reason: '没有可用下载源',
    );
  }

  rangeSources.sort((a, b) => b.score.compareTo(a.score));
  final bestScore = rangeSources.first.score;
  var candidates = rangeSources
      .where((s) => s.score >= bestScore * 0.1)
      .toList();
  final minKeep = math.min(4, rangeSources.length);
  if (candidates.length < minKeep) {
    candidates = rangeSources.take(minKeep).toList();
  }
  final total = math.min(
    kMaxTotalConnections,
    totalConnectionsFor(size, maxTotal),
  );
  var take = math.min(kMaxSites, candidates.length);
  take = math.min(take, math.max(1, total));
  final selected = candidates.take(take).toList();
  final caps = selected.map((s) => math.max(1, s.maxConns)).toList();
  final weights = selected
      .map((s) => math.max(1.0, math.max(s.score, s.speedBps * 0.1)))
      .toList();
  final quotas = allocate(total, weights, caps);
  final totalConnections = quotas.fold<int>(0, (a, b) => a + b);
  final chunkSize = chunkSizeFor(size, totalConnections);
  final chunkCount = size > 0
      ? math.min(kMaxChunkCount, (size + chunkSize - 1) ~/ chunkSize)
      : 0;

  final sites = <SiteAllocation>[];
  for (var i = 0; i < selected.length; i++) {
    final source = selected[i];
    sites.add(
      SiteAllocation(
        id: source.id,
        name: source.name,
        url: source.url,
        lane: source.lane,
        connections: quotas[i],
        score: source.score,
        speedBps: source.speedBps,
        maxConns: source.maxConns,
      ),
    );
  }

  return ThreadPlan(
    totalConnections: totalConnections,
    chunkSize: chunkSize,
    chunkCount: chunkCount,
    sites: sites,
    singleStream: false,
    reason:
        '${sites.length} 个可用源按实测速度分配 $totalConnections 条连接，分片 ${humanChunk(chunkSize)}',
  );
}

String humanChunk(int value) {
  if (value >= 1024 * 1024) {
    return '${(value / 1024 / 1024).toStringAsFixed(1)} MB';
  }
  if (value >= 1024) {
    return '${(value / 1024).toStringAsFixed(0)} KB';
  }
  return '$value B';
}
