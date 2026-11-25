import 'dart:io';

import 'package:flutter/material.dart';

import '../core/github_accel.dart';
import '../core/speed_bench.dart';
import '../state/accel_controller.dart';
import 'theme.dart';
import 'widgets.dart';

/// GitHub 加速页。
///
/// 这一页要回答三个问题，顺序也是按用户关心的顺序排的：
///   1. 现在到底有没有在加速？
///   2. 用的是哪种办法（Windows 改 hosts / Android 走 VPN）？
///   3. 具体生效了哪些域名和 IP？
class GithubAccelPage extends StatefulWidget {
  final AccelController accel;

  const GithubAccelPage({super.key, required this.accel});

  @override
  State<GithubAccelPage> createState() => _GithubAccelPageState();
}

class _GithubAccelPageState extends State<GithubAccelPage> {
  @override
  void initState() {
    super.initState();
    widget.accel.refresh();
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return AnimatedBuilder(
      animation: widget.accel,
      builder: (context, _) {
        final accel = widget.accel;
        return LayoutBuilder(
          builder: (context, constraints) {
            final narrow = constraints.maxWidth < 560;
            return SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(
                narrow ? 20 : 34,
                28,
                narrow ? 20 : 34,
                40,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  PageHead(
                    title: 'GitHub 加速',
                    subtitle: Platform.isAndroid
                        ? '用 DNS 分流接管 GitHub 域名解析，只影响这些域名。'
                        : '把实测可用的 IP 写进系统 hosts，随时可以关掉。',
                    trailing: _StatusBadge(enabled: accel.enabled),
                  ),
                  const SizedBox(height: 22),
                  if (!accel.supported) _unsupportedCard(palette),
                  if (accel.supported) ...[
                    _actionCard(context, palette, accel, narrow),
                    if (accel.bestIp != null) ...[
                      const SizedBox(height: 16),
                      _ipRankCard(context, palette, accel, narrow),
                    ] else if (accel.comparison != null) ...[
                      const SizedBox(height: 16),
                      _speedCard(context, palette, accel, narrow),
                    ],
                    if (accel.candidates.isNotEmpty) ...[
                      const SizedBox(height: 16),
                      _previewCard(palette, accel),
                    ],
                    if (accel.activeEntries.isNotEmpty) ...[
                      const SizedBox(height: 16),
                      _activeCard(context, palette, accel),
                    ],
                    const SizedBox(height: 16),
                    _howItWorks(palette, accel),
                  ],
                ],
              ),
            );
          },
        );
      },
    );
  }

  Widget _unsupportedCard(AppPalette palette) {
    return AppCard(
      child: Padding(
        padding: const EdgeInsets.all(22),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('当前平台不支持', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            Text(
              'GitHub 加速目前只在 Windows（写 hosts）与 Android（DNS 分流 VPN）上提供。',
              style: TextStyle(fontSize: 13, color: palette.muted, height: 1.7),
            ),
          ],
        ),
      ),
    );
  }

  Widget _actionCard(
    BuildContext context,
    AppPalette palette,
    AccelController accel,
    bool narrow,
  ) {
    final status = accel.enabled ? '已开启' : '未开启';
    final statusColor = accel.enabled ? palette.accent : palette.faint;
    return AppCard(
      child: Padding(
        padding: EdgeInsets.all(narrow ? 18 : 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                    color: statusColor,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  status,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: accel.enabled ? palette.ink : palette.muted,
                  ),
                ),
                const SizedBox(width: 10),
                QuietTag(text: accel.method),
                const Spacer(),
                if (accel.resolvedSourceName != null && !accel.enabled)
                  QuietTag(text: '来源 ${accel.resolvedSourceName}'),
              ],
            ),
            const SizedBox(height: 16),
            if (accel.busy) ...[
              _progressBlock(palette, accel),
              const SizedBox(height: 14),
            ],
            if (accel.message.isNotEmpty && !accel.busy) ...[
              _messageBlock(palette, accel.message, accel.enabled),
              const SizedBox(height: 14),
            ],
            Wrap(
              spacing: 10,
              runSpacing: 10,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (!accel.enabled)
                  FilledButton.icon(
                    onPressed: accel.busy ? null : accel.enableAccel,
                    icon: const Icon(Icons.north_east_rounded, size: 16),
                    label: Text(_enableLabel(accel)),
                  ),
                if (!accel.enabled)
                  OutlinedButton.icon(
                    onPressed: accel.busy ? null : accel.resolve,
                    icon: const Icon(Icons.history_rounded, size: 16),
                    label: Text(accel.comparison == null ? '测速' : '重新测速'),
                  ),
                if (accel.enabled)
                  OutlinedButton.icon(
                    onPressed: accel.busy ? null : accel.disableAccel,
                    icon: const Icon(Icons.close_rounded, size: 16),
                    label: const Text('关闭加速'),
                  ),
                if (accel.enabled)
                  OutlinedButton.icon(
                    onPressed: accel.busy ? null : accel.resolve,
                    icon: const Icon(Icons.history_rounded, size: 16),
                    label: const Text('重新测速'),
                  ),
                _sourcePicker(context, palette, accel),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// 按当前测速结论决定主按钮该说什么。
  ///
  /// 测速没用时不该给一个「开启加速」的按钮——那等于引导用户去做
  /// 一件我们刚测出来没意义的事。
  String _enableLabel(AccelController accel) {
    final cmp = accel.comparison;
    if (cmp == null) return '测速并开启';
    if (!cmp.worthEnabling) return '没有提升，不启用';
    if (cmp.isAvailabilityGain) return '开启加速（直连不通）';
    return '开启加速';
  }

  Widget _progressBlock(AppPalette palette, AccelController accel) {
    final total = accel.progressTotal;
    final done = accel.progressDone;
    final determinate = total != null && total > 0 && done != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (determinate)
          ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: LinearProgressIndicator(
              value: (done / total).clamp(0.0, 1.0),
              minHeight: 3,
              backgroundColor: palette.surfaceAlt,
              color: palette.accent,
            ),
          )
        else
          ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: LinearProgressIndicator(
              minHeight: 3,
              backgroundColor: palette.surfaceAlt,
              color: palette.accent,
            ),
          ),
        const SizedBox(height: 8),
        Text(
          determinate
              ? '${accel.progress}（$done/$total）'
              : (accel.progress.isEmpty ? accel.busyLabel ?? '' : accel.progress),
          style: TextStyle(fontSize: 12, color: palette.muted),
        ),
      ],
    );
  }

  Widget _messageBlock(AppPalette palette, String message, bool active) {
    final color = active ? palette.accent : palette.muted;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: palette.surfaceAlt,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            active ? Icons.info_outline_rounded : Icons.info_outline_rounded,
            size: 15,
            color: color,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: TextStyle(fontSize: 12, height: 1.6, color: palette.muted),
            ),
          ),
        ],
      ),
    );
  }

  Widget _sourcePicker(
    BuildContext context,
    AppPalette palette,
    AccelController accel,
  ) {
    return PopupMenuButton<String?>(
      enabled: !accel.busy,
      tooltip: '选择加速源',
      onSelected: (value) {
        accel.setPreferredSource(value);
        accel.clearResult();
      },
      itemBuilder: (context) => [
        const PopupMenuItem<String?>(
          value: null,
          child: Text('自动（优先 GitHub-IP-hosts）'),
        ),
        for (final source in kHostsSources)
          PopupMenuItem<String?>(
            value: source.id,
            child: Text(source.name),
          ),
      ],
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: palette.border),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '来源：${accel.preferredSourceLabel}',
              style: TextStyle(fontSize: 12, color: palette.muted),
            ),
            const SizedBox(width: 4),
            Icon(
              Icons.keyboard_arrow_down_rounded,
              size: 16,
              color: palette.faint,
            ),
          ],
        ),
      ),
    );
  }

  /// 多源择优结果：每个候选 IP 的出处与实测耗时，最佳的那条高亮。
  ///
  /// 这一块要回答「为什么选这个 IP」，而不是只给一个结论。
  /// 用户能亲眼看到第三方列表给的 IP 可能比系统 DNS 还慢——
  /// 那正是之前「开了加速反而慢 50%」的原因。
  Widget _ipRankCard(
    BuildContext context,
    AppPalette palette,
    AccelController accel,
    bool narrow,
  ) {
    final result = accel.bestIp!;
    final top = result.best;
    final base = result.baseline;
    final worth = result.worthApplying;
    final accent = worth ? palette.accent : palette.warning;
    final improvement = result.improvementPercent;

    // 按耗时从快到慢列出用过的候选，失败的放最后。
    final ranked = [...result.ranked];
    final failed = result.all.where((c) => !c.ok).toList();
    final slowest = ranked.isEmpty ? 0 : ranked.last.totalMs;

    return AppCard(
      child: Padding(
        padding: EdgeInsets.all(narrow ? 18 : 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SectionHeader(
              title: '最佳 IP 选择',
              trailing: Text(
                '${result.all.length} 个候选',
                style: TextStyle(fontSize: 11, color: palette.faint),
              ),
            ),
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
              decoration: BoxDecoration(
                color: palette.surfaceAlt,
                borderRadius: BorderRadius.circular(8),
                border: Border(left: BorderSide(color: accent, width: 2.5)),
              ),
              child: Text(
                top == null
                    ? '没有可用的候选 IP'
                    : worth
                    ? '选用 ${top.ip}（${top.origin}），比直连快 '
                          '${improvement?.toStringAsFixed(0) ?? '—'}%'
                    : '没有比直连更快的候选，不建议改动系统设置',
                style: TextStyle(
                  fontSize: 13,
                  height: 1.5,
                  fontWeight: FontWeight.w600,
                  color: worth ? palette.ink : palette.muted,
                ),
              ),
            ),
            const SizedBox(height: 14),
            // 直连基准单独一行，作为比较的锚点。
            if (base != null)
              _ipRow(
                palette,
                label: '直连（不改设置）',
                ip: '系统 DNS',
                ms: base.ok ? base.totalMs : null,
                slowestMs: slowest,
                highlight: false,
                muted: true,
              ),
            for (final c in ranked)
              _ipRow(
                palette,
                label: c.origin,
                ip: c.ip,
                ms: c.totalMs,
                slowestMs: slowest,
                highlight: c == top && worth,
              ),
            if (failed.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                '另有 ${failed.length} 个候选连接失败，已排除',
                style: TextStyle(fontSize: 11, color: palette.faint),
              ),
            ],
            const SizedBox(height: 10),
            Text(
              '候选来自第三方列表、系统 DNS、阿里/腾讯/DNSPod DoH，以及 GitHub 官方 IP 段。'
              '全部实测后择优，不是照抄某个列表。',
              style: TextStyle(fontSize: 11.5, color: palette.faint, height: 1.6),
            ),
          ],
        ),
      ),
    );
  }

  Widget _ipRow(
    AppPalette palette, {
    required String label,
    required String ip,
    required int? ms,
    required int slowestMs,
    required bool highlight,
    bool muted = false,
  }) {
    final color = highlight
        ? palette.accent
        : muted
        ? palette.faint
        : palette.muted;
    // 用一条横条直观表示相对快慢（越短越快）。
    final ratio = (ms == null || slowestMs <= 0)
        ? 1.0
        : (ms / slowestMs).clamp(0.0, 1.0);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          SizedBox(
            width: 88,
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11.5,
                color: color,
                fontWeight: highlight ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 108,
            child: Text(
              ip,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: dataStyle(size: 11.5, color: color, letterSpacing: 0),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Align(
              alignment: Alignment.centerLeft,
              child: FractionallySizedBox(
                widthFactor: ratio.clamp(0.02, 1.0),
                child: Container(
                  height: 4,
                  decoration: BoxDecoration(
                    color: highlight ? palette.accent : palette.borderStrong,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          SizedBox(
            width: 62,
            child: Text(
              ms == null ? '失败' : '${ms}ms',
              textAlign: TextAlign.right,
              // 「失败」是中文，等宽字体没有中文字形会渲染成方块；
              // 只有「123ms」这种纯数字才走等宽。
              style: ms == null
                  ? TextStyle(fontSize: 11.5, color: palette.danger)
                  : dataStyle(
                      size: 11.5,
                      weight: highlight ? FontWeight.w600 : FontWeight.w400,
                      color: color,
                      letterSpacing: 0,
                    ),
            ),
          ),
        ],
      ),
    );
  }

  /// 直连 vs 加速的速度对比。
  ///
  /// 这一块是整个功能的说服力所在：用户要知道「开了到底有没有用」，
  /// 而不是只有一句「已开启」。
  Widget _speedCard(
    BuildContext context,
    AppPalette palette,
    AccelController accel,
    bool narrow,
  ) {
    final cmp = accel.comparison!;
    final worth = cmp.worthEnabling;
    final accent = worth ? palette.accent : palette.warning;

    return AppCard(
      child: Padding(
        padding: EdgeInsets.all(narrow ? 18 : 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SectionHeader(
              title: '速度对比',
              trailing: Text(
                cmp.host,
                style: TextStyle(fontSize: 11, color: palette.faint),
              ),
            ),
            const SizedBox(height: 14),
            // 结论先说，数字再补充——用户最先想知道的是「值不值得开」。
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
              decoration: BoxDecoration(
                color: palette.surfaceAlt,
                borderRadius: BorderRadius.circular(8),
                border: Border(
                  left: BorderSide(color: accent, width: 2.5),
                ),
              ),
              child: Text(
                cmp.verdict,
                style: TextStyle(
                  fontSize: 13,
                  height: 1.5,
                  fontWeight: FontWeight.w600,
                  color: worth ? palette.ink : palette.muted,
                ),
              ),
            ),
            const SizedBox(height: 16),
            if (narrow)
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _speedRow(palette, '直连', cmp.direct, null, false),
                  const SizedBox(height: 10),
                  _speedRow(palette, '加速', cmp.accelerated, cmp, true),
                ],
              )
            else
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: _speedRow(palette, '直连', cmp.direct, null, false),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: _speedRow(
                      palette,
                      '加速后',
                      cmp.accelerated,
                      cmp,
                      true,
                    ),
                  ),
                ],
              ),
            if (cmp.improvementPercent != null) ...[
              const SizedBox(height: 14),
              _improvementBar(palette, cmp, accent),
            ],
            const SizedBox(height: 12),
            Text(
              cmp.host == kSpeedTestHost
                  ? '测的是 ${cmp.host} 上一个约 8KB 的真实文件，两条路各跑一次。'
                  : '测的是 ${cmp.host} 上的真实请求，两条路各跑一次。',
              style: TextStyle(fontSize: 11.5, color: palette.faint, height: 1.6),
            ),
            if (!worth) ...[
              const SizedBox(height: 6),
              Text(
                '没有明显提升时不会改动你的系统设置。',
                style: TextStyle(fontSize: 11.5, color: palette.faint),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _speedRow(
    AppPalette palette,
    String label,
    SpeedSample sample,
    SpeedComparison? cmp,
    bool highlight,
  ) {
    final ok = sample.ok;
    final color = !ok
        ? palette.danger
        : highlight
        ? palette.accent
        : palette.muted;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: palette.surfaceAlt,
        borderRadius: BorderRadius.circular(9),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(fontSize: 11.5, color: palette.faint),
          ),
          const SizedBox(height: 6),
          Text(
            sample.speedText,
            style: dataStyle(size: 17, weight: FontWeight.w600, color: color),
          ),
          const SizedBox(height: 4),
          Text(
            ok
                ? '总计 ${sample.totalMs}ms · 握手 ${sample.handshakeMs}ms'
                : (sample.error ?? '失败'),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 10.5, color: palette.faint, height: 1.4),
          ),
        ],
      ),
    );
  }

  /// 提升幅度条：直观看出「快了多少」。
  Widget _improvementBar(
    AppPalette palette,
    SpeedComparison cmp,
    Color accent,
  ) {
    final value = cmp.improvementPercent!;
    // 条形长度按提升幅度折算，±100% 封顶，负值画在左侧。
    final ratio = (value / 100).clamp(-1.0, 1.0);
    final positive = value >= 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              '提升',
              style: TextStyle(fontSize: 11.5, color: palette.faint),
            ),
            const SizedBox(width: 8),
            Text(
              '${positive ? '+' : ''}${value.toStringAsFixed(0)}%',
              style: dataStyle(
                size: 15,
                weight: FontWeight.w600,
                color: positive ? accent : palette.danger,
              ),
            ),
          ],
        ),
        const SizedBox(height: 7),
        LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth;
            final barWidth = (width * 0.5 * ratio.abs()).clamp(2.0, width * 0.5);
            return SizedBox(
              height: 5,
              child: Stack(
                children: [
                  Container(
                    decoration: BoxDecoration(
                      color: palette.surfaceAlt,
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
                  Positioned(
                    left: positive ? width * 0.5 : width * 0.5 - barWidth,
                    width: barWidth,
                    top: 0,
                    bottom: 0,
                    child: Container(
                      decoration: BoxDecoration(
                        color: positive ? accent : palette.danger,
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                  ),
                  // 中线 = 和直连一样快
                  Positioned(
                    left: width * 0.5 - 0.5,
                    width: 1,
                    top: 0,
                    bottom: 0,
                    child: Container(color: palette.borderStrong),
                  ),
                ],
              ),
            );
          },
        ),
      ],
    );
  }

  /// 测速结果：让用户在按下「开启」之前就看到会写进去什么。
  Widget _previewCard(AppPalette palette, AccelController accel) {
    return AppCard(
      child: Padding(
        padding: const EdgeInsets.all(22),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SectionHeader(
              title: '将要写入的条目',
              trailing: Text(
                '${accel.candidates.length} 条',
                style: TextStyle(fontSize: 11.5, color: palette.faint),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '这些 IP 都做过 TLS 握手验证，确认可用才会写进去。'
              '${Platform.isAndroid ? '安卓端不会逐个列出，由 VPN 统一接管。' : ''}',
              style: TextStyle(fontSize: 12, color: palette.muted, height: 1.6),
            ),
            const SizedBox(height: 14),
            for (final entry in accel.candidates.take(24))
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  children: [
                    SizedBox(
                      width: 130,
                      child: Text(
                        entry.host,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12, color: palette.ink),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Text(
                      entry.ip,
                      style: dataStyle(
                        size: 12,
                        color: palette.muted,
                        letterSpacing: 0,
                      ),
                    ),
                  ],
                ),
              ),
            if (accel.candidates.length > 24)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  '另有 ${accel.candidates.length - 24} 条未显示',
                  style: TextStyle(fontSize: 11.5, color: palette.faint),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// 当前生效的条目。
  Widget _activeCard(
    BuildContext context,
    AppPalette palette,
    AccelController accel,
  ) {
    return AppCard(
      child: Padding(
        padding: const EdgeInsets.all(22),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SectionHeader(
              title: '当前生效',
              trailing: Text(
                '${accel.activeEntries.length} 条',
                style: TextStyle(fontSize: 11.5, color: palette.faint),
              ),
            ),
            const SizedBox(height: 10),
            for (final entry in accel.activeEntries)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  children: [
                    Container(
                      width: 6,
                      height: 6,
                      decoration: BoxDecoration(
                        color: palette.accent,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        entry.host,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12, color: palette.ink),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Text(
                      entry.ip,
                      style: dataStyle(
                        size: 12,
                        color: palette.muted,
                        letterSpacing: 0,
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _howItWorks(AppPalette palette, AccelController accel) {
    final isWindows = !Platform.isAndroid;
    return AppCard(
      child: Padding(
        padding: const EdgeInsets.all(22),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SectionHeader(title: '怎么做的'),
            const SizedBox(height: 12),
            if (isWindows) ...[
              _step(
                palette,
                '取列表',
                '先取 GitHub-IP-hosts；取不到或一条都验不过，再自动改用 GitHub520。',
              ),
              _step(
                palette,
                '验真',
                '每个 IP 都用「连接该 IP + 用域名做证书校验」验证。'
                    '握手不通过的一律不写——写错 IP 比不写更糟。',
              ),
              _step(
                palette,
                '写 hosts',
                '按域名保留最快的一条，写进系统 hosts 的标记区块里，'
                    '需要时弹一次管理员授权。你原有的条目不会被动到。',
              ),
              _step(
                palette,
                '可还原',
                '关闭加速时只移除自己那一段；写入前也留了备份。',
                last: true,
              ),
            ] else ...[
              _step(
                palette,
                '取列表并验真',
                '同样先取 GitHub-IP-hosts，失败再用 GitHub520，'
                    '并逐个做证书校验。',
              ),
              _step(
                palette,
                '只接管 DNS',
                '安卓不允许普通应用改 hosts，所以起一个 VpnService，'
                    '只把系统 DNS 查询接过来，GitHub 域名解析成验过的 IP。',
              ),
              _step(
                palette,
                '不转发流量',
                '不代理任何正文流量、不加默认路由，其它应用的上网行为完全不受影响。',
              ),
              _step(
                palette,
                '随时可关',
                '关闭即撤销该 VPN，系统 DNS 立即回到原来的设置。',
                last: true,
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _step(AppPalette palette, String title, String body, {bool last = false}) {
    return Padding(
      padding: EdgeInsets.only(bottom: last ? 0 : 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 3),
            child: SizedBox(
              width: 62,
              child: Text(
                title,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: palette.ink,
                ),
              ),
            ),
          ),
          Expanded(
            child: Text(
              body,
              style: TextStyle(fontSize: 12, height: 1.65, color: palette.muted),
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusBadge extends StatelessWidget {
  final bool enabled;

  const _StatusBadge({required this.enabled});

  @override
  Widget build(BuildContext context) {
    return QuietTag(text: enabled ? '加速中' : '未开启');
  }
}
