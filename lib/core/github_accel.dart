import 'dart:async';
import 'dart:convert';
import 'dart:io';

// GitHub 访问加速：取一份实测可用的 IP 列表。
//
// 思路与下载器的多镜像思路一致——不迷信单一来源，而是：
//   1. 先取 GitHub-IP-hosts（首选，维护更勤、覆盖面更广）；
//   2. 它取不到或一条都没验过，再退到 GitHub520；
//   3. 每条 IP 都用「连到该 IP + 用域名做 SNI 与证书校验」验证，
//      握手成功才算这条 IP 真的在服务这个域名。
//
// 第 3 步是关键：hosts 里写一个连不上或证书不对的 IP，比不写更糟——
// 会把原本能用的 github.com 直接指到黑洞里。所以这里宁可少写几条，
// 也不写没验过的。

// 一个 hosts 条目：域名 -> IP。
class HostEntry {
  final String host;
  final String ip;

  const HostEntry(this.host, this.ip);

  @override
  String toString() => '$ip $host';

  @override
  bool operator ==(Object other) =>
      other is HostEntry && other.host == host && other.ip == ip;

  @override
  int get hashCode => Object.hash(host, ip);
}

// 加速源的定义。
class HostsSource {
  /// 稳定的内部 id（存进设置用）。
  final String id;

  /// 显示名。
  final String name;

  /// 说明（怎么来的、维护情况）。
  final String note;

  /// 候选下载地址，按顺序尝试。第一个是不走代理的直连，
  /// 后面两个是代理镜像——GitHub 直连本身可能就不通。
  final List<String> urls;

  const HostsSource({
    required this.id,
    required this.name,
    required this.note,
    required this.urls,
  });
}

// 首选源：ittuann/GitHub-IP-hosts。
const HostsSource kSourceGithubIpHosts = HostsSource(
  id: 'github-ip-hosts',
  name: 'GitHub-IP-hosts',
  note: '自动测速更新，覆盖 github.com 与相关子域',
  urls: [
    'https://raw.githubusercontent.com/ittuann/GitHub-IP-hosts/main/hosts',
    'https://gh-proxy.com/https://raw.githubusercontent.com/ittuann/GitHub-IP-hosts/main/hosts',
    'https://cdn.jsdelivr.net/gh/ittuann/GitHub-IP-hosts@main/hosts',
  ],
);

// 备选源：521xueweihan/GitHub520。
const HostsSource kSourceGithub520 = HostsSource(
  id: 'github520',
  name: 'GitHub520',
  note: '老牌加速列表，GitHub-IP-hosts 不可用时自动改用',
  urls: [
    'https://raw.githubusercontent.com/521xueweihan/GitHub520/main/hosts',
    'https://gh-proxy.com/https://raw.githubusercontent.com/521xueweihan/GitHub520/main/hosts',
    'https://cdn.jsdelivr.net/gh/521xueweihan/GitHub520@main/hosts',
  ],
);

// 按优先级排列的全部源。
const List<HostsSource> kHostsSources = [
  kSourceGithubIpHosts,
  kSourceGithub520,
];

// 我们只关心这些域名——写 hosts 的目的是让 GitHub 相关访问变快，
// 不是接管整个系统的域名解析。范围收窄也降低了出错的影响面。
const List<String> kGithubHostSuffixes = [
  'github.com',
  'githubusercontent.com',
  'githubassets.com',
  'github.io',
  'githubcopilot.com',
  'github.dev',
  'ghcr.io',
];

// 判断某个域名是否属于我们管的范围。
bool isGithubHost(String host) {
  final lower = host.toLowerCase();
  for (final suffix in kGithubHostSuffixes) {
    if (lower == suffix || lower.endsWith('.$suffix')) return true;
  }
  return false;
}

// 解析 hosts 文本，只保留 GitHub 相关行。
//
// 能容忍这几种实际出现的写法：
//   `140.82.113.26   alive.github.com`
//   `140.82.114.6    api.github.com  # 注释`
//   制表符分隔、行尾 CRLF、行首空白、`#` 开头的注释行。
List<HostEntry> parseHosts(String text) {
  final entries = <HostEntry>[];
  final seen = <String>{};
  for (final rawLine in const LineSplitter().convert(text)) {
    var line = rawLine;
    final hash = line.indexOf('#');
    if (hash >= 0) line = line.substring(0, hash);
    line = line.trim();
    if (line.isEmpty) continue;

    final parts = line.split(RegExp(r'\s+'));
    if (parts.length < 2) continue;
    final ip = parts[0];
    if (!_looksLikeIpv4(ip)) continue;
    // 一行可以跟多个域名，逐个判断。
    for (var i = 1; i < parts.length; i++) {
      final host = parts[i].toLowerCase();
      if (host.isEmpty || !isGithubHost(host)) continue;
      if (!seen.add(host)) continue;
      entries.add(HostEntry(host, ip));
    }
  }
  return entries;
}

bool _looksLikeIpv4(String value) {
  final parts = value.split('.');
  if (parts.length != 4) return false;
  for (final p in parts) {
    if (p.isEmpty || p.length > 3) return false;
    final n = int.tryParse(p);
    if (n == null || n < 0 || n > 255) return false;
  }
  return true;
}

// 一条 IP 的验证结果。
class HostProbe {
  final HostEntry entry;

  /// 握手耗时（毫秒）。null 表示验证失败。
  final int? latencyMs;

  const HostProbe(this.entry, this.latencyMs);

  bool get ok => latencyMs != null;
}

// 连到指定 IP，用 [host] 做 SNI 与证书校验。
//
// 这不是普通 ping：ping 通了不代表 TLS 能过（可能被中间设备劫持、
// 证书不匹配、或者该 IP 根本不服务这个域名）。只有 TLS 握手带着
// 正确的域名且证书校验通过，才说明「把 hosts 指到这个 IP 是有效的」。
Future<int?> verifyHostEntry(
  HostEntry entry, {
  Duration timeout = const Duration(seconds: 6),
}) async {
  Socket? raw;
  SecureSocket? tls;
  final stopwatch = Stopwatch()..start();
  try {
    raw = await Socket.connect(
      entry.ip,
      443,
      timeout: timeout,
    );
    tls = await SecureSocket.secure(
      raw,
      host: entry.host,
    ).timeout(timeout);
    stopwatch.stop();
    return stopwatch.elapsedMilliseconds;
  } catch (_) {
    return null;
  } finally {
    try {
      await tls?.close();
    } catch (_) {}
    try {
      raw?.destroy();
    } catch (_) {}
  }
}

// 一次加速准备（取列表 + 验证 + 择优）的完整结果。
class HostsResolveResult {
  /// 实际用到的源 id；一条都没成功时为 null。
  final String? sourceId;
  final String? sourceName;

  /// 验证通过、可以直接写进 hosts 的条目。
  final List<HostEntry> entries;

  /// 取到了列表但一条都没验过（此时调用方不该提示「成功」）。
  final bool fetchedButUnverified;

  /// 每个源的失败原因，便于在界面上说清楚为什么没成。
  final Map<String, String> failures;

  /// 取列表花的时间。
  final int fetchMs;

  /// 验证花的时间。
  final int verifyMs;

  const HostsResolveResult({
    required this.sourceId,
    required this.sourceName,
    required this.entries,
    required this.failures,
    this.fetchedButUnverified = false,
    this.fetchMs = 0,
    this.verifyMs = 0,
  });

  bool get ok => entries.isNotEmpty;

  /// 每个域名挑延迟最低的那个 IP。
  ///
  /// 同一域名常有多个 IP（GitHub 本身就是多 IP 轮询），全写进去
  /// 只会让解析结果不确定。留最快的一条，行为可预测。
  static List<HostEntry> pickFastest(List<HostProbe> probes) {
    final best = <String, HostProbe>{};
    for (final probe in probes) {
      if (!probe.ok) continue;
      final host = probe.entry.host;
      final current = best[host];
      if (current == null ||
          (probe.latencyMs ?? 1 << 30) < (current.latencyMs ?? 1 << 30)) {
        best[host] = probe;
      }
    }
    final result = best.values.map((p) => p.entry).toList()
      ..sort((a, b) => a.host.compareTo(b.host));
    return result;
  }
}

// 带进度回调的解析流程。
typedef HostsProgress = void Function(String message, {int? done, int? total});

// 按「首选 GitHub-IP-hosts，失败再用 GitHub520」的顺序取一份可用列表。
//
// [preferredId] 允许用户手动指定只用某个源；为 null 时自动按顺序回退。
Future<HostsResolveResult> resolveHosts({
  HostsProgress? onProgress,
  String? preferredId,
  Duration fetchTimeout = const Duration(seconds: 15),
  Duration verifyTimeout = const Duration(seconds: 6),
  int maxConcurrency = 16,
}) async {
  final failures = <String, String>{};
  final sources = preferredId == null
      ? kHostsSources
      : kHostsSources.where((s) => s.id == preferredId).toList();
  if (sources.isEmpty) {
    return HostsResolveResult(
      sourceId: null,
      sourceName: null,
      entries: const [],
      failures: {'': '未找到指定的加速源：$preferredId'},
    );
  }

  var fetchMs = 0;
  var verifyMs = 0;

  for (final source in sources) {
    onProgress?.call('正在获取 ${source.name} 的 IP 列表…');

    final fetchWatch = Stopwatch()..start();
    String? text;
    final urlErrors = <String>[];
    for (final url in source.urls) {
      try {
        text = await _fetchText(url, fetchTimeout);
        if (text != null && text.trim().isNotEmpty) break;
        text = null;
        urlErrors.add('空响应');
      } catch (error) {
        urlErrors.add(_short(error));
      }
    }
    fetchWatch.stop();
    fetchMs += fetchWatch.elapsedMilliseconds;

    if (text == null) {
      failures[source.id] = '取不到列表（${urlErrors.join('；')}）';
      continue;
    }

    final parsed = parseHosts(text);
    if (parsed.isEmpty) {
      failures[source.id] = '列表里没有 GitHub 相关条目';
      continue;
    }

    onProgress?.call(
      '正在验证 ${parsed.length} 个 IP…',
      done: 0,
      total: parsed.length,
    );
    final verifyWatch = Stopwatch()..start();
    final probes = await _verifyAll(
      parsed,
      timeout: verifyTimeout,
      maxConcurrency: maxConcurrency,
      onProgress: (done) => onProgress?.call(
        '正在验证 IP…',
        done: done,
        total: parsed.length,
      ),
    );
    verifyWatch.stop();
    verifyMs += verifyWatch.elapsedMilliseconds;

    final usable = HostsResolveResult.pickFastest(probes);
    if (usable.isEmpty) {
      failures[source.id] = '${parsed.length} 个 IP 全部握手失败';
      continue;
    }

    return HostsResolveResult(
      sourceId: source.id,
      sourceName: source.name,
      entries: usable,
      failures: failures,
      fetchMs: fetchMs,
      verifyMs: verifyMs,
    );
  }

  return HostsResolveResult(
    sourceId: null,
    sourceName: null,
    entries: const [],
    failures: failures,
    fetchedButUnverified: true,
    fetchMs: fetchMs,
    verifyMs: verifyMs,
  );
}

Future<String?> _fetchText(String url, Duration timeout) async {
  final client = HttpClient()
    ..connectionTimeout = timeout
    ..userAgent = 'InkFetch/1.0';
  try {
    final request = await client.getUrl(Uri.parse(url)).timeout(timeout);
    request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
    final response = await request.close().timeout(timeout);
    if (response.statusCode != HttpStatus.ok) {
      await response.drain<void>().catchError((_) {});
      throw HttpException('HTTP ${response.statusCode}');
    }
    final bytes = await response
        .fold<List<int>>(<int>[], (acc, chunk) => acc..addAll(chunk))
        .timeout(timeout);
    return utf8.decode(bytes, allowMalformed: true);
  } finally {
    client.close(force: true);
  }
}

String _short(Object error) {
  final text = error.toString().replaceAll('\n', ' ');
  return text.length <= 60 ? text : '${text.substring(0, 60)}…';
}

// 并发验证，但保持结果顺序无关（后面会按域名择优）。
Future<List<HostProbe>> _verifyAll(
  List<HostEntry> entries, {
  required Duration timeout,
  required int maxConcurrency,
  void Function(int done)? onProgress,
}) async {
  final results = <HostProbe>[];
  var index = 0;
  var done = 0;
  final limit = maxConcurrency < 1 ? 1 : maxConcurrency;

  Future<void> worker() async {
    while (true) {
      final i = index++;
      if (i >= entries.length) return;
      final entry = entries[i];
      final latency = await verifyHostEntry(entry, timeout: timeout);
      results.add(HostProbe(entry, latency));
      done++;
      onProgress?.call(done);
    }
  }

  await Future.wait([for (var i = 0; i < limit; i++) worker()]);
  return results;
}
