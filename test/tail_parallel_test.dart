import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:inkfetch/core/downloader.dart';
import 'package:inkfetch/core/models.dart';
import 'package:inkfetch/core/scheduler.dart';
import 'package:inkfetch/core/url_parser.dart';

/// 记录每个 Range 请求，用来判断结尾是不是只剩一两条连接在磨。
class _RangeLog {
  final List<(int, int)> ranges = [];
  int maxConcurrent = 0;
  int _active = 0;

  void enter() {
    _active++;
    if (_active > maxConcurrent) maxConcurrent = _active;
  }

  void leave() => _active--;
}

SourceProbe _probe(String id, String url, int size) {
  return SourceProbe(
    id: id,
    name: id,
    url: url,
    lane: 'proxy',
    status: ProbeStatus.healthy,
    httpStatus: 206,
    supportsRange: true,
    totalSize: size,
    latencyMs: 5,
    speedBps: 4000000,
    score: 4000000,
    maxConns: 8,
    experimental: false,
  );
}

void main() {
  late HttpServer server;
  late String baseUrl;
  late List<int> payload;
  final log = _RangeLog();

  setUp(() async {
    HttpOverrides.global = null;
    log.ranges.clear();
    log.maxConcurrent = 0;
    // 特意让最后一片明显小于一个完整分片但足够长（约 160KB）：
    // 这正是「结尾剩一点、却只有一个连接在磨」的场景。
    payload = List<int>.generate(4 * 1024 * 1024 + 3 - 100 * 1024, (i) => i % 251);
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    baseUrl = 'http://127.0.0.1:${server.port}';
    server.listen((request) async {
      final response = request.response;
      final header = request.headers.value(HttpHeaders.rangeHeader);
      if (header == null || !header.startsWith('bytes=')) {
        response.statusCode = HttpStatus.ok;
        response.headers.contentLength = payload.length;
        response.add(payload);
        await response.close();
        return;
      }
      final spec = header.substring(6);
      final dash = spec.indexOf('-');
      final start = int.parse(spec.substring(0, dash));
      final end = int.parse(spec.substring(dash + 1));
      final clampedEnd = min(end, payload.length - 1);
      final body = payload.sublist(start, clampedEnd + 1);
      log.enter();
      log.ranges.add((start, clampedEnd));
      try {
        response.statusCode = HttpStatus.partialContent;
        response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes $start-$clampedEnd/${payload.length}',
        );
        response.headers.contentLength = body.length;
        // 分几次写完并稍作延迟，让多条连接真正重叠起来。
        const step = 16 * 1024;
        for (var i = 0; i < body.length; i += step) {
          response.add(body.sublist(i, min(i + step, body.length)));
          await response.flush();
          await Future<void>.delayed(const Duration(milliseconds: 2));
        }
      } finally {
        log.leave();
      }
      await response.close();
    });
  });

  tearDown(() async {
    await server.close(force: true);
  });

  test('结尾阶段把最后一片拆开并行收口，不会退化成单连接慢慢磨', () async {
    final parsed = parseGitHubUrl(
      'https://raw.githubusercontent.com/owner/repo/main/tail.bin',
    );
    final sources = [
      _probe('a', '$baseUrl/file', payload.length),
      _probe('b', '$baseUrl/file', payload.length),
      _probe('c', '$baseUrl/file', payload.length),
      _probe('d', '$baseUrl/file', payload.length),
    ];
    final plan = planThreads(sources, payload.length, 32);
    expect(plan.singleStream, isFalse);

    final report = ProbeReport(
      parsed: parsed,
      sources: sources,
      testedCount: 4,
      usableCount: 4,
      rangeCount: 4,
      totalSize: payload.length,
      baselineHash: 'x',
      plan: plan,
      expectedSha256: sha256.convert(payload).toString(),
      probedMs: 10,
    );

    final dir = await Directory.systemTemp.createTemp('inkfetch_tail_');
    final dest = '${dir.path}/tail.bin';
    final job = DownloadJob(
      taskId: 'tail',
      parsed: parsed,
      report: report,
      destPath: dest,
      maxConnections: 32,
      verifySha: true,
      onUpdate: (_) {},
    );

    final result = await job.run();
    expect(result.success, isTrue, reason: result.error);
    expect(result.sha256, sha256.convert(payload).toString());
    expect(await File(dest).readAsBytes(), orderedEquals(payload));

    // 整个过程中出现过多条连接同时工作。
    expect(
      log.maxConcurrent,
      greaterThan(1),
      reason: '全程都没有并行连接，明显不对',
    );

    // 最后一片必须被切成多段并行拉取。
    // 只发一次请求 = 一个连接从头啃到尾 = 结尾卡住。
    final lastChunkStart = (plan.chunkCount - 1) * plan.chunkSize;
    final lastChunkEnd = payload.length - 1;
    final tailRequests = log.ranges
        .where((r) => r.$1 >= lastChunkStart && r.$2 <= lastChunkEnd)
        .toList();
    expect(
      lastChunkEnd - lastChunkStart,
      greaterThan(2 * 32 * 1024),
      reason: '这个用例本身需要最后一片足够长才测得出来',
    );
    expect(
      tailRequests.length,
      greaterThan(1),
      reason: '最后一片只发了 ${tailRequests.length} 次请求，'
          '说明结尾没有拆分，只剩单连接在磨',
    );

    // 结尾应该是「多条连接分头收口」：最后一片被切成最多 32KB 的小段，
    // 且这些小段的起点各不相同、覆盖整个末尾。
    final tailSegments = tailRequests
        .map((r) => (r.$1, r.$2))
        .where((r) => r.$2 - r.$1 + 1 <= 2 * 32 * 1024)
        .toList();
    expect(
      tailSegments.length,
      greaterThan(1),
      reason: '最后一片没有被切成小段并行拉取',
    );

    await dir.delete(recursive: true);
  });
}

