import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 品牌资产与图标的回归检查。
///
/// 这几项都在过去真实出过问题，而且都是「打包之后才发现」的类型：
///   · 界面里的品牌标记用了图标字体之外的图形 → 要保证资源真的存在；
///   · 图标被 tree-shake 掉 → 界面上变成方块；
///   · 首页示例链接指向已删除的文件 → 用户点了下载不到。
void main() {
  group('品牌资产', () {
    test('界面用的猫图标资源存在且带透明通道', () {
      final file = File('assets/icon/inkfetch_mark_320.png');
      expect(file.existsSync(), isTrue, reason: 'BrandMark 依赖这张图');

      final bytes = file.readAsBytesSync();
      // PNG 头 + IHDR 里的色彩类型：6 = RGBA（带 alpha）
      expect(bytes.length, greaterThan(1000));
      // 直接检查第 25 字节（IHDR 的 color type）
      expect(bytes[25], 6, reason: '必须是 RGBA，否则放在深色界面上会有白色方底');
    });

    test('pubspec 声明了该资源', () {
      final pubspec = File('pubspec.yaml').readAsStringSync();
      expect(
        pubspec.contains('assets/icon/inkfetch_mark_320.png'),
        isTrue,
        reason: '没在 pubspec 里声明，打包后运行时读不到',
      );
    });

    test('旧的纯色图标已移除', () {
      expect(
        File('assets/icon/inkfetch_icon.png').existsSync(),
        isFalse,
        reason: '图标已统一成水墨猫，旧的箭头图标不该再留着',
      );
    });
  });

  group('首页示例链接', () {
    test('示例指向的文件在仓库里真实存在', () {
      final home = File('lib/ui/home_page.dart').readAsStringSync();
      // 抓出仓库内路径的示例（blob/main/...）
      final matches = RegExp(
        r'github\.com/Roambus/inkfetch/blob/main/([^'"'"']+)',
      ).allMatches(home);
      expect(matches, isNotEmpty, reason: '至少要有一个指向本仓库的示例');

      for (final m in matches) {
        final path = m.group(1)!;
        expect(
          File(path).existsSync(),
          isTrue,
          reason: '示例指向 $path，但文件不存在——用户点了会下载失败',
        );
      }
    });
  });

  group('版本一致性', () {
    test('pubspec 版本与产品主页一致', () {
      final pubspec = File('pubspec.yaml').readAsStringSync();
      final m = RegExp(r'^version:\s*([\d.]+)\+(\d+)', multiLine: true)
          .firstMatch(pubspec);
      expect(m, isNotNull, reason: 'pubspec 里应当有 version');
      final version = m!.group(1)!;

      final page = File('product/site/index.html').readAsStringSync();
      expect(
        page.contains('v$version') || page.contains('InkFetch-$version'),
        isTrue,
        reason: '主页还写着旧版本号 $version，发布时要一起改',
      );
    });

    test('主页下载链接与 version.json 指向同一版本', () {
      final versionJson = File('dist/version.json');
      if (!versionJson.existsSync()) {
        // dist 还没生成时跳过，不算失败
        return;
      }
      final text = versionJson.readAsStringSync();
      final pubspec = File('pubspec.yaml').readAsStringSync();
      final version = RegExp(r'^version:\s*([\d.]+)', multiLine: true)
          .firstMatch(pubspec)!
          .group(1)!;
      expect(text.contains('"version": "$version"'), isTrue);
    });
  });
}
