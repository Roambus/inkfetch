import 'package:flutter/material.dart';

import 'state/app_controller.dart';
import 'ui/app_shell.dart';
import 'ui/theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(InkFetchApp(controller: AppController()));
}

class InkFetchApp extends StatefulWidget {
  final AppController controller;
  const InkFetchApp({super.key, required this.controller});

  @override
  State<InkFetchApp> createState() => _InkFetchAppState();
}

class _InkFetchAppState extends State<InkFetchApp> {
  @override
  void initState() {
    super.initState();
    widget.controller.init();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final theme = widget.controller.settings.theme;
        final mode = switch (theme) {
          'dark' => ThemeMode.dark,
          'light' => ThemeMode.light,
          _ => ThemeMode.system,
        };
        return MaterialApp(
          title: 'InkFetch',
          debugShowCheckedModeBanner: false,
          theme: buildAppTheme(Brightness.light),
          darkTheme: buildAppTheme(Brightness.dark),
          themeMode: mode,
          home: AppShell(controller: widget.controller),
        );
      },
    );
  }
}
