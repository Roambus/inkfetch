import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:inkfetch/main.dart';
import 'package:inkfetch/state/app_controller.dart';

void main() {
  testWidgets('首页与底部导航', (tester) async {
    final controller = AppController();
    await tester.pumpWidget(InkFetchApp(controller: controller));
    await tester.pumpAndSettle();

    expect(find.text('开始下载'), findsOneWidget);
    expect(find.text('下载'), findsWidgets);
    expect(find.text('任务'), findsWidgets);
    expect(find.text('记录'), findsWidgets);
    expect(find.text('设置'), findsWidgets);
  });

  testWidgets('桌面宽屏显示品牌名', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final controller = AppController();
    await tester.pumpWidget(InkFetchApp(controller: controller));
    await tester.pumpAndSettle();

    expect(find.text('墨取'), findsOneWidget);
    expect(find.text('INKFETCH'), findsOneWidget);
  });

  testWidgets('切换记录与设置页', (tester) async {
    final controller = AppController();
    await tester.pumpWidget(InkFetchApp(controller: controller));
    await tester.pumpAndSettle();

    await tester.tap(find.text('记录').last);
    await tester.pumpAndSettle();
    expect(find.text('还没有下载记录'), findsOneWidget);

    await tester.tap(find.text('设置').last);
    await tester.pumpAndSettle();
    expect(find.text('保存位置'), findsOneWidget);
    expect(find.text('最大并发连接'), findsOneWidget);
    expect(find.text('镜像管理'), findsOneWidget);
  });

  testWidgets('示例链接会填入输入框', (tester) async {
    final controller = AppController();
    await tester.pumpWidget(InkFetchApp(controller: controller));
    await tester.pumpAndSettle();

    // 示例行显示的是“仓库/文件”这样的可读标签，不再直接铺 URL。
    final example = find.textContaining('rust-lang/rust').first;
    await tester.ensureVisible(example);
    await tester.pumpAndSettle();
    await tester.tap(example);
    await tester.pumpAndSettle();
    expect(controller.urlInput, contains('rust-lang/rust'));
    expect(controller.urlInput, startsWith('https://github.com/'));
  });
}
