import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:inkfetch/core/downloader.dart';
import 'package:inkfetch/core/models.dart';
import 'package:inkfetch/core/scheduler.dart';
import 'package:inkfetch/core/url_parser.dart';

SourceProbe _probe(String id, String url, int size, {bool range = true}) {
  return SourceProbe(
    id: id,
    name: id,
    url: url,
    lane: 'proxy',
    status: range ? ProbeStatus.healthy : ProbeStatus.noRange,
    httpStatus: range ? 206 : 200,
    supportsRange: range,
    totalSize: size,
    latencyMs: 5,
    speedBps: 4000000,
    score: 4000000,
    maxConns: 4,
    experimental: false,
  );
}

void main() {
  late HttpServer server;
  late String baseUrl;
  final payload = List<int>.generate(3 * 1024 * 1024 + 137, (i) => i % 251);

  setUp(() async {
    HttpOverrides.global = null;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    baseUrl = 'http://127.0.0.1:${server.port}';
    server.listen((request) async {
      final response = request.response;
      switch (request.uri.path) {
        case '/file':
          final header = request.headers.value(HttpHeaders.rangeHeader);
          if (header != null && header.startsWith('bytes=')) {
            final spec = header.substring(6);
            final dash = spec.indexOf('-');
            final start = int.parse(spec.substring(0, dash));
            final end = int.parse(spec.substring(dash + 1));
            final length = payload.length;
            final clampedEnd = min(end, length - 1);
            final body = payload.sublist(start, clampedEnd + 1);
            response.statusCode = HttpStatus.partialContent;
            response.headers.set(
              HttpHeaders.contentRangeHeader,
              'bytes $start-$clampedEnd/$length',
            );
            response.headers.contentLength = body.length;
            response.add(body);
          } else {
            response.statusCode = HttpStatus.ok;
            response.headers.contentLength = payload.length;
            response.add(payload);
          }
          break;
        case '/no-range':
          response.statusCode = HttpStatus.ok;
          response.headers.contentLength = payload.length;
          response.add(payload);
          break;
        default:
          response.statusCode = HttpStatus.notFound;
          response.write('not found');
      }
      await response.close();
    });
  });

  tearDown(() async {
    await server.close(force: true);
  });

  test('Content-Range 解析', () {
    final parsed = parseContentRange('bytes 0-1023/1048576');
    expect(parsed, isNotNull);
    expect(parsed!.$1, 0);
    expect(parsed.$2, 1023);
    expect(parsed.$3, 1048576);
    expect(parseContentRange('bytes 5-9/*'), (5, 9, null));
    expect(parseContentRange('invalid'), isNull);
  });

  test('多源多线程分片下载与 SHA-256 校验', () async {
    final parsed = parseGitHubUrl(
      'https://raw.githubusercontent.com/owner/repo/main/big.bin',
    );
    final sources = [
      _probe('a', '$baseUrl/file', payload.length),
      _probe('b', '$baseUrl/file', payload.length),
    ];
    final plan = planThreads(sources, payload.length, 4);
    expect(plan.singleStream, isFalse);
    final report = ProbeReport(
      parsed: parsed,
      sources: sources,
      testedCount: 2,
      usableCount: 2,
      rangeCount: 2,
      totalSize: payload.length,
      baselineHash: 'x',
      plan: plan,
      expectedSha256: sha256.convert(payload).toString(),
      probedMs: 10,
    );

    final dir = await Directory.systemTemp.createTemp('inkfetch_it_');
    final dest = '${dir.path}/big.bin';
    final snapshots = <DownloadSnapshot>[];
    final job = DownloadJob(
      taskId: 'test',
      parsed: parsed,
      report: report,
      destPath: dest,
      maxConnections: 8,
      verifySha: true,
      onUpdate: snapshots.add,
    );

    final result = await job.run();
    expect(result.success, isTrue);
    expect(result.sha256, sha256.convert(payload).toString());
    expect(result.total, payload.length);
    final bytes = await File(dest).readAsBytes();
    expect(bytes.length, payload.length);
    expect(bytes, orderedEquals(payload));
    expect(snapshots.last.phase, DownloadPhase.completed);
    expect(snapshots.last.progress, 1.0);
    await dir.delete(recursive: true);
  });

  test('无 Range 时回退单流下载', () async {
    final parsed = parseGitHubUrl(
      'https://raw.githubusercontent.com/owner/repo/main/single.bin',
    );
    final sources = [
      _probe('single', '$baseUrl/no-range', payload.length, range: false),
    ];
    final plan = planThreads(sources, payload.length, 4);
    final report = ProbeReport(
      parsed: parsed,
      sources: sources,
      testedCount: 1,
      usableCount: 1,
      rangeCount: 0,
      totalSize: payload.length,
      baselineHash: 'x',
      plan: plan,
      expectedSha256: null,
      probedMs: 10,
    );
    final dir = await Directory.systemTemp.createTemp('inkfetch_single_');
    final dest = '${dir.path}/single.bin';
    final job = DownloadJob(
      taskId: 'single',
      parsed: parsed,
      report: report,
      destPath: dest,
      maxConnections: 4,
      verifySha: false,
      onUpdate: (_) {},
    );
    final result = await job.run();
    expect(result.success, isTrue);
    final bytes = await File(dest).readAsBytes();
    expect(bytes, orderedEquals(payload));
    await dir.delete(recursive: true);
  });

  test('分片源返回 200 时不会被误用', () async {
    final parsed = parseGitHubUrl(
      'https://raw.githubusercontent.com/owner/repo/main/big.bin',
    );
    final sources = [
      _probe('a', '$baseUrl/file', payload.length),
      _probe('bad', '$baseUrl/no-range', payload.length),
    ];
    final report = ProbeReport(
      parsed: parsed,
      sources: sources,
      testedCount: 2,
      usableCount: 2,
      rangeCount: 2,
      totalSize: payload.length,
      baselineHash: 'x',
      plan: planThreads(sources, payload.length, 4),
      expectedSha256: null,
      probedMs: 10,
    );
    final dir = await Directory.systemTemp.createTemp('inkfetch_bad_');
    final dest = '${dir.path}/mix.bin';
    final job = DownloadJob(
      taskId: 'mix',
      parsed: parsed,
      report: report,
      destPath: dest,
      maxConnections: 8,
      verifySha: false,
      onUpdate: (_) {},
    );
    final result = await job.run();
    expect(result.success, isTrue);
    final bytes = await File(dest).readAsBytes();
    expect(bytes, orderedEquals(payload));
    await dir.delete(recursive: true);
  });

  test('响应体错误时能检测出不完整文件', () async {
    final dir = await Directory.systemTemp.createTemp('inkfetch_err_');
    final dest = '${dir.path}/missing.bin';
    final parsed = parseGitHubUrl(
      'https://raw.githubusercontent.com/owner/repo/main/big.bin',
    );
    final sources = [_probe('a', '$baseUrl/missing', payload.length)];
    final report = ProbeReport(
      parsed: parsed,
      sources: sources,
      testedCount: 1,
      usableCount: 1,
      rangeCount: 1,
      totalSize: payload.length,
      baselineHash: 'x',
      plan: planThreads(sources, payload.length, 4),
      expectedSha256: null,
      probedMs: 10,
    );
    final job = DownloadJob(
      taskId: 'fail',
      parsed: parsed,
      report: report,
      destPath: dest,
      maxConnections: 4,
      verifySha: false,
      onUpdate: (_) {},
    );
    final result = await job.run();
    expect(result.success, isFalse);
    await dir.delete(recursive: true);
  });
}
