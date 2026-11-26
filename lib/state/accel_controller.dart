import 'dart:io';

import 'package:flutter/foundation.dart';

import '../core/accel_platform.dart';
import '../core/github_accel.dart';
import '../core/hosts_file.dart';
import '../core/ip_sources.dart';
import '../core/relay.dart';
import '../core/speed_bench.dart';
import '../core/windows_proxy.dart';

/// 加速方式。
enum AccelApproach {
  /// 自动：两条路都测，选更快的那条。
  auto,

  /// 写 hosts 指向实测最佳 IP。
  hosts,

  /// 走中转服务器。
  relay,

  /// 两条路都不理想。
  none,
}

/// GitHub 加速页面的状态。
///
/// 刻意与 AppController 分开：加速功能有自己的生命周期
/// （取列表 → 验证 → 提权写入 → 可停用），塞进主控制器只会让
/// 那个类越来越难以理解，也会让下载逻辑无谓地跟着一起重建。
class AccelController extends ChangeNotifier {
  /// 当前平台是否支持加速。
  final bool supported = AccelPlatform.isSupported;

  /// 平台的加速方式说明（hosts / VPN）。
  final String method = AccelPlatform.method;

  /// 正在运行的操作名；null 表示空闲。
  String? busyLabel;

  /// 详细进度文案（例如「正在验证 IP…」）。
  String progress = '';

  /// 进度完成的计数，用于界面画进度条。null 表示不确定进度。
  int? progressDone;
  int? progressTotal;

  /// 是否已经启用。
  bool enabled = false;

  /// 当前生效的条目。
  List<HostEntry> activeEntries = const [];

  /// 已解析出来但还没启用的候选（用户可以先看看再决定）。
  List<HostEntry> candidates = const [];

  /// 上次解析用到的源名。
  String? resolvedSourceName;

  /// 直连与加速的速度对比结果；null 表示还没测。
  SpeedComparison? comparison;

  /// 多源择优的结果（含每个候选 IP 的实测速度）。这是决定「用哪个 IP」
  /// 和「要不要改系统」的唯一依据。
  BestIpResult? bestIp;

  /// 候选 IP 的出处统计，界面上说明「试了几个来源」。
  int candidateCount = 0;

  /// 中转评估结果（是否值得走自己的阿里云中转）。
  RelayAssessment? relay;

  /// 是否启用中转。只在 relay.worthUsing 为真时才可能为 true。
  bool relayEnabled = false;

  /// 用户显式选择的加速方式。
  ///
  /// 早期实现只做一件事：IP 有效就用 IP，IP 无效才去看中转。
  /// 结果是「中转明明更快，但界面不给选」——因为 IP 方案一旦
  /// 稍有提升，中转连评估都不会发生。
  ///
  /// 现在两条路都会评估，并默认选更快的那条；用户也可以手动切换。
  AccelApproach approach = AccelApproach.auto;

  /// 实际生效的方式（由 [approach] 与两条路的实测结果共同决定）。
  AccelApproach get effectiveApproach {
    final ipOk = bestIp?.worthApplying ?? false;
    final relayOk = relay?.worthUsing ?? false;
    switch (approach) {
      case AccelApproach.hosts:
        return AccelApproach.hosts;
      case AccelApproach.relay:
        return relayOk ? AccelApproach.relay : AccelApproach.none;
      case AccelApproach.none:
        return AccelApproach.none;
      case AccelApproach.auto:
        if (!ipOk && !relayOk) return AccelApproach.none;
        if (!ipOk) return AccelApproach.relay;
        if (!relayOk) return AccelApproach.hosts;
        // 两条都可用：比谁更快。
        final ipMs = bestIp?.best?.totalMs ?? 1 << 30;
        final relayMs = relay?.toRelay.totalMs ?? 1 << 30;
        return relayMs < ipMs ? AccelApproach.relay : AccelApproach.hosts;
    }
  }

  /// 上次解析的耗时统计。
  int lastFetchMs = 0;
  int lastVerifyMs = 0;

  /// 每个源的失败原因（用于把「为什么不行」讲清楚）。
  Map<String, String> failures = const {};

  /// 给用户看的结果说明。
  String message = '';

  /// 用户手动指定的源；null 表示自动（优先 GitHub-IP-hosts）。
  String? preferredSourceId;

  bool _disposed = false;
  bool _busy = false;

  bool get busy => _busy;

  /// 当前选中的源（自动模式下显示「自动」）。
  String get preferredSourceLabel {
    if (preferredSourceId == null) return '自动（优先 GitHub-IP-hosts）';
    final match = kHostsSources.where((s) => s.id == preferredSourceId);
    return match.isEmpty ? preferredSourceId! : match.first.name;
  }

  void _safeNotify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  /// 页面进入时刷新当前状态。
  Future<void> refresh() async {
    if (!supported) return;
    try {
      // 两条路各自查状态：可能只开了其中一条。
      final hostsActive = await AccelPlatform.isActive();
      final entries = await AccelPlatform.currentEntries();
      final proxyActive =
          Platform.isWindows && await WindowsProxy.isEnabled();

      enabled = hostsActive || proxyActive;
      relayEnabled = proxyActive;
      activeEntries = entries;

      if (message.isEmpty) {
        if (hostsActive && entries.isNotEmpty) {
          message = '已启用，${entries.length} 个域名走加速';
        } else if (proxyActive) {
          message = '已启用中转，仅 GitHub 域名走代理';
        }
      }
      _safeNotify();
    } catch (_) {
      // 读取状态失败不该让页面报错，静默保持默认值。
    }
  }

  /// 切换加速源（自动 / 指定）。
  void setPreferredSource(String? id) {
    if (preferredSourceId == id) return;
    preferredSourceId = id;
    _safeNotify();
  }

  /// 取列表并验证，但不写入。让用户先看到「将要写什么」。
  Future<void> resolve() async {
    if (!supported || _busy) return;
    _begin('正在获取加速节点');
    candidates = const [];
    failures = const {};
    resolvedSourceName = null;
    comparison = null;
    message = '';
    try {
      final result = await resolveHosts(
        preferredId: preferredSourceId,
        onProgress: (text, {done, total}) {
          progress = text;
          progressDone = done;
          progressTotal = total;
          _safeNotify();
        },
      );
      failures = result.failures;
      lastFetchMs = result.fetchMs;
      lastVerifyMs = result.verifyMs;
      if (!result.ok) {
        message = _describeFailure(result.failures);
        return;
      }
      candidates = result.entries;
      resolvedSourceName = result.sourceName;

      // 关键一步：不是「能连上就算好」，而是量出到底快没有。
      // 没有提升就不该改 hosts —— 那只会让用户背上改系统文件的成本，
      // 却换不来任何体验改善。
      await _measure(result.entries);
    } catch (error) {
      message = '获取失败：$error';
    } finally {
      _end();
    }
  }

  /// 拿测速结果里最适合对比的那条（优先 codeload，下载归档时走它）。
  Future<void> _measure(List<HostEntry> entries) async {
    if (entries.isEmpty) return;

    // 选一个既能代表下载路径、又有足够候选来源的域名。
    const preferred = kSpeedTestHost;
    final entry = entries.firstWhere(
      (e) => e.host == preferred,
      orElse: () => entries.first,
    );

    progress = '正在汇总候选 IP…';
    progressDone = null;
    progressTotal = null;
    _safeNotify();

    // 关键：不只信第三方列表。把系统 DNS、公共 DoH、GitHub 官方
    // IP 段一起拉进来，全部实测，谁快用谁。
    final candidates = await collectCandidates(
      host: entry.host,
      listedEntries: entries,
      onProgress: (text) {
        progress = text;
        _safeNotify();
      },
    );
    candidateCount = candidates.length;

    if (candidates.isEmpty) {
      message = '没有收集到任何候选 IP';
      _safeNotify();
      return;
    }

    bestIp = await pickFastestIp(
      host: entry.host,
      candidates: [
        for (final c in candidates) (ip: c.ip, origin: c.origin),
      ],
      onProgress: (text, done, total) {
        progress = text;
        progressDone = done;
        progressTotal = total;
        _safeNotify();
      },
    );

    // 两条路都评估，不再「IP 有效就跳过中转」。
    // 用户明确反馈过：中转明明更快，界面却不给选。
    progress = '正在评估中转线路…';
    _safeNotify();
    relay = await assessRelay();
    relayEnabled = relay?.worthUsing ?? false;

    // 让 comparison 反映「择优后」的真实提升，而不是无脑用列表 IP。
    final top = bestIp!.best;
    final base = bestIp!.baseline;
    if (top != null && base != null) {
      comparison = SpeedComparison(
        direct: base,
        accelerated: top.sample,
        host: entry.host,
        ip: top.ip,
        improvementPercent: bestIp!.improvementPercent,
      );
    }

    // 结论按「实际会采用哪条」来说，而不是只看 IP。
    final effective = effectiveApproach;
    if (effective == AccelApproach.none) {
      message = '两条路都没有明显提升，不建议改动任何设置';
    } else if (effective == AccelApproach.relay) {
      final relayMs = relay?.toRelay.totalMs;
      message = '选择中转线路（${relay?.summary ?? ''}）'
          '${relayMs != null ? '，$relayMs ms' : ''}';
    } else {
      final improve = bestIp!.improvementPercent;
      message = bestIp!.isReliable()
          ? '选择 hosts 方案：${top?.origin} 的 ${top?.ip}，比直连快 '
                '${improve?.toStringAsFixed(0) ?? '—'}%'
          : 'hosts 方案略快（${improve?.toStringAsFixed(0) ?? '—'}%），'
                '但${bestIp!.reliabilityNote}';
    }
    _safeNotify();
  }

  /// 写入用的条目：把选出来的最佳 IP 应用到要写的域名上。
  ///
  /// 只对**测速用的那个域名**换成最佳 IP，其余域名仍用各自列表里
  /// 验过的地址——因为测速只证明了这一个域名的优劣，不能外推。
  List<HostEntry> _entriesWithBestIp() {
    final top = bestIp?.best;
    if (top == null) return candidates;
    final host = bestIp!.host;
    return [
      for (final e in candidates)
        if (e.host == host) HostEntry(e.host, top.ip) else e,
    ];
  }

  /// 两条路都没达到「明显提升」时的兜底选择。
  ///
  /// 原则：只要某条路**技术上可用**（能连上、能生效），就允许启用。
  /// 是否值得启用交给用户判断，我们不再替他否决。
  ///
  /// 优先级：中转 > hosts。理由是中转只改当前用户的代理配置、
  /// 不碰系统文件、随时可关，代价比改 hosts 小。
  AccelApproach _fallbackApproach() {
    if (relay?.relayReachable ?? false) return AccelApproach.relay;
    if (bestIp?.best != null) return AccelApproach.hosts;
    // 候选 IP 存在但都没测通时，仍允许写 hosts 试试
    // （可能是测速目标被限流，而实际域名可用）。
    if (candidates.isNotEmpty) return AccelApproach.hosts;
    return AccelApproach.none;
  }

  /// 启用加速。
  ///
  /// 测速只作为「参考信息」，**不再阻止用户启用**。
  ///
  /// 之前的实现里，如果两条路都没跑出明显提升，这里会直接 return，
  /// 结果用户连中转都点不了——而中转本身可能正是当时最合适的选择，
  /// 只是我们的测速没测出来（网络抖动、测速目标单一等）。
  /// 现在改成：测完把结论摆出来，用哪条、要不要用，由用户决定。
  Future<void> enableAccel() async {
    if (!supported || _busy) return;
    // 两条路都要评估过才能选：用户可能是先手动点了「中转」。
    if (candidates.isEmpty || relay == null) {
      await resolve();
      if (candidates.isEmpty && relay == null) return;
    }

    // 用户显式选过就用它；没选过（auto）则挑一条可用的，
    // 两条都不可用时也仍然允许尝试——留给用户判断。
    var choice = effectiveApproach;
    if (choice == AccelApproach.none) {
      choice = _fallbackApproach();
    }
    if (choice == AccelApproach.none) {
      message = '没有可用的加速路径，请稍后重测';
      _safeNotify();
      return;
    }

    if (choice == AccelApproach.relay) {
      // 中转走「应用外」：写系统 PAC，让 Windows 按域名决定走向。
      //
      // 为什么用 PAC 而不是普通系统代理：用户要求「只针对 GitHub，
      // 其它流量还是走默认网络」。普通代理会把所有站点都推给中转，
      // 既影响其它上网、也浪费服务器带宽；PAC 能精确到域名。
      _begin('正在启用中转');
      try {
        final (ok, text) = await WindowsProxy.enable();
        message = text;
        if (ok) {
          relayEnabled = true;
          enabled = true;
          activeEntries = const [];
        }
      } catch (error) {
        message = '启用中转失败：$error';
      } finally {
        progress = '';
        _end();
      }
      return;
    }

    // hosts 方案：需要提权写系统文件。
    _begin('正在启用加速');
    try {
      progress = Platform.isWindows
          ? '等待管理员授权，请在系统弹框中点「是」…'
          : '正在申请 VPN 权限…';
      _safeNotify();
      final (ok, text) = await AccelPlatform.enable(_entriesWithBestIp());
      message = text;
      if (ok) {
        enabled = true;
        activeEntries = await AccelPlatform.currentEntries();
      }
    } catch (error) {
      message = '启用失败：$error';
    } finally {
      progress = '';
      _end();
    }
  }

  /// 停用加速并恢复原状。
  ///
  /// 两条路各自收尾：hosts 方案移除标记区块并恢复备份，
  /// 中转方案删掉 PAC 设置、恢复用户原本的代理配置。
  /// 两件事都做（而不是只做一条），是因为用户可能中途切换过方式，
  /// 只清理一条会留下残留。
  Future<void> disableAccel() async {
    if (!supported || _busy) return;
    _begin('正在关闭加速');
    final notes = <String>[];
    try {
      final (hostsOk, hostsText) = await AccelPlatform.disable();
      if (hostsOk) notes.add(hostsText);

      if (Platform.isWindows) {
        final (proxyOk, proxyText) = await WindowsProxy.disable();
        if (proxyOk) notes.add(proxyText);
      }
      relayEnabled = false;
      enabled = false;
      activeEntries = const [];
      message = notes.isEmpty ? '已关闭加速' : notes.join('；');
    } catch (error) {
      message = '关闭失败：$error';
    } finally {
      _end();
    }
  }

  /// 两条路是否都可用（决定要不要给用户选择）。
  ///
  /// 用户反馈过：中转明明更快，界面却只给 hosts，没得选。
  /// 只要两条路都有实测数据，就把选择权交出来。
  bool get hasBothOptions {
    final ipOk = bestIp?.best != null;
    final relayOk = relay?.relayReachable ?? false;
    return ipOk && relayOk;
  }

  /// 把某条路的实测耗时拿出来，供界面比较展示。
  int? get ipOptionMs => bestIp?.best?.totalMs;
  int? get relayOptionMs => relay?.toRelay.totalMs;

  /// 切换加速方式（用户手动选择）。
  void setApproach(AccelApproach value) {
    if (approach == value) return;
    approach = value;
    _safeNotify();
  }

  /// 清空页面上的一次性结果（换源或重测时调用）。
  void clearResult() {
    candidates = const [];
    failures = const {};
    message = '';
    resolvedSourceName = null;
    _safeNotify();
  }

  void _begin(String label) {
    _busy = true;
    busyLabel = label;
    progress = label;
    progressDone = null;
    progressTotal = null;
    _safeNotify();
  }

  void _end() {
    _busy = false;
    busyLabel = null;
    progress = '';
    progressDone = null;
    progressTotal = null;
    _safeNotify();
  }

  /// 把「每个源都失败了」翻译成一句人话。
  String _describeFailure(Map<String, String> failures) {
    if (failures.isEmpty) return '没有取到可用的 IP';
    final parts = <String>[];
    for (final source in kHostsSources) {
      final reason = failures[source.id];
      if (reason != null) parts.add('${source.name}：$reason');
    }
    for (final entry in failures.entries) {
      if (entry.key.isEmpty ||
          kHostsSources.any((s) => s.id == entry.key)) {
        continue;
      }
      parts.add(entry.value);
    }
    if (parts.isEmpty) return '没有取到可用的 IP';
    return parts.join('；');
  }

  /// 备份文件是否存在（Windows 用于提示「可以恢复」）。
  Future<bool> hasBackup() async {
    if (!Platform.isWindows) return false;
    try {
      return await File(hostsBackupPath(windowsHostsPath())).exists();
    } catch (_) {
      return false;
    }
  }
}
