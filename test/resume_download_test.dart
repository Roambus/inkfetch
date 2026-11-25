import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:inkfetch/core/downloader.dart';
import 'package:inkfetch/core/models.dart';
import 'package:inkfetch/core/resume_store.dart';
import 'package:inkfetch/core/scheduler.dart';
import 'package:inkfetch/core/url_parser.dart';

/// 内存版续传状态，用来验证注入后下载目录里不会再出现 `.octopart`。
class MemoryResumeStore implements ResumeStore {
  final Map<String, Map<String, dynamic>> entries = {};
  int saveCount = 0;

  @override
  Future<Map<String, dynamic>?> load(String destPath) async =>
      entries[destPath];

  @override
  Future<void> save(String destPath, Map<String, dynamic> payload) async {
    saveCount++;
    entries[destPath] = Map<String, dynamic>.from(payload);
  }

  @override
  Future<void> remove(String destPath) async {
    entries.remove(destPath);
  }

  @override
  Future<List<ResumeRecord>> listIncomplete({String? root}) async => [
    for (final entry in entries.entries) ResumeRecord(entry.key, entry.value),
  ];
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
    maxConns: 4,
    experimental: false,
  );
}

ProbeReport _report(String baseUrl, int size) {
  final parsed = parseGitHubUrl(
    'https://raw.githubusercontent.com/owner/repo/main/big.bin',
  );
  final sources = [
    _probe('a', '$baseUrl/file', size),
    _probe('b', '$baseUrl/file', size),
  ];
  return ProbeReport(
    parsed: parsed,
    sources: sources,
    testedCount: 2,
    usableCount: 2,
    rangeCount: 2,
    totalSize: size,
    baselineHash: 'x',
    plan: planThreads(sources, size, 4),
    expectedSha256: null,
    probedMs: 10,
  );
}

void main() {
  late HttpServer server;
  late String baseUrl;
  late List<(int, int)> ranges;
  var responseDelayMs = 0;
  final payload = List<int>.generate(3 * 1024 * 1024 + 137, (i) => i % 251);

  setUp(() async {
    HttpOverrides.global = null;
    ranges = [];
    responseDelayMs = 0;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    baseUrl = 'http://127.0.0.1:${server.port}';
    server.listen((request) async {
      final response = request.response;
      final header = request.headers.value(HttpHeaders.rangeHeader);
      if (request.uri.path != '/file' ||
          header == null ||
          !header.startsWith('bytes=')) {
        response.statusCode = HttpStatus.notFound;
        await response.close();
        return;
      }
      final spec = header.substring(6);
      final dash = spec.indexOf('-');
      final start = int.parse(spec.substring(0, dash));
      final end = min(int.parse(spec.substring(dash + 1)), payload.length - 1);
      ranges.add((start, end));
      if (responseDelayMs > 0) {
        await Future<void>.delayed(Duration(milliseconds: responseDelayMs));
      }
      final body = payload.sublist(start, end + 1);
      response.statusCode = HttpStatus.partialContent;
      response.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes $start-$end/${payload.length}',
      );
      response.headers.contentLength = body.length;
      response.add(body);
      await response.close();
    });
  });

  tearDown(() async {
    await server.close(force: true);
  });

  test('注入内存续传状态时不写 .octopart，完成后状态清空', () async {
    final dir = await Directory.systemTemp.createTemp('inkfetch_mem_');
    final destPath = '${dir.path}${Platform.pathSeparator}big.bin';
    final report = _report(baseUrl, payload.length);
    final store = MemoryResumeStore();
    final job = DownloadJob(
      taskId: 'mem',
      parsed: report.parsed,
      report: report,
      destPath: destPath,
      maxConnections: 8,
      verifySha: true,
      resumeStore: store,
      onUpdate: (_) {},
    );

    final result = await job.run();
    expect(result.success, isTrue);
    expect(result.sha256, sha256.convert(payload).toString());
    expect(await File(destPath).readAsBytes(), orderedEquals(payload));
    // 下载目录里只剩下用户要的文件。
    final leftovers = await dir.list().map((e) => e.path).toList();
    expect(leftovers, [destPath]);
    expect(await File('$destPath.octopart').exists(), isFalse);
    // 完成后不再留可续传状态。
    expect(store.entries, isEmpty);
    await dir.delete(recursive: true);
  });

  test('中断后按注入的状态续传，只补缺失分片并校验 SHA', () async {
    final dir = await Directory.systemTemp.createTemp('inkfetch_resume_');
    final destPath = '${dir.path}${Platform.pathSeparator}big.bin';
    final report = _report(baseUrl, payload.length);
    final plan = report.plan;
    final total = payload.length;
    final chunkSize = plan.chunkSize;
    final chunkCount = plan.chunkCount;
    final done = <int>[0, 1, 5];

    // 模拟上次中断：文件已按总长度占位，只有已完成分片有数据。
    final bytes = Uint8List(total);
    for (final index in done) {
      final start = index * chunkSize;
      final end = min(start + chunkSize, total);
      bytes.setRange(start, end, payload.sublist(start, end));
    }
    await File(destPath).writeAsBytes(bytes);

    final store = MemoryResumeStore();
    await store.save(destPath, {
      'version': 1,
      'url': report.parsed.normalized,
      'total': total,
      'etag': null,
      'chunkSize': chunkSize,
      'chunkCount': chunkCount,
      'completed': done,
    });

    final job = DownloadJob(
      taskId: 'resume',
      parsed: report.parsed,
      report: report,
      destPath: destPath,
      maxConnections: 8,
      verifySha: true,
      resumeStore: store,
      onUpdate: (_) {},
    );
    final result = await job.run();

    expect(result.success, isTrue);
    expect(result.sha256, sha256.convert(payload).toString());
    expect(await File(destPath).readAsBytes(), orderedEquals(payload));

    // 只请求了缺失的分片，已完成的分片没有重新下载。
    final requested = ranges.map((r) => r.$1 ~/ chunkSize).toSet();
    expect(requested.intersection(done.toSet()), isEmpty);
    expect(requested, {
      for (var i = 0; i < chunkCount; i++)
        if (!done.contains(i)) i,
    });
    expect(await File('$destPath.octopart').exists(), isFalse);
    expect(store.entries, isEmpty);
    await dir.delete(recursive: true);
  });

  test('取消时把续传状态写进注入的 store 而不是旁挂文件', () async {
    final dir = await Directory.systemTemp.createTemp('inkfetch_cancel_');
    final destPath = '${dir.path}${Platform.pathSeparator}big.bin';
    final report = _report(baseUrl, payload.length);
    final store = MemoryResumeStore();
    responseDelayMs = 400;
    final job = DownloadJob(
      taskId: 'cancel',
      parsed: report.parsed,
      report: report,
      destPath: destPath,
      maxConnections: 4,
      verifySha: false,
      resumeStore: store,
      onUpdate: (_) {},
    );
    final running = job.run();
    await Future<void>.delayed(const Duration(milliseconds: 120));
    job.cancel();
    final result = await running;

    expect(result.cancelled, isTrue);
    expect(store.entries.containsKey(destPath), isTrue);
    final state = store.entries[destPath]!;
    expect(state['total'], payload.length);
    expect(state['completed'], isA<List<dynamic>>());
    expect(await File('$destPath.octopart').exists(), isFalse);
    await dir.delete(recursive: true);
  }, timeout: const Timeout(Duration(seconds: 30)));
}
