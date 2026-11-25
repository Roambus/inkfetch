import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:inkfetch/core/downloader.dart';
import 'package:inkfetch/core/models.dart';
import 'package:inkfetch/core/scheduler.dart';
import 'package:inkfetch/core/url_parser.dart';

/// 结尾阶段的收口行为。
///
/// 症状：下载能到 99.9%，然后卡住十几秒才完成。
/// 真实成因有两层：
///
///   1. 最后一点数据只剩一条连接在啃。原来的抢尾阈值是
///      `remaining > 32KB`，最后 25KB 不满足，于是没人来帮忙
///      （阈值已降到 4KB）。
///   2. 守着最后一段的连接可能已经半死不活，原来只能等 35 秒的
///      整体超时（已改为 8 秒停滞 + 空闲连接接管）。
///
/// 说明：本地环回网络没有丢包与半死连接，无法真实复现线上的停滞，
/// 所以这个测试不冒充「能抓住线上 bug」。它守住的是**可确定的部分**：
/// 结尾慢速分片能被并行收口、校验和正确、总耗时不失控。
/// 线上那两层修复的依据是真实链路实测（结尾 19.7s → 3.6s）。
void main() {
  late HttpServer server;
  late List<int> payload;
  var slowTailRequests = 0;

  setUp(() async {
    payload = List<int>.generate(6 * 1024 * 1024 + 313, (i) => i % 251);
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final response = request.response;
      final header = request.headers.value(HttpHeaders.rangeHeader);
      if (header == null || !header.startsWith('bytes=')) {
        response.statusCode = 200;
        response.headers.contentLength = payload.length;
        response.add(payload);
        await response.close();
        return;
      }
      final spec = header.substring('bytes='.length);
      final dash = spec.indexOf('-');
      final start = int.parse(spec.substring(0, dash));
      final end = min(int.parse(spec.substring(dash + 1)), payload.length - 1);
      if (start > end) {
        response.statusCode = 416;
        await response.close();
        return;
      }
      final body = payload.sublist(start, end + 1);
      response.statusCode = 206;
      response.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes $start-$end/${payload.length}',
      );
      response.headers.contentLength = body.length;

      // 结尾那一段（请求落在最后 64KB 内）故意几乎不发数据，
      // 模拟「守着尾巴的连接已经半死不活」。每秒只吐一点点，
      // 旧实现会一直等这条连接，新实现应当由空闲连接接管。
      final isTail = start >= payload.length - 64 * 1024 && body.length < 64 * 1024;
      if (isTail) {
        slowTailRequests++;
        for (var i = 0; i < body.length; i += 4096) {
          response.add(body.sublist(i, min(i + 4096, body.length)));
          await response.flush();
          await Future<void>.delayed(const Duration(milliseconds: 700));
        }
        await response.close();
        return;
      }
      const step = 64 * 1024;
      for (var i = 0; i < body.length; i += step) {
        response.add(body.sublist(i, min(i + step, body.length)));
        await response.flush();
      }
      await response.close();
    });
  });

  tearDown(() async {
    await server.close(force: true);
  });

  test('结尾不会长时间卡在 99.x%', () async {
    final baseUrl = 'http://127.0.0.1:${server.port}';
    final parsed = parseGitHubUrl(
      'https://raw.githubusercontent.com/o/r/main/x.bin',
    );

    SourceProbe source(String id) => SourceProbe(
      id: id,
      name: id,
      url: '$baseUrl/file',
      lane: 'proxy',
      status: ProbeStatus.healthy,
      httpStatus: 206,
      supportsRange: true,
      totalSize: payload.length,
      latencyMs: 5,
      speedBps: 8000000,
      score: 8000000,
      maxConns: 8,
      experimental: false,
    );

    final sources = [source('a'), source('b'), source('c'), source('d')];
    final plan = planThreads(sources, payload.length, 16);
    final report = ProbeReport(
      parsed: parsed,
      sources: sources,
      testedCount: sources.length,
      usableCount: sources.length,
      rangeCount: sources.length,
      totalSize: payload.length,
      baselineHash: 'x',
      plan: plan,
      expectedSha256: sha256.convert(payload).toString(),
      probedMs: 1,
    );

    final dir = await Directory.systemTemp.createTemp('tail_finish_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final dest = '${dir.path}/x.bin';

    final stopwatch = Stopwatch()..start();
    var lastProgressAt = 0;
    var lastProgress = 0.0;
    var worstStallMs = 0;

    final job = DownloadJob(
      taskId: 'tail',
      parsed: parsed,
      report: report,
      destPath: dest,
      maxConnections: 16,
      verifySha: true,
      onUpdate: (snapshot) {
        final ms = stopwatch.elapsedMilliseconds;
        if (snapshot.progress > lastProgress + 0.0001) {
          if (lastProgressAt > 0) {
            worstStallMs = max(worstStallMs, ms - lastProgressAt);
          }
          lastProgress = snapshot.progress;
          lastProgressAt = ms;
        }
      },
    );

    final result = await job.run();
    stopwatch.stop();

    expect(result.success, isTrue, reason: '下载应当成功');
    expect(File(dest).lengthSync(), payload.length);

    final stamp = sha256.convert(File(dest).readAsBytesSync()).toString();
    expect(stamp, report.expectedSha256, reason: '校验和应当正确');

    // 关键断言：进度不允许长时间不动。
    // 结尾分片每秒只吐 4KB，靠单条连接要拖很久；并行收口才能快。
    expect(
      worstStallMs,
      lessThan(10000),
      reason: '结尾停滞了 ${worstStallMs}ms，进度长时间不动就是「卡住」',
    );

    // 尾巴确实被请求过（说明那段代码路径被覆盖到了）。
    expect(slowTailRequests, greaterThan(0), reason: '应当碰到结尾慢速分片');

    // 整体耗时不应当被结尾拖到失控。
    expect(
      stopwatch.elapsedMilliseconds,
      lessThan(30000),
      reason: '整体耗时 ${stopwatch.elapsedMilliseconds}ms 过长',
    );
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('结尾阈值足够小，最后几十 KB 也有资格被抢占', () {
    // 线上卡在 99.97%（剩 25KB）时，阈值是 16KB 且要求 remaining > 32KB，
    // 25KB 不满足，抢尾对它失效。这里把「阈值必须小到能覆盖几十 KB」
    // 钉成断言，防止以后有人把它调回去。
    final source = File('lib/core/downloader.dart').readAsStringSync();
    final match = RegExp(
      r'const int _minTailPart = (\d+) \* 1024;',
    ).firstMatch(source);
    expect(match, isNotNull, reason: '找不到 _minTailPart 定义');
    final kb = int.parse(match!.group(1)!);
    expect(
      kb,
      lessThanOrEqualTo(8),
      reason: '结尾阈值 ${kb}KB 太大：剩余 2 倍阈值以下的分片无法被抢占，'
          '最后那点数据会由一条连接独吞，表现为卡住',
    );

    // 停滞超时必须明显短于原来的 35 秒，否则尾部卡住要等很久。
    final stall = RegExp(
      r'const Duration _stallTimeout = Duration\(seconds: (\d+)\);',
    ).firstMatch(source);
    expect(stall, isNotNull, reason: '找不到 _stallTimeout 定义');
    expect(
      int.parse(stall!.group(1)!),
      lessThanOrEqualTo(15),
      reason: '停滞超时太长，尾部卡住时要等很久才放弃',
    );
  });
}
