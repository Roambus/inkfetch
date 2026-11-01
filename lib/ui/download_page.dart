import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/format.dart';
import '../core/models.dart';
import '../state/app_controller.dart';
import 'theme.dart';
import 'widgets.dart';

class DownloadPage extends StatelessWidget {
  final AppController controller;
  const DownloadPage({super.key, required this.controller});

  AppController get c => controller;

  @override
  Widget build(BuildContext context) {
    final snapshot = c.snapshot;
    if (snapshot == null) {
      return ListView(
        padding: const EdgeInsets.fromLTRB(18, 14, 18, 28),
        children: [
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 960),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  EmptyState(
                    icon: Icons.cloud_download_rounded,
                    title: '暂无进行中的下载',
                    description:
                        '在首页粘贴 GitHub 链接，点击底部的「开始下载」即可。'
                        '下载按钮固定在底部，不需要滚动。',
                    action: FilledButton.icon(
                      onPressed: () => c.setTab(0),
                      icon: const Icon(Icons.add_link_rounded, size: 18),
                      label: const Text('去下载'),
                    ),
                  ),
                  if (c.queuedUrls.isNotEmpty) ...[
                    const SizedBox(height: 14),
                    _buildQueueCard(context),
                  ],
                  if (c.incompleteTasks.isNotEmpty) ...[
                    const SizedBox(height: 14),
                    _buildIncompleteCard(context),
                  ],
                ],
              ),
            ),
          ),
        ],
      );
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 24),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 960),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildHeader(context, snapshot),
              const SizedBox(height: 14),
              _buildProgressCard(context, snapshot),
              if (c.copyingToFolder) ...[
                const SizedBox(height: 14),
                _buildCopyCard(context),
              ],
              if (snapshot.error != null &&
                  snapshot.phase != DownloadPhase.failed) ...[
                const SizedBox(height: 14),
                _buildNotice(context, snapshot.error!),
              ],
              if (snapshot.phase == DownloadPhase.completed ||
                  snapshot.phase == DownloadPhase.failed ||
                  snapshot.phase == DownloadPhase.cancelled) ...[
                const SizedBox(height: 14),
                _buildResultActions(context, snapshot),
              ],
              if (c.queuedUrls.isNotEmpty) ...[
                const SizedBox(height: 14),
                _buildQueueCard(context),
              ],
              const SizedBox(height: 14),
              _buildSitesCard(context, snapshot),
              const SizedBox(height: 14),
              _buildChunkCard(context, snapshot),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildQueueCard(BuildContext context) {
    final muted = Theme.of(context).colorScheme.onSurface
        .withValues(alpha: 0.5);
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionHeader(
            title: '下载队列',
            subtitle: '当前任务结束后自动依次下载，共 ${c.queuedUrls.length} 个',
            trailing: TextButton(
              onPressed: c.clearQueue,
              child: const Text('清空'),
            ),
          ),
          const SizedBox(height: 4),
          for (var i = 0; i < c.queuedUrls.length; i++)
            Row(
              children: [
                const Icon(Icons.schedule_rounded, size: 15),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    c.queuedUrls[i],
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: muted),
                  ),
                ),
                IconButton(
                  tooltip: '移出队列',
                  visualDensity: VisualDensity.compact,
                  onPressed: () => c.cancelQueued(i),
                  icon: const Icon(Icons.close_rounded, size: 16),
                ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _buildIncompleteCard(BuildContext context) {
    final muted = Theme.of(context).colorScheme.onSurface
        .withValues(alpha: 0.5);
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionHeader(
            title: '未完成的下载',
            subtitle: '重启后仍可继续，已完成的分片不会重复下载',
          ),
          const SizedBox(height: 8),
          for (final task in c.incompleteTasks)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 7),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(
                        Icons.restore_rounded,
                        size: 16,
                        color: kAccentAlt,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          task.filename,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      Text(
                        '${(task.progress * 100).toStringAsFixed(1)}%',
                        style: const TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w700,
                          color: kAccentAlt,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 5),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(5),
                    child: LinearProgressIndicator(
                      value: task.progress,
                      minHeight: 4,
                      backgroundColor: Theme.of(context).colorScheme.onSurface
                          .withValues(alpha: 0.08),
                      color: kAccentAlt,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '${humanBytes(task.downloaded)} / '
                          '${humanBytes(task.total)} · '
                          '${task.completedChunks}/${task.chunkCount} 分片',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 11, color: muted),
                        ),
                      ),
                      TextButton(
                        onPressed: () => c.resumeIncomplete(task),
                        child: const Text('继续'),
                      ),
                      TextButton(
                        onPressed: () => c.deleteIncomplete(task),
                        child: const Text('删除'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildCopyCard(BuildContext context) {
    final muted = Theme.of(context).colorScheme.onSurface
        .withValues(alpha: 0.5);
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionHeader(
            title: '正在复制到所选文件夹',
            subtitle: '复制完成后会自动删除应用目录里的临时文件',
          ),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: LinearProgressIndicator(
              value: c.copyProgress,
              minHeight: 8,
              backgroundColor: Theme.of(context).colorScheme.onSurface
                  .withValues(alpha: 0.08),
              color: kAccent,
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Text(
                '${(c.copyProgress * 100).toStringAsFixed(1)}%',
                style: TextStyle(fontSize: 11.5, color: muted),
              ),
              const Spacer(),
              OutlinedButton.icon(
                onPressed: c.cancelFolderCopy,
                icon: const Icon(Icons.stop_rounded, size: 17),
                label: const Text('取消复制'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildHeader(BuildContext context, DownloadSnapshot snapshot) {
    final muted = Theme.of(context).colorScheme.onSurface
        .withValues(alpha: 0.5);
    final running = c.downloading;
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            snapshot.filename,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                        ),
                        const SizedBox(width: 10),
                        StatusChip(phase: snapshot.phase),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      snapshot.destPath.isEmpty ? '准备下载…' : snapshot.destPath,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11.5, color: muted),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (running && snapshot.phase == DownloadPhase.downloading)
                OutlinedButton.icon(
                  onPressed: c.pauseDownload,
                  icon: const Icon(Icons.pause_rounded, size: 18),
                  label: const Text('暂停'),
                ),
              if (running && snapshot.phase == DownloadPhase.paused)
                FilledButton.icon(
                  onPressed: c.resumeDownload,
                  icon: const Icon(Icons.play_arrow_rounded, size: 18),
                  label: const Text('继续'),
                ),
              if (running)
                OutlinedButton.icon(
                  onPressed: c.cancelDownload,
                  icon: const Icon(Icons.stop_rounded, size: 18),
                  label: const Text('取消'),
                ),
              if (!running &&
                  (snapshot.phase == DownloadPhase.completed ||
                      snapshot.phase == DownloadPhase.failed ||
                      snapshot.phase == DownloadPhase.cancelled)) ...[
                FilledButton.icon(
                  onPressed: c.clearTask,
                  icon: const Icon(Icons.add_rounded, size: 18),
                  label: const Text('新的下载'),
                ),
                if (snapshot.phase == DownloadPhase.failed ||
                    snapshot.phase == DownloadPhase.cancelled) ...[
                  OutlinedButton.icon(
                    onPressed: c.startDownload,
                    icon: const Icon(Icons.refresh_rounded, size: 18),
                    label: Text(
                      snapshot.phase == DownloadPhase.cancelled
                          ? '继续下载'
                          : '重试下载',
                    ),
                  ),
                  OutlinedButton.icon(
                    onPressed: c.deleteCurrentPartial,
                    icon: const Icon(Icons.delete_outline_rounded, size: 18),
                    label: const Text('删除未完成文件'),
                  ),
                ],
              ],
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildProgressCard(BuildContext context, DownloadSnapshot snapshot) {
    final muted = Theme.of(context).colorScheme.onSurface
        .withValues(alpha: 0.5);
    final percent = snapshot.phase == DownloadPhase.completed
        ? 1.0
        : snapshot.progress;
    final verifying = snapshot.phase == DownloadPhase.verifying;
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                (percent * 100).toStringAsFixed(1),
                style: TextStyle(
                  fontSize: 46,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -2,
                  height: 1,
                  color: snapshot.phase == DownloadPhase.failed
                      ? kDanger
                      : Theme.of(context).colorScheme.onSurface,
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(bottom: 4, left: 2),
                child: Text(
                  '%',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                    color: muted,
                  ),
                ),
              ),
              const Spacer(),
              if (snapshot.phase == DownloadPhase.downloading ||
                  snapshot.phase == DownloadPhase.paused)
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      humanSpeed(snapshot.speedBps),
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                        color: kAccent,
                        letterSpacing: -0.5,
                      ),
                    ),
                    Text(
                      '实时速度',
                      style: TextStyle(fontSize: 10.5, color: muted),
                    ),
                  ],
                ),
            ],
          ),
          const SizedBox(height: 16),
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: LinearProgressIndicator(
              value: verifying
                  ? null
                  : (snapshot.phase == DownloadPhase.failed
                        ? snapshot.progress
                        : percent),
              minHeight: 10,
              backgroundColor: Theme.of(context).colorScheme.onSurface
                  .withValues(alpha: 0.08),
              color: snapshot.phase == DownloadPhase.failed
                  ? kDanger
                  : (snapshot.phase == DownloadPhase.completed
                        ? kAccentAlt
                        : kAccent),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                '${humanBytes(snapshot.downloaded)} / '
                '${snapshot.total > 0 ? humanBytes(snapshot.total) : '未知大小'}',
                style: TextStyle(fontSize: 11.5, color: muted),
              ),
              if (verifying)
                const Text(
                  '正在校验 SHA-256…',
                  style: TextStyle(fontSize: 11.5, color: kAccentAlt),
                )
              else
                Text(
                  '${snapshot.chunkMap.length} 分片 · ${snapshot.sites.length} 个源',
                  style: TextStyle(fontSize: 11.5, color: muted),
                ),
            ],
          ),
          const SizedBox(height: 16),
          StatGrid(
            items: [
              StatBlock(
                label: '已下载',
                value: humanBytes(snapshot.downloaded),
                icon: Icons.download_done_rounded,
              ),
              StatBlock(
                label: '剩余时间',
                value: snapshot.phase == DownloadPhase.downloading
                    ? humanDuration(snapshot.etaSecs)
                    : '—',
                icon: Icons.hourglass_bottom_rounded,
              ),
              StatBlock(
                label: '耗时',
                value: humanDuration(snapshot.elapsedMs ~/ 1000),
                icon: Icons.timer_outlined,
              ),
              StatBlock(
                label: '平均速度',
                value: snapshot.elapsedMs > 0
                    ? humanSpeed(
                        (snapshot.downloaded / (snapshot.elapsedMs / 1000.0))
                            .round(),
                      )
                    : '—',
                icon: Icons.speed_rounded,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildNotice(BuildContext context, String message) {
    return AppCard(
      color: kWarning.withValues(alpha: 0.1),
      child: Row(
        children: [
          const Icon(Icons.info_outline_rounded, color: kWarning, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(fontSize: 12, height: 1.5),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildResultActions(BuildContext context, DownloadSnapshot snapshot) {
    final completed = snapshot.phase == DownloadPhase.completed;
    final muted = Theme.of(context).colorScheme.onSurface
        .withValues(alpha: 0.5);
    return AppCard(
      gradient: completed
          ? LinearGradient(
              colors: [
                kAccentAlt.withValues(alpha: 0.12),
                kAccent.withValues(alpha: 0.05),
              ],
            )
          : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                completed
                    ? Icons.check_circle_rounded
                    : (snapshot.phase == DownloadPhase.cancelled
                          ? Icons.cancel_rounded
                          : Icons.error_rounded),
                color: completed
                    ? kAccentAlt
                    : (snapshot.phase == DownloadPhase.cancelled
                          ? kWarning
                          : kDanger),
                size: 22,
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  completed
                      ? '下载完成，文件已就绪'
                      : (snapshot.phase == DownloadPhase.cancelled
                            ? '下载已取消'
                            : snapshot.error ?? '下载失败'),
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          if (completed) ...[
            const SizedBox(height: 6),
            Text(
              snapshot.destPath,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11.5, color: muted),
            ),
            if (snapshot.sha256 != null) ...[
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 7,
                ),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.onSurface
                      .withValues(alpha: 0.05),
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Row(
                  children: [
                    const Icon(
                      Icons.fingerprint_rounded,
                      size: 15,
                      color: kAccentAlt,
                    ),
                    const SizedBox(width: 7),
                    Expanded(
                      child: Text(
                        snapshot.shaVerified
                            ? 'SHA-256（已与 GitHub 官方 digest 一致）  ${snapshot.sha256}'
                            : 'SHA-256（已计算，未与官方比对）  ${snapshot.sha256}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          color: muted,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ),
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      tooltip: '复制 SHA-256',
                      onPressed: () {
                        Clipboard.setData(
                          ClipboardData(text: snapshot.sha256!),
                        );
                      },
                      icon: const Icon(Icons.copy_rounded, size: 15),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 14),
            Wrap(
              spacing: 9,
              runSpacing: 9,
              children: [
                FilledButton.icon(
                  onPressed: c.openCurrentFile,
                  icon: const Icon(Icons.open_in_new_rounded, size: 18),
                  label: const Text('打开文件'),
                ),
                OutlinedButton.icon(
                  onPressed: c.openCurrentFolder,
                  icon: const Icon(Icons.folder_open_rounded, size: 18),
                  label: const Text('打开文件夹'),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildSitesCard(BuildContext context, DownloadSnapshot snapshot) {
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionHeader(
            title: '来源分配',
            subtitle: '按实测速度加权分配线程；失效源会自动降权或停用',
          ),
          const SizedBox(height: 8),
          if (snapshot.sites.isEmpty)
            Text(
              '暂无来源信息',
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.onSurface
                    .withValues(alpha: 0.5),
              ),
            )
          else
            for (var i = 0; i < snapshot.sites.length; i++)
              SiteLaneRow(site: snapshot.sites[i], index: i),
        ],
      ),
    );
  }

  Widget _buildChunkCard(BuildContext context, DownloadSnapshot snapshot) {
    final muted = Theme.of(context).colorScheme.onSurface
        .withValues(alpha: 0.5);
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionHeader(
            title: '分片热力图',
            subtitle: snapshot.chunkMap.isEmpty
                ? '当前任务未获取到文件大小，使用单流下载'
                : '共 ${snapshot.chunkMap.length} 个分片，'
                      '每个方块代表 ${humanBytes(snapshot.chunkSize)}',
            trailing: snapshot.chunkMap.isEmpty
                ? null
                : Pill(
                    text: snapshot.chunkMap.length <= 160
                        ? '${snapshot.chunkMap.length} 块'
                        : '已压缩显示',
                    color: muted,
                    dense: true,
                  ),
          ),
          const SizedBox(height: 14),
          ChunkHeatmap(chunkMap: snapshot.chunkMap),
          if (snapshot.chunkMap.isNotEmpty) ...[
            const SizedBox(height: 14),
            Wrap(
              spacing: 12,
              runSpacing: 6,
              children: [
                for (var i = 0; i < snapshot.sites.length; i++)
                  LegendDot(color: siteColor(i), label: snapshot.sites[i].name),
                const LegendDot(color: kDanger, label: '重试中'),
                LegendDot(
                  color: Theme.of(context).colorScheme.onSurface
                      .withValues(alpha: 0.12),
                  label: '待下载',
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
