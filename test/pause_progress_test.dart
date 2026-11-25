import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:inkfetch/core/downloader.dart';
import 'package:inkfetch/core/models.dart';
import 'package:inkfetch/core/scheduler.dart';
import 'package:inkfetch/core/url_parser.dart';

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

  setUp(() async {
    HttpOverrides.global = null;
    payload = List<int>.generate(12 * 1024 * 1024 + 977, (i) => i % 251);
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
      final end = min(int.parse(spec.substring(dash + 1)), payload.length - 1);
      final body = payload.sublist(start, end + 1);
      response.statusCode = HttpStatus.partialContent;
      response.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes $start-$end/${payload.length}',
      );
      response.headers.contentLength = body.length;
      const step = 24 * 1024;
      for (var i = 0; i < body.length; i += step) {
        response.add(body.sublist(i, min(i + step, body.length)));
        await response.flush();
        await Future<void>.delayed(const Duration(milliseconds: 12));
      }
      await response.close();
    });
  });

  tearDown(() async {
    await server.close(force: true);
  });

  ProbeReport reportFor(ParsedUrl parsed, List<SourceProbe> sources, ThreadPlan plan) {
    return ProbeReport(
      parsed: parsed,
      sources: sources,
      testedCount: sources.length,
      usableCount: sources.length,
      rangeCount: sources.length,
      totalSize: payload.length,
      baselineHash: 'x',
      plan: plan,
      expectedSha256: sha256.convert(payload).toString(),
      probedMs: 10,
    );
  }

  test('中途暂停再继续，进度不回退、字节不重复统计，最终校验通过', () async {
    final parsed = parseGitHubUrl(
      'https://raw.githubusercontent.com/owner/repo/main/pause.bin',
    );
    final sources = [
      _probe('a', '$baseUrl/file', payload.length),
      _probe('b', '$baseUrl/file', payload.length),
    ];
    final plan = planThreads(sources, payload.length, 16);
    final report = reportFor(parsed, sources, plan);

    final dir = await Directory.systemTemp.createTemp('inkfetch_pause_');
    final dest = '${dir.path}/pause.bin';

    final downloaded = <int>[];
    var pauseRequested = false;
    late DownloadJob job;
    job = DownloadJob(
      taskId: 'pause',
      parsed: parsed,
      report: report,
      destPath: dest,
      maxConnections: 16,
      verifySha: true,
      onUpdate: (snapshot) {
        downloaded.add(snapshot.downloaded);
        // 下到一定程度暂停一次，等一会儿再继续。
        if (!pauseRequested &&
            snapshot.progress > 0.2 &&
            snapshot.phase == DownloadPhase.downloading) {
          pauseRequested = true;
          job.pause();
        }
      },
    );

    final running = job.run();
    // 等到暂停真正生效（由 onUpdate 触发，不靠固定延时猜）。
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (!job.isPaused && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(pauseRequested, isTrue, reason: '下载过程中应该触发过暂停');
    expect(job.isPaused, isTrue, reason: '应该已经暂停');
    final exportedAtPause = downloaded.last;
    await Future<void>.delayed(const Duration(milliseconds: 150));
    job.resume();

    final result = await running;
    expect(result.success, isTrue, reason: result.error);
    expect(result.sha256, sha256.convert(payload).toString());
    expect(await File(dest).readAsBytes(), orderedEquals(payload));

    // 暂停期间进度不该继续涨，恢复后也不该回退。
    expect(downloaded.last, greaterThanOrEqualTo(exportedAtPause));
    // 总进度不应该超过文件大小（重复统计会冲破这个上界）。
    expect(downloaded.every((d) => d <= payload.length), isTrue);
    // 最后一次报告应正好等于文件大小。
    expect(downloaded.last, payload.length);

    await dir.delete(recursive: true);
  });

  test('末尾分片被抢尾后，总进度仍然精确等于文件大小', () async {
    final parsed = parseGitHubUrl(
      'https://raw.githubusercontent.com/owner/repo/main/tail.bin',
    );
    final sources = [
      _probe('a', '$baseUrl/file', payload.length),
      _probe('b', '$baseUrl/file', payload.length),
      _probe('c', '$baseUrl/file', payload.length),
    ];
    final plan = planThreads(sources, payload.length, 24);
    final report = reportFor(parsed, sources, plan);

    final dir = await Directory.systemTemp.createTemp('inkfetch_tailcnt_');
    final dest = '${dir.path}/tail.bin';
    final seen = <int>[];
    final job = DownloadJob(
      taskId: 'tailcnt',
      parsed: parsed,
      report: report,
      destPath: dest,
      maxConnections: 24,
      verifySha: true,
      onUpdate: (s) => seen.add(s.downloaded),
    );
    final result = await job.run();
    expect(result.success, isTrue, reason: result.error);
    expect(seen.last, payload.length);
    expect(seen.every((d) => d <= payload.length), isTrue);
    await dir.delete(recursive: true);
  });
}



