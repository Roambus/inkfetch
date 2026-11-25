import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:inkfetch/core/kv_store.dart';
import 'package:inkfetch/core/resume_store.dart';

/// 模拟 Windows runner 的注册表存储，语义与 `app.inkfetch/store` 通道一致。
class _FakeRegistry {
  final Map<String, String> values = {};

  Future<Object?> handle(MethodCall call) async {
    final args = (call.arguments as Map?)?.cast<String, dynamic>() ?? {};
    switch (call.method) {
      case 'read':
        return values[args['key'] as String];
      case 'write':
        values[args['key'] as String] = args['value'] as String;
        return null;
      case 'remove':
        values.remove(args['key'] as String);
        return null;
      case 'clear':
        values.clear();
        return null;
      case 'readAll':
        final prefix = args['prefix'] as String?;
        return {
          for (final entry in values.entries)
            if (prefix == null || entry.key.startsWith(prefix))
              entry.key: entry.value,
        };
      default:
        throw MissingPluginException('未实现的方法：${call.method}');
    }
  }
}

Map<String, dynamic> _payload({
  required String url,
  required int total,
  int chunkSize = 256 * 1024,
  List<int> completed = const [0, 2],
}) => {
  'version': 1,
  'url': url,
  'total': total,
  'etag': 'W/"abc"',
  'chunkSize': chunkSize,
  'chunkCount': (total + chunkSize - 1) ~/ chunkSize,
  'completed': completed,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final tempDirs = <Directory>[];

  Future<Directory> tempDir() async {
    final dir = await Directory.systemTemp.createTemp('inkfetch_resume_');
    tempDirs.add(dir);
    return dir;
  }

  tearDown(() async {
    for (final dir in tempDirs) {
      try {
        await dir.delete(recursive: true);
      } catch (_) {}
    }
    tempDirs.clear();
  });

  test('FileResumeStore 写 .octopart 旁挂文件并可枚举', () async {
    final dir = await tempDir();
    final destPath = '${dir.path}${Platform.pathSeparator}big.bin';
    await File(destPath).writeAsBytes([1, 2, 3]);
    const store = FileResumeStore();
    final payload = _payload(
      url: 'https://github.com/o/r/releases/download/v1/big.bin',
      total: 1024 * 1024,
    );

    expect(await store.load(destPath), isNull);
    await store.save(destPath, payload);
    expect(await File('$destPath.octopart').exists(), isTrue);
    expect((await store.load(destPath))!['completed'], [0, 2]);

    final records = await store.listIncomplete(root: dir.path);
    expect(records, hasLength(1));
    expect(records.single.destPath, destPath);

    await store.remove(destPath);
    expect(await File('$destPath.octopart').exists(), isFalse);
    expect(await store.listIncomplete(root: dir.path), isEmpty);
    // 真正的下载文件不受影响。
    expect(await File(destPath).exists(), isTrue);
  });

  group('RegistryResumeStore', () {
    late _FakeRegistry registry;

    setUp(() {
      registry = _FakeRegistry();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel(kStoreChannel),
            registry.handle,
          );
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel(kStoreChannel), null);
    });

    test('键名是 resume. + sha1(目标路径)，值为 sidecar JSON', () async {
      final dir = await tempDir();
      final destPath = '${dir.path}${Platform.pathSeparator}big.bin';
      await File(destPath).writeAsBytes([1, 2, 3]);
      const store = RegistryResumeStore();
      final payload = _payload(
        url: 'https://github.com/o/r/releases/download/v1/big.bin',
        total: 1024 * 1024,
      );

      expect(await store.load(destPath), isNull);
      await store.save(destPath, payload);

      final key = 'resume.${sha1.convert(utf8.encode(destPath))}';
      expect(registry.values.keys, [key]);
      final stored = jsonDecode(registry.values[key]!) as Map<String, dynamic>;
      expect(stored['version'], 1);
      expect(stored['url'], payload['url']);
      expect(stored['total'], payload['total']);
      expect(stored['chunkSize'], payload['chunkSize']);
      expect(stored['completed'], [0, 2]);
      expect(stored['destPath'], destPath);

      final loaded = await store.load(destPath);
      expect(loaded!['completed'], [0, 2]);
      // 注册表里的状态不能落到下载目录。
      expect(await File('$destPath.octopart').exists(), isFalse);
    });

    test('枚举、丢弃目标文件已删除的条目、单条删除', () async {
      final dir = await tempDir();
      final kept = '${dir.path}${Platform.pathSeparator}kept.bin';
      final gone = '${dir.path}${Platform.pathSeparator}gone.bin';
      await File(kept).writeAsBytes([1, 2, 3]);
      const store = RegistryResumeStore();

      await store.save(
        kept,
        _payload(
          url: 'https://github.com/o/r/releases/download/v1/kept.bin',
          total: 1024 * 1024,
        ),
      );
      await store.save(
        gone,
        _payload(
          url: 'https://github.com/o/r/releases/download/v1/gone.bin',
          total: 512 * 1024,
        ),
      );
      expect(registry.values, hasLength(2));

      final records = await store.listIncomplete();
      expect(records, hasLength(1));
      expect(records.single.destPath, kept);
      expect(records.single.payload['url'], contains('kept.bin'));
      // 目标文件不见了，对应键要顺手清掉。
      expect(registry.values, hasLength(1));

      await store.remove(kept);
      expect(registry.values, isEmpty);
      expect(await store.listIncomplete(), isEmpty);
    });
  });
}
