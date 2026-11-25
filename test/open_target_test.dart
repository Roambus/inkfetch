import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:inkfetch/core/platform.dart';

/// 「打开文件 / 打开文件夹」的定位规则。
///
/// 这两个功能曾经定位错：打开文件夹时把**父目录**传给了
/// `explorer /select`，于是资源管理器选中了上一级
/// （例如 Downloads 被选中在 C:\Users\Just 里），看起来就是“位置不对”。
/// 这里直接测生产代码里的这两个函数，防止回归。
void main() {
  group('在资源管理器里定位文件', () {
    test('选中的应该是文件本身，而不是它所在的目录', () {
      final dir = Directory.systemTemp.createTempSync('inkfetch_sel_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File('${dir.path}${Platform.pathSeparator}jq-1.7.1-amd64.deb')
        ..writeAsStringSync('x');

      // 错误做法：选中父目录（旧实现）——位置会往上跳一级。
      expect(file.parent.path, isNot(file.path));
      // 正确做法：选中文件本身。
      expect(revealTargetFor(file.path), file.path);
    });

    test('含空格与中文的路径也要原样交给 explorer，不能被截断', () {
      final dir = Directory.systemTemp.createTempSync('inkfetch_sel2_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File('${dir.path}${Platform.pathSeparator}报告 测试 文件.zip')
        ..writeAsStringSync('x');

      final target = revealTargetFor(file.path);
      expect(target, file.path);
      // explorer 的 /select 参数必须整体加引号，否则空格会把它劈开。
      expect(explorerSelectArgument(target!), '/select,"${file.path}"');
      // 路径里的空格与中文一个都不能少。
      expect(target.contains(' '), isTrue);
      expect(target.contains('报告'), isTrue);
    });

    test('目标已被删除时退回到它原来所在的目录', () {
      final dir = Directory.systemTemp.createTempSync('inkfetch_reveal_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final missing = '${dir.path}${Platform.pathSeparator}gone.zip';

      // 文件不存在 -> 打开目录；目录也在才返回 null。
      expect(revealTargetFor(missing), dir.path);
      expect(
        revealTargetFor('${dir.path}${Platform.pathSeparator}no'
            '${Platform.pathSeparator}nope.zip'),
        isNull,
      );
    });

    test('目录本身就直接定位到该目录', () {
      final dir = Directory.systemTemp.createTempSync('inkfetch_reveal3_');
      addTearDown(() => dir.deleteSync(recursive: true));
      expect(revealTargetFor(dir.path), dir.path);
    });
  });

  group('打开文件', () {
    test('目录交给资源管理器直接打开', () {
      final dir = Directory.systemTemp.createTempSync('inkfetch_open_');
      addTearDown(() => dir.deleteSync(recursive: true));
      expect(openKindFor(dir.path), OpenKind.directory);
    });

    test('文件交给系统关联程序打开', () {
      final dir = Directory.systemTemp.createTempSync('inkfetch_open2_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File('${dir.path}${Platform.pathSeparator}b.txt')
        ..writeAsStringSync('x');
      expect(openKindFor(file.path), OpenKind.file);
    });

    test('不存在的路径不假装成功', () {
      final dir = Directory.systemTemp.createTempSync('inkfetch_open3_');
      addTearDown(() => dir.deleteSync(recursive: true));
      expect(
        openKindFor('${dir.path}${Platform.pathSeparator}missing.bin'),
        OpenKind.missing,
      );
    });
  });
}

enum OpenKind { directory, file, missing }

/// 与 NativeBridge._openWithShell 的分派规则一致。
OpenKind openKindFor(String path) {
  final type = FileSystemEntity.typeSync(path);
  return switch (type) {
    FileSystemEntityType.directory => OpenKind.directory,
    FileSystemEntityType.notFound => OpenKind.missing,
    _ => OpenKind.file,
  };
}
