import 'package:flutter_test/flutter_test.dart';
import 'package:octofetch/core/mirrors.dart';
import 'package:octofetch/core/models.dart';
import 'package:octofetch/core/scheduler.dart';
import 'package:octofetch/core/url_parser.dart';

SourceProbe _source(String id, int speed, int maxConns, bool range) {
  return SourceProbe(
    id: id,
    name: id,
    url: 'https://example.com/$id',
    lane: 'proxy',
    status: range ? ProbeStatus.healthy : ProbeStatus.noRange,
    httpStatus: 206,
    supportsRange: range,
    totalSize: 1000000000,
    latencyMs: 80,
    speedBps: speed,
    score: speed.toDouble(),
    maxConns: maxConns,
    experimental: false,
  );
}

void main() {
  group('调度算法', () {
    test('按文件大小决定基础连接数', () {
      expect(totalConnectionsFor(500000, 32), 4);
      expect(totalConnectionsFor(2000000, 32), 16);
      expect(totalConnectionsFor(10000000, 32), 32);
      expect(totalConnectionsFor(100000000, 32), 32);
      expect(totalConnectionsFor(100000000, 48), 40);
      expect(totalConnectionsFor(1000000000, 48), 48);
      expect(totalConnectionsFor(4000000000, 48), 48);
      expect(totalConnectionsFor(1000000000, 8), 8);
    });

    test('加权分配连接', () {
      expect(allocate(16, [3.0, 2.0, 1.0, 0.5], [8, 8, 8, 8]), [7, 5, 3, 1]);
    });

    test('分配遵守单站上限', () {
      final quotas = allocate(16, [10.0, 2.0, 1.0], [4, 6, 6]);
      expect(quotas.reduce((a, b) => a + b), 16);
      expect(quotas, [4, 6, 6]);
    });

    test('大文件多源计划', () {
      final plan = planThreads(
        [
          _source('a', 3000000, 8, true),
          _source('b', 2000000, 6, true),
          _source('c', 1000000, 4, true),
          _source('d', 500000, 4, true),
        ],
        1000000000,
        16,
      );
      expect(plan.totalConnections, 16);
      expect(plan.sites.first.connections, 7);
      expect(plan.sites.length, 4);
      expect(plan.singleStream, isFalse);
      expect(plan.chunkCount, greaterThan(0));
    });

    test('最多选择 8 个源并跑满连接', () {
      final sources = [
        for (var i = 0; i < 12; i++)
          _source('s$i', 2000000 - i * 10000, 6, true),
      ];
      final plan = planThreads(sources, 1000000000, 48);
      expect(plan.sites.length, 8);
      expect(plan.totalConnections, 48);
    });

    test('无分片源回退单流', () {
      final plan = planThreads(
        [_source('only', 2000000, 6, false)],
        100000000,
        16,
      );
      expect(plan.singleStream, isTrue);
      expect(plan.totalConnections, 1);
      expect(plan.chunkCount, 1);
    });

    test('没有可用源时计划为空', () {
      final plan = planThreads(const [], 100, 16);
      expect(plan.totalConnections, 0);
      expect(plan.sites, isEmpty);
    });

    test('分片大小受限', () {
      final small = chunkSizeFor(2000000, 2);
      expect(small, greaterThanOrEqualTo(kMinChunk));
      final large = chunkSizeFor(2000000000, 16);
      expect(large, lessThanOrEqualTo(kMaxChunk));
      final huge = chunkSizeFor(20000000000, 16);
      expect(
        (20000000000 + huge - 1) ~/ huge,
        lessThanOrEqualTo(kMaxChunkCount),
      );
    });

    test('过滤明显过慢的源，避免拖慢尾段', () {
      final plan = planThreads(
        [
          _source('a', 10000000, 6, true),
          _source('b', 8000000, 6, true),
          _source('c', 6000000, 6, true),
          _source('d', 5000000, 6, true),
          _source('e', 3000000, 6, true),
          _source('slow', 30000, 6, true),
        ],
        1000000000,
        48,
      );
      expect(plan.sites.any((s) => s.id == 'slow'), isFalse);
      expect(plan.sites.length, 5);
    });
  });

  group('镜像候选', () {
    test('raw 文件获得官方、CDN 与代理', () {
      final parsed = parseGitHubUrl(
        'https://raw.githubusercontent.com/owner/repo/main/src/main.rs',
      );
      final list = buildCandidates(parsed, const []);
      expect(list.any((c) => c.id == 'official'), isTrue);
      expect(list.any((c) => c.id == 'jsdelivr-cdn'), isTrue);
      expect(list.any((c) => c.id == 'ghproxy'), isTrue);
      expect(
        list.any(
          (c) =>
              c.url ==
              'https://cdn.jsdelivr.net/gh/owner/repo@main/src/main.rs',
        ),
        isTrue,
      );
      expect(list.any((c) => c.id == 'official-codeload'), isFalse);
    });

    test('Release 不使用 jsDelivr', () {
      final parsed = parseGitHubUrl(
        'https://github.com/owner/repo/releases/download/v1.0/app.zip',
      );
      final list = buildCandidates(parsed, const []);
      expect(list.any((c) => c.id == 'official'), isTrue);
      expect(list.any((c) => c.id.startsWith('jsdelivr')), isFalse);
      expect(list.any((c) => c.lane == 'proxy'), isTrue);
      expect(list.any((c) => c.id == 'kkgithub'), isTrue);
    });

    test('归档获得 codeload', () {
      final parsed = parseGitHubUrl(
        'https://github.com/owner/repo/archive/refs/heads/main.zip',
      );
      final list = buildCandidates(parsed, const []);
      expect(list.any((c) => c.id == 'official-codeload'), isTrue);
      expect(
        list.any(
          (c) =>
              c.url ==
              'https://codeload.github.com/owner/repo/zip/refs/heads/main',
        ),
        isTrue,
      );
    });

    test('禁用镜像会被移除', () {
      final parsed = parseGitHubUrl(
        'https://raw.githubusercontent.com/owner/repo/main/README.md',
      );
      final list = buildCandidates(parsed, ['jsdelivr-cdn', 'ghproxy']);
      expect(list.any((c) => c.id == 'jsdelivr-cdn'), isFalse);
      expect(list.any((c) => c.id == 'ghproxy'), isFalse);
      expect(list.any((c) => c.id == 'official'), isTrue);
    });

    test('镜像目录数量充足且包含新增镜像', () {
      expect(builtinMirrors.length, greaterThanOrEqualTo(40));
      final ids = builtinMirrors.map((m) => m.id).toSet();
      expect(ids.contains('githubproxy-cc'), isTrue);
      expect(ids.contains('gh-chjina'), isTrue);
      expect(ids.contains('tvv-tw'), isTrue);
      expect(ids.contains('fastgit-cc'), isTrue);
      expect(ids.contains('githubfast'), isTrue);
    });

    test('所有镜像 URL 唯一', () {
      final parsed = parseGitHubUrl(
        'https://github.com/owner/repo/releases/download/v1/app.zip',
      );
      final list = buildCandidates(parsed, const []);
      final urls = list.map((c) => c.url).toList();
      expect(urls.toSet().length, urls.length);
    });
  });
}
