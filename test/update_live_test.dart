import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:inkfetch/core/update_check.dart';

/// 联网验证：官网的版本清单真的能取到、能被解析。
///
/// 单元测试里的 fetch 是注入的假数据，只用它无法证明「应用内检查更新」
/// 在真实网络下能工作。这一条真的去拉官网，确认整条链路通。
///
/// 网络不通时自动跳过，不让 CI 因为环境问题红掉。
void main() {
  test('真的能从官网取到版本清单', () async {
    final text = await fetchSmallText(kVersionManifestUrl);
    if (text == null) {
      markTestSkipped('取不到 ${kVersionManifestUrl}，跳过联网验证');
      return;
    }
    // 能取到就必须是合法 JSON 且带 version
    expect(text.contains('"version"'), isTrue, reason: text);

    final result = await checkForUpdate(currentVersion: '0.0.1');
    expect(result.ok, isTrue);
    expect(result.latest, isNotEmpty);
    expect(result.source, '官网');
    // 0.0.1 一定比任何真实版本旧
    expect(result.hasUpdate, isTrue);
    print('官网版本 ${result.latest}（来源 ${result.source}）');
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('已是最新时不提示更新', () async {
    final result = await checkForUpdate(currentVersion: '9.9.9');
    if (!result.ok) {
      markTestSkipped('取不到清单，跳过');
      return;
    }
    expect(result.hasUpdate, isFalse);
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('官网图标可下载（设置页与品牌标记用同一张）', () async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    try {
      final req = await client.getUrl(
        Uri.parse('https://www.roambus.me/inkfetch/assets/cat-ink-cut.png'),
      );
      final res = await req.close().timeout(const Duration(seconds: 20));
      if (res.statusCode != 200) {
        markTestSkipped('HTTP ${res.statusCode}，跳过');
        await res.drain<void>();
        return;
      }
      final bytes = await res.fold<List<int>>([], (a, b) => a..addAll(b));
      expect(bytes.length, greaterThan(10000));
      // PNG 头
      expect(bytes.sublist(0, 4), [0x89, 0x50, 0x4E, 0x47]);
    } finally {
      client.close(force: true);
    }
  }, timeout: const Timeout(Duration(seconds: 60)));
}
