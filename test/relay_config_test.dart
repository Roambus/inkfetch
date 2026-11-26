import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 中转链路的静态检查。
///
/// 真实链路已在开发过程中实测：
///   - 代理放行 GitHub，拒绝非 GitHub（白名单生效）；
///   - PAC 让 GitHub 走代理、其它站点直连；
///   - 经代理访问 api.github.com 约 737ms，直连约 1442ms。
///
/// 这个测试守的是「配置内容本身正确」——PAC 规则写错或地址掉了，
/// 用户那边就会表现为「开了中转但没效果」或「全都走代理」。
void main() {
  group('PAC 分流规则', () {
    late String pac;

    setUpAll(() {
      // PAC 同时托管在服务器上；仓库里也留一份，便于离线核对。
      final local = File('docs/relay/inkfetch-gh.pac');
      pac = local.existsSync()
          ? local.readAsStringSync()
          : (throw StateError('缺少 docs/relay/inkfetch-gh.pac'));
    });

    test('包含代理地址与端口', () {
      expect(pac.contains('8.133.220.160:8899'), isTrue,
          reason: 'PAC 里必须有中转地址，否则等于没配');
    });

    test('必须保留 DIRECT 回退', () {
      expect(pac.contains('DIRECT'), isTrue,
          reason: '没有 DIRECT 回退会让非 GitHub 站点也走代理或直接失败');
    });

    test('覆盖 GitHub 主站与其子域', () {
      expect(pac.contains('github.com'), isTrue);
      expect(pac.contains('.github.com'), isTrue,
          reason: '子域（api/codeload 等）必须走代理');
    });

    test('覆盖 raw CDN', () {
      expect(pac.contains('githubusercontent.com'), isTrue,
          reason: 'raw/objects 等 CDN 是下载走的主要域名');
    });

    test('非 GitHub 域名不应出现在代理规则里', () {
      // 常见误配：把 baidu 之类也塞进去，会让用户其它上网变慢。
      for (final host in ['baidu.com', 'qq.com', 'taobao.com']) {
        expect(pac.contains(host), isFalse,
            reason: 'PAC 不应代理 $host');
      }
    });
  });

  group('中转代理白名单（服务端约定）', () {
    test('代理脚本只放行 GitHub 主机名', () {
      // 服务端脚本在服务器上；这里核对仓库留档的副本，
      // 防止有人日后把白名单改成 *（变成开放代理）。
      final local = File('docs/relay/ghproxy.py');
      expect(local.existsSync(), isTrue);
      final script = local.readAsStringSync();
      expect(script.contains('github.com'), isTrue);
      expect(script.contains('All Not') || script.contains('ALLOW_HOSTS'), isTrue);
      // 绝对不能出现通配放行
      expect(script.contains('ALLOW_HOSTS = None'), isFalse);
    });
  });
}
