import 'package:flutter/material.dart';

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
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(22, 26, 22, 40),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 880),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              PageHead(
                title: '任务',
                subtitle: snapshot == null
                    ? '当前没有下载。在「下载」页粘贴链接即可开始。'
                    : '进度、来源分配与分片状态。',
                trailing: snapshot == null
                    ? null
                    : StatusChip(phase: snapshot.phase),
              ),
              const SizedBox(height: 24),
              if (snapshot == null)
                _buildEmpty(context)
              else ...[
                _buildProgress(context, snapshot),
                if (c.copyingToFolder) ...[
                  const SizedBox(height: 12),
                  _buildCopy(context),
                ],
                if (snapshot.error != null &&
                    snapshot.phase != DownloadPhase.failed) ...[
                  const SizedBox(height: 12),
                  _buildNotice(context, snapshot.error!),
                ],
                const SizedBox(height: 12),
                _buildSites(context, snapshot),
              ],
              if (c.queuedUrls.isNotEmpty) ...[
                const SizedBox(height: 12),
                _buildQueue(context),
              ],
              if (c.incompleteTasks.isNotEmpty) ...[
                const SizedBox(height: 12),
                _buildIncomplete(context),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildEmpty(BuildContext context) {
    return AppCard(
      padding: EdgeInsets.zero,
      child: EmptyState(
        icon: Icons.south_rounded,
        title: '还没有正在进行的下载',
        description: '在「下载」页粘贴一个 GitHub 链接开始。断掉的下载会留在这里，随时可以接着下。',
        action: OutlinedButton(
          onPressed: () => c.setTab(0),
          child: const Text('去粘贴链接'),
        ),
      ),
    );
  }

  /// 进度区：把百分比、速度、分片带放在一张面板里，
  /// 分数线以上的信息少而重，以下的信息多而轻。
  Widget _buildProgress(BuildContext context, DownloadSnapshot snapshot) {
    final palette = AppPalette.of(context);
    final percent = snapshot.phase == DownloadPhase.completed
        ? 1.0
        : snapshot.progress;
    final verifying = snapshot.phase == DownloadPhase.verifying;
    final running = c.downloading;
    final done = snapshot.phase == DownloadPhase.completed;
    final failed = snapshot.phase == DownloadPhase.failed;
    final activeSpeed = snapshot.phase == DownloadPhase.downloading ||
        snapshot.phase == DownloadPhase.paused;

    return AppCard(
      padding: const EdgeInsets.fromLTRB(22, 20, 22, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            snapshot.filename,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 6),
          Text(
            snapshot.destPath.isEmpty ? '准备下载…' : snapshot.destPath,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 10.5,
              color: palette.faint,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(height: 22),
          // 数字是这一页的主角：百分比巨大，速度紧跟。
          // 窄屏时速度换到百分比下方，避免挤压。
          LayoutBuilder(
            builder: (context, constraints) {
              final compact = constraints.maxWidth < 430;
              final percentBlock = Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    (percent * 100).toStringAsFixed(1),
                    style: TextStyle(
                      fontSize: compact ? 44 : 52,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -1.8,
                      height: 0.95,
                      color: failed ? palette.danger : palette.ink,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6, left: 4),
                    child: Text(
                      '%',
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w400,
                        color: palette.faint,
                      ),
                    ),
                  ),
                ],
              );
              final speedBlock = activeSpeed
                  ? Column(
                      crossAxisAlignment: compact
                          ? CrossAxisAlignment.start
                          : CrossAxisAlignment.end,
                      children: [
                        Text(
                          humanSpeed(snapshot.speedBps),
                          style: dataStyle(
                            size: 21,
                            weight: FontWeight.w600,
                            color: palette.ink,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          snapshot.phase == DownloadPhase.paused
                              ? '已暂停'
                              : '实时速度',
                          style: TextStyle(fontSize: 10.5, color: palette.faint),
                        ),
                      ],
                    )
                  : done
                  ? Text(
                      humanBytes(snapshot.total),
                      style: dataStyle(
                        size: 21,
                        weight: FontWeight.w600,
                        color: palette.positive,
                      ),
                    )
                  : const SizedBox.shrink();
              if (compact) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    percentBlock,
                    if (activeSpeed || done) ...[
                      const SizedBox(height: 10),
                      speedBlock,
                    ],
                  ],
                );
              }
              return Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  percentBlock,
                  const Spacer(),
                  speedBlock,
                ],
              );
            },
          ),
          const SizedBox(height: 18),
          // 分片带：这个应用真正的样子。多镜像供给一个文件，
          // 颜色就是供给它的源，所以图例紧贴在下面。
          if (!verifying) ...[
            ShardBand(chunkMap: snapshot.chunkMap, height: 52),
            if (snapshot.sites.isNotEmpty) ...[
              const SizedBox(height: 14),
              Wrap(
                spacing: 14,
                runSpacing: 7,
                children: [
                  for (var i = 0; i < snapshot.sites.length; i++)
                    LegendDot(
                      color: siteColor(i),
                      label: snapshot.sites[i].name,
                    ),
                  LegendDot(color: palette.danger, label: '重试中'),
                  LegendDot(color: palette.surfaceAlt, label: '待下载'),
                ],
              ),
            ],
          ] else
            Meter(value: null, height: 52),
          const SizedBox(height: 11),
          // 字节数与分片数在窄屏会挤，用 Wrap 让它们自然换行。
          // 这两行含中文，不能用等宽字体（等宽字体没有中文字形，会出方块）。
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            spacing: 12,
            runSpacing: 4,
            children: [
              Text(
                '${humanBytes(snapshot.downloaded)} / '
                '${snapshot.total > 0 ? humanBytes(snapshot.total) : '未知大小'}',
                style: TextStyle(
                  fontSize: 11,
                  color: palette.muted,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              Text(
                verifying
                    ? '正在校验 SHA-256…'
                    : '${snapshot.chunkMap.length} 分片 · ${snapshot.sites.length} 个源',
                style: TextStyle(
                  fontSize: 11,
                  color: verifying ? palette.accent : palette.faint,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          Divider(height: 1),
          const SizedBox(height: 18),
          ReadingStrip(
            items: [
              Reading(
                label: '已下载',
                value: humanBytes(snapshot.downloaded),
                valueSize: 16,
              ),
              Reading(
                label: '剩余时间',
                value: snapshot.phase == DownloadPhase.downloading
                    ? humanDuration(snapshot.etaSecs)
                    : '—',
                valueSize: 16,
              ),
              Reading(
                label: '耗时',
                value: humanDuration(snapshot.elapsedMs ~/ 1000),
                valueSize: 16,
              ),
              Reading(
                label: '平均速度',
                value: snapshot.elapsedMs > 0
                    ? humanSpeed(
                        (snapshot.downloaded / (snapshot.elapsedMs / 1000.0))
                            .round(),
                      )
                    : '—',
                valueSize: 16,
              ),
            ],
          ),
          const SizedBox(height: 20),
          _actions(context, snapshot, running, done, failed),
        ],
      ),
    );
  }

  Widget _actions(
    BuildContext context,
    DownloadSnapshot snapshot,
    bool running,
    bool done,
    bool failed,
  ) {
    final palette = AppPalette.of(context);
    return Wrap(
      spacing: 9,
      runSpacing: 9,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (running && snapshot.phase == DownloadPhase.downloading)
          OutlinedButton.icon(
            onPressed: c.pauseDownload,
            icon: const Icon(Icons.pause_rounded, size: 15),
            label: const Text('暂停'),
          ),
        if (running && snapshot.phase == DownloadPhase.paused)
          FilledButton.icon(
            onPressed: c.resumeDownload,
            icon: const Icon(Icons.play_arrow_rounded, size: 15),
            label: const Text('继续'),
          ),
        if (running)
          OutlinedButton.icon(
            onPressed: c.cancelDownload,
            icon: const Icon(Icons.close_rounded, size: 15),
            label: const Text('取消'),
          ),
        if (!running && done) ...[
          FilledButton.icon(
            onPressed: c.openCurrentFile,
            icon: const Icon(Icons.north_east_rounded, size: 15),
            label: const Text('打开文件'),
          ),
          OutlinedButton.icon(
            onPressed: c.openCurrentFolder,
            icon: const Icon(Icons.folder_outlined, size: 15),
            label: const Text('打开文件夹'),
          ),
          TextButton(
            onPressed: c.clearTask,
            child: const Text('新的下载'),
          ),
        ],
        if (!running && failed) ...[
          FilledButton(
            onPressed: c.startDownload,
            child: const Text('重新下载'),
          ),
          OutlinedButton(
            onPressed: c.clearTask,
            child: const Text('新的下载'),
          ),
          TextButton(
            onPressed: c.deleteCurrentPartial,
            child: Text('删除未完成文件', style: TextStyle(color: palette.muted)),
          ),
        ],
        if (!running && snapshot.phase == DownloadPhase.cancelled) ...[
          FilledButton(
            onPressed: c.startDownload,
            child: const Text('继续下载'),
          ),
          OutlinedButton(
            onPressed: c.clearTask,
            child: const Text('新的下载'),
          ),
          TextButton(
            onPressed: c.deleteCurrentPartial,
            child: Text('删除未完成文件', style: TextStyle(color: palette.muted)),
          ),
        ],
      ],
    );
  }

  Widget _buildCopy(BuildContext context) {
    final palette = AppPalette.of(context);
    return AppCard(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionHeader(
            title: '正在复制到所选文件夹',
            subtitle: '复制完成后会删除应用目录中的临时文件',
          ),
          const SizedBox(height: 14),
          Meter(value: c.copyProgress),
          const SizedBox(height: 10),
          Row(
            children: [
              Text(
                '${(c.copyProgress * 100).toStringAsFixed(1)}%',
                style: dataStyle(
                  size: 11,
                  weight: FontWeight.w400,
                  color: palette.muted,
                  letterSpacing: 0,
                ),
              ),
              const Spacer(),
              TextButton(
                onPressed: c.cancelFolderCopy,
                child: const Text('取消复制'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildNotice(BuildContext context, String message) {
    final palette = AppPalette.of(context);
    return AppCard(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
      color: palette.warning.withValues(alpha: 0.05),
      child: Row(
        children: [
          Icon(Icons.info_outline_rounded, size: 15, color: palette.warning),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: TextStyle(
                fontSize: 12,
                color: palette.muted,
                height: 1.55,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSites(BuildContext context, DownloadSnapshot snapshot) {
    final palette = AppPalette.of(context);
    return AppCard(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionHeader(
            title: '来源分配',
            subtitle: '按实测速度加权分配线程，失效源自动降权或停用',
          ),
          const SizedBox(height: 10),
          if (snapshot.sites.isEmpty)
            Text(
              '暂无来源信息',
              style: TextStyle(fontSize: 12, color: palette.muted),
            )
          else
            for (var i = 0; i < snapshot.sites.length; i++) ...[
              if (i > 0) Divider(height: 1),
              SiteLaneRow(site: snapshot.sites[i], index: i),
            ],
        ],
      ),
    );
  }

  Widget _buildQueue(BuildContext context) {
    final palette = AppPalette.of(context);
    return AppCard(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionHeader(
            title: '下载队列',
            subtitle: '当前任务结束后依次下载，共 ${c.queuedUrls.length} 个',
            trailing: TextButton(
              onPressed: c.clearQueue,
              child: const Text('清空'),
            ),
          ),
          const SizedBox(height: 8),
          for (var i = 0; i < c.queuedUrls.length; i++) ...[
            if (i > 0) Divider(height: 1),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                children: [
                  SizedBox(
                    width: 20,
                    child: Text(
                      '${i + 1}',
                      style: dataStyle(
                        size: 10.5,
                        weight: FontWeight.w400,
                        color: palette.faint,
                        letterSpacing: 0,
                      ),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      c.queuedUrls[i],
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontFamily: kMono,
                        fontFamilyFallback: kMonoFallback,
                        fontSize: 11,
                        color: palette.muted,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: '移出队列',
                    onPressed: () => c.cancelQueued(i),
                    icon: const Icon(Icons.close_rounded, size: 14),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildIncomplete(BuildContext context) {
    final palette = AppPalette.of(context);
    return AppCard(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionHeader(
            title: '未完成的下载',
            subtitle: '已完成的分片不会重复下载',
          ),
          const SizedBox(height: 12),
          for (final task in c.incompleteTasks) ...[
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          task.filename,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                      Text(
                        '${(task.progress * 100).toStringAsFixed(0)}%',
                        style: dataStyle(
                          size: 11.5,
                          color: palette.muted,
                          letterSpacing: 0,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Meter(value: task.progress, height: 3),
                  const SizedBox(height: 5),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '${humanBytes(task.downloaded)} / ${humanBytes(task.total)} · '
                          '${task.completedChunks}/${task.chunkCount} 分片',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 10.5,
                            color: palette.faint,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
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
            if (task != c.incompleteTasks.last) Divider(height: 1),
          ],
        ],
      ),
    );
  }
}

