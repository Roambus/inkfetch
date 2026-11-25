import 'package:flutter_test/flutter_test.dart';
import 'package:inkfetch/core/speed_bench.dart';

/// 「测了没提升就不改」的判定逻辑。
///
/// 这段逻辑决定要不要改用户的系统 hosts。改错了的代价是：
/// 用户为了一个没用的「优化」背上提权与改系统文件的风险，
/// 甚至可能因为写错 IP 让 GitHub 更不通。
///
/// 所以这里把判定门槛钉死：只有确实更快（或从不可用变可用）才动系统。
void main() {
  SpeedSample ok(int totalMs, {int handshakeMs = 100, int bytes = 1000}) =>
      SpeedSample(
        handshakeMs: handshakeMs,
        totalMs: totalMs,
        bytes: bytes,
        ok: true,
      );

  SpeedComparison compare({
    required int directMs,
    required int accelMs,
    bool directOk = true,
    bool accelOk = true,
  }) {
    final direct = directOk ? ok(directMs) : const SpeedSample.failed('连不上');
    final accel = accelOk ? ok(accelMs) : const SpeedSample.failed('连不上');
    double? improvement;
    if (direct.ok && accel.ok && direct.totalMs > 0) {
      improvement = (direct.totalMs - accel.totalMs) / direct.totalMs * 100;
    }
    return SpeedComparison(
      direct: direct,
      accelerated: accel,
      host: 'codeload.github.com',
      ip: '140.82.113.10',
      improvementPercent: improvement,
    );
  }

  group('提升幅度计算', () {
    test('加速更快时提升为正', () {
      final cmp = compare(directMs: 1000, accelMs: 500);
      expect(cmp.improvementPercent, closeTo(50, 0.01));
    });

    test('加速更慢时提升为负', () {
      final cmp = compare(directMs: 500, accelMs: 1000);
      expect(cmp.improvementPercent, closeTo(-100, 0.01));
    });

    test('一样快时提升为 0', () {
      final cmp = compare(directMs: 700, accelMs: 700);
      expect(cmp.improvementPercent, 0);
    });

    test('直连失败时不给百分比（那不是「快多少」）', () {
      final cmp = compare(directMs: 0, accelMs: 500, directOk: false);
      expect(cmp.improvementPercent, isNull);
      expect(cmp.isAvailabilityGain, isTrue);
    });
  });

  group('要不要动系统设置', () {
    test('加速明显更快 → 值得启用', () {
      expect(compare(directMs: 1000, accelMs: 400).worthEnabling, isTrue);
    });

    test('只快一点点（不足 10%）→ 不值得，不改', () {
      // 1000ms -> 950ms 只有 5%，属于抖动范围，不该写 hosts。
      final cmp = compare(directMs: 1000, accelMs: 950);
      expect(cmp.improvementPercent, closeTo(5, 0.01));
      expect(cmp.worthEnabling, isFalse, reason: '5% 的提升不值得改系统文件');
    });

    test('恰好 10% → 值得启用（门槛含等号）', () {
      final cmp = compare(directMs: 1000, accelMs: 900);
      expect(cmp.improvementPercent, closeTo(10, 0.01));
      expect(cmp.worthEnabling, isTrue);
    });

    test('加速更慢 → 绝不启用', () {
      final cmp = compare(directMs: 500, accelMs: 1000);
      expect(cmp.worthEnabling, isFalse);
      expect(cmp.verdict.contains('慢'), isTrue);
    });

    test('直连不通但加速可用 → 值得启用（可用性提升）', () {
      final cmp = compare(directMs: 0, accelMs: 800, directOk: false);
      expect(cmp.worthEnabling, isTrue);
      expect(cmp.verdict.contains('直连不通'), isTrue);
    });

    test('加速后反而不通 → 绝不启用', () {
      final cmp = compare(directMs: 500, accelMs: 0, accelOk: false);
      expect(cmp.worthEnabling, isFalse);
      expect(cmp.verdict.contains('不建议启用'), isTrue);
    });

    test('两条路都失败 → 不启用（网络本身有问题）', () {
      final cmp = compare(
        directMs: 0,
        accelMs: 0,
        directOk: false,
        accelOk: false,
      );
      expect(cmp.worthEnabling, isFalse);
      expect(cmp.bothFailed, isTrue);
      expect(cmp.verdict.contains('都失败'), isTrue);
    });
  });

  group('结论文案', () {
    test('提升足够时说「值得启用」并给出百分比', () {
      final cmp = compare(directMs: 1000, accelMs: 300);
      expect(cmp.verdict.contains('快'), isTrue);
      expect(cmp.verdict.contains('70'), isTrue);
      expect(cmp.verdict.contains('值得启用'), isTrue);
    });

    test('差不多时明确说「不建议改动」', () {
      final cmp = compare(directMs: 1000, accelMs: 990);
      expect(cmp.verdict.contains('差不多'), isTrue);
      expect(cmp.verdict.contains('不建议改动'), isTrue);
    });
  });

  group('速度文案', () {
    test('失败样本显示失败', () {
      expect(const SpeedSample.failed('x').speedText, '失败');
    });

    test('速率按量级选择单位', () {
      const slow = SpeedSample(
        handshakeMs: 10,
        totalMs: 1000,
        bytes: 500,
        ok: true,
      );
      expect(slow.speedText.contains('B/s'), isTrue);

      const mid = SpeedSample(
        handshakeMs: 10,
        totalMs: 1000,
        bytes: 200 * 1024,
        ok: true,
      );
      expect(mid.speedText.contains('KB/s'), isTrue);

      const fast = SpeedSample(
        handshakeMs: 10,
        totalMs: 1000,
        bytes: 5 * 1024 * 1024,
        ok: true,
      );
      expect(fast.speedText.contains('MB/s'), isTrue);
    });

    test('耗时为 0 时不给出虚高速度', () {
      const sample = SpeedSample(
        handshakeMs: 0,
        totalMs: 0,
        bytes: 1000,
        ok: true,
      );
      expect(sample.bytesPerSecond, 0);
      expect(sample.speedText, '—');
    });
  });

  group('测速目标选择', () {
    test('测速域名必须是真实存在且对下载有意义的', () {
      // raw.githubusercontent.com 在这类网络下经常整个握手失败，
      // 拿它当基准会让「测速」永远失败——这是实际踩过的坑。
      expect(kSpeedTestHost, isNot('raw.githubusercontent.com'));
      expect(kSpeedTestHost.contains('github'), isTrue);
      expect(kSpeedTestPath.startsWith('/'), isTrue);
    });
  });
}
