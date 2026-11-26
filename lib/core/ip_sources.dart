import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'github_accel.dart';

// 候选 IP 的收集：不只依赖第三方列表。
//
// 之前的做法有个结构性缺陷：只用 GitHub-IP-hosts / GitHub520 给的 IP。
// 那些列表是按「大陆常见网络」整批测出来的固定结论，未必适合当前这台
// 机器、这个运营商、这一刻。实测就出现过：列表给 140.82.113.x（美国），
// 而系统 DNS 解析到 20.205.243.x（Azure 中国节点）反而更快——
// 于是「开了加速比直连慢 50%」。
//
// 所以现在收集多个来源，**全部参与实测**，谁快用谁：
//   1. 公共 DNS 的解析结果（系统 DNS、DoH 服务）——反映当前网络实际可达的节点
//   2. GitHub 官方 Meta 接口（api.github.com/meta）——官方公布的可用 IP 段
//   3. 第三方 hosts 列表——覆盖面广，但只作为候选之一，不再盲信
//   4. 用户的阿里云中转（只在前面都不理想时才考虑，见 relay.dart）

/// 一个候选 IP 及其出处。
class CandidateIp {
  final String ip;

  /// 这条候选是从哪来的，界面上用来解释「为什么选它」。
  final String origin;

  const CandidateIp(this.ip, this.origin);

  @override
  bool operator ==(Object other) =>
      other is CandidateIp && other.ip == ip;

  @override
  int get hashCode => ip.hashCode;

  @override
  String toString() => '$ip($origin)';
}

/// 公共 DNS 服务：用 DoH（DNS over HTTPS）查询，避免明文 DNS 被污染。
///
/// 覆盖国内与国外几家，因为不同运营商对不同 DoH 的连通性差别很大。
const List<({String name, String url})> kPublicDohServices = [
  (name: '阿里 DoH', url: 'https://223.5.5.5/resolve'),
  (name: '腾讯 DoH', url: 'https://doh.pub/dns-query'),
  (name: 'DNSPod DoH', url: 'https://1.12.12.12/resolve'),
  (name: 'Cloudflare DoH', url: 'https://cloudflare-dns.com/dns-query'),
];

/// 用系统 DNS 解析域名，拿到当前网络实际会连的 IP。
///
/// 注意：这个结果本身**可能被污染**，所以它只是候选之一，
/// 后面一律要过 TLS 证书校验 + 实测速度。
Future<List<CandidateIp>> resolveViaSystemDns(
  String host, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  try {
    final addresses = await InternetAddress.lookup(
      host,
    ).timeout(timeout);
    return addresses
        .where((a) => a.type == InternetAddressType.IPv4)
        .map((a) => CandidateIp(a.address, '系统 DNS'))
        .toList();
  } catch (_) {
    return const [];
  }
}

/// 通过 DoH 查询域名，绕过本地 DNS 可能遭受的污染。
Future<List<CandidateIp>> resolveViaDoh(
  String host,
  ({String name, String url}) service, {
  Duration timeout = const Duration(seconds: 6),
}) async {
  final client = HttpClient()
    ..connectionTimeout = timeout
    ..userAgent = 'InkFetch/1.0';
  try {
    // 各家的 DoH 都支持 GET + name/type 参数、返回 application/dns-json，
    // 所以统一按这个形式请求即可。
    final uri = Uri.parse('${service.url}?name=$host&type=A');
    final request = await client.getUrl(uri).timeout(timeout);
    request.headers.set(HttpHeaders.acceptHeader, 'application/dns-json');
    final response = await request.close().timeout(timeout);
    if (response.statusCode != HttpStatus.ok) {
      await response.drain<void>().catchError((_) {});
      return const [];
    }
    final text = await utf8.decoder
        .bind(response)
        .join()
        .timeout(timeout);
    final decoded = jsonDecode(text);
    if (decoded is! Map<String, dynamic>) return const [];
    final answers = decoded['Answer'];
    if (answers is! List) return const [];
    final ips = <CandidateIp>[];
    for (final answer in answers) {
      if (answer is! Map) continue;
      // type 1 = A 记录
      if (answer['type'] != 1) continue;
      final data = answer['data'];
      if (data is String && _isIpv4(data)) {
        ips.add(CandidateIp(data, service.name));
      }
    }
    return ips;
  } catch (_) {
    return const [];
  } finally {
    client.close(force: true);
  }
}

/// 从 GitHub 官方 Meta 接口取可用 IP 段。
///
/// api.github.com/meta 会返回各服务（git、web、api…）的 CIDR 范围。
/// 这些是官方公布的、确实在服务 GitHub 的地址段，比第三方列表更可靠。
///
/// 注意拿到的是 CIDR 段而不是单个 IP，需要从中挑若干代表地址实测。
Future<List<CandidateIp>> fetchGithubMetaRanges({
  Duration timeout = const Duration(seconds: 8),
  Function(String message)? onProgress,
}) async {
  // 直连可能不通，按顺序尝试镜像。
  const urls = [
    'https://api.github.com/meta',
    'https://gh-proxy.com/https://api.github.com/meta',
  ];
  String? text;
  for (final url in urls) {
    final client = HttpClient()
      ..connectionTimeout = timeout
      ..userAgent = 'InkFetch/1.0';
    try {
      onProgress?.call('正在读取 GitHub 官方 IP 段…');
      final request = await client.getUrl(Uri.parse(url)).timeout(timeout);
      final response = await request.close().timeout(timeout);
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>().catchError((_) {});
        continue;
      }
      text = await utf8.decoder.bind(response).join().timeout(timeout);
      if (text.trim().isNotEmpty) break;
    } catch (_) {
      continue;
    } finally {
      client.close(force: true);
    }
  }
  if (text == null) return const [];

  try {
    final decoded = jsonDecode(text);
    if (decoded is! Map<String, dynamic>) return const [];
    // 只取与我们相关的几类：git（下载）、web、api。
    //
    // 注意：这三类合起来有两百多个网段，逐个实测是跑不完的
    // （实测 71 个候选串行测速就超过 8 分钟）。这里只取**最可能
    // 可用**的一小批：GitHub 的 git/web 服务集中在少数几个网段，
    // 且与当前网络同区域（前缀 20.x、4.x 的 Azure 节点）的优先。
    final all = <String>[];
    for (final key in ['git', 'web']) {
      final ranges = decoded[key];
      if (ranges is! List) continue;
      for (final range in ranges) {
        if (range is! String) continue;
        final ip = _representativeIpFromCidr(range);
        if (ip != null) all.add(ip);
      }
    }
    // 去重后按「是否常见可用段」排序，取前若干个就够实测了。
    final unique = <String>[];
    final seen = <String>{};
    for (final ip in all) {
      if (seen.add(ip)) unique.add(ip);
    }
    unique.sort((a, b) {
      final pa = _priorityOf(a);
      final pb = _priorityOf(b);
      if (pa != pb) return pa.compareTo(pb);
      return a.compareTo(b);
    });
    return unique.take(kMaxMetaCandidates)
        .map((ip) => CandidateIp(ip, 'GitHub 官方'))
        .toList();
  } catch (_) {
    return const [];
  }
}

/// 官方网段里最多取几个来实测。
///
/// 定 6 的原因是测速总时长：每个候选要跑 2 次真实请求，
/// 加上直连基准，候选数直接决定用户要等多久。
/// 实测下来 6 个刚好能在十几秒内出结果，再多人就不愿等了。
const int kMaxMetaCandidates = 6;

/// 官方网段的优先级：数字越小越优先实测。
///
/// 依据是 GitHub 实际提供 git/web 服务的几组常见地址：
///   - 140.82.x、143.55.x：GitHub 自有 AS
///   - 20.x、4.x：Azure 全球节点（国内访问常落在这里）
///   - 185.199.x：GitHub Pages / raw CDN
/// 其余（大量 172.x、48.x 等）多为内部分配段，盲测命中率低，
/// 排在后面，被 kMaxMetaCandidates 截掉也不可惜。
int _priorityOf(String ip) {
  if (ip.startsWith('140.82.') || ip.startsWith('143.55.')) return 0;
  if (ip.startsWith('20.')) return 1;
  if (ip.startsWith('4.')) return 2;
  if (ip.startsWith('185.199.')) return 3;
  return 9;
}

/// 从 CIDR 里取一个代表地址（网段起的第一个可用地址）。
///
/// GitHub Meta 给的是 /20、/22 这类大段，不能全测——只取每段的
/// 首个主机地址当代表，既覆盖各段，又把候选数控制在可测范围。
String? _representativeIpFromCidr(String cidr) {
  final slash = cidr.indexOf('/');
  if (slash < 0) return null;
  final base = cidr.substring(0, slash);
  if (!_isIpv4(base)) return null;
  final parts = base.split('.').map(int.parse).toList();
  // 取 .1 作为该段代表（.0 是网络地址，不响应）。
  return '${parts[0]}.${parts[1]}.${parts[2]}.1';
}

bool _isIpv4(String value) {
  final parts = value.split('.');
  if (parts.length != 4) return false;
  for (final p in parts) {
    if (p.isEmpty || p.length > 3) return false;
    final n = int.tryParse(p);
    if (n == null || n < 0 || n > 255) return false;
  }
  return true;
}

/// 汇总所有来源的候选 IP（去重）。
///
/// [listedEntries] 是第三方 hosts 列表给出的条目；
/// 只取其中与我们关心的域名匹配的部分。
Future<List<CandidateIp>> collectCandidates({
  required String host,
  required List<HostEntry> listedEntries,
  Function(String message)? onProgress,
}) async {
  final seen = <String>{};
  final result = <CandidateIp>[];

  void add(Iterable<CandidateIp> items) {
    for (final item in items) {
      if (seen.add(item.ip)) result.add(item);
    }
  }

  // 1) 第三方列表里该域名的条目
  add(
    listedEntries
        .where((e) => e.host == host)
        .map((e) => CandidateIp(e.ip, '列表')),
  );

  // 2) 系统 DNS 当前解析到的地址
  onProgress?.call('正在查询系统 DNS…');
  add(await resolveViaSystemDns(host));

  // 3) 各公共 DoH
  for (final service in kPublicDohServices) {
    onProgress?.call('正在查询 ${service.name}…');
    add(await resolveViaDoh(host, service));
  }

  // 4) GitHub 官方 IP 段
  add(await fetchGithubMetaRanges(onProgress: onProgress));

  return result;
}
