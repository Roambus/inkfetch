import 'package:flutter/material.dart';

/// ─────────────────────────────────────────────────────────────
/// 墨取的设计基调：宣纸 + 墨。
///
/// 只用一种字音：系统无衬线（中文走系统黑体，拉丁走系统 UI 字体），
/// 靠字重与字号建立层次，而不是靠换字体。
///
/// 之前试过「标题用宋体、正文用黑体」，结果同一个界面上两种中文字体
/// 混排，按钮与标题风格割裂，看起来又乱又土。中文字体一旦换，整套
/// 界面的语气就断了，所以这里收回成单一字体：
///   - 标题：同族、更重、字距收紧
///   - 正文：同族、常规字重
///   - 数字：等宽，只为对齐，不为风格
///
/// 颜色只用两族：墨（中性，从纸白到墨黑）与一点朱砂、一点松烟绿。
/// ─────────────────────────────────────────────────────────────

/// 等宽字体，只用于需要纵向对齐的数字与路径。
const String kMono = 'Cascadia Mono';

/// 关键：等宽字体不含中日韩字形。一旦有人把中文也套上 kMono，
/// 那些字就会变成方块（「64 分片 · 4 个源」这行曾经整句是豆腐块）。
/// 所以回退链里必须放一个中文字体，让中文自动落到它上面。
const List<String> kMonoFallback = [
  'Microsoft YaHei UI',
  'Microsoft YaHei',
  'Noto Sans SC',
  'PingFang SC',
  'Segoe UI',
  'Consolas',
  'monospace',
];

/// 朱砂：只用于失败与危险，不做装饰。
const Color kCinnabar = Color(0xFFB23A2C);

/// 松烟：主要动作与「正在下载」。
const Color kPine = Color(0xFF1C5B4A);

/// 分片热力图配色：像不同成色的墨，低饱和、彼此可辨。
const List<Color> kSitePalette = [
  Color(0xFF1C5B4A),
  Color(0xFF3F6E62),
  Color(0xFF6E7F5A),
  Color(0xFF8A6A46),
  Color(0xFF5B6280),
  Color(0xFF7C5560),
];

Color siteColor(int siteIndex) =>
    kSitePalette[siteIndex.clamp(0, kSitePalette.length - 1).toInt()];


/// 数字统一走等宽 + 等宽数字，避免速度跳动时整行抖动。
TextStyle dataStyle({
  double size = 13,
  FontWeight weight = FontWeight.w600,
  Color? color,
  double letterSpacing = -0.2,
}) {
  return TextStyle(
    fontFamily: kMono,
    fontFamilyFallback: kMonoFallback,
    fontSize: size,
    fontWeight: weight,
    letterSpacing: letterSpacing,
    color: color,
    fontFeatures: const [FontFeature.tabularFigures()],
    height: 1.15,
  );
}

/// 大标题用：同族字体、更重的字重、收紧的字距。
/// 不再换字体，只用字重和字距做层次。
TextStyle displayStyle({
  double size = 30,
  FontWeight weight = FontWeight.w700,
  Color? color,
  double letterSpacing = -0.6,
  double height = 1.2,
}) {
  return TextStyle(
    fontSize: size,
    fontWeight: weight,
    letterSpacing: letterSpacing,
    color: color,
    height: height,
  );
}

/// 一套克制的明暗色板，页面统一从这里取色。
class AppPalette {
  final bool dark;
  const AppPalette({required this.dark});

  static AppPalette of(BuildContext context) =>
      AppPalette(dark: Theme.of(context).brightness == Brightness.dark);

  /// 纸：浅色是带一点青灰的宣纸，深色是墨池。
  Color get background =>
      dark ? const Color(0xFF0C0E10) : const Color(0xFFF0F1EC);
  /// 承墨的案面。
  Color get surface =>
      dark ? const Color(0xFF14171A) : const Color(0xFFFBFBF8);
  /// 凹下去的浅槽。
  Color get surfaceAlt =>
      dark ? const Color(0xFF1C2024) : const Color(0xFFE9EBE4);
  /// 发丝线。
  Color get border =>
      dark ? const Color(0xFF262B30) : const Color(0xFFD9DCD2);
  Color get borderStrong =>
      dark ? const Color(0xFF3A4046) : const Color(0xFFC2C7BB);
  /// 正文墨色。
  Color get ink => dark ? const Color(0xFFE9E6DE) : const Color(0xFF14171A);
  Color get muted =>
      dark ? const Color(0xFF9AA098) : const Color(0xFF5C6159);
  Color get faint =>
      dark ? const Color(0xFF6B7169) : const Color(0xFF92978C);
  /// 松烟绿：正在发生。
  Color get accent => dark ? const Color(0xFF74AF9B) : kPine;
  Color get positive => dark ? const Color(0xFF74AF9B) : const Color(0xFF236653);
  Color get danger => dark ? const Color(0xFFD2695A) : kCinnabar;
  Color get warning => dark ? const Color(0xFFC7A063) : const Color(0xFF8E6425);

  /// 主要按钮填充色。
  Color get primaryFill => accent;
  Color get onPrimaryFill => dark ? const Color(0xFF07120E) : const Color(0xFFF7FAF6);
}

ThemeData buildAppTheme(Brightness brightness) {
  final palette = AppPalette(dark: brightness == Brightness.dark);

  final scheme = ColorScheme(
    brightness: brightness,
    primary: palette.primaryFill,
    onPrimary: palette.onPrimaryFill,
    secondary: palette.accent,
    onSecondary: palette.onPrimaryFill,
    error: palette.danger,
    onError: Colors.white,
    surface: palette.surface,
    onSurface: palette.ink,
    surfaceContainerHighest: palette.surfaceAlt,
    outline: palette.border,
    outlineVariant: palette.border,
  );

  final base = ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: palette.background,
    splashFactory: InkSparkle.splashFactory,
    visualDensity: VisualDensity.standard,
  );

  final text = base.textTheme.apply(
    bodyColor: palette.ink,
    displayColor: palette.ink,
  );

  return base.copyWith(
    textTheme: text.copyWith(
      // 页面标题：同族字体，加粗 + 收紧字距，不再换字体。
      displaySmall: displayStyle(size: 30, color: palette.ink),
      headlineMedium: displayStyle(size: 23, color: palette.ink),
      headlineSmall: displayStyle(
        size: 19,
        weight: FontWeight.w600,
        letterSpacing: -0.2,
        color: palette.ink,
      ),
      // 文件名这类「有身份的内容」用无衬线加重。
      titleLarge: text.titleLarge?.copyWith(
        fontSize: 17,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.1,
        height: 1.35,
      ),
      titleMedium: text.titleMedium?.copyWith(
        fontSize: 13.5,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.1,
        height: 1.4,
      ),
      titleSmall: text.titleSmall?.copyWith(
        fontSize: 12.5,
        fontWeight: FontWeight.w600,
      ),
      bodyLarge: text.bodyLarge?.copyWith(fontSize: 14, height: 1.65),
      bodyMedium: text.bodyMedium?.copyWith(fontSize: 13, height: 1.65),
      bodySmall: text.bodySmall?.copyWith(fontSize: 12, height: 1.6),
      labelLarge: text.labelLarge?.copyWith(
        fontSize: 13,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.2,
      ),
      labelSmall: text.labelSmall?.copyWith(
        fontSize: 10,
        fontWeight: FontWeight.w600,
        letterSpacing: 1.1,
      ),
    ),
    canvasColor: palette.background,
    appBarTheme: const AppBarTheme(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
    ),
    // 面板：只有一个层级的容器，圆角与描边克制。
    cardTheme: CardThemeData(
      elevation: 0,
      color: palette.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: palette.border),
      ),
      margin: EdgeInsets.zero,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: Colors.transparent,
      hintStyle: TextStyle(
        fontSize: 13.5,
        color: palette.faint,
        fontWeight: FontWeight.w400,
      ),
      border: InputBorder.none,
      enabledBorder: InputBorder.none,
      focusedBorder: InputBorder.none,
      contentPadding: const EdgeInsets.symmetric(horizontal: 2, vertical: 6),
    ),
    // 主要动作：墨绿实底，不用通栏黑条。
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: palette.primaryFill,
        foregroundColor: palette.onPrimaryFill,
        minimumSize: const Size(0, 40),
        padding: const EdgeInsets.symmetric(horizontal: 22),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        textStyle: const TextStyle(
          fontSize: 13.5,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.3,
        ),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, 40),
        padding: const EdgeInsets.symmetric(horizontal: 18),
        foregroundColor: palette.ink,
        backgroundColor: palette.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        side: BorderSide(color: palette.borderStrong),
        textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: palette.muted,
        minimumSize: const Size(0, 34),
        padding: const EdgeInsets.symmetric(horizontal: 10),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
        textStyle: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w500),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        foregroundColor: palette.muted,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
      ),
    ),
    dividerTheme: DividerThemeData(
      color: palette.border,
      thickness: 1,
      space: 1,
    ),
    sliderTheme: SliderThemeData(
      trackHeight: 3,
      activeTrackColor: palette.accent,
      inactiveTrackColor: palette.surfaceAlt,
      thumbColor: palette.accent,
      showValueIndicator: ShowValueIndicator.never,
      overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
    ),
    switchTheme: SwitchThemeData(
      trackColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) {
          return palette.accent.withValues(alpha: 0.9);
        }
        return palette.surfaceAlt;
      }),
      thumbColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) {
          return palette.dark ? const Color(0xFF0C0E10) : Colors.white;
        }
        return palette.dark ? const Color(0xFF4A5158) : Colors.white;
      }),
      trackOutlineColor: WidgetStatePropertyAll(palette.border),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: palette.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      height: 58,
      indicatorColor: Colors.transparent,
      labelTextStyle: WidgetStateProperty.resolveWith((states) {
        final selected = states.contains(WidgetState.selected);
        return TextStyle(
          fontSize: 11,
          fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
          letterSpacing: 0.4,
          color: selected ? palette.ink : palette.faint,
        );
      }),
      iconTheme: WidgetStateProperty.resolveWith((states) {
        final selected = states.contains(WidgetState.selected);
        return IconThemeData(
          size: 19,
          color: selected ? palette.accent : palette.faint,
        );
      }),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: palette.dark
          ? const Color(0xFF23272C)
          : const Color(0xFF1A1D1B),
      contentTextStyle: const TextStyle(
        color: Color(0xFFEDEAE3),
        fontSize: 12.5,
      ),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      insetPadding: const EdgeInsets.all(16),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: palette.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: palette.border),
      ),
      titleTextStyle: displayStyle(
        size: 17,
        weight: FontWeight.w600,
        color: palette.ink,
        letterSpacing: -0.2,
      ),
      contentTextStyle: TextStyle(
        fontSize: 13,
        height: 1.7,
        color: palette.muted,
      ),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: palette.surface,
      surfaceTintColor: Colors.transparent,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: palette.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: palette.border),
      ),
      textStyle: TextStyle(fontSize: 12.5, color: palette.ink),
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: palette.dark ? const Color(0xFF2A2F34) : const Color(0xFF1A1D1B),
        borderRadius: BorderRadius.circular(5),
      ),
      textStyle: const TextStyle(fontSize: 11.5, color: Color(0xFFEDEAE3)),
      waitDuration: const Duration(milliseconds: 500),
    ),
  );
}

/// 纯色画布。界面不靠渐变与光晕取悦，靠排布与留白。
class AppBackground extends StatelessWidget {
  final Widget child;
  const AppBackground({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return ColoredBox(color: palette.background, child: child);
  }
}
