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
    if (c.history.isEmpty) {
      return EmptyState(
        icon: Icons.history_rounded,
        title: '还没有下载记录',
        description: '完成的下载会记录在这里，可直接打开文件或所在文件夹。',
        action: OutlinedButton.icon(
          onPressed: () => c.setTab(0),
          icon: const Icon(Icons.add_link_rounded, size: 18),
          label: const Text('去下载'),
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 28),
      children: [
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 960),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Text(
                      '下载记录',
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    const SizedBox(width: 10),
                    Pill(
                      text: '${c.history.length}',
                      color: kAccent,
                      dense: true,
                    ),
                    const Spacer(),
                    TextButton.icon(
                      onPressed: () => _confirmClear(context),
                      icon: const Icon(Icons.delete_sweep_rounded, size: 18),
                      label: const Text('清空'),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                for (final entry in c.history) ...[
                  _HistoryCard(controller: c, entry: entry),
                  const SizedBox(height: 10),
                ],
              ],
            ),
          ),
        ),
      ],
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

class _HistoryCard extends StatelessWidget {
  final AppController controller;
  final HistoryEntry entry;

  const _HistoryCard({required this.controller, required this.entry});

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).colorScheme.onSurface
        .withValues(alpha: 0.5);
    final completed = entry.status == 'completed';
    final color = completed
        ? kAccentAlt
        : (entry.status == 'cancelled' ? kWarning : kDanger);
    final icon = completed
        ? Icons.check_circle_rounded
        : (entry.status == 'cancelled'
              ? Icons.cancel_rounded
              : Icons.error_rounded);
    return AppCard(
      padding: const EdgeInsets.fromLTRB(16, 14, 10, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon, color: color, size: 19),
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      entry.filename,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${humanBytes(entry.total)} · '
                      '${humanSpeed(entry.speedBps)} · '
                      '${formatTime(entry.createdAt)}',
                      style: TextStyle(fontSize: 11.5, color: muted),
                    ),
                    if (entry.destPath.isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Text(
                        entry.destPath,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 11, color: muted),
                      ),
                    ],
                    if (entry.error != null) ...[
                      const SizedBox(height: 4),
                      Text(
                        entry.error!,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 11, color: kDanger),
                      ),
                    ],
                  ],
                ),
              ),
              PopupMenuButton<String>(
                tooltip: '更多操作',
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
                    child: ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.copy_rounded, size: 18),
                      title: Text('复制原始链接'),
                    ),
                  ),
                  PopupMenuItem(
                    value: 'delete',
                    child: ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.delete_outline_rounded, size: 18),
                      title: Text('删除记录'),
                    ),
                  ),
                ],
              ),
            ],
          ),
          if (completed) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: () => controller.openHistoryFile(entry),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(0, 38),
                    padding: const EdgeInsets.symmetric(horizontal: 13),
                  ),
                  icon: const Icon(Icons.open_in_new_rounded, size: 16),
                  label: const Text('打开文件', style: TextStyle(fontSize: 12.5)),
                ),
                OutlinedButton.icon(
                  onPressed: () => controller.openHistoryFolder(entry),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(0, 38),
                    padding: const EdgeInsets.symmetric(horizontal: 13),
                  ),
                  icon: const Icon(Icons.folder_open_rounded, size: 16),
                  label: const Text('打开文件夹', style: TextStyle(fontSize: 12.5)),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
