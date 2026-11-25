import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

class PickedDirectory {
  final String path;
  final String? treeUri;
  final String? name;

  const PickedDirectory({required this.path, this.treeUri, this.name});
}

class SavedFile {
  final String uri;
  final String name;

  const SavedFile({required this.uri, required this.name});
}

class NativeBridge {
  static const MethodChannel _channel = MethodChannel('app.inkfetch/native');
  static const EventChannel _events = EventChannel('app.inkfetch/native_events');

  /// Android 原生事件流（当前用于“复制到所选文件夹”的进度）。
  static Stream<Map<String, dynamic>> get nativeEvents =>
      _events.receiveBroadcastStream().map(
        (event) => Map<String, dynamic>.from(event as Map),
      );

  static bool get isAndroid => Platform.isAndroid;
  static bool get isDesktop =>
      Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  static Future<String?> defaultDownloadDir() async {
    if (isAndroid) {
      try {
        return await _channel.invokeMethod<String>('defaultDownloadDir');
      } catch (_) {
        return null;
      }
    }
    try {
      final downloads = await getDownloadsDirectory();
      if (downloads != null && downloads.path.isNotEmpty) {
        return downloads.path;
      }
      final home =
          Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
      if (home != null) return '$home${Platform.pathSeparator}Downloads';
    } catch (_) {}
    return null;
  }

  static Future<PickedDirectory?> pickDirectory() async {
    if (isAndroid) {
      try {
        final result = await _channel.invokeMapMethod<String, dynamic>(
          'pickDirectory',
        );
        if (result == null) return null;
        final uri = result['uri'] as String?;
        if (uri == null) return null;
        return PickedDirectory(
          path: uri,
          treeUri: uri,
          name: result['name'] as String? ?? '已选文件夹',
        );
      } catch (_) {
        return null;
      }
    }
    try {
      final path = await FilePicker.getDirectoryPath(dialogTitle: '选择下载保存文件夹');
      if (path == null) return null;
      return PickedDirectory(path: path, name: path);
    } catch (_) {
      return null;
    }
  }

  static Future<SavedFile?> saveToTree({
    required String srcPath,
    required String treeUri,
    required String fileName,
  }) async {
    if (!isAndroid) return null;
    try {
      final result = await _channel.invokeMapMethod<String, dynamic>(
        'saveToDirectory',
        {'srcPath': srcPath, 'treeUri': treeUri, 'fileName': fileName},
      );
      if (result == null) return null;
      final uri = result['uri'] as String?;
      if (uri == null) return null;
      return SavedFile(uri: uri, name: result['name'] as String? ?? fileName);
    } catch (_) {
      return null;
    }
  }

  /// 开始前台服务，避免应用切到后台后下载被系统回收。
  static Future<void> startDownloadNotification({required String title}) async {
    if (!isAndroid) return;
    try {
      await _channel.invokeMethod<bool>('startDownloadService', {
        'title': title,
      });
    } catch (_) {}
  }

  static Future<void> stopDownloadNotification() async {
    if (!isAndroid) return;
    try {
      await _channel.invokeMethod<bool>('stopDownloadService');
    } catch (_) {}
  }

  /// 取消正在进行的“复制到所选文件夹”。
  static Future<void> cancelFolderCopy() async {
    if (!isAndroid) return;
    try {
      await _channel.invokeMethod<bool>('cancelCopyToDirectory');
    } catch (_) {}
  }

  /// 用系统默认程序打开文件；[path] 优先，[uri] 供 Android 的 content:// 使用。
  static Future<bool> openFile({String? uri, String? path}) async {
    if (isAndroid) {
      try {
        return await _channel.invokeMethod<bool>('openFile', {
              'uri': uri,
              'path': path,
            }) ??
            false;
      } catch (_) {
        return false;
      }
    }
    if (Platform.isWindows) {
      return _openWithShell(path);
    }
    final target = path;
    if (target == null || target.isEmpty) return false;
    try {
      if (Platform.isMacOS) {
        await Process.start('open', [
          target,
        ], mode: ProcessStartMode.detached);
      } else {
        await Process.start('xdg-open', [
          target,
        ], mode: ProcessStartMode.detached);
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 在资源管理器里定位文件：选中这个文件本身，而不是它的父目录。
  static Future<bool> openFolder({String? treeUri, String? path}) async {
    if (isAndroid) {
      try {
        return await _channel.invokeMethod<bool>('openFolder', {
              'treeUri': treeUri,
              'path': path,
            }) ??
            false;
      } catch (_) {
        return false;
      }
    }
    final target = path;
    if (target == null || target.isEmpty) return false;
    if (Platform.isWindows) {
      return _revealInExplorer(target);
    }
    try {
      final file = File(target);
      final dirPath = await file.exists() ? file.parent.path : target;
      if (Platform.isMacOS) {
        await Process.start('open', [dirPath], mode: ProcessStartMode.detached);
      } else {
        await Process.start('xdg-open', [
          dirPath,
        ], mode: ProcessStartMode.detached);
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Windows：用 ShellExecute 走系统关联程序打开。
  ///
  /// 原来直接 `explorer.exe <文件>` 是不对的：explorer 对「文件路径」的
  /// 处理和资源管理器定位是两回事，遇到不认识的扩展名会退化成打开
  /// 「文档」目录，看起来就像定位错了。
  static Future<bool> _openWithShell(String? path) async {
    if (path == null || path.isEmpty) return false;
    final type = FileSystemEntity.typeSync(path);
    if (type == FileSystemEntityType.notFound) return false;
    // 目录直接交给资源管理器打开。
    if (type == FileSystemEntityType.directory) {
      try {
        await Process.start('explorer.exe', [
          path,
        ], mode: ProcessStartMode.detached);
        return true;
      } catch (_) {
        return false;
      }
    }
    try {
      // rundll32 的 FileProtocolHandler 等价于 ShellExecute 的 open 动词，
      // 会按系统关联程序打开，且不经过 explorer 的目录逻辑。
      await Process.start('rundll32.exe', [
        'shell32.dll,ShellExec_RunDLL',
        path,
      ], mode: ProcessStartMode.detached);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Windows：在资源管理器里选中 [path] 所指向的条目。
  ///
  /// `explorer /select,<路径>` 的参数必须是被选中的那个路径本身；
  /// 早先这里传的是父目录，于是选中变成了上一级，位置看起来就是错的。
  static Future<bool> _revealInExplorer(String path) async {
    final target = revealTargetFor(path);
    if (target == null) return false;
    try {
      final type = FileSystemEntity.typeSync(target);
      if (type == FileSystemEntityType.directory) {
        // 目标已不存在、退回到目录：直接打开该目录。
        await Process.start('explorer.exe', [
          target,
        ], mode: ProcessStartMode.detached);
      } else {
        await Process.start('explorer.exe', [
          explorerSelectArgument(target),
        ], mode: ProcessStartMode.detached);
      }
      return true;
    } catch (_) {
      return false;
    }
  }
}

/// 决定「在资源管理器里定位」要选中的路径。
///
/// 目标存在就选它自己；只有父目录存在就退回打开父目录；
/// 都不存在返回 null。抽成顶层函数是为了让测试直接覆盖这段逻辑，
/// 而不是复制一份到测试里。
String? revealTargetFor(String path) {
  final type = FileSystemEntity.typeSync(path);
  if (type != FileSystemEntityType.notFound) return path;
  final parent = File(path).parent.path;
  if (FileSystemEntity.typeSync(parent) == FileSystemEntityType.directory) {
    return parent;
  }
  return null;
}

/// explorer 的 /select 参数格式：选项与路径必须是同一个参数、
/// 路径整体加引号，否则含空格的路径会被劈开。
String explorerSelectArgument(String path) => '/select,"$path"';
