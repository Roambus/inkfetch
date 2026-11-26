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

  /// 在系统浏览器里打开一个网址。
  ///
  /// Android 交给原生 Intent（否则没有默认浏览器可用时会静默失败），
  /// Windows 走 rundll32 的 ShellExecute，macOS/Linux 用 open / xdg-open。
  static Future<bool> openUrl(String url) async {
    if (url.isEmpty) return false;
    if (isAndroid) {
      try {
        return await _channel.invokeMethod<bool>('openUrl', {'url': url}) ??
            false;
      } catch (_) {
        return false;
      }
    }
    if (Platform.isWindows) {
      try {
        // 与打开文件同一条路：ShellExecute 的 open 动词会按 http(s) 关联
        // 交给默认浏览器，且不必解析浏览器装在哪。
        await Process.start('rundll32.exe', [
          'shell32.dll,ShellExec_RunDLL',
          url,
        ], mode: ProcessStartMode.detached);
        return true;
      } catch (_) {
        return false;
      }
    }
    try {
      final cmd = Platform.isMacOS ? 'open' : 'xdg-open';
      await Process.start(cmd, [url], mode: ProcessStartMode.detached);
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

  /// Windows：在资源管理器里定位 [path] 所指向的条目。
  ///
  /// 这里有三个坑，都会表现成「定位到上级 / 跑到别处」：
  ///
  /// 1. `/select,<路径>` 的路径必须是**要被选中的那个条目**。传父目录进去，
  ///    资源管理器会打开父目录的父级，并选中那个父目录。
  /// 2. 如果传入的本身是**目录**，`/select` 会打开它的上一级并选中它，
  ///    看起来同样像定位错了。目录应当直接打开，不该走 /select。
  /// 3. **引号不能自己加。** Dart 的 Process.start 会把单个参数里的双引号
  ///    转义成 `\"`，explorer 收到 `/select,\"C:\...\"` 会当成非法路径，
  ///    直接回退去打开「文档」目录——这就是「打开的是上一级/别的目录」
  ///    反复出现的原因。必须把 `/select,` 与路径拆成两个参数，
  ///    由 Windows 负责给含空格的路径加引号。
  static Future<bool> _revealInExplorer(String path) async {
    final target = revealTargetFor(path);
    if (target == null) return false;
    final type = FileSystemEntity.typeSync(target);
    try {
      if (type == FileSystemEntityType.directory) {
        // 目标是目录：直接打开它，不要 /select。
        await Process.start('explorer.exe', [
          target,
        ], mode: ProcessStartMode.detached);
      } else {
        // 两个独立参数，不要拼成一个带引号的字符串。
        await Process.start(
          'explorer.exe',
          explorerSelectArgs(target),
          mode: ProcessStartMode.detached,
        );
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
/// 都不存在返回 null。
String? revealTargetFor(String path) {
  final type = FileSystemEntity.typeSync(path);
  if (type != FileSystemEntityType.notFound) return path;
  // 目标已经不在（被手动删掉/移动）：退回它原来所在的目录。
  // 注意返回的是**目录**，调用方要按目录处理（直接打开），
  // 不能拿去 /select——/select 一个目录会跳到它的父级。
  final parent = File(path).parent.path;
  if (FileSystemEntity.typeSync(parent) == FileSystemEntityType.directory) {
    return parent;
  }
  return null;
}

/// 构造 explorer 的定位参数。
///
/// 必须返回**两个**元素：`/select,` 和路径本身。
/// 千万不要拼成 `/select,"<路径>"` 这样单个字符串——Dart 的
/// Process.start 会把内层双引号转义成 `\"`，explorer 收到非法路径
/// 后会静默回退去打开「文档」目录，表现为「打开的是别的文件夹」。
List<String> explorerSelectArgs(String path) => ['/select,', path];
