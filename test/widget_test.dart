import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:octofetch/main.dart';
import 'package:octofetch/state/app_controller.dart';

void main() {
  testWidgets('首页固定底部下载栏与导航', (tester) async {
    final controller = AppController();
    await tester.pumpWidget(OctoFetchApp(controller: controller));
    await tester.pumpAndSettle();

    expect(find.text('OctoFetch'), findsOneWidget);
    expect(find.text('开始下载'), findsOneWidget);
    expect(find.text('下载'), findsWidgets);
    expect(find.text('记录'), findsWidgets);
    expect(find.text('设置'), findsWidgets);

    await tester.drag(
      find.byType(SingleChildScrollView).first,
      const Offset(0, -600),
    );
    await tester.pumpAndSettle();
    expect(find.text('开始下载'), findsOneWidget);
  });

  testWidgets('切换记录与设置页', (tester) async {
    final controller = AppController();
    await tester.pumpWidget(OctoFetchApp(controller: controller));
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
    await tester.pumpWidget(OctoFetchApp(controller: controller));
    await tester.pumpAndSettle();

    final example = find.textContaining('github.com/rust-lang').first;
    await tester.ensureVisible(example);
    await tester.pumpAndSettle();
    await tester.tap(example);
    await tester.pumpAndSettle();
    expect(controller.urlInput, contains('rust-lang/rust'));
  });
}
