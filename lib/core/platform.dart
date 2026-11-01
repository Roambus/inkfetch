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
  static const MethodChannel _channel = MethodChannel('app.octofetch/native');

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
    final target = path;
    if (target == null || target.isEmpty) return false;
    try {
      if (Platform.isWindows) {
        await Process.start('explorer.exe', [
          target,
        ], mode: ProcessStartMode.detached);
      } else if (Platform.isMacOS) {
        await Process.start('open', [target], mode: ProcessStartMode.detached);
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
    try {
      final file = File(target);
      final dirPath = await file.exists() ? file.parent.path : target;
      if (Platform.isWindows) {
        await Process.start('explorer.exe', [
          '/select,$dirPath',
        ], mode: ProcessStartMode.detached);
      } else if (Platform.isMacOS) {
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
}
