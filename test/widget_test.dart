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

    // 示例行显示的是「仓库/文件」这样的可读标签，不再直接铺 URL。
    // 用的是本项目自己的仓库（Roambus/inkfetch）作为示例。
    final example = find.textContaining('inkfetch').first;
    await tester.ensureVisible(example);
    await tester.pumpAndSettle();
    await tester.tap(example);
    await tester.pumpAndSettle();
    expect(controller.urlInput, contains('Roambus/inkfetch'));
    expect(controller.urlInput, startsWith('https://github.com/'));
  });

  testWidgets('三类示例链接分别覆盖单文件、仓库快照与 Release 资产', (tester) async {
    final controller = AppController();
    await tester.pumpWidget(InkFetchApp(controller: controller));
    await tester.pumpAndSettle();

    // 三条示例各自代表的链接类型，用标签本身来锚定。
    expect(find.text('单文件'), findsOneWidget);
    expect(find.text('仓库快照'), findsOneWidget);
    expect(find.text('Release 资产'), findsOneWidget);

    // 全部指向 Roambus 名下的仓库，不再混入第三方项目。
    expect(find.textContaining('photocraft'), findsOneWidget);
    expect(find.textContaining('scrcpy-LiteUI'), findsOneWidget);
    expect(find.textContaining('rust-lang'), findsNothing);
  });
}
