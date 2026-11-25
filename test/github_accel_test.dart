import 'package:flutter_test/flutter_test.dart';
import 'package:inkfetch/core/github_accel.dart';
import 'package:inkfetch/core/hosts_file.dart';

/// hosts 改写规则。
///
/// 这是整个加速功能里**风险最高**的一段代码：它直接改系统文件。
/// 一旦把用户原有的条目弄丢，Docker、内网服务、Tailscale 之类
/// 全都会连带失灵，而且很难让人想到是我们的锅。
///
/// 所以这里围绕三条底线做测试：
///   1. 只增删自己的标记区块，其余内容逐字保留；
///   2. 重复启用不会累积出多份；
///   3. 停用后能逐字节还原。
void main() {
  const userContent =
      '# 用户自己的条目\r\n'
      '127.0.0.1 localhost\r\n'
      '100.121.252.58 aliyun-server.tailb1c50b.ts.net\r\n'
      '\r\n'
      '192.168.1.10 nas.lan\r\n';

  const sampleEntries = [
    HostEntry('api.github.com', '140.82.114.6'),
    HostEntry('github.com', '140.82.112.3'),
  ];

  group('解析 hosts 数据源', () {
    test('只保留 GitHub 相关域名', () {
      const text =
          '# 注释\n'
          '140.82.114.6    api.github.com\n'
          '8.8.8.8         dns.google\n'
          '151.101.0.133   github.githubassets.com  # 行尾注释\n'
          '1.1.1.1         baidu.com\n';
      final entries = parseHosts(text);
      expect(entries.length, 2);
      expect(entries[0].host, 'api.github.com');
      expect(entries[0].ip, '140.82.114.6');
      expect(entries[1].host, 'github.githubassets.com');
    });

    test('容忍制表符、多余空白与 CRLF', () {
      const text = '140.82.114.6\tapi.github.com\r\n  140.82.112.3   github.com  \r\n';
      final entries = parseHosts(text);
      expect(entries.length, 2);
      expect(entries[1].host, 'github.com');
    });

    test('一行多个域名会分别判断', () {
      const text = '140.82.114.6 api.github.com dns.google github.com';
      final entries = parseHosts(text);
      expect(entries.map((e) => e.host), ['api.github.com', 'github.com']);
    });

    test('同一域名只保留第一条（避免重复堆积）', () {
      const text =
          '140.82.114.6 api.github.com\n'
          '140.82.113.6 api.github.com\n';
      final entries = parseHosts(text);
      expect(entries.length, 1);
      expect(entries.single.ip, '140.82.114.6');
    });

    test('忽略非法 IP 与不完整行', () {
      const text =
          '999.1.1.1 api.github.com\n'
          'not-an-ip github.com\n'
          '140.82.114.6\n'
          '140.82.114.6 api.github.com\n';
      final entries = parseHosts(text);
      expect(entries.length, 1);
      expect(entries.single.ip, '140.82.114.6');
    });

    test('子域判定', () {
      expect(isGithubHost('github.com'), isTrue);
      expect(isGithubHost('api.github.com'), isTrue);
      expect(isGithubHost('raw.githubusercontent.com'), isTrue);
      expect(isGithubHost('ghcr.io'), isTrue);
      expect(isGithubHost('notgithub.com'), isFalse);
      expect(isGithubHost('github.com.evil.com'), isFalse);
    });
  });

  group('择优', () {
    test('同一域名取延迟最低的 IP', () {
      final probes = [
        const HostProbe(HostEntry('api.github.com', '1.2.3.4'), 300),
        const HostProbe(HostEntry('api.github.com', '1.2.3.5'), 120),
        const HostProbe(HostEntry('api.github.com', '1.2.3.6'), null),
        const HostProbe(HostEntry('github.com', '1.2.3.7'), 200),
      ];
      final picked = HostsResolveResult.pickFastest(probes);
      expect(picked.length, 2);
      final api = picked.firstWhere((e) => e.host == 'api.github.com');
      expect(api.ip, '1.2.3.5', reason: '应当选延迟最低的那条');
    });

    test('握手失败的条目一律不采用', () {
      final probes = [
        const HostProbe(HostEntry('api.github.com', '1.2.3.4'), null),
        const HostProbe(HostEntry('github.com', '1.2.3.5'), null),
      ];
      expect(HostsResolveResult.pickFastest(probes), isEmpty);
    });
  });

  group('改写 hosts：绝不破坏用户内容', () {
    test('启用只追加自己的区块，用户内容逐字保留', () {
      final updated = applyHostsBlock(userContent, sampleEntries);

      // 用户原有的每一行都还在。
      for (final line in userContent.split('\r\n')) {
        if (line.trim().isEmpty) continue;
        expect(updated.contains(line), isTrue, reason: '用户内容被弄丢了：$line');
      }
      // 我们的区块在里面。
      expect(hasHostsBlock(updated), isTrue);
      expect(updated.contains('140.82.114.6'), isTrue);
      expect(updated.contains('api.github.com'), isTrue);
    });

    test('停用后能还原成原始内容', () {
      final updated = applyHostsBlock(userContent, sampleEntries);
      final restored = stripHostsBlock(updated);

      // 逐行比对：除了我们引入的首尾空行差异，用户内容必须完全一致。
      final original = userContent
          .split('\r\n')
          .where((l) => l.trim().isNotEmpty)
          .toList();
      final after = restored
          .split(RegExp(r'\r?\n'))
          .where((l) => l.trim().isNotEmpty)
          .toList();
      expect(after, original, reason: '停用后没有还原成原本的 hosts');
    });

    test('重复启用不会累积出多个区块', () {
      var text = applyHostsBlock(userContent, sampleEntries);
      text = applyHostsBlock(text, sampleEntries);
      text = applyHostsBlock(text, sampleEntries);

      final begin = kHostsBeginMarker.allMatches(text).length;
      final end = kHostsEndMarker.allMatches(text).length;
      expect(begin, 1, reason: '启用了三次，应当只有一个区块');
      expect(end, 1);
    });

    test('重复启用后条目仍是最新的', () {
      var text = applyHostsBlock(userContent, sampleEntries);
      text = applyHostsBlock(text, [
        const HostEntry('api.github.com', '9.9.9.9'),
      ]);
      final entries = readHostsBlock(text);
      expect(entries.length, 1);
      expect(entries.single.ip, '9.9.9.9');
      expect(text.contains('140.82.114.6'), isFalse, reason: '旧 IP 应当被替换掉');
    });

    test('对空 hosts 也能正常工作', () {
      final updated = applyHostsBlock('', sampleEntries);
      expect(hasHostsBlock(updated), isTrue);
      expect(readHostsBlock(updated).length, 2);
      // 移除后应当是干净的。
      expect(stripHostsBlock(updated).trim(), isEmpty);
    });

    test('只有标记没有内容也不会崩', () {
      const broken = '$kHostsBeginMarker\r\n$kHostsEndMarker\r\n';
      final restored = stripHostsBlock(broken);
      expect(restored.trim(), isEmpty);
    });

    test('残留多个区块也能全部清掉', () {
      const messy =
          '$kHostsBeginMarker\n'
          '1.1.1.1 api.github.com\n'
          '$kHostsEndMarker\n'
          '127.0.0.1 localhost\n'
          '$kHostsBeginMarker\n'
          '2.2.2.2 github.com\n'
          '$kHostsEndMarker\n';
      final restored = stripHostsBlock(messy);
      expect(restored.contains(kHostsBeginMarker), isFalse);
      expect(restored.contains('api.github.com'), isFalse);
      expect(restored.contains('127.0.0.1 localhost'), isTrue);
    });

    test('保留原有的 CRLF 换行风格', () {
      final updated = applyHostsBlock(userContent, sampleEntries);
      // 原有是 CRLF，写入后仍应是 CRLF，不能变成混合换行。
      expect(updated.contains('\r\n'), isTrue);
      final lfOnly = updated.replaceAll('\r\n', '');
      expect(lfOnly.contains('\n'), isFalse, reason: '不应混入裸 LF');
    });

    test('写出内容可被重新读回', () {
      final updated = applyHostsBlock(userContent, sampleEntries);
      final readBack = readHostsBlock(updated);
      expect(readBack.length, 2);
      final api = readBack.firstWhere((e) => e.host == 'api.github.com');
      expect(api.ip, '140.82.114.6');
    });
  });

  group('区块内容', () {
    test('按域名排序，输出稳定', () {
      final block = buildHostsBlock(const [
        HostEntry('github.com', '2.2.2.2'),
        HostEntry('api.github.com', '1.1.1.1'),
      ]);
      final lines = block.trim().split('\n');
      expect(lines[0].contains('api.github.com'), isTrue);
      expect(lines[1].contains('github.com'), isTrue);
    });

    test('同一域名重复条目只输出一条', () {
      final block = buildHostsBlock(const [
        HostEntry('github.com', '1.1.1.1'),
        HostEntry('github.com', '2.2.2.2'),
      ]);
      expect(block.trim().split('\n').length, 1);
    });
  });
}
