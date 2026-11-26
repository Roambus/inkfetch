import 'package:flutter/material.dart';

import '../state/accel_controller.dart';
import '../state/app_controller.dart';
import 'download_page.dart';
import 'history_page.dart';
import 'home_page.dart';
import 'theme.dart';

/// 下载区：把「下载 / 任务 / 记录」收进同一个页面。
///
/// 这三件事本来就是一件事的三个阶段——输入链接、看进度、看历史。
/// 之前拆成三个顶级导航项，用户要在侧栏来回跳：
/// 粘完链接跳到「任务」，想找回上次下的东西又要去「记录」。
///
/// 现在用一行分段标签把它们放在一起，标签栏常驻在页面顶部，
/// 切换不改变整体布局，也不会让侧栏变长。
class DownloadsHub extends StatefulWidget {
  final AppController controller;
  final AccelController accel;

  const DownloadsHub({
    super.key,
    required this.controller,
    required this.accel,
  });

  @override
  State<DownloadsHub> createState() => _DownloadsHubState();
}

class _DownloadsHubState extends State<DownloadsHub> {
  @override
  void initState() {
    super.initState();
    // 自动跟随控制器的阶段：开始下载后要能自动切到「任务」。
    widget.controller.addListener(_onChanged);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (!mounted) return;
    // 控制器一开始下载就会把 downloadSection 切到「进行中」，
    // 这里只需要重建即可，标签选中态由控制器状态决定。
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final palette = AppPalette.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SectionTabs(
          controller: c,
          palette: palette,
        ),
        Expanded(
          child: IndexedStack(
            index: c.downloadSection.clamp(0, 2),
            children: [
              HomePage(controller: c),
              DownloadPage(controller: c),
              HistoryPage(controller: c),
            ],
          ),
        ),
      ],
    );
  }
}

/// 分段标签：下载 / 进行中 / 历史。
class _SectionTabs extends StatelessWidget {
  final AppController controller;
  final AppPalette palette;

  const _SectionTabs({required this.controller, required this.palette});

  @override
  Widget build(BuildContext context) {
    final current = controller.downloadSection.clamp(0, 2);
    final tabs = [
      (label: '下载', index: 0, badge: 0),
      (label: '进行中', index: 1, badge: controller.incompleteTasks.length),
      (label: '历史', index: 2, badge: 0),
    ];

    return Container(
      padding: const EdgeInsets.fromLTRB(34, 22, 34, 0),
      child: Row(
        children: [
          for (final tab in tabs) ...[
            _Tab(
              label: tab.label,
              badge: tab.badge,
              selected: current == tab.index,
              palette: palette,
              onTap: () => controller.setDownloadSection(tab.index),
            ),
            const SizedBox(width: 6),
          ],
        ],
      ),
    );
  }
}

class _Tab extends StatelessWidget {
  final String label;
  final int badge;
  final bool selected;
  final AppPalette palette;
  final VoidCallback onTap;

  const _Tab({
    required this.label,
    required this.badge,
    required this.selected,
    required this.palette,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? palette.surfaceAlt : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: selected ? palette.borderStrong : Colors.transparent,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                color: selected ? palette.ink : palette.muted,
              ),
            ),
            if (badge > 0) ...[
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                decoration: BoxDecoration(
                  color: palette.accent,
                  borderRadius: BorderRadius.circular(7),
                ),
                child: Text(
                  '$badge',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                    color: palette.surface,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
