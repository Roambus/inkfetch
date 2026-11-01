import 'package:flutter/material.dart';

import '../core/format.dart';
import '../core/models.dart';
import 'theme.dart';

class AppCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final Color? color;
  final double radius;
  final Gradient? gradient;
  final bool border;

  const AppCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(18),
    this.color,
    this.radius = 22,
    this.gradient,
    this.border = true,
  });

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      decoration: BoxDecoration(
        color: color ?? (dark ? const Color(0xFF101C2E) : Colors.white),
        gradient: gradient,
        borderRadius: BorderRadius.circular(radius),
        border: border
            ? Border.all(
                color: dark ? const Color(0xFF22324C) : const Color(0xFFE4EBF6),
              )
            : null,
        boxShadow: dark
            ? null
            : [
                BoxShadow(
                  color: const Color(0xFF0F2A5A).withValues(alpha: 0.05),
                  blurRadius: 24,
                  offset: const Offset(0, 10),
                ),
              ],
      ),
      child: Material(
        type: MaterialType.transparency,
        borderRadius: BorderRadius.circular(radius),
        clipBehavior: Clip.antiAlias,
        child: Padding(padding: padding, child: child),
      ),
    );
  }
}

class SectionHeader extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Widget? trailing;

  const SectionHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).colorScheme.onSurface
        .withValues(alpha: 0.55);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: Theme.of(context).textTheme.titleMedium),
              if (subtitle != null) ...[
                const SizedBox(height: 4),
                Text(
                  subtitle!,
                  style: TextStyle(fontSize: 12.5, color: muted, height: 1.4),
                ),
              ],
            ],
          ),
        ),
        ?trailing,
      ],
    );
  }
}

class Pill extends StatelessWidget {
  final String text;
  final Color color;
  final IconData? icon;
  final bool dense;

  const Pill({
    super.key,
    required this.text,
    this.color = kAccent,
    this.icon,
    this.dense = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: dense ? 7 : 10,
        vertical: dense ? 3 : 5,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.13),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: dense ? 11 : 13, color: color),
            const SizedBox(width: 4),
          ],
          Text(
            text,
            style: TextStyle(
              color: color,
              fontSize: dense ? 10.5 : 11.5,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.1,
            ),
          ),
        ],
      ),
    );
  }
}

class StatBlock extends StatelessWidget {
  final String label;
  final String value;
  final Color? accent;
  final IconData? icon;

  const StatBlock({
    super.key,
    required this.label,
    required this.value,
    this.accent,
    this.icon,
  });

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).colorScheme.onSurface
        .withValues(alpha: 0.5);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            if (icon != null) ...[
              Icon(icon, size: 13, color: muted),
              const SizedBox(width: 4),
            ],
            Text(
              label,
              style: TextStyle(
                fontSize: 11.5,
                color: muted,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
        const SizedBox(height: 5),
        Text(
          value,
          style: TextStyle(
            fontSize: 19,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.4,
            color: accent ?? Theme.of(context).colorScheme.onSurface,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }
}

class GradientBadge extends StatelessWidget {
  final double size;
  final IconData icon;
  const GradientBadge({
    super.key,
    this.size = 46,
    this.icon = Icons.bolt_rounded,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(size * 0.3),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [kAccent, kAccentAlt],
        ),
        boxShadow: [
          BoxShadow(
            color: kAccent.withValues(alpha: 0.35),
            blurRadius: 18,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Icon(icon, color: Colors.white, size: size * 0.5),
    );
  }
}

class StatGrid extends StatelessWidget {
  final List<Widget> items;
  final double spacing;

  const StatGrid({super.key, required this.items, this.spacing = 10});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final twoRows = constraints.maxWidth < 620;
        if (!twoRows) {
          return Row(
            children: [
              for (var i = 0; i < items.length; i++) ...[
                if (i > 0) SizedBox(width: spacing),
                Expanded(child: items[i]),
              ],
            ],
          );
        }
        final rows = <Widget>[];
        for (var i = 0; i < items.length; i += 2) {
          if (i > 0) rows.add(SizedBox(height: 14));
          final left = items[i];
          final right = i + 1 < items.length ? items[i + 1] : null;
          rows.add(
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: left),
                if (right != null) ...[
                  SizedBox(width: spacing),
                  Expanded(child: right),
                ],
              ],
            ),
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: rows,
        );
      },
    );
  }
}

class StatusChip extends StatelessWidget {
  final DownloadPhase phase;
  const StatusChip({super.key, required this.phase});

  @override
  Widget build(BuildContext context) {
    final (color, icon) = switch (phase) {
      DownloadPhase.downloading => (kAccent, Icons.downloading_rounded),
      DownloadPhase.paused => (kWarning, Icons.pause_rounded),
      DownloadPhase.verifying => (kAccentAlt, Icons.verified_rounded),
      DownloadPhase.completed => (kAccentAlt, Icons.check_circle_rounded),
      DownloadPhase.failed => (kDanger, Icons.error_rounded),
      DownloadPhase.cancelled => (kWarning, Icons.cancel_rounded),
    };
    return Pill(text: phaseLabel(phase), color: color, icon: icon);
  }
}

class EmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String description;
  final Widget? action;

  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.description,
    this.action,
  });

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).colorScheme.onSurface
        .withValues(alpha: 0.5);
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 48),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 76,
              height: 76,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: kAccent.withValues(alpha: 0.1),
                border: Border.all(color: kAccent.withValues(alpha: 0.22)),
              ),
              child: Icon(icon, size: 34, color: kAccent),
            ),
            const SizedBox(height: 20),
            Text(
              title,
              style: Theme.of(context).textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 380),
              child: Text(
                description,
                style: TextStyle(fontSize: 13, color: muted, height: 1.6),
                textAlign: TextAlign.center,
              ),
            ),
            if (action != null) ...[const SizedBox(height: 22), action!],
          ],
        ),
      ),
    );
  }
}

class SourceProbeRow extends StatelessWidget {
  final SourceProbe probe;
  final int? index;

  const SourceProbeRow({super.key, required this.probe, this.index});

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).colorScheme.onSurface
        .withValues(alpha: 0.48);
    final color = index == null ? kAccent : siteColor(index!);
    final statusColor = switch (probe.status) {
      ProbeStatus.healthy => kAccentAlt,
      ProbeStatus.noRange => kWarning,
      ProbeStatus.failed => kDanger,
    };
    final statusText = switch (probe.status) {
      ProbeStatus.healthy => '可用 · 支持分片',
      ProbeStatus.noRange => '可用 · 不支持分片',
      ProbeStatus.failed => probe.error ?? '不可用',
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 9),
      child: Row(
        children: [
          Container(
            width: 9,
            height: 9,
            decoration: BoxDecoration(
              color: statusColor,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        probe.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w600,
                          color: probe.status == ProbeStatus.failed
                              ? muted
                              : null,
                        ),
                      ),
                    ),
                    const SizedBox(width: 7),
                    Pill(
                      text: laneLabel(probe.lane),
                      color: color,
                      dense: true,
                    ),
                    if (probe.experimental) ...[
                      const SizedBox(width: 5),
                      const Pill(text: '实验', color: kWarning, dense: true),
                    ],
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  probe.status == ProbeStatus.failed
                      ? statusText
                      : '${humanSpeed(probe.speedBps)} · ${probe.latencyMs}ms · '
                            '${probe.httpStatus ?? '—'}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11.5, color: muted),
                ),
              ],
            ),
          ),
          if (probe.status != ProbeStatus.failed) ...[
            const SizedBox(width: 8),
            Text(
              humanSpeed(probe.speedBps),
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: statusColor,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class SiteLaneRow extends StatelessWidget {
  final SiteProgress site;
  final int index;

  const SiteLaneRow({super.key, required this.site, required this.index});

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).colorScheme.onSurface
        .withValues(alpha: 0.48);
    final color = siteColor(index);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              color: site.disabled ? muted : color,
              borderRadius: BorderRadius.circular(3),
            ),
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        site.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: site.disabled ? muted : null,
                        ),
                      ),
                    ),
                    const SizedBox(width: 7),
                    Pill(
                      text: '${site.connections} 线程',
                      color: color,
                      dense: true,
                    ),
                    if (site.disabled) ...[
                      const SizedBox(width: 5),
                      const Pill(text: '已停用', color: kDanger, dense: true),
                    ],
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  '${humanBytes(site.bytes)} · ${site.errors} 次重试',
                  style: TextStyle(fontSize: 11.5, color: muted),
                ),
              ],
            ),
          ),
          Text(
            humanSpeed(site.speedBps),
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

class ChunkHeatmap extends StatelessWidget {
  final List<int> chunkMap;
  const ChunkHeatmap({super.key, required this.chunkMap});

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    if (chunkMap.isEmpty) {
      return Text(
        '单流下载模式，无分片视图',
        style: TextStyle(
          fontSize: 12,
          color: Theme.of(context).colorScheme.onSurface
              .withValues(alpha: 0.45),
        ),
      );
    }
    const buckets = 160;
    final step = (chunkMap.length / buckets).ceil().clamp(1, chunkMap.length);
    final cells = <int>[];
    for (var i = 0; i < chunkMap.length; i += step) {
      final end = (i + step).clamp(0, chunkMap.length);
      var chosen = 0;
      for (var j = i; j < end; j++) {
        final value = chunkMap[j];
        if (value > 0) {
          chosen = value;
          break;
        }
        if (value < 0) chosen = value;
      }
      cells.add(chosen);
    }
    final pending = dark ? const Color(0xFF1A2740) : const Color(0xFFE2E9F5);
    return Wrap(
      spacing: 3,
      runSpacing: 3,
      children: [
        for (final cell in cells)
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              color: cell > 0
                  ? siteColor(cell - 1)
                  : cell < 0
                  ? kDanger
                  : pending,
              borderRadius: BorderRadius.circular(2.5),
            ),
          ),
      ],
    );
  }
}

class LegendDot extends StatelessWidget {
  final Color color;
  final String label;
  const LegendDot({super.key, required this.color, required this.label});

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).colorScheme.onSurface
        .withValues(alpha: 0.5);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 5),
        Text(label, style: TextStyle(fontSize: 10.5, color: muted)),
      ],
    );
  }
}
