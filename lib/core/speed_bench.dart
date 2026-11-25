import 'dart:async';
import 'dart:convert';
import 'dart:io';

// 「直连 vs 加速」速度对比。
//
// 之前只测了 TLS 握手耗时——那是「能不能连上」，不是「快不快」。
// 用户真正关心的是：开了加速到底有没有变快？快了多少？
//
// 所以这里做一次真实 HTTP 请求，分别走两条路：
//   直连：交给系统 DNS 解析域名（当前没有加速时的真实体验）
//   加速：直接连到我们验过的那个 IP，仍用域名做 SNI 与证书校验
//
// 比的是**同一条路径、同一个文件的完整请求耗时**，这样结果才有意义。

/// 一次测速的结果。
class SpeedSample {
  /// 连接 + TLS 握手耗时（毫秒）。
  final int handshakeMs;

  /// 从发起请求到读完响应的总耗时（毫秒）。
  final int totalMs;

  /// 收到的字节数。
  final int bytes;

  /// 是否成功。
  final bool ok;

  /// 失败原因。
  final String? error;

  const SpeedSample({
    required this.handshakeMs,
    required this.totalMs,
    required this.bytes,
    required this.ok,
    this.error,
  });

  const SpeedSample.failed(String reason)
    : handshakeMs = 0,
      totalMs = 0,
      bytes = 0,
      ok = false,
      error = reason;

  /// 有效速率（字节/秒）。总耗时过短时不给出虚高的数。
  double get bytesPerSecond {
    if (!ok || totalMs <= 0 || bytes <= 0) return 0;
    return bytes * 1000 / totalMs;
  }

  /// 给界面看的速率文案。
  String get speedText {
    if (!ok) return '失败';
    final bps = bytesPerSecond;
    if (bps <= 0) return '—';
    if (bps >= 1024 * 1024) {
      return '${(bps / 1024 / 1024).toStringAsFixed(2)} MB/s';
    }
    if (bps >= 1024) return '${(bps / 1024).toStringAsFixed(0)} KB/s';
    return '${bps.toStringAsFixed(0)} B/s';
  }
}

/// 一次对比的结论。
class SpeedComparison {
  /// 走系统 DNS 的直连结果。
  final SpeedSample direct;

  /// 走验过 IP 的结果。
  final SpeedSample accelerated;

  /// 用来对比的域名（展示用）。
  final String host;

  /// 用来对比的 IP（展示用）。
  final String ip;

  /// 相同数据量下，加速比直连快多少（百分比）。
  ///
  /// 直连彻底失败时返回 null——那不是「快百分之多少」，
  /// 而是「从不可用到可用」，界面上要分开说。
  final double? improvementPercent;

  const SpeedComparison({
    required this.direct,
    required this.accelerated,
    required this.host,
    required this.ip,
    this.improvementPercent,
  });

  /// 直连不通、加速可用：属于「可用性提升」而不是「速度提升」。
  bool get isAvailabilityGain => !direct.ok && accelerated.ok;

  /// 两边都失败。
  bool get bothFailed => !direct.ok && !accelerated.ok;

  /// 是否值得启用加速。
  ///
  /// 判定标准写死在这里，界面只负责展示：
  ///   - 直连失败而加速可用 → 值得（从不能用到能用）；
  ///   - 加速至少比直连快 10% → 值得；
  ///   - 其它情况（差不多、甚至更慢）→ 不值得，不该改 hosts。
  ///
  /// 门槛定 10% 而不是 0%：网络抖动很容易让一次测量差个几毫秒，
  /// 若只要快一丁点就写 hosts，用户会发现「开了也没感觉」，
  /// 却已经背上了改系统文件的成本。
  bool get worthEnabling {
    if (bothFailed) return false;
    if (isAvailabilityGain) return true;
    if (!accelerated.ok) return false;
    final value = improvementPercent;
    if (value == null) return false;
    return value >= 10.0;
  }

  /// 给界面的一句话结论。
  String get verdict {
    if (bothFailed) {
      return '两条路都失败了，可能是网络本身不通，建议稍后重试';
    }
    if (isAvailabilityGain) {
      return '直连不通，加速后可用（${accelerated.speedText}）';
    }
    if (!accelerated.ok) {
      return '加速后反而连不上，不建议启用';
    }
    final value = improvementPercent ?? 0;
    if (value >= 10) {
      return '比直连快 ${value.toStringAsFixed(0)}%，值得启用';
    }
    if (value > -10) {
      return '和直连差不多（${value >= 0 ? '+' : ''}${value.toStringAsFixed(0)}%），不建议改动';
    }
    return '比直连慢 ${value.abs().toStringAsFixed(0)}%，不建议启用';
  }
}

/// 用于测速的真实地址。
///
/// 选 **codeload.github.com** 上的一个仓库归档，原因是：
///   - 它正是这个应用下载仓库归档时走的域名，测出来的结果有代表性；
///   - 实测 raw.githubusercontent.com 在这类网络下经常整个握手失败，
///     拿它当基准会让「测速」永远失败（这正是之前测试失败的根因）；
///   - 归档体积小，一次往返就能比较完，不会为了测速花掉用户流量。
///
/// 注意：因为体积小，这里比的不是「带宽」而是**完成同一次真实下载
/// 所需的时间**——对用户来说，这正是「点下载到拿到文件」的体感。
const String kSpeedTestHost = 'codeload.github.com';
const String kSpeedTestPath =
    '/octocat/Spoon-Knife/legacy.zip/refs/heads/main';

/// 对一个目标发起真实的 HTTPS 请求并计时。
///
/// [viaIp] 为空表示走系统 DNS（模拟未加速）；给了 IP 就直连该 IP，
/// 但 TLS 仍然用 [host] 做 SNI 与证书校验，因此校验强度不变。
Future<SpeedSample> measureRealRequest({
  String host = kSpeedTestHost,
  String path = kSpeedTestPath,
  String? viaIp,
  Duration timeout = const Duration(seconds: 10),
}) async {
  Socket? raw;
  SecureSocket? tls;
  final stopwatch = Stopwatch()..start();
  var handshakeMs = 0;
  try {
    final connectTarget = viaIp ?? host;
    raw = await Socket.connect(connectTarget, 443, timeout: timeout);
    tls = await SecureSocket.secure(raw, host: host).timeout(timeout);
    handshakeMs = stopwatch.elapsedMilliseconds;

    final request =
        'GET $path HTTP/1.1\r\n'
        'Host: $host\r\n'
        'User-Agent: InkFetch/1.0\r\n'
        'Accept: */*\r\n'
        'Connection: close\r\n'
        '\r\n';
    tls.write(request);
    await tls.flush();

    // 读完整个响应体，用「总量 / 总耗时」算真实速率。
    final bytes = <int>[];
    await for (final chunk in tls.timeout(timeout)) {
      bytes.addAll(chunk);
      // 8KB 左右的文件读完就停，避免个别情况下连接不关导致挂住。
      if (bytes.length > 4 * 1024 * 1024) break;
    }
    stopwatch.stop();
    if (bytes.isEmpty) {
      return const SpeedSample.failed('没有收到数据');
    }
    final text = latin1.decode(bytes, allowInvalid: true);
    final statusLine = text.split('\r\n').first;
    if (!statusLine.contains('200')) {
      return SpeedSample(
        handshakeMs: handshakeMs,
        totalMs: stopwatch.elapsedMilliseconds,
        bytes: 0,
        ok: false,
        error: statusLine.replaceAll('HTTP/1.1 ', 'HTTP ').trim(),
      );
    }
    // 扣掉响应头的字节，只算正文，速率才可比。
    final split = text.indexOf('\r\n\r\n');
    final bodyBytes = split >= 0 ? bytes.length - split - 4 : bytes.length;
    return SpeedSample(
      handshakeMs: handshakeMs,
      totalMs: stopwatch.elapsedMilliseconds,
      bytes: bodyBytes > 0 ? bodyBytes : bytes.length,
      ok: true,
    );
  } catch (error) {
    stopwatch.stop();
    return SpeedSample.failed(_shortError(error));
  } finally {
    try {
      await tls?.close();
    } catch (_) {}
    try {
      raw?.destroy();
    } catch (_) {}
  }
}

String _shortError(Object error) {
  if (error is SocketException) {
    final message = error.message.replaceAll('\n', ' ');
    return message.isEmpty ? '连接失败' : message;
  }
  if (error is TimeoutException) return '超时';
  if (error is TlsException) return 'TLS 握手失败';
  final text = error.toString().replaceAll('\n', ' ');
  return text.length <= 50 ? text : '${text.substring(0, 50)}…';
}

/// 对比「直连」与「走验过 IP」两条路的实际速度。
///
/// 每条路各跑 [samples] 次，取**中位数**作为结果。
/// 单次测量很容易被 DNS 缓存、TCP 慢启动、瞬时抖动带偏——
/// 而这个结论会决定要不要改用户的系统文件，必须稳。
Future<SpeedComparison> compareDirectVsAccelerated({
  required String host,
  required String ip,
  String path = kSpeedTestPath,
  Duration timeout = const Duration(seconds: 10),
  int samples = 3,
  void Function(String message)? onProgress,
}) async {
  final count = samples < 1 ? 1 : samples;

  onProgress?.call('正在测试直连速度…');
  final directRuns = <SpeedSample>[];
  for (var i = 0; i < count; i++) {
    directRuns.add(await measureRealRequest(host: host, path: path, timeout: timeout));
  }

  onProgress?.call('正在测试加速速度…');
  final accelRuns = <SpeedSample>[];
  for (var i = 0; i < count; i++) {
    accelRuns.add(
      await measureRealRequest(host: host, path: path, viaIp: ip, timeout: timeout),
    );
  }

  final direct = _best(directRuns);
  final accel = _best(accelRuns);

  double? improvement;
  if (direct.ok && accel.ok && direct.totalMs > 0) {
    // 用「总的完成时间」比较：两条路下载的是同一个资源，
    // 完成时间短就是体感更快，不依赖文件大小是否够大。
    improvement = (direct.totalMs - accel.totalMs) / direct.totalMs * 100;
  }

  return SpeedComparison(
    direct: direct,
    accelerated: accel,
    host: host,
    ip: ip,
    improvementPercent: improvement,
  );
}

/// 从多次采样里挑一个代表值。
///
/// 成功的样本按总耗时排序取中位数；全失败时返回第一个失败样本
/// （保留错误原因给界面看）。
SpeedSample _best(List<SpeedSample> runs) {
  final ok = runs.where((r) => r.ok).toList()
    ..sort((a, b) => a.totalMs.compareTo(b.totalMs));
  if (ok.isEmpty) return runs.first;
  return ok[ok.length ~/ 2];
}

/// 一个候选 IP 的实测结果。
class CandidateSpeed {
  final String ip;

  /// 出处（系统 DNS / 阿里 DoH / GitHub 官方 / 列表…），用于界面解释。
  final String origin;

  /// 测速样本；ok=false 表示这个 IP 根本不可用。
  final SpeedSample sample;

  const CandidateSpeed({
    required this.ip,
    required this.origin,
    required this.sample,
  });

  bool get ok => sample.ok;
  int get totalMs => sample.totalMs;
}

/// 在所有候选 IP 里实测，找出真正最快的那个。
///
/// 这是「慢 50%」问题的正解：之前只用一个第三方列表给的 IP，
/// 那恰好可能是最慢的（实测列表给 140.82.113.10 要 1186ms，
/// 而腾讯 DoH 给的 20.247.166.65 只要 559ms）。
///
/// 做法：每个候选各跑 [samplesPerCandidate] 次取中位数，
/// 再按最快排序。同时把「系统 DNS 直连」也作为基准一起量，
/// 后面才能回答「加速到底有没有比现状更快」。
Future<BestIpResult> pickFastestIp({
  required String host,
  required List<({String ip, String origin})> candidates,
  String path = kSpeedTestPath,
  Duration timeout = const Duration(seconds: 8),
  int samplesPerCandidate = 2,
  int concurrency = 6,
  bool measureDirectBaseline = true,
  void Function(String message, int done, int total)? onProgress,
}) async {
  // 直连基准：走系统 DNS，代表「什么都不改」时的体验。
  SpeedSample? baseline;
  if (measureDirectBaseline) {
    onProgress?.call('正在测量直连基准…', 0, candidates.length + 1);
    final runs = <SpeedSample>[];
    for (var i = 0; i < samplesPerCandidate; i++) {
      runs.add(await measureRealRequest(host: host, path: path, timeout: timeout));
    }
    baseline = _best(runs);
  }

  // 并发测速：候选可能有十几个，串行测要等很久。
  // 限制并发数是为了避免自己的连接互相抢带宽，反而测不准。
  final measured = List<CandidateSpeed?>.filled(candidates.length, null);
  var done = 0;
  var nextIndex = 0;
  final limit = concurrency < 1 ? 1 : concurrency;

  onProgress?.call('正在逐个测试候选 IP…', 0, candidates.length);

  Future<void> worker() async {
    while (true) {
      final index = nextIndex++;
      if (index >= candidates.length) return;
      final candidate = candidates[index];
      final runs = <SpeedSample>[];
      for (var i = 0; i < samplesPerCandidate; i++) {
        runs.add(
          await measureRealRequest(
            host: host,
            path: path,
            viaIp: candidate.ip,
            timeout: timeout,
          ),
        );
      }
      measured[index] = CandidateSpeed(
        ip: candidate.ip,
        origin: candidate.origin,
        sample: _best(runs),
      );
      done++;
      onProgress?.call('正在逐个测试候选 IP…', done, candidates.length);
    }
  }

  await Future.wait([for (var i = 0; i < limit; i++) worker()]);

  final all = measured.whereType<CandidateSpeed>().toList();
  final usable = all.where((m) => m.ok).toList()
    ..sort((a, b) => a.totalMs.compareTo(b.totalMs));

  return BestIpResult(
    host: host,
    baseline: baseline,
    all: all,
    ranked: usable,
  );
}

/// 择优结果。
class BestIpResult {
  final String host;

  /// 直连基准（走系统 DNS）。null 表示没测。
  final SpeedSample? baseline;

  /// 所有候选的实测结果（含失败的），用于展示与排查。
  final List<CandidateSpeed> all;

  /// 可用候选，按从快到慢排序。
  final List<CandidateSpeed> ranked;

  const BestIpResult({
    required this.host,
    required this.baseline,
    required this.all,
    required this.ranked,
  });

  /// 最快的那条；一个都没有时为 null。
  CandidateSpeed? get best => ranked.isEmpty ? null : ranked.first;

  /// 和直连相比是否值得写 hosts。
  ///
  /// 关键：**只跟直连基准比**。如果所有候选都不比现状快，
  /// 就不该改动系统——那正是之前「慢 50%」的教训。
  bool get worthApplying {
    final top = best;
    if (top == null) return false;
    final base = baseline;
    if (base == null || !base.ok) {
      // 直连不通而候选可用 → 属于可用性提升，值得。
      return true;
    }
    if (base.totalMs <= 0) return false;
    final improvement = (base.totalMs - top.totalMs) / base.totalMs * 100;
    return improvement >= 10.0;
  }

  /// 相对直连提升的百分比；无法计算时为 null。
  double? get improvementPercent {
    final top = best;
    final base = baseline;
    if (top == null || base == null || !base.ok || base.totalMs <= 0) {
      return null;
    }
    return (base.totalMs - top.totalMs) / base.totalMs * 100;
  }
}
