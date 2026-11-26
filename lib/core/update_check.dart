import 'dart:convert';
import 'dart:io';

import 'package:package_info_plus/package_info_plus.dart';

import 'platform.dart';

/// 版本检查。
///
/// 目标很单纯：打开应用时问一次官网「现在最新是几版」，比当前新就弹一次
/// 提示，让用户可以下载或跳过这个版本。不做自动下载、不做强制升级——
/// 这是单文件免安装的工具，用户随时可以自己换掉那个 exe。
///
/// 关于「官网版本」的取得方式，这里有一条明确的优先级：
///   1. 主站 `https://www.roambus.me/inkfetch/version.json`；
///   2. 主站取不到时，走 GitHub Release 的 tag。
/// 两条都拿不到就当「检查失败」安静退出，不弹任何东西——
/// 网络不通不是用户需要处理的问题。
const String kHomepageUrl = 'https://www.roambus.me/inkfetch/';

/// 版本清单地址。放在产品主页同目录下，和下载文件放在一起，
/// 发布时只需要替换这一个 JSON。
const String kVersionManifestUrl = 'https://www.roambus.me/inkfetch/version.json';

/// 兜底：GitHub 仓库的 latest release。
const String kGitHubLatestReleaseUrl =
    'https://api.github.com/repos/Roambus/inkfetch/releases/latest';

/// 一次版本检查的结果。
class UpdateCheckResult {
  /// 线上最新版本，例如 `2.6.0`。
  final String latest;

  /// 当前运行版本。
  final String current;

  /// 这次检查是否真的拿到了线上版本。
  final bool ok;

  /// 拿到版本的方式，用于设置页显示「检查于何处」。
  final String source;

  /// GitHub Release 页面，用于「去下载」。
  final String? releaseUrl;

  /// 版本说明（可选）。
  final String? notes;

  const UpdateCheckResult({
    required this.latest,
    required this.current,
    required this.ok,
    this.source = '',
    this.releaseUrl,
    this.notes,
  });

  /// 线上版本是否比当前新。
  bool get hasUpdate => ok && compareVersions(latest, current) > 0;
}

/// 语义化版本比较。
///
/// 只比较数字段，忽略 `+build` 与预发布后缀；缺失的段按 0 处理，
/// 所以 `2.6` 与 `2.6.0` 相等。返回 >0 表示 [a] 更新。
int compareVersions(String a, String b) {
  List<int> parse(String v) {
    // 去掉 build 号与预发布后缀，只留 1.2.3
    var core = v.trim().split('+').first;
    core = core.split('-').first;
    final parts = core
        .split('.')
        .map((p) => int.tryParse(p.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0)
        .toList();
    while (parts.length < 3) {
      parts.add(0);
    }
    return parts;
  }

  final pa = parse(a);
  final pb = parse(b);
  for (var i = 0; i < 3; i++) {
    if (pa[i] != pb[i]) return pa[i] - pb[i];
  }
  return 0;
}

/// 当前应用的版本号，读 android/iOS 的 packageInfo，桌面走同一套。
Future<String> currentAppVersion() async {
  try {
    final info = await PackageInfo.fromPlatform();
    return info.version;
  } catch (_) {
    return '';
  }
}

/// 拉取线上版本。
///
/// [fetch] 允许注入，测试里用它避免真的联网。
Future<UpdateCheckResult> checkForUpdate({
  Future<String?> Function(String url)? fetch,
  String? currentVersion,
}) async {
  final current = currentVersion ?? await currentAppVersion();
  final getter = fetch ?? fetchSmallText;

  // 1) 主站清单
  final raw = await getter(kVersionManifestUrl);
  if (raw != null && raw.trim().isNotEmpty) {
    try {
      final json = jsonDecode(raw);
      if (json is Map<String, dynamic>) {
        final latest = (json['version'] ?? json['latest'] ?? '').toString();
        if (latest.isNotEmpty) {
          return UpdateCheckResult(
            latest: latest,
            current: current,
            ok: true,
            source: '官网',
            releaseUrl: json['url']?.toString(),
            notes: json['notes']?.toString(),
          );
        }
      }
    } catch (_) {
      // 清单坏了就当没拿到，继续走兜底
    }
  }

  // 2) GitHub Release 兜底
  final gh = await getter(kGitHubLatestReleaseUrl);
  if (gh != null && gh.trim().isNotEmpty) {
    try {
      final json = jsonDecode(gh);
      if (json is Map<String, dynamic>) {
        final tag = (json['tag_name'] ?? '').toString();
        if (tag.isNotEmpty) {
          return UpdateCheckResult(
            latest: tag.replaceFirst(RegExp(r'^v'), ''),
            current: current,
            ok: true,
            source: 'GitHub',
            releaseUrl:
                json['html_url']?.toString() ??
                'https://github.com/Roambus/inkfetch/releases',
            notes: json['body']?.toString(),
          );
        }
      }
    } catch (_) {}
  }

  return UpdateCheckResult(latest: '', current: current, ok: false);
}

/// 直接拉一个很小的文本资源（版本清单、Release JSON）。
///
/// 不复用 relay.dart 里的取文本函数：那条路把路径拼到中转的 `/gh/raw/`
/// 下面，只适合 GitHub raw；这里要打的是自己的主站和 api.github.com，
/// 走中转反而绕远。也不跟镜像下载共用连接池——版本检查要快，
/// 失败就走，不能因为某个镜像挂着把启动拖住。
Future<String?> fetchSmallText(String url) async {
  final client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 5)
    ..userAgent = 'InkFetch-UpdateCheck/1.0';
  try {
    final request = await client
        .getUrl(Uri.parse(url))
        .timeout(const Duration(seconds: 6));
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    // 始终要最新的一份，缓存会让我们永远看到旧版本号。
    request.headers.set(HttpHeaders.cacheControlHeader, 'no-cache');
    final response = await request.close().timeout(
      const Duration(seconds: 8),
    );
    if (response.statusCode != HttpStatus.ok) {
      await response.drain<void>().catchError((_) {});
      return null;
    }
    // 逐块累积：清单带 chunked 编码没有 content-length，
    // 按流读会一直等到连接关闭，启动时不能卡在那里。
    final bytes = <int>[];
    await for (final chunk in response.timeout(const Duration(seconds: 8))) {
      bytes.addAll(chunk);
      if (bytes.length > 512 * 1024) break;
    }
    if (bytes.isEmpty) return null;
    return utf8.decode(bytes, allowMalformed: true);
  } catch (_) {
    return null;
  } finally {
    client.close(force: true);
  }
}

/// 打开官网。桌面用系统浏览器，Android 交给系统 Intent。
Future<void> openHomepage() => NativeBridge.openUrl(kHomepageUrl);

/// 打开 Release 页面（拿不到时退回仓库地址）。
Future<void> openReleasePage([String? url]) =>
    NativeBridge.openUrl(url ?? 'https://github.com/Roambus/inkfetch/releases');
