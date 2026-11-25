import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:inkfetch/core/kv_store.dart';
import 'package:inkfetch/core/models.dart';
import 'package:inkfetch/core/storage.dart';

/// 模拟 Windows runner 里的注册表存储：与 `app.inkfetch/store` 通道同语义。
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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

  test('键值通道写入/读取/删除/清空', () async {
    const kv = ChannelKeyValueStore();
    expect(await kv.read('a'), isNull);
    await kv.write('a', '1');
    await kv.write('b', '2');
    expect(await kv.read('a'), '1');
    expect(await kv.readAll(), {'a': '1', 'b': '2'});
    expect(await kv.readAll(prefix: 'a'), {'a': '1'});
    await kv.remove('a');
    expect(await kv.read('a'), isNull);
    expect(registry.values, {'b': '2'});
    await kv.clear();
    expect(registry.values, isEmpty);
  });

  test('AppStore 通过注册表往返且保持原键名与 JSON 结构', () async {
    final store = AppStore(store: const ChannelKeyValueStore());
    final settings = AppSettings()
      ..maxConnections = 12
      ..theme = 'dark'
      ..downloadDir = r'C:\Users\me\Downloads'
      ..disabledMirrors = ['ghproxy']
      ..verifySha = false;
    final history = [
      HistoryEntry(
        taskId: 'h1',
        filename: 'a.zip',
        url: 'https://github.com/o/r/archive/refs/heads/main.zip',
        destPath: r'C:\Users\me\Downloads\a.zip',
        total: 10,
        downloaded: 10,
        speedBps: 2048,
        status: 'completed',
        createdAt: DateTime(2026, 1, 2, 3, 4),
        finishedAt: DateTime(2026, 1, 2, 3, 5),
      ),
    ];
    await store.saveSettings(settings);
    await store.saveHistory(history);
    await store.saveQueue([
      'https://github.com/o/r/releases/download/v1/b.bin',
    ]);

    expect(
      registry.values.keys,
      containsAll([
        'inkfetch.settings.v1',
        'inkfetch.history.v1',
        'inkfetch.queue.v1',
      ]),
    );
    expect(
      (jsonDecode(registry.values['inkfetch.settings.v1']!) as Map)['theme'],
      'dark',
    );

    final (loaded, loadedHistory, loadedQueue) = await AppStore(
      store: const ChannelKeyValueStore(),
    ).load();
    expect(loaded.maxConnections, 12);
    expect(loaded.theme, 'dark');
    expect(loaded.verifySha, isFalse);
    expect(loaded.disabledMirrors, ['ghproxy']);
    expect(loadedHistory.single.filename, 'a.zip');
    expect(loadedHistory.single.createdAt, DateTime(2026, 1, 2, 3, 4));
    expect(loadedQueue, hasLength(1));
  });

  test('存储出错时不抛出异常', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel(kStoreChannel),
          (call) async => throw PlatformException(code: 'boom'),
        );
    final store = AppStore(store: const ChannelKeyValueStore());
    await store.saveSettings(AppSettings());
    final (settings, history, queue) = await store.load();
    expect(settings.maxConnections, 32);
    expect(history, isEmpty);
    expect(queue, isEmpty);
  });
}
