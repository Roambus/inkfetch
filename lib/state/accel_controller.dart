import 'dart:io';

import 'package:flutter/foundation.dart';

import '../core/accel_platform.dart';
import '../core/github_accel.dart';
import '../core/hosts_file.dart';

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
      final active = await AccelPlatform.isActive();
      final entries = await AccelPlatform.currentEntries();
      enabled = active;
      activeEntries = entries;
      if (active && entries.isNotEmpty && message.isEmpty) {
        message = '已启用，${entries.length} 个域名走加速';
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
      if (result.ok) {
        candidates = result.entries;
        resolvedSourceName = result.sourceName;
        message = '从 ${result.sourceName} 取到 ${result.entries.length} 个可用 IP';
      } else {
        message = _describeFailure(result.failures);
      }
    } catch (error) {
      message = '获取失败：$error';
    } finally {
      _end();
    }
  }

  /// 一键加速：取列表 → 验证 → 启用。
  ///
  /// 已经有可用候选时直接用它，省一次网络往返。
  Future<void> enableAccel() async {
    if (!supported || _busy) return;
    if (candidates.isEmpty) {
      await resolve();
      if (candidates.isEmpty) return;
    }
    _begin('正在启用加速');
    try {
      progress = Platform.isWindows
          ? '等待管理员授权，请在系统弹框中点「是」…'
          : '正在申请 VPN 权限…';
      _safeNotify();
      final (ok, text) = await AccelPlatform.enable(candidates);
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
  Future<void> disableAccel() async {
    if (!supported || _busy) return;
    _begin('正在关闭加速');
    try {
      final (ok, text) = await AccelPlatform.disable();
      message = text;
      if (ok) {
        enabled = false;
        activeEntries = const [];
      }
    } catch (error) {
      message = '关闭失败：$error';
    } finally {
      _end();
    }
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
