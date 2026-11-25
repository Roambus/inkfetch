import 'dart:io';

import 'package:flutter/material.dart';

import '../core/github_accel.dart';
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
                    const SizedBox(height: 16),
                    if (accel.candidates.isNotEmpty && !accel.enabled)
                      _previewCard(palette, accel),
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
                    label: Text(accel.candidates.isEmpty ? '检测并开启' : '开启加速'),
                  ),
                if (!accel.enabled)
                  OutlinedButton.icon(
                    onPressed: accel.busy ? null : accel.resolve,
                    icon: const Icon(Icons.history_rounded, size: 16),
                    label: const Text('仅测速'),
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
