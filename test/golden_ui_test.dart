import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:inkfetch/core/models.dart';
import 'package:inkfetch/core/scheduler.dart';
import 'package:inkfetch/core/url_parser.dart';
import 'package:inkfetch/state/app_controller.dart';
import 'package:inkfetch/ui/app_shell.dart';
import 'package:inkfetch/ui/theme.dart';

const _cjkFontCandidates = [
  '/usr/share/fonts/opentype/noto-cjk-otf/NotoSansCJKsc-Regular.otf',
  '/usr/share/fonts/opentype/noto-cjk-otf/NotoSansCJKsc-Bold.otf',
  r'C:\Windows\Fonts\msyh.ttc',
  r'C:\Windows\Fonts\simhei.ttf',
];

const _iconFontCandidates = [
  '/opt/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
  r'C:\flutter\flutter\bin\cache\artifacts\material_fonts\MaterialIcons-Regular.otf',
];

String? _firstExisting(List<String> paths) {
  for (final path in paths) {
    if (File(path).existsSync()) return path;
  }
  return null;
}

/// golden 测试需要真实的 CJK 与图标字体，缺失时直接跳过而不是失败。
bool _fontsAvailable() =>
    _firstExisting(_cjkFontCandidates) != null &&
    _firstExisting(_iconFontCandidates) != null;

Future<void> _loadFonts() async {
  final cjk = _firstExisting(_cjkFontCandidates);
  final iconPath = _firstExisting(_iconFontCandidates);
  if (cjk == null || iconPath == null) return;

  final loader = FontLoader('Roboto');
  final bytes = await File(cjk).readAsBytes();
  loader.addFont(Future.value(ByteData.view(bytes.buffer)));
  await loader.load();

  final icons = FontLoader('MaterialIcons');
  final iconBytes = await File(iconPath).readAsBytes();
  icons.addFont(Future.value(ByteData.view(iconBytes.buffer)));
  await icons.load();
}

SourceProbe _source(
  String id,
  String name,
  String lane,
  int speed,
  int latency, {
  bool healthy = true,
  String? error,
  bool experimental = false,
}) {
  return SourceProbe(
    id: id,
    name: name,
    url: 'https://example.com/$id',
    lane: lane,
    status: healthy ? ProbeStatus.healthy : ProbeStatus.failed,
    httpStatus: healthy ? 206 : 403,
    supportsRange: healthy,
    totalSize: healthy ? 38 * 1024 * 1024 : null,
    latencyMs: latency,
    speedBps: speed,
    firstHash: healthy ? 'hash' : null,
    identityOk: healthy ? true : null,
    score: speed.toDouble(),
    maxConns: 4,
    error: error,
    experimental: experimental,
  );
}

ProbeReport _fakeReport() {
  final parsed = parseGitHubUrl(
    'https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-1.7.1-amd64.deb',
  );
  final sources = [
    _source('official', 'GitHub 官方', 'official', 2200000, 120),
    _source('ghproxy', 'GhProxy', 'proxy', 8100000, 35),
    _source('ghfast', 'GhFast', 'proxy', 6400000, 48),
    _source('jsdelivr-cdn', 'jsDelivr CDN', 'cdn', 3100000, 22),
    _source(
      'gh-boki',
      'Boki Proxy',
      'proxy',
      0,
      0,
      healthy: false,
      error: 'HTTP 403',
      experimental: true,
    ),
  ];
  final plan = planThreads(sources, 38 * 1024 * 1024, 16);
  return ProbeReport(
    parsed: parsed,
    sources: sources,
    testedCount: 5,
    usableCount: 4,
    rangeCount: 4,
    totalSize: 38 * 1024 * 1024,
    baselineHash: 'hash',
    plan: plan,
    expectedSha256: null,
    probedMs: 1830,
  );
}

DownloadSnapshot _fakeSnapshot() {
  final plan = _fakeReport().plan;
  final chunkMap = List<int>.generate(64, (i) {
    if (i < 27) return (i % 4) + 1;
    if (i < 30) return 0;
    if (i == 30) return -2;
    return 0;
  });
  return DownloadSnapshot(
    taskId: 'demo',
    phase: DownloadPhase.downloading,
    filename: 'jq-1.7.1-amd64.deb',
    destPath: '/storage/emulated/0/Download/InkFetch/jq-1.7.1-amd64.deb',
    downloaded: 16 * 1024 * 1024 + 512 * 1024,
    total: 38 * 1024 * 1024,
    speedBps: 9400000,
    etaSecs: 5,
    elapsedMs: 2600,
    sites: [
      for (var i = 0; i < plan.sites.length; i++)
        SiteProgress(
          id: plan.sites[i].id,
          name: plan.sites[i].name,
          lane: plan.sites[i].lane,
          connections: plan.sites[i].connections,
          speedBps: [5200000, 3100000, 1100000, 800000][i % 4],
          bytes: [9000000, 5000000, 2000000, 1200000][i % 4],
          errors: i == 1 ? 1 : 0,
        ),
    ],
    chunkMap: chunkMap,
    chunkSize: plan.chunkSize,
    sha256: null,
    error: null,
    savedUri: null,
    progress: (16 * 1024 * 1024 + 512 * 1024) / (38 * 1024 * 1024),
  );
}

Future<void> _pump(
  WidgetTester tester,
  AppController controller, {
  required Size size,
  bool dark = true,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  controller.settings.downloadDir ??= '/home/user/Downloads/InkFetch';

  final theme = buildAppTheme(dark ? Brightness.dark : Brightness.light);
  final fontTheme = theme.copyWith(
    textTheme: theme.textTheme.apply(fontFamily: 'Roboto'),
    primaryTextTheme: theme.primaryTextTheme.apply(fontFamily: 'Roboto'),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        textStyle: const TextStyle(
          fontFamily: 'Roboto',
          fontWeight: FontWeight.w700,
          fontSize: 15,
        ),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        textStyle: const TextStyle(
          fontFamily: 'Roboto',
          fontWeight: FontWeight.w600,
          fontSize: 14,
        ),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        textStyle: const TextStyle(fontFamily: 'Roboto'),
      ),
    ),
    navigationBarTheme: theme.navigationBarTheme.copyWith(
      labelTextStyle: WidgetStatePropertyAll(
        TextStyle(
          fontFamily: 'Roboto',
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: dark ? const Color(0xFFB9C8E0) : const Color(0xFF4A5A75),
        ),
      ),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        textStyle: WidgetStatePropertyAll(
          TextStyle(fontFamily: 'Roboto', fontSize: 14),
        ),
      ),
    ),
  );
  await tester.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: fontTheme,
      home: AppShell(controller: controller),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _golden(WidgetTester tester, String name) async {
  await expectLater(
    find.byType(AppShell),
    matchesGoldenFile('goldens/$name.png'),
  );
}

void main() {
  // golden 基线依赖具体字体环境，默认跳过；
  // 需要时用 `INKFETCH_GOLDEN=1 flutter test test/golden_ui_test.dart` 运行。
  final fontsReady = _fontsAvailable();
  final runGoldens = fontsReady && Platform.environment['INKFETCH_GOLDEN'] == '1';
  setUpAll(_loadFonts);

  void goldenTest(String description, WidgetTesterCallback body) {
    testWidgets(description, body, skip: !runGoldens);
  }

  goldenTest('golden 首页 手机', (tester) async {
    final controller = AppController();
    await _pump(tester, controller, size: const Size(390, 844));
    await _golden(tester, 'home_phone_dark');
  });

  goldenTest('golden 首页 手机 浅色', (tester) async {
    final controller = AppController();
    await _pump(tester, controller, size: const Size(390, 844), dark: false);
    await _golden(tester, 'home_phone_light');
  });

  goldenTest('golden 首页 测试结果 手机', (tester) async {
    final controller = AppController()
      ..urlInput = 'https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-1.7.1-amd64.deb'
      ..report = _fakeReport()
      ..parsed = _fakeReport().parsed
      ..reportUrl = _fakeReport().parsed.normalized;
    await _pump(tester, controller, size: const Size(390, 844));
    await _golden(tester, 'home_report_phone');
  });

  goldenTest('golden 下载中 手机', (tester) async {
    final controller = AppController();
    controller.urlInput = 'https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-1.7.1-amd64.deb';
    controller.report = _fakeReport();
    controller.snapshot = _fakeSnapshot();
    controller.downloading = true;
    controller.tabIndex = 1;
    await _pump(tester, controller, size: const Size(390, 844));
    await _golden(tester, 'download_phone');
  });

  goldenTest('golden 下载记录 手机', (tester) async {
    final controller = AppController();
    controller.history = [
      HistoryEntry(
        taskId: 'h1',
        filename: 'jq-1.7.1-amd64.deb',
        url: 'https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-1.7.1-amd64.deb',
        destPath: 'Download/InkFetch/jq-1.7.1-amd64.deb',
        total: 38 * 1024 * 1024,
        downloaded: 38 * 1024 * 1024,
        speedBps: 8600000,
        sha256:
            '9c4d3c2eae0d10f6b1b0a8d8f3e9b5c3a1d7e9f0b2c4d6e8f0a1b3c5d7e9f1a3',
        status: 'completed',
        createdAt: DateTime(2026, 10, 31, 18, 22),
        finishedAt: DateTime(2026, 10, 31, 18, 22),
      ),
      HistoryEntry(
        taskId: 'h2',
        filename: 'git-master.zip',
        url: 'https://github.com/git/git/archive/refs/heads/master.zip',
        destPath: '/home/user/Downloads/InkFetch/git-master.zip',
        total: 0,
        downloaded: 0,
        speedBps: 0,
        status: 'failed',
        createdAt: DateTime(2026, 10, 30, 21, 4),
        finishedAt: DateTime(2026, 10, 30, 21, 5),
        error: '网络连接中断',
      ),
    ];
    controller.tabIndex = 2;
    await _pump(tester, controller, size: const Size(390, 844));
    await _golden(tester, 'history_phone');
  });

  goldenTest('golden 设置 手机', (tester) async {
    final controller = AppController();
    controller.settings.androidTreeName = 'Download/InkFetch';
    controller.settings.androidTreeUri = 'content://tree/123';
    controller.tabIndex = 3;
    await _pump(tester, controller, size: const Size(390, 844));
    await _golden(tester, 'settings_phone');
  });

  goldenTest('golden 首页 桌面宽屏', (tester) async {
    final controller = AppController()
      ..urlInput = 'https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-1.7.1-amd64.deb'
      ..report = _fakeReport()
      ..parsed = _fakeReport().parsed
      ..reportUrl = _fakeReport().parsed.normalized;
    await _pump(tester, controller, size: const Size(1280, 800));
    await _golden(tester, 'home_desktop');
  });

  goldenTest('golden 设置 平板', (tester) async {
    final controller = AppController();
    controller.tabIndex = 3;
    await _pump(tester, controller, size: const Size(1024, 768));
    await _golden(tester, 'settings_tablet');
  });
}
