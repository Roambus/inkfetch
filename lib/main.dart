import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'state/app_controller.dart';
import 'ui/app_shell.dart';
import 'ui/theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runZonedGuarded(
    () {
      FlutterError.onError = (details) {
        FlutterError.presentError(details);
        if (kReleaseMode) debugPrint('界面异常：${details.exception}');
      };
      runApp(InkFetchApp(controller: AppController()));
    },
    (error, stack) {
      debugPrint('未捕获异常：$error');
    },
  );
}

class InkFetchApp extends StatefulWidget {
  final AppController controller;
  const InkFetchApp({super.key, required this.controller});

  @override
  State<InkFetchApp> createState() => _InkFetchAppState();
}

class _InkFetchAppState extends State<InkFetchApp> {
  late String _theme;

  @override
  void initState() {
    super.initState();
    _theme = widget.controller.settings.theme;
    widget.controller.addListener(_onControllerChanged);
    widget.controller.init();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChanged);
    super.dispose();
  }

  /// 只有主题变化时才重建 MaterialApp，避免下载进度刷新导致整棵树反复重建。
  void _onControllerChanged() {
    final next = widget.controller.settings.theme;
    if (next == _theme) return;
    _theme = next;
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final mode = switch (_theme) {
      'dark' => ThemeMode.dark,
      'light' => ThemeMode.light,
      _ => ThemeMode.system,
    };
    return MaterialApp(
      title: '墨取',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(Brightness.light),
      darkTheme: buildAppTheme(Brightness.dark),
      themeMode: mode,
      home: AppShell(controller: widget.controller),
    );
  }
}
