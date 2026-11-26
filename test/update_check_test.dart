import 'package:flutter_test/flutter_test.dart';
import 'package:inkfetch/core/update_check.dart';

void main() {
  group('compareVersions', () {
    test('按段比较数字', () {
      expect(compareVersions('2.6.0', '2.5.1'), greaterThan(0));
      expect(compareVersions('2.5.1', '2.6.0'), lessThan(0));
      expect(compareVersions('2.5.1', '2.5.1'), 0);
    });

    test('缺失的段按 0 处理', () {
      expect(compareVersions('2.6', '2.6.0'), 0);
      expect(compareVersions('2.6.1', '2.6'), greaterThan(0));
    });

    test('忽略 build 号与预发布后缀', () {
      expect(compareVersions('2.6.0+10', '2.6.0'), 0);
      expect(compareVersions('2.6.0-beta.1', '2.6.0'), 0);
      expect(compareVersions('2.6.0+11', '2.5.9+99'), greaterThan(0));
    });

    test('多位数字按数值比较，不是字典序', () {
      // 字典序里 "2.10" < "2.9"，数值上相反。
      expect(compareVersions('2.10.0', '2.9.0'), greaterThan(0));
      expect(compareVersions('1.100.0', '1.99.0'), greaterThan(0));
    });

    test('空串与异常输入不抛异常', () {
      expect(compareVersions('', '2.5.1'), lessThan(0));
      expect(compareVersions('x.y.z', '0.0.0'), 0);
    });
  });

  group('UpdateCheckResult', () {
    test('线上更新才算 hasUpdate', () {
      const newer = UpdateCheckResult(
        latest: '2.6.0',
        current: '2.5.1',
        ok: true,
      );
      expect(newer.hasUpdate, isTrue);

      const same = UpdateCheckResult(
        latest: '2.5.1',
        current: '2.5.1',
        ok: true,
      );
      expect(same.hasUpdate, isFalse);

      const older = UpdateCheckResult(
        latest: '2.4.0',
        current: '2.5.1',
        ok: true,
      );
      expect(older.hasUpdate, isFalse);
    });

    test('检查失败时永不报更新', () {
      const failed = UpdateCheckResult(
        latest: '9.9.9',
        current: '2.5.1',
        ok: false,
      );
      expect(failed.hasUpdate, isFalse);
    });
  });

  group('checkForUpdate', () {
    test('读官网清单里的 version 字段', () async {
      final result = await checkForUpdate(
        currentVersion: '2.5.1',
        fetch: (url) async {
          if (url == kVersionManifestUrl) {
            return '{"version":"2.6.0","url":"https://example.test/dl"}';
          }
          return null;
        },
      );
      expect(result.ok, isTrue);
      expect(result.latest, '2.6.0');
      expect(result.source, '官网');
      expect(result.releaseUrl, 'https://example.test/dl');
      expect(result.hasUpdate, isTrue);
    });

    test('官网挂了走 GitHub release tag', () async {
      final result = await checkForUpdate(
        currentVersion: '2.5.1',
        fetch: (url) async {
          if (url == kVersionManifestUrl) return null;
          if (url == kGitHubLatestReleaseUrl) {
            return '{"tag_name":"v2.7.0","html_url":"https://gh.test/r"}';
          }
          return null;
        },
      );
      expect(result.ok, isTrue);
      expect(result.latest, '2.7.0');
      expect(result.source, 'GitHub');
    });

    test('两个源都挂时安静失败', () async {
      final result = await checkForUpdate(
        currentVersion: '2.5.1',
        fetch: (url) async => null,
      );
      expect(result.ok, isFalse);
      expect(result.hasUpdate, isFalse);
      expect(result.latest, isEmpty);
    });

    test('清单是坏 JSON 时回落到 GitHub', () async {
      final result = await checkForUpdate(
        currentVersion: '2.5.1',
        fetch: (url) async {
          if (url == kVersionManifestUrl) return '<html>404</html>';
          return '{"tag_name":"v2.6.3"}';
        },
      );
      expect(result.ok, isTrue);
      expect(result.latest, '2.6.3');
      expect(result.source, 'GitHub');
    });

    test('清单缺 version 字段时也回落', () async {
      final result = await checkForUpdate(
        currentVersion: '2.5.1',
        fetch: (url) async {
          if (url == kVersionManifestUrl) return '{"foo":"bar"}';
          return '{"tag_name":"2.6.1"}';
        },
      );
      expect(result.source, 'GitHub');
      expect(result.latest, '2.6.1');
    });
  });
}
