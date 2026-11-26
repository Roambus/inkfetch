import 'package:flutter/material.dart';

import '../core/update_check.dart';
import '../state/app_controller.dart';
import 'theme.dart';
import 'widgets.dart';

/// 新版本提示。
///
/// 只有三个出口，且都不强迫用户：
///   · 去下载   —— 打开官网下载页；
///   · 跳过此版本 —— 只在下一个版本出现前不再打扰；
///   · 稍后       —— 这次不处理，下次启动还会问。
///
/// 不做「必须更新才能继续」的门：这是免安装的单文件工具，
/// 拦着用户不让他用，比让他用旧版本更糟。
Future<void> showUpdateDialog(
  BuildContext context,
  AppController controller,
  UpdateCheckResult update,
) async {
  final action = await showDialog<_UpdateAction>(
    context: context,
    barrierDismissible: true,
    builder: (context) => _UpdateDialog(update: update),
  );
  switch (action) {
    case _UpdateAction.download:
      await openReleasePage(update.releaseUrl);
    case _UpdateAction.skip:
      await controller.skipUpdateVersion();
    case _UpdateAction.later:
    case null:
      // 什么都不记：下次启动会再提示一次。
      break;
  }
}

enum _UpdateAction { download, skip, later }

class _UpdateDialog extends StatelessWidget {
  final UpdateCheckResult update;

  const _UpdateDialog({required this.update});

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final notes = (update.notes ?? '').trim();
    return AlertDialog(
      backgroundColor: palette.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: palette.border),
      ),
      titlePadding: const EdgeInsets.fromLTRB(24, 22, 24, 0),
      contentPadding: const EdgeInsets.fromLTRB(24, 14, 24, 4),
      actionsPadding: const EdgeInsets.fromLTRB(16, 8, 20, 16),
      title: Row(
        children: [
          const BrandMark(size: 30),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '有新版本',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: palette.ink,
                  ),
                ),
                const SizedBox(height: 1),
                Text(
                  '官网最新 ${update.latest}',
                  style: TextStyle(
                    fontSize: 11.5,
                    color: palette.muted,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 380),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                _versionChip(palette, '当前', update.current, false),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Icon(
                    Icons.east_rounded,
                    size: 14,
                    color: palette.faint,
                  ),
                ),
                _versionChip(palette, '最新', update.latest, true),
              ],
            ),
            if (notes.isNotEmpty) ...[
              const SizedBox(height: 14),
              Text(
                notes.length > 220 ? '${notes.substring(0, 220)}…' : notes,
                style: TextStyle(
                  fontSize: 12,
                  height: 1.7,
                  color: palette.muted,
                ),
              ),
            ],
            const SizedBox(height: 14),
            Text(
              '不更新也能继续用。跳过后只记住这个版本，下个版本还会提示。',
              style: TextStyle(
                fontSize: 11.5,
                height: 1.65,
                color: palette.faint,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(_UpdateAction.skip),
          child: const Text('跳过此版本'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(_UpdateAction.later),
          child: const Text('稍后'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_UpdateAction.download),
          child: const Text('去下载'),
        ),
      ],
    );
  }

  Widget _versionChip(
    AppPalette palette,
    String label,
    String version,
    bool highlight,
  ) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: highlight
            ? palette.accent.withValues(alpha: 0.08)
            : palette.surfaceAlt,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: highlight
              ? palette.accent.withValues(alpha: 0.28)
              : palette.border,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: TextStyle(fontSize: 10.5, color: palette.faint),
          ),
          const SizedBox(width: 6),
          Text(
            version,
            style: TextStyle(
              fontFamily: kMono,
              fontFamilyFallback: kMonoFallback,
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: highlight ? palette.accent : palette.ink,
            ),
          ),
        ],
      ),
    );
  }
}
