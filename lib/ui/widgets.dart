import 'package:flutter/material.dart';

import '../core/format.dart';
import '../core/models.dart';
import 'theme.dart';

/// ─────────────────────────────────────────────────────────────
/// 组件库。
///
/// 三条纪律：
///   1. 容器只有一个层级（AppCard），不要卡片里套卡片；
///   2. 层级靠留白、字重与发丝线区分，不靠阴影和更多灰阶；
///   3. 数字一律等宽对齐，让速度跳动时整行不抖。
/// ─────────────────────────────────────────────────────────────

/// 墨色面板：发丝描边，无阴影，无渐变。
class AppCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final Color? color;
  final double radius;
  final bool border;

  const AppCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(20),
    this.color,
    this.radius = 14,
    this.border = true,
  });

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return Container(
      decoration: BoxDecoration(
        color: color ?? palette.surface,
        borderRadius: BorderRadius.circular(radius),
        border: border ? Border.all(color: palette.border) : null,
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

/// 页面抬头：一枚宋体大标题 + 一行说明，右上角放本页主要的动作。
/// 底部一道发丝线，把抬头和内容分开——这条线是版式的节奏点。
class PageHead extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Widget? trailing;

  const PageHead({
    super.key,
    required this.title,
    this.subtitle,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return Container(
      padding: const EdgeInsets.only(bottom: 18),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: palette.border)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: Theme.of(context).textTheme.displaySmall),
                if (subtitle != null) ...[
                  const SizedBox(height: 7),
                  Text(
                    subtitle!,
                    style: TextStyle(
                      fontSize: 12.5,
                      color: palette.muted,
                      height: 1.5,
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (trailing != null) ...[
            const SizedBox(width: 16),
            Padding(padding: const EdgeInsets.only(bottom: 2), child: trailing),
          ],
        ],
      ),
    );
  }
}

/// 小节标题。左侧一小段墨条，是这套界面的排版权记。
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
    final palette = AppPalette.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 2.5,
          height: 15,
          margin: const EdgeInsets.only(top: 2, right: 10),
          decoration: BoxDecoration(
            color: palette.accent,
            borderRadius: BorderRadius.circular(1.5),
          ),
        ),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: Theme.of(context).textTheme.titleMedium),
              if (subtitle != null) ...[
                const SizedBox(height: 4),
                Text(
                  subtitle!,
                  style: TextStyle(
                    fontSize: 11.5,
                    color: palette.muted,
                    height: 1.5,
                  ),
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

/// 品牌标记。
///
/// 用的是应用图标上那只水墨猫，不是另外画的图形：图标、窗口、侧栏、
/// 关于页必须是同一件东西，否则用户会觉得这是两个应用。
///
/// 猫是墨画在纸上的，墨色本身就深。直接放在深色主题上会糊成一团，
/// 所以这里始终垫一层纸色——不是偷懒加个底，而是让它在深色界面上
/// 仍然读作「一张纸上的墨」，而不是一块发灰的剪影。
class BrandMark extends StatelessWidget {
  final double size;
  const BrandMark({super.key, this.size = 34});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: const Color(0xFFF4F2EC),
        borderRadius: BorderRadius.circular(size * 0.22),
        boxShadow: const [
          BoxShadow(color: Color(0x14000000), blurRadius: 1, offset: Offset(0, 1)),
        ],
      ),
      padding: EdgeInsets.all(size * 0.07),
      child: Image.asset(
        'assets/icon/inkfetch_mark_320.png',
        fit: BoxFit.contain,
        filterQuality: FilterQuality.high,
        // 装饰性图片，读屏时不该念出来；品牌名已经在旁边以文字呈现。
        excludeFromSemantics: true,
      ),
    );
  }
}


/// 状态点 + 文字。用一小块实心色块表示状态，比整块着色更克制。
class StatusDot extends StatelessWidget {
  final Color color;
  final String label;

  const StatusDot({super.key, required this.color, required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 6,
          height: 6,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Text(
          label,
          style: TextStyle(
            fontSize: 11.5,
            fontWeight: FontWeight.w500,
            color: color,
          ),
        ),
      ],
    );
  }
}

class StatusChip extends StatelessWidget {
  final DownloadPhase phase;
  const StatusChip({super.key, required this.phase});

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final color = switch (phase) {
      DownloadPhase.downloading => palette.accent,
      DownloadPhase.paused => palette.warning,
      DownloadPhase.verifying => palette.accent,
      DownloadPhase.completed => palette.positive,
      DownloadPhase.failed => palette.danger,
      DownloadPhase.cancelled => palette.warning,
    };
    return StatusDot(color: color, label: phaseLabel(phase));
  }
}

/// 中性标签：只有背景，没有描边，避免满屏小盒子。
class QuietTag extends StatelessWidget {
  final String text;
  const QuietTag({super.key, required this.text});

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: palette.surfaceAlt,
        borderRadius: BorderRadius.circular(3),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 10,
          color: palette.muted,
          fontWeight: FontWeight.w500,
          letterSpacing: 0.2,
        ),
      ),
    );
  }
}

/// 提示条。用于必须让用户看见、但不能打断流程的说明。
///
/// 与 QuietTag 的分工：QuietTag 只是给一个词加个底；这里承载一句话，
/// 允许带一行标题。语气克制——用细边和浅底，不用整块色板压过来。
class CautionNote extends StatelessWidget {
  final String text;
  final String? title;
  final bool severe;

  const CautionNote({
    super.key,
    required this.text,
    this.title,
    this.severe = false,
  });

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final color = severe ? palette.danger : palette.warning;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(11, 10, 12, 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.22)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(Icons.info_outline_rounded, size: 14, color: color),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (title != null) ...[
                  Text(
                    title!,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: color,
                      height: 1.5,
                    ),
                  ),
                  const SizedBox(height: 2),
                ],
                Text(
                  text,
                  style: TextStyle(
                    fontSize: 11.5,
                    height: 1.65,
                    color: palette.muted,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 仪表读数：小号标签在上，等宽大数字在下。
class Reading extends StatelessWidget {
  final String label;
  final String value;
  final Color? accent;
  final double valueSize;

  const Reading({
    super.key,
    required this.label,
    required this.value,
    this.accent,
    this.valueSize = 18,
  });

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 10.5,
            color: palette.faint,
            fontWeight: FontWeight.w500,
            letterSpacing: 0.3,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: dataStyle(
            size: valueSize,
            weight: FontWeight.w600,
            color: accent ?? palette.ink,
          ),
        ),
      ],
    );
  }
}

/// 一排读数，用竖线分隔；窄屏自动折成两列。
class ReadingStrip extends StatelessWidget {
  final List<Widget> items;

  const ReadingStrip({super.key, required this.items});

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth < 560 ? 2 : items.length;
        final rows = <Widget>[];
        for (var i = 0; i < items.length; i += columns) {
          if (i > 0) rows.add(const SizedBox(height: 18));
          final slice = items.sublist(i, (i + columns).clamp(0, items.length));
          rows.add(
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var j = 0; j < slice.length; j++) ...[
                  if (j > 0)
                    Container(
                      width: 1,
                      height: 32,
                      margin: const EdgeInsets.symmetric(horizontal: 18),
                      color: palette.border,
                    ),
                  Expanded(child: slice[j]),
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

/// 空状态：一句话说清下一步，不摆装饰。
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
    final palette = AppPalette.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 64),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 26, color: palette.faint),
            const SizedBox(height: 20),
            Text(
              title,
              style: Theme.of(context).textTheme.headlineSmall,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 9),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 330),
              child: Text(
                description,
                style: TextStyle(
                  fontSize: 12.5,
                  color: palette.muted,
                  height: 1.7,
                ),
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

/// 探测行右侧「单流 / 速度」的文字样式。
///
/// 「单流」是中文，等宽字体不含中文字形，套上去会变成方块；
/// 速度是纯数字，用等宽才能对齐。分开写清楚，别在三元里混。
TextStyle _probeValueStyle(ProbeStatus status, AppPalette palette) {
  if (status == ProbeStatus.noRange) {
    return TextStyle(fontSize: 11.5, color: palette.warning);
  }
  return dataStyle(size: 11.5, color: palette.ink, letterSpacing: 0);
}

/// 镜像探测结果行：名称、类型、延迟、速度。
class SourceProbeRow extends StatelessWidget {
  final SourceProbe probe;
  final int? index;

  const SourceProbeRow({super.key, required this.probe, this.index});

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final failed = probe.status == ProbeStatus.failed;
    final dotColor = switch (probe.status) {
      ProbeStatus.healthy => palette.positive,
      ProbeStatus.noRange => palette.warning,
      ProbeStatus.failed => palette.faint,
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 9),
      child: Row(
        children: [
          Container(
            width: 5,
            height: 5,
            decoration: BoxDecoration(color: dotColor, shape: BoxShape.circle),
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Row(
              children: [
                Flexible(
                  child: Text(
                    probe.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w500,
                      color: failed ? palette.faint : palette.ink,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                QuietTag(text: laneLabel(probe.lane)),
              ],
            ),
          ),
          if (failed)
            Text(
              probe.error ?? '不可用',
              style: TextStyle(fontSize: 11, color: palette.faint),
            )
          else ...[
            SizedBox(
              width: 52,
              child: Text(
                '${probe.latencyMs}ms',
                textAlign: TextAlign.right,
                style: dataStyle(
                  size: 11,
                  weight: FontWeight.w400,
                  color: palette.muted,
                  letterSpacing: 0,
                ),
              ),
            ),
            const SizedBox(width: 14),
            SizedBox(
              width: 78,
              child: Text(
                probe.status == ProbeStatus.noRange
                    ? '单流'
                    : humanSpeed(probe.speedBps),
                textAlign: TextAlign.right,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                // 「单流」是中文（等宽字体没有中文字形，会变方块），
                // 速度是纯数字，才用等宽。
                style: _probeValueStyle(probe.status, palette),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 下载来源行：色条标识来源，右侧速度。
class SiteLaneRow extends StatelessWidget {
  final SiteProgress site;
  final int index;

  const SiteLaneRow({super.key, required this.site, required this.index});

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final color = site.disabled ? palette.faint : siteColor(index);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 9),
      child: Row(
        children: [
          Container(
            width: 3,
            height: 15,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(1.5),
            ),
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Row(
              children: [
                Flexible(
                  child: Text(
                    site.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w500,
                      color: site.disabled ? palette.faint : palette.ink,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                QuietTag(text: '${site.connections} 线程'),
                if (site.disabled) ...[
                  const SizedBox(width: 6),
                  Text(
                    '已停用',
                    style: TextStyle(fontSize: 10.5, color: palette.danger),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 10),
          SizedBox(
            width: 82,
            child: Text(
              humanSpeed(site.speedBps),
              textAlign: TextAlign.right,
              style: dataStyle(
                size: 11.5,
                color: site.disabled ? palette.faint : palette.ink,
                letterSpacing: 0,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 分片条纹——这个应用的视觉签名。
///
/// 108 个镜像把一个大文件切成上千片同时拉，这件事本身就是产品。
/// 所以不画成小方块网格，而画成一条连续的墨带：未下载是纸色，
/// 已完成的按来源上色，失败是朱砂。它随下载推进而生长，
/// 比任何进度条都更能说明「很多条线在同时供给一个文件」。
class ShardBand extends StatelessWidget {
  final List<int> chunkMap;
  final double height;

  const ShardBand({super.key, required this.chunkMap, this.height = 34});

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    if (chunkMap.isEmpty) {
      return Text(
        '单流下载，无分片视图',
        style: TextStyle(fontSize: 12, color: palette.muted),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(3),
      child: SizedBox(
        height: height,
        child: LayoutBuilder(
          builder: (context, constraints) {
            // 一个分片至少要半个像素才看得见，超过就按比例合并。
            final cells = constraints.maxWidth.floor().clamp(1, 4000);
            final step = (chunkMap.length / cells).ceil().clamp(1, chunkMap.length);
            final bars = <Widget>[];
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
              bars.add(
                Expanded(
                  flex: end - i,
                  child: ColoredBox(
                    color: chosen > 0
                        ? siteColor(chosen - 1)
                        : chosen < 0
                        ? palette.danger
                        : palette.surfaceAlt,
                  ),
                ),
              );
            }
            return Row(
              // stretch 是必须的：ColoredBox 没有固有高度，
              // 否则整条带子会塌成 0 高。
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: bars,
            );
          },
        ),
      ),
    );
  }
}

/// 细线条进度条。
class Meter extends StatelessWidget {
  final double? value;
  final Color? color;
  final double height;

  const Meter({super.key, this.value, this.color, this.height = 4});

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return ClipRRect(
      borderRadius: BorderRadius.circular(height / 2),
      child: LinearProgressIndicator(
        value: value,
        minHeight: height,
        backgroundColor: palette.surfaceAlt,
        color: color ?? palette.accent,
      ),
    );
  }
}

/// 图例。
class LegendDot extends StatelessWidget {
  final Color color;
  final String label;
  const LegendDot({super.key, required this.color, required this.label});

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
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
        const SizedBox(width: 6),
        Text(label, style: TextStyle(fontSize: 10.5, color: palette.muted)),
      ],
    );
  }
}
