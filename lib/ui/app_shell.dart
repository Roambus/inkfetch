import 'package:flutter/material.dart';

import '../state/app_controller.dart';
import 'download_page.dart';
import 'history_page.dart';
import 'home_page.dart';
import 'settings_page.dart';
import 'theme.dart';
import 'widgets.dart';

class AppShell extends StatefulWidget {
  final AppController controller;
  const AppShell({super.key, required this.controller});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  late int _lastNoticeSeq;
  bool _folderChecked = false;

  AppController get c => widget.controller;

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
    final wide = MediaQuery.sizeOf(context).width >= 880;
    final pages = <Widget>[
      HomePage(controller: c),
      DownloadPage(controller: c),
      HistoryPage(controller: c),
      SettingsPage(controller: c),
    ];
    final body = IndexedStack(index: c.tabIndex, children: pages);

    // 固定字号的小布局在超大字体缩放下会重叠，这里限制上限。
    final media = MediaQuery.of(context);
    return MediaQuery(
      data: media.copyWith(
        textScaler: media.textScaler.clamp(maxScaleFactor: 1.4),
      ),
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: AppBackground(
          child: SafeArea(
            bottom: !wide,
            child: wide
                ? Row(
                    children: [
                      _buildRail(context),
                      Expanded(child: body),
                    ],
                  )
                : body,
          ),
        ),
        bottomNavigationBar: wide ? null : _buildBottomBar(context),
      ),
    );
  }

  Widget _buildRail(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      width: 92,
      decoration: BoxDecoration(
        border: Border(
          right: BorderSide(
            color: dark ? const Color(0xFF1D2B43) : const Color(0xFFE4EBF6),
          ),
        ),
      ),
      child: Column(
        children: [
          const SizedBox(height: 18),
          const GradientBadge(size: 42, icon: Icons.bolt_rounded),
          const SizedBox(height: 26),
          Expanded(
            child: NavigationRail(
              selectedIndex: c.tabIndex,
              onDestinationSelected: c.setTab,
              labelType: NavigationRailLabelType.all,
              backgroundColor: Colors.transparent,
              groupAlignment: -1,
              destinations: [
                for (final item in _navItems)
                  NavigationRailDestination(
                    icon: Icon(item.$1),
                    selectedIcon: Icon(item.$2),
                    label: Text(item.$3),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBottomBar(BuildContext context) {
    return NavigationBar(
      selectedIndex: c.tabIndex,
      onDestinationSelected: c.setTab,
      destinations: [
        for (final item in _navItems)
          NavigationDestination(
            icon: Icon(item.$1),
            selectedIcon: Icon(item.$2),
            label: item.$3,
          ),
      ],
    );
  }

  static const List<(IconData, IconData, String)> _navItems = [
    (Icons.rocket_launch_outlined, Icons.rocket_launch_rounded, '下载'),
    (Icons.cloud_download_outlined, Icons.cloud_download_rounded, '任务'),
    (Icons.history_outlined, Icons.history_rounded, '记录'),
    (Icons.tune_outlined, Icons.tune_rounded, '设置'),
  ];
}
