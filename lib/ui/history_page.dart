import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/format.dart';
import '../core/models.dart';
import '../state/app_controller.dart';
import 'theme.dart';
import 'widgets.dart';

class HistoryPage extends StatelessWidget {
  final AppController controller;
  const HistoryPage({super.key, required this.controller});

  AppController get c => controller;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 28),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 920),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              PageHead(
                title: '记录',
                subtitle: '完成、取消与失败的下载都会留在这里。',
                trailing: c.history.isEmpty
                    ? null
                    : TextButton.icon(
                        onPressed: () => _confirmClear(context),
                        icon: const Icon(Icons.delete_sweep_outlined, size: 16),
                        label: const Text('清空'),
                      ),
              ),
              const SizedBox(height: 22),
              if (c.history.isEmpty)
                AppCard(
                  child: EmptyState(
                    icon: Icons.schedule_rounded,
                    title: '还没有下载记录',
                    description: '完成的下载会记录在这里，可直接打开文件或所在文件夹。',
                    action: OutlinedButton.icon(
                      onPressed: () => c.setTab(0),
                      icon: const Icon(Icons.link_rounded, size: 17),
                      label: const Text('去下载'),
                    ),
                  ),
                )
              else
                AppCard(
                  padding: EdgeInsets.zero,
                  child: Column(
                    children: [
                      for (var i = 0; i < c.history.length; i++) ...[
                        if (i > 0)
                          Divider(height: 1, color: palette.border),
                        _HistoryRow(controller: c, entry: c.history[i]),
                      ],
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _confirmClear(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清空下载记录？'),
        content: const Text('仅删除记录，不会删除已下载的文件。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await c.clearHistory();
    }
  }
}

class _HistoryRow extends StatelessWidget {
  final AppController controller;
  final HistoryEntry entry;

  const _HistoryRow({required this.controller, required this.entry});

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final completed = entry.status == 'completed';
    final color = completed
        ? palette.positive
        : (entry.status == 'cancelled' ? palette.warning : palette.danger);
    final statusText = completed
        ? '已完成'
        : (entry.status == 'cancelled' ? '已取消' : '失败');

    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 14, 8, 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Container(
              width: 7,
              height: 7,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  entry.filename,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                    color: palette.ink,
                  ),
                ),
                const SizedBox(height: 5),
                Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    Text(
                      statusText,
                      style: TextStyle(fontSize: 11, color: color),
                    ),
                    Text(
                      '${humanBytes(entry.total)} · ${humanSpeed(entry.speedBps)}',
                      style: TextStyle(fontSize: 11, color: palette.muted),
                    ),
                    Text(
                      formatTime(entry.createdAt),
                      style: TextStyle(fontSize: 11, color: palette.faint),
                    ),
                  ],
                ),
                if (entry.destPath.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    entry.destPath,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11, color: palette.faint),
                  ),
                ],
                if (entry.error != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    entry.error!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11, color: palette.danger),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 6),
          if (completed)
            IconButton(
              tooltip: '打开文件',
              onPressed: () => controller.openHistoryFile(entry),
              icon: const Icon(Icons.open_in_new_rounded, size: 17),
            ),
          IconButton(
            tooltip: '打开文件夹',
            onPressed: () => controller.openHistoryFolder(entry),
            icon: const Icon(Icons.folder_open_outlined, size: 17),
          ),
          PopupMenuButton<String>(
            tooltip: '更多操作',
            icon: const Icon(Icons.more_horiz_rounded, size: 18),
            onSelected: (action) async {
              switch (action) {
                case 'copy':
                  await Clipboard.setData(ClipboardData(text: entry.url));
                  break;
                case 'delete':
                  await controller.deleteHistoryEntry(entry);
                  break;
              }
            },
            itemBuilder: (context) => const [
              PopupMenuItem(
                value: 'copy',
                height: 40,
                child: Text('复制原始链接', style: TextStyle(fontSize: 12.5)),
              ),
              PopupMenuItem(
                value: 'delete',
                height: 40,
                child: Text('删除记录', style: TextStyle(fontSize: 12.5)),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
