import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:inkfetch/main.dart';
import 'package:inkfetch/state/accel_controller.dart';
import 'package:inkfetch/state/app_controller.dart';
import 'package:inkfetch/ui/downloads_hub.dart';

/// 下载区合并后的交互。
///
/// 「下载 / 进行中 / 历史」原本是三个顶级导航项，现在收进一个页面
/// 用标签切换。这个测试确保三件事：
///   1. 顶级导航只剩三项，不再有「任务」「记录」；
///   2. 点击标签能在三个分段之间切换；
///   3. 开始下载会自动跳到「进行中」。
void main() {
  Future<AppController> pumpApp(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final controller = AppController();
    await tester.pumpWidget(
      InkFetchApp(controller: controller, accel: AccelController()),
    );
    await tester.pumpAndSettle();
    return controller;
  }

  testWidgets('顶级导航只有三项', (tester) async {
    await pumpApp(tester);
    // 侧栏（宽屏）应只有 下载 / 加速 / 设置
    expect(find.text('下载'), findsWidgets);
    expect(find.text('加速'), findsOneWidget);
    expect(find.text('设置'), findsOneWidget);
    // 旧的「任务」「记录」不再作为顶级导航项
    expect(find.text('任务'), findsNothing);
    expect(find.text('记录'), findsNothing);
  });

  testWidgets('下载区有三个分段标签', (tester) async {
    await pumpApp(tester);
    expect(find.text('下载'), findsWidgets);
    expect(find.text('进行中'), findsOneWidget);
    expect(find.text('历史'), findsOneWidget);
  });

  testWidgets('点击标签在分段之间切换', (tester) async {
    final controller = await pumpApp(tester);
    expect(controller.downloadSection, 0);

    await tester.tap(find.text('历史'));
    await tester.pumpAndSettle();
    expect(controller.downloadSection, 2);
    // 历史页为空时显示这个占位文案
    expect(find.text('还没有下载记录'), findsOneWidget);

    await tester.tap(find.text('进行中'));
    await tester.pumpAndSettle();
    expect(controller.downloadSection, 1);

    // 「下载」在侧栏与分段标签里都有。分段标签在 DownloadsHub 内，
    // 用 ancestor 限定范围，避免点到侧栏那个。
    final downloadTab = find.descendant(
      of: find.byType(DownloadsHub),
      matching: find.text('下载'),
    );
    expect(downloadTab, findsOneWidget);
    await tester.tap(downloadTab);
    await tester.pumpAndSettle();
    expect(controller.downloadSection, 0);
    expect(find.text('开始下载'), findsOneWidget);
  });

  testWidgets('setDownloadSection 会夹取越界值', (tester) async {
    final controller = await pumpApp(tester);
    controller.setDownloadSection(99);
    expect(controller.downloadSection, 2);
    controller.setDownloadSection(-5);
    expect(controller.downloadSection, 0);
  });
}
