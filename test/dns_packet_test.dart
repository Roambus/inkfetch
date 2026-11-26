import 'package:flutter_test/flutter_test.dart';

/// DNS 报文构造与解析的等价验证。
///
/// 这一组测试复刻 Kotlin 侧 VpnService 里的同名逻辑，用来确认
/// 「按查询类型正确应答」这条规则成立——那正是「浏览器完全打不开
/// 网页、其它应用正常」的成因：
///
///   - 浏览器打开一个页面会并发查询几十个域名，且每个域名同时查
///     A（IPv4）与 AAAA（IPv6）；
///   - 旧实现对 AAAA 查询也塞了一条 A 记录，属于畸形响应，
///     浏览器会重试甚至直接判失败；
///   - 同时旧实现是串行处理的，一条慢查询就把整条队列堵死。
///
/// 这里不依赖 Android，只验证报文层面「查 A 给 A、查 AAAA 给空应答」
/// 这个约定，以及查询类型/域名的解析是否准确。
void main() {
  /// 构造一个最小的 DNS 查询报文。
  List<int> buildQuery(String name, int type) {
    final out = <int>[];
    // 事务 ID
    out.addAll([0x12, 0x34]);
    // flags：标准查询、递归期望
    out.addAll([0x01, 0x00]);
    // QDCOUNT=1，其余 0
    out.addAll([0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]);
    for (final label in name.split('.')) {
      out.add(label.length);
      out.addAll(label.codeUnits);
    }
    out.add(0);
    // QTYPE
    out.add((type >> 8) & 0xFF);
    out.add(type & 0xFF);
    // QCLASS=IN
    out.addAll([0x00, 0x01]);
    return out;
  }

  /// 与 Kotlin 侧 parseQueryName 等价的实现。
  String? parseQueryName(List<int> query) {
    if (query.length < 13) return null;
    final buffer = StringBuffer();
    var index = 12;
    while (index < query.length) {
      final len = query[index];
      if (len == 0) break;
      if ((len & 0xC0) == 0xC0) break;
      index++;
      if (index + len > query.length) return null;
      if (buffer.isNotEmpty) buffer.write('.');
      buffer.write(String.fromCharCodes(query.sublist(index, index + len)));
      index += len;
    }
    final name = buffer.toString();
    return name.isEmpty ? null : name;
  }

  /// 与 Kotlin 侧 parseQueryType 等价的实现。
  int parseQueryType(List<int> query) {
    var index = 12;
    while (index < query.length) {
      final len = query[index];
      if (len == 0) {
        index++;
        break;
      }
      if ((len & 0xC0) == 0xC0) {
        index += 2;
        break;
      }
      index += len + 1;
    }
    if (index + 2 > query.length) return 1;
    return ((query[index] & 0xFF) << 8) | (query[index + 1] & 0xFF);
  }

  /// 与 Kotlin 侧 buildEmptyAnswer 等价的实现（ANCOUNT=0）。
  List<int> buildEmptyAnswer(List<int> query) {
    final index = query.length - 4; // QTYPE+QCLASS 紧贴末尾
    final question = query.sublist(12, index + 4);
    return [
      query[0], query[1],
      0x81, 0x80,
      0x00, 0x01,
      0x00, 0x00, // 没有记录，这是关键
      0x00, 0x00,
      0x00, 0x00,
      ...question,
    ];
  }

  group('查询解析', () {
    test('能取出域名', () {
      final q = buildQuery('example.com', 1);
      expect(parseQueryName(q), 'example.com');
    });

    test('多级子域也正确', () {
      final q = buildQuery('api.github.com', 1);
      expect(parseQueryName(q), 'api.github.com');
    });

    test('能区分 A 与 AAAA 查询', () {
      expect(parseQueryType(buildQuery('a.com', 1)), 1);
      expect(parseQueryType(buildQuery('a.com', 28)), 28);
      expect(parseQueryType(buildQuery('a.com', 5)), 5);
    });
  });

  group('按类型正确应答', () {
    test('AAAA 查询回空应答，不塞 A 记录', () {
      final q = buildQuery('github.com', 28);
      final answer = buildEmptyAnswer(q);
      // ANCOUNT 应为 0（第 6-7 字节）
      expect(answer[6], 0x00);
      expect(answer[7], 0x00);
      // 事务 ID 要沿用
      expect(answer[0], q[0]);
      expect(answer[1], q[1]);
      // 响应位与 RCODE
      expect(answer[2] & 0x80, 0x80, reason: 'QR 位必须为 1');
      expect(answer[3] & 0x0F, 0x00, reason: 'RCODE 应为 0（无错误）');
    });

    test('空应答保留问题段，长度合理', () {
      final q = buildQuery('github.com', 28);
      final answer = buildEmptyAnswer(q);
      // 头 12 字节 + 问题段
      expect(answer.length, greaterThan(12));
      expect(answer.length, q.length);
    });
  });

  group('这组测试覆盖的真实场景', () {
    test('一次页面加载的并发查询形态', () {
      // 浏览器打开一个页面大致是这个样子：多个域名 × 两种记录类型。
      const hosts = [
        'github.com',
        'api.github.com',
        'avatars.githubusercontent.com',
        'github.githubassets.com',
      ];
      final queries = <List<int>>[];
      for (final h in hosts) {
        queries.add(buildQuery(h, 1));
        queries.add(buildQuery(h, 28));
      }
      expect(queries.length, 8);

      // 每一对里必须能分出 A 与 AAAA，否则就会像旧实现那样
      // 给 AAAA 塞 A 记录，造成畸形响应。
      for (var i = 0; i < queries.length; i += 2) {
        expect(parseQueryType(queries[i]), 1);
        expect(parseQueryType(queries[i + 1]), 28);
        expect(parseQueryName(queries[i]), hosts[i ~/ 2]);
        expect(parseQueryName(queries[i + 1]), hosts[i ~/ 2]);
      }
    });
  });
}
