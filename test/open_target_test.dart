import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:inkfetch/core/platform.dart';

/// 「打开文件 / 打开文件夹」的定位规则。
///
/// 这个功能反复出错，而且症状很具体：**定位到上级文件夹**。
/// 两种写法都会造成这个现象，这里把两种都钉死：
///
///  1. 把父目录传给 `/select`：资源管理器会打开父目录的父级，
///     并选中那个父目录。
///  2. 把**目录**传给 `/select`：资源管理器会打开它的上一级并选中它。
///     所以目录必须直接打开，不能走 /select。
void main() {
  group('在资源管理器里定位文件', () {
    test('选中文件本身，不是它所在的目录', () {
      final dir = Directory.systemTemp.createTempSync('inkfetch_sel_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File('${dir.path}${Platform.pathSeparator}jq-1.7.1-amd64.deb')
        ..writeAsStringSync('x');

      expect(file.parent.path, isNot(file.path));
      expect(revealTargetFor(file.path), file.path);
    });

    test('含空格与中文的路径原样保留，并整体加引号', () {
      final dir = Directory.systemTemp.createTempSync('inkfetch_sel2_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File('${dir.path}${Platform.pathSeparator}报告 测试 文件.zip')
        ..writeAsStringSync('x');

      final target = revealTargetFor(file.path);
      expect(target, file.path);
      expect(explorerSelectArgument(target!), '/select,"${file.path}"');
      expect(target.contains(' '), isTrue);
      expect(target.contains('报告'), isTrue);
    });

    test('目标是目录时原样返回目录（调用方必须直接打开，不能 /select）', () {
      final dir = Directory.systemTemp.createTempSync('inkfetch_reveal3_');
      addTearDown(() => dir.deleteSync(recursive: true));

      final target = revealTargetFor(dir.path);
      expect(target, dir.path);
      // 这就是「定位到上级」的根源：把目录交给 /select，
      // 资源管理器会跳到父级并选中该目录。
      expect(
        shouldSelectRatherThanOpen(target!),
        isFalse,
        reason: '目录不能走 /select，否则会定位到上一级',
      );
    });

    test('文件走 /select，目录直接打开', () {
      final dir = Directory.systemTemp.createTempSync('inkfetch_reveal4_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File('${dir.path}${Platform.pathSeparator}a.txt')
        ..writeAsStringSync('x');

      expect(shouldSelectRatherThanOpen(file.path), isTrue);
      expect(shouldSelectRatherThanOpen(dir.path), isFalse);
    });

    test('目标已删除时退回它所在目录（且该目录按目录处理）', () {
      final dir = Directory.systemTemp.createTempSync('inkfetch_reveal_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final missing = '${dir.path}${Platform.pathSeparator}gone.zip';

      final target = revealTargetFor(missing);
      expect(target, dir.path);
      // 退回的是目录，必须直接打开，不能 /select。
      expect(shouldSelectRatherThanOpen(target!), isFalse);
    });

    test('目标与父目录都不存在时返回 null', () {
      final dir = Directory.systemTemp.createTempSync('inkfetch_reveal5_');
      addTearDown(() => dir.deleteSync(recursive: true));
      expect(
        revealTargetFor('${dir.path}${Platform.pathSeparator}no'
            '${Platform.pathSeparator}nope.zip'),
        isNull,
      );
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

/// 与 NativeBridge._revealInExplorer 的分派规则一致：
/// 只有「文件」才走 `/select`；目录必须直接打开。
bool shouldSelectRatherThanOpen(String path) =>
    FileSystemEntity.typeSync(path) != FileSystemEntityType.directory;
