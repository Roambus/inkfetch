import 'dart:async';
import 'dart:convert';
import 'dart:io';

// 用户的阿里云中转。
//
// 用途限定得很死：**只做访问加速，不做下载中转**。
// 那台机器是 2 核 1.7G 的小机型，还跑着用户自己的其它站点；
// 如果让它代理大文件下载，会瞬间打满带宽并拖垮那些站点。
//
// 所以：
//   - 只走小体积请求（api.github.com 的元数据、raw CDN 的小文本）；
//   - 服务端对 release/archive 路径直接返回 429（已配置）；
//   - 客户端也只在「本机直连确实不行」时才考虑它，且必须先测速。
//
// 判断是否「值得用中转」的流程：
//   1. 测「本机 → 中转服务器」的往返延迟（拉一个约 2KB 的探针文件）；
//   2. 测「本机 → GitHub 直连」的往返延迟；
//   3. 只有中转明显更快时才用，否则不碰。

/// 中转服务的基础地址与口令。
///
/// 口令不是安全边界（客户端代码里必然可见），只是防止这个端点被
/// 扫描到后当成公开免费代理滥用。
const String kRelayBaseUrl = 'https://www.roambus.me';
const String kRelayToken = 'inkfetch-8f3a2c';

/// 服务端放的探针文件路径（约 2KB）。
const String kRelayProbePath = '/download/../../var/www/relay/probe.txt';

/// 实际可访问的探针地址：直接放在站点根下的一个固定文件。
const String kRelayProbeUrl = '$kRelayBaseUrl/relay-probe.txt';

/// 一次 HTTP 往返的测量结果。
class RoundTrip {
  /// 总耗时（毫秒）；失败为 null。
  final int? totalMs;

  /// 收到的字节数。
  final int bytes;

  /// 失败原因。
  final String? error;

  const RoundTrip({required this.totalMs, required this.bytes, this.error});

  bool get ok => totalMs != null;

  const RoundTrip.failed(String reason)
    : totalMs = null,
      bytes = 0,
      error = reason;
}

/// 测一次到指定 URL 的完整往返（含 TLS 与首包）。
///
/// 用途是**比较线路快慢**，不是测带宽——所以我们只需要
/// 「拿到一个已知小文件要多久」，这与用户刷网页的实际体感最接近。
Future<RoundTrip> measureRoundTrip(
  String url, {
  Map<String, String>? headers,
  Duration timeout = const Duration(seconds: 8),
}) async {
  final client = HttpClient()
    ..connectionTimeout = timeout
    ..userAgent = 'InkFetch/1.0';
  final stopwatch = Stopwatch()..start();
  try {
    final request = await client.getUrl(Uri.parse(url)).timeout(timeout);
    headers?.forEach(request.headers.set);
    final response = await request.close().timeout(timeout);
    if (response.statusCode < 200 || response.statusCode >= 400) {
      await response.drain<void>().catchError((_) {});
      stopwatch.stop();
      return RoundTrip(
        totalMs: stopwatch.elapsedMilliseconds,
        bytes: 0,
        error: 'HTTP ${response.statusCode}',
      );
    }
    final bytes = await response.fold<int>(
      0,
      (sum, chunk) => sum + chunk.length,
    ).timeout(timeout);
    stopwatch.stop();
    return RoundTrip(totalMs: stopwatch.elapsedMilliseconds, bytes: bytes);
  } catch (error) {
    stopwatch.stop();
    return RoundTrip.failed(_short(error));
  } finally {
    client.close(force: true);
  }
}

/// 中转与直连的对比结论。
class RelayAssessment {
  /// 本机 → 中转服务器的往返。
  final RoundTrip toRelay;

  /// 本机 → GitHub 直连的往返。
  final RoundTrip toGithubDirect;

  const RelayAssessment({
    required this.toRelay,
    required this.toGithubDirect,
  });

  /// 中转是否可用（服务器在、探针拿得到）。
  bool get relayReachable => toRelay.ok && toRelay.bytes > 0;

  /// 是否值得启用中转。
  ///
  /// 门槛同样定 10%：中转多一跳，若不比直连快一截就没意义，
  /// 还占用了用户自己服务器的带宽。
  bool get worthUsing {
    if (!relayReachable) return false;
    final relayMs = toRelay.totalMs!;
    final direct = toGithubDirect;
    if (!direct.ok) return true; // 直连不通 → 中转是「从不能用到能用」
    final directMs = direct.totalMs!;
    if (directMs <= 0) return false;
    final improvement = (directMs - relayMs) / directMs * 100;
    return improvement >= 10.0;
  }

  /// 相对直连的提升百分比；无法计算时为 null。
  double? get improvementPercent {
    if (!relayReachable) return null;
    final relayMs = toRelay.totalMs!;
    final direct = toGithubDirect;
    if (!direct.ok || direct.totalMs == null || direct.totalMs! <= 0) {
      return null;
    }
    return (direct.totalMs! - relayMs) / direct.totalMs! * 100;
  }

  String get summary {
    if (!relayReachable) {
      return '中转服务器不可达，不使用';
    }
    if (!toGithubDirect.ok) {
      return '直连 GitHub 不通，可用中转（${toRelay.totalMs}ms）';
    }
    final value = improvementPercent;
    if (value == null) return '无法比较';
    if (value >= 10) {
      return '中转比直连快 ${value.toStringAsFixed(0)}%';
    }
    return '中转没有优势（${value >= 0 ? '+' : ''}${value.toStringAsFixed(0)}%），不使用';
  }
}

/// 评估是否该用中转。
///
/// 注意 [toGithubDirect] 的测量固定打 GitHub 的 API——那是「访问加速」
/// 最典型的场景（拉 release 元数据、查仓库信息）。不用它测下载，
/// 是因为中转本来就不代理下载。
Future<RelayAssessment> assessRelay({
  Duration timeout = const Duration(seconds: 8),
  String directUrl = 'https://api.github.com/meta',
}) async {
  final relayFuture = measureRoundTrip(kRelayProbeUrl, timeout: timeout);
  final directFuture = measureRoundTrip(directUrl, timeout: timeout);
  final toRelay = await relayFuture;
  final toDirect = await directFuture;
  return RelayAssessment(toRelay: toRelay, toGithubDirect: toDirect);
}

/// 通过中转请求一个 GitHub API 路径，返回解析后的 JSON。
///
/// 只在 [RelayAssessment.worthUsing] 为真时才该调用。
Future<Map<String, dynamic>?> fetchViaRelay(
  String path, {
  Duration timeout = const Duration(seconds: 10),
}) async {
  final client = HttpClient()
    ..connectionTimeout = timeout
    ..userAgent = 'InkFetch/1.0';
  try {
    final url = '$kRelayBaseUrl/gh/api/${path.replaceFirst(RegExp(r'^/'), '')}';
    final request = await client.getUrl(Uri.parse(url)).timeout(timeout);
    request.headers.set('X-InkFetch-Relay', kRelayToken);
    final response = await request.close().timeout(timeout);
    if (response.statusCode != HttpStatus.ok) {
      await response.drain<void>().catchError((_) {});
      return null;
    }
    final text = await utf8.decoder.bind(response).join().timeout(timeout);
    final decoded = jsonDecode(text);
    return decoded is Map<String, dynamic> ? decoded : null;
  } catch (_) {
    return null;
  } finally {
    client.close(force: true);
  }
}

/// 通过中转拉一个小文本（例如 hosts 列表）。
Future<String?> fetchTextViaRelay(
  String path, {
  Duration timeout = const Duration(seconds: 15),
}) async {
  final client = HttpClient()
    ..connectionTimeout = timeout
    ..userAgent = 'InkFetch/1.0';
  try {
    final url =
        '$kRelayBaseUrl/gh/raw/${path.replaceFirst(RegExp(r'^/'), '')}';
    final request = await client.getUrl(Uri.parse(url)).timeout(timeout);
    request.headers.set('X-InkFetch-Relay', kRelayToken);
    final response = await request.close().timeout(timeout);
    if (response.statusCode != HttpStatus.ok) {
      await response.drain<void>().catchError((_) {});
      return null;
    }
    // 注意：这里不能用 utf8.decoder.bind(response).join()。
    // 转发过来的响应可能带 chunked 编码且没有 content-length，
    // 直接按流读取会等到连接关闭才结束；服务器那边
    // proxy_buffering 也会让它看起来"没有数据"。
    // 改成逐块累积再解码，并且一旦拿到足够的字节就返回。
    final bytes = <int>[];
    await for (final chunk in response.timeout(timeout)) {
      bytes.addAll(chunk);
      // hosts 列表不到 16KB，超过就说明拿全了或有异常，都可以停了。
      if (bytes.length > 256 * 1024) break;
    }
    if (bytes.isEmpty) return null;
    return utf8.decode(bytes, allowMalformed: true);
  } catch (_) {
    return null;
  } finally {
    client.close(force: true);
  }
}

String _short(Object error) {
  final text = error.toString().replaceAll('\n', ' ');
  return text.length <= 60 ? text : '${text.substring(0, 60)}…';
}
