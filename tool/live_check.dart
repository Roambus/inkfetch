import 'dart:io';

import 'package:inkfetch/core/downloader.dart';
import 'package:inkfetch/core/format.dart';
import 'package:inkfetch/core/models.dart';
import 'package:inkfetch/core/probe.dart';
import 'package:inkfetch/core/url_parser.dart';

/// 手动联网检查脚本：dart run tool/live_check.dart [url]
/// 会真实测试全部镜像并下载一个文件，用于验证镜像可用性。
Future<void> main(List<String> args) async {
  final input = args.isNotEmpty
      ? args.first
      : 'https://raw.githubusercontent.com/rust-lang/rust/master/README.md';
  final parsed = parseGitHubUrl(input);
  stdout.writeln('URL: ${parsed.normalized}');
  stdout.writeln('文件: ${parsed.filename} (${kindLabel(parsed.kind)})');

  final report = await probeSources(
    parsed,
    const ProbeOptions(probeBytes: 1024 * 1024),
    onProgress: (m) => stdout.writeln(m),
  );
  stdout.writeln('');
  stdout.writeln(
    '测试 ${report.testedCount} 个源，'
    '${report.usableCount} 可用，${report.rangeCount} 支持分片，'
    '耗时 ${report.probedMs}ms',
  );
  stdout.writeln('文件大小: ${report.totalSize}');
  stdout.writeln('计划: ${report.plan.reason}');
  for (final source in report.sources) {
    final status = switch (source.status) {
      ProbeStatus.healthy => 'OK',
      ProbeStatus.noRange => 'NORANGE',
      ProbeStatus.failed => 'FAIL',
    };
    stdout.writeln(
      '${status.padRight(8)} ${source.name.padRight(22)} '
      '${humanSpeed(source.speedBps).padRight(10)} '
      '${source.latencyMs}ms  ${source.error ?? ''}',
    );
  }

  final plan = report.plan;
  if (plan.totalConnections == 0) {
    stdout.writeln('没有可用源，终止');
    exit(1);
  }

  final temp = await Directory.systemTemp.createTemp('inkfetch_live_');
  final dest = '${temp.path}/${parsed.filename}';
  final job = DownloadJob(
    taskId: 'live',
    parsed: parsed,
    report: report,
    destPath: dest,
    maxConnections: 16,
    verifySha: true,
    onUpdate: (snapshot) {
      if (snapshot.phase == DownloadPhase.downloading &&
          snapshot.speedBps > 0) {
        stdout.writeln(
          '  ${(snapshot.progress * 100).toStringAsFixed(1)}%  '
          '${humanSpeed(snapshot.speedBps)}  '
          '${humanBytes(snapshot.downloaded)}/${humanBytes(snapshot.total)}',
        );
      }
    },
  );
  final result = await job.run();
  stdout.writeln('');
  stdout.writeln('下载成功: ${result.success}  错误: ${result.error}');
  stdout.writeln('SHA-256: ${result.sha256}');
  stdout.writeln(
    '耗时: ${result.elapsedMs}ms  平均: ${humanSpeed(result.averageSpeedBps)}',
  );
  if (result.success) {
    final file = File(dest);
    stdout.writeln('文件: ${file.path} (${await file.length()} 字节)');
  }
  await temp.delete(recursive: true);
  exit(result.success ? 0 : 2);
}
