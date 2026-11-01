import 'package:flutter/material.dart';

import 'state/app_controller.dart';
import 'ui/app_shell.dart';
import 'ui/theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(OctoFetchApp(controller: AppController()));
}

class OctoFetchApp extends StatefulWidget {
  final AppController controller;
  const OctoFetchApp({super.key, required this.controller});

  @override
  State<OctoFetchApp> createState() => _OctoFetchAppState();
}

class _OctoFetchAppState extends State<OctoFetchApp> {
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
          title: 'OctoFetch',
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
