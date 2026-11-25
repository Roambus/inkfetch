import 'package:flutter/material.dart';

import '../state/accel_controller.dart';
import '../state/app_controller.dart';
import 'download_page.dart';
import 'github_accel_page.dart';
import 'history_page.dart';
import 'home_page.dart';
import 'settings_page.dart';
import 'theme.dart';
import 'widgets.dart';

class AppShell extends StatefulWidget {
  final AppController controller;
  final AccelController accel;

  const AppShell({super.key, required this.controller, required this.accel});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  late int _lastNoticeSeq;
  bool _folderChecked = false;

  AppController get c => widget.controller;

  AccelController get accel => widget.accel;

  @override
  void initState() {
    super.initState();
    _lastNoticeSeq = c.noticeSeq;
    c.addListener(_onControllerChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _folderChecked || !c.initialized) return;
      _folderChecked = true;
      c.promptFolderOnFirstLaunch();
    });
  }

  @override
  void dispose() {
    c.removeListener(_onControllerChanged);
    super.dispose();
  }

  void _onControllerChanged() {
    if (!_folderChecked && c.initialized) {
      _folderChecked = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) c.promptFolderOnFirstLaunch();
      });
    }
    if (c.noticeSeq == _lastNoticeSeq) return;
    _lastNoticeSeq = c.noticeSeq;
    final message = c.notice;
    if (message == null || message.isEmpty) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final messenger = ScaffoldMessenger.maybeOf(context);
      messenger?.hideCurrentSnackBar();
      messenger?.showSnackBar(SnackBar(content: Text(message)));
    });
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) => MediaQuery(
        data: media.copyWith(
          textScaler: media.textScaler.clamp(maxScaleFactor: 1.3),
        ),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final wide = constraints.maxWidth >= 900;
            return Scaffold(
              backgroundColor: Colors.transparent,
              body: AppBackground(
                child: SafeArea(
                  bottom: !wide,
                  child: wide
                      ? Row(
                          children: [
                            _SideBar(controller: c),
                            Expanded(child: _content()),
                          ],
                        )
                      : _content(),
                ),
              ),
              bottomNavigationBar: wide ? null : _BottomBar(controller: c),
            );
          },
        ),
      ),
    );
  }

  /// 只构建当前页，避免常驻四页产生大量无效语义节点。
  Widget _content() {
    return switch (c.tabIndex) {
      1 => DownloadPage(controller: c),
      2 => HistoryPage(controller: c),
      3 => GithubAccelPage(accel: accel),
      4 => SettingsPage(controller: c),
      _ => HomePage(controller: c),
    };
  }
}

/// 桌面侧栏：印章 + 宋体品牌字，导航项左侧一条墨线指示当前位置。
class _SideBar extends StatelessWidget {
  final AppController controller;
  const _SideBar({required this.controller});

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return Container(
      width: 216,
      decoration: BoxDecoration(
        color: palette.background,
        border: Border(right: BorderSide(color: palette.border)),
      ),
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Row(
              children: [
                const SealMark(size: 34),
                const SizedBox(width: 11),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '墨取',
                        style: displayStyle(
                          size: 18,
                          weight: FontWeight.w700,
                          color: palette.ink,
                          letterSpacing: 2,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'INKFETCH',
                        style: TextStyle(
                          fontFamily: kMono,
                          fontFamilyFallback: kMonoFallback,
                          fontSize: 8.5,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 2.2,
                          color: palette.faint,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 32),
          for (final item in _buildNavItems(controller))
            _SideNavItem(
              item: item,
              selected: controller.tabIndex == item.index,
              onTap: () => controller.setTab(item.index),
            ),
          const Spacer(),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Divider(color: palette.border),
                const SizedBox(height: 14),
                Text(
                  '本地运行',
                  style: TextStyle(
                    fontSize: 11,
                    color: palette.muted,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  '不上传任何数据',
                  style: TextStyle(fontSize: 10.5, color: palette.faint),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SideNavItem extends StatelessWidget {
  final _NavItem item;
  final bool selected;
  final VoidCallback onTap;

  const _SideNavItem({
    required this.item,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Material(
        color: selected ? palette.surface : Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide(
            color: selected ? palette.border : Colors.transparent,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(11, 10, 11, 10),
            child: Row(
              children: [
                Icon(
                  item.icon,
                  size: 17,
                  color: selected ? palette.accent : palette.faint,
                ),
                const SizedBox(width: 11),
                Expanded(
                  child: Text(
                    item.label,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                      letterSpacing: 0.6,
                      color: selected ? palette.ink : palette.muted,
                    ),
                  ),
                ),
                if (item.badge != null)
                  _NavBadge(
                    count: item.badge!(context),
                    active: selected,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _NavBadge extends StatelessWidget {
  final int count;
  final bool active;
  const _NavBadge({required this.count, required this.active});

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    if (count <= 0) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: active ? palette.accent : palette.surfaceAlt,
        borderRadius: BorderRadius.circular(3),
      ),
      child: Text(
        '$count',
        style: dataStyle(
          size: 9.5,
          weight: FontWeight.w600,
          color: active ? palette.onPrimaryFill : palette.muted,
          letterSpacing: 0,
        ),
      ),
    );
  }
}

/// 手机底部栏：选中项上方一小段墨线，比整块着色克制。
class _BottomBar extends StatelessWidget {
  final AppController controller;
  const _BottomBar({required this.controller});

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return Container(
      decoration: BoxDecoration(
        color: palette.surface,
        border: Border(top: BorderSide(color: palette.border)),
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 56,
          child: Row(
            children: [
              for (final item in _buildNavItems(controller))
                Expanded(
                  child: InkWell(
                    onTap: () => controller.setTab(item.index),
                    child: _BottomTab(
                      item: item,
                      selected: controller.tabIndex == item.index,
                      badge: item.badge?.call(context) ?? 0,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _BottomTab extends StatelessWidget {
  final _NavItem item;
  final bool selected;
  final int badge;

  const _BottomTab({
    required this.item,
    required this.selected,
    required this.badge,
  });

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Container(
          width: 16,
          height: 2,
          margin: const EdgeInsets.only(bottom: 7),
          decoration: BoxDecoration(
            color: selected ? palette.accent : Colors.transparent,
            borderRadius: BorderRadius.circular(1),
          ),
        ),
        Icon(
          item.icon,
          size: 19,
          color: selected ? palette.accent : palette.faint,
        ),
        const SizedBox(height: 4),
        Text(
          item.label,
          style: TextStyle(
            fontSize: 10.5,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
            letterSpacing: 0.5,
            color: selected ? palette.ink : palette.faint,
          ),
        ),
      ],
    );
  }
}

class _NavItem {
  final int index;
  final IconData icon;
  final String label;
  /// 导航项右侧的计数（未完成任务数），没有就不显示。
  final int Function(BuildContext)? badge;

  const _NavItem(this.index, this.icon, this.label, {this.badge});
}

/// 导航项由 shell 在使用处补上 controller 的计数。
List<_NavItem> _buildNavItems(AppController c) => [
  _NavItem(0, Icons.add_link_rounded, '下载'),
  _NavItem(1, Icons.south_rounded, '任务', badge: (_) => c.incompleteTasks.length),
  _NavItem(2, Icons.history_rounded, '记录'),
  _NavItem(3, Icons.north_east_rounded, '加速'),
  _NavItem(4, Icons.tune_rounded, '设置'),
];
