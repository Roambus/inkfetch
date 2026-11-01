import 'package:flutter/material.dart';

const Color kAccent = Color(0xFF5B8CFF);
const Color kAccentAlt = Color(0xFF37D6C0);
const Color kWarning = Color(0xFFFFB648);
const Color kDanger = Color(0xFFFF6B81);

const List<Color> kSitePalette = [
  Color(0xFF5B8CFF),
  Color(0xFF37D6C0),
  Color(0xFFFFB648),
  Color(0xFFB388FF),
  Color(0xFFFF6B81),
  Color(0xFF4DD0E1),
  Color(0xFFA3E635),
  Color(0xFFF472B6),
];

Color siteColor(int siteIndex) =>
    kSitePalette[siteIndex.clamp(0, kSitePalette.length - 1).toInt()];

ThemeData buildAppTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final scheme =
      ColorScheme.fromSeed(seedColor: kAccent, brightness: brightness).copyWith(
        primary: dark ? kAccent : const Color(0xFF3355CC),
        secondary: kAccentAlt,
        error: kDanger,
        surface: dark ? const Color(0xFF0E1828) : Colors.white,
        onSurface: dark ? const Color(0xFFE7EEFA) : const Color(0xFF111B2E),
        surfaceContainerHighest: dark
            ? const Color(0xFF16233A)
            : const Color(0xFFEAF0FA),
      );

  final base = ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: Colors.transparent,
    splashFactory: InkSparkle.splashFactory,
  );

  final textTheme = base.textTheme.copyWith(
    headlineMedium: base.textTheme.headlineMedium?.copyWith(
      fontWeight: FontWeight.w700,
      letterSpacing: -0.6,
    ),
    headlineSmall: base.textTheme.headlineSmall?.copyWith(
      fontWeight: FontWeight.w700,
      letterSpacing: -0.4,
    ),
    titleLarge: base.textTheme.titleLarge?.copyWith(
      fontWeight: FontWeight.w700,
      letterSpacing: -0.3,
    ),
    titleMedium: base.textTheme.titleMedium?.copyWith(
      fontWeight: FontWeight.w600,
    ),
    bodyMedium: base.textTheme.bodyMedium?.copyWith(height: 1.5),
    labelLarge: base.textTheme.labelLarge?.copyWith(
      fontWeight: FontWeight.w600,
      letterSpacing: 0.1,
    ),
  );

  return base.copyWith(
    textTheme: textTheme,
    appBarTheme: const AppBarTheme(
      backgroundColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      color: dark ? const Color(0xFF101C2E) : Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(
          color: dark ? const Color(0xFF223250) : const Color(0xFFE3EAF5),
        ),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: dark ? const Color(0xFF0B1422) : const Color(0xFFF3F6FC),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(
          color: dark ? const Color(0xFF24344F) : const Color(0xFFDCE5F2),
        ),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(
          color: dark ? const Color(0xFF24344F) : const Color(0xFFDCE5F2),
        ),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: kAccent, width: 1.4),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(0, 50),
        padding: const EdgeInsets.symmetric(horizontal: 22),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        textStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, 50),
        padding: const EdgeInsets.symmetric(horizontal: 18),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        side: BorderSide(
          color: dark ? const Color(0xFF2C405F) : const Color(0xFFD5DFEF),
        ),
        textStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    ),
    dividerTheme: DividerThemeData(
      color: dark ? const Color(0xFF1D2B43) : const Color(0xFFE8EEF8),
      thickness: 1,
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: dark ? const Color(0xFF0A1220) : Colors.white,
      elevation: 0,
      height: 68,
      indicatorColor: kAccent.withValues(alpha: dark ? 0.18 : 0.12),
      labelTextStyle: WidgetStatePropertyAll(
        TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: dark ? const Color(0xFFB9C8E0) : const Color(0xFF4A5A75),
        ),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: dark ? const Color(0xFF1B2942) : const Color(0xFF1E2A44),
      contentTextStyle: const TextStyle(color: Colors.white),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
  );
}

class AppBackground extends StatelessWidget {
  final Widget child;
  const AppBackground({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: dark
              ? const [Color(0xFF070B14), Color(0xFF0B1424), Color(0xFF0A101C)]
              : const [Color(0xFFF6F9FF), Color(0xFFEDF3FE), Color(0xFFF7FAFF)],
        ),
      ),
      child: Stack(
        children: [
          Positioned(
            top: -160,
            right: -120,
            child: _Glow(
              color: kAccent.withValues(alpha: dark ? 0.22 : 0.16),
              size: 380,
            ),
          ),
          Positioned(
            bottom: 120,
            left: -160,
            child: _Glow(
              color: kAccentAlt.withValues(alpha: dark ? 0.14 : 0.12),
              size: 420,
            ),
          ),
          child,
        ],
      ),
    );
  }
}

class _Glow extends StatelessWidget {
  final Color color;
  final double size;
  const _Glow({required this.color, required this.size});

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(colors: [color, color.withValues(alpha: 0)]),
        ),
      ),
    );
  }
}
