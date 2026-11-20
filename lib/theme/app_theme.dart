import 'dart:io';

import 'package:material_ui/material_ui.dart';

import '../models/models.dart';

class AppTheme {
  static const Color expressiveSeed = Color(0xFF7C4DFF);
  static const Color statusGreen = Color(0xFF10B981);
  static const Color statusAmber = Color(0xFFF59E0B);

  static ThemeData buildTheme({
    required Brightness brightness,
    required AppThemeStyle style,
    required bool useDynamicColor,
    ColorScheme? dynamicLight,
    ColorScheme? dynamicDark,
  }) {
    final isOled = style == AppThemeStyle.oled && brightness == Brightness.dark;

    ColorScheme scheme;
    if (useDynamicColor) {
      final dynamicScheme =
          brightness == Brightness.dark ? dynamicDark : dynamicLight;
      if (dynamicScheme != null) {
        scheme = dynamicScheme;
      } else {
        scheme = ColorScheme.fromSeed(
          seedColor: expressiveSeed,
          brightness: brightness,
          dynamicSchemeVariant: DynamicSchemeVariant.expressive,
        );
      }
    } else {
      scheme = ColorScheme.fromSeed(
        seedColor: expressiveSeed,
        brightness: brightness,
        dynamicSchemeVariant: DynamicSchemeVariant.expressive,
      );
    }

    if (isOled) {
      scheme = scheme.copyWith(
        surface: const Color(0xFF000000),
        surfaceDim: const Color(0xFF000000),
        surfaceBright: const Color(0xFF1A1628),
        surfaceContainerLowest: const Color(0xFF000000),
        surfaceContainerLow: const Color(0xFF090714),
        surfaceContainer: const Color(0xFF100C1E),
        surfaceContainerHigh: const Color(0xFF17122B),
        surfaceContainerHighest: const Color(0xFF211A3D),
        outlineVariant: scheme.primary.withValues(alpha: 0.16),
      );
    }

    final textTheme = _buildExpressiveTextTheme(scheme);

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      visualDensity: (Platform.isWindows || Platform.isLinux)
          ? VisualDensity.compact
          : VisualDensity.standard,
      scaffoldBackgroundColor: scheme.surface,
      textTheme: textTheme,
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: textTheme.titleLarge,
      ),
      cardTheme: CardThemeData(
        color: scheme.surfaceContainerHigh,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(24),
          side: isOled
              ? BorderSide(color: scheme.outlineVariant, width: 1)
              : BorderSide.none,
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor:
            isOled ? const Color(0xFF070510) : scheme.surfaceContainer,
        indicatorColor: scheme.secondaryContainer,
        elevation: 0,
        height: 76,
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return textTheme.labelMedium?.copyWith(
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            color: selected ? scheme.onSurface : scheme.onSurfaceVariant,
          );
        }),
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor:
            isOled ? const Color(0xFF070510) : scheme.surfaceContainerLow,
        indicatorColor: scheme.secondaryContainer,
        selectedIconTheme: IconThemeData(color: scheme.onSecondaryContainer),
        unselectedIconTheme: IconThemeData(color: scheme.onSurfaceVariant),
        selectedLabelTextStyle: textTheme.labelLarge?.copyWith(
          fontWeight: FontWeight.w700,
          color: scheme.onSurface,
        ),
        unselectedLabelTextStyle: textTheme.labelLarge?.copyWith(
          fontWeight: FontWeight.w500,
          color: scheme.onSurfaceVariant,
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          shape: const StadiumBorder(),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
          textStyle: textTheme.labelLarge?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          shape: const StadiumBorder(),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          textStyle: textTheme.labelLarge?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          shape: const StadiumBorder(),
          textStyle: textTheme.labelLarge?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      chipTheme: ChipThemeData(
        shape: const StadiumBorder(),
        side: BorderSide(color: scheme.outlineVariant),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: scheme.surfaceContainerHigh,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(28),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
      ),
    );
  }

  static TextTheme _buildExpressiveTextTheme(ColorScheme scheme) {
    const base = TextStyle(fontFamily: 'Inter');
    return TextTheme(
      displaySmall: base.copyWith(
        fontSize: 36,
        height: 44 / 36,
        fontWeight: FontWeight.w800,
        letterSpacing: -0.75,
        color: scheme.onSurface,
      ),
      headlineMedium: base.copyWith(
        fontSize: 28,
        height: 34 / 28,
        fontWeight: FontWeight.w800,
        letterSpacing: -0.5,
        color: scheme.onSurface,
      ),
      headlineSmall: base.copyWith(
        fontSize: 24,
        height: 30 / 24,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.35,
        color: scheme.onSurface,
      ),
      titleLarge: base.copyWith(
        fontSize: 22,
        height: 28 / 22,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.25,
        color: scheme.onSurface,
      ),
      titleMedium: base.copyWith(
        fontSize: 16,
        height: 22 / 16,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.0,
        color: scheme.onSurface,
      ),
      titleSmall: base.copyWith(
        fontSize: 14,
        height: 20 / 14,
        fontWeight: FontWeight.w600,
        color: scheme.onSurface,
      ),
      bodyLarge: base.copyWith(
        fontSize: 16,
        height: 24 / 16,
        fontWeight: FontWeight.w400,
        color: scheme.onSurface,
      ),
      bodyMedium: base.copyWith(
        fontSize: 14,
        height: 20 / 14,
        fontWeight: FontWeight.w400,
        color: scheme.onSurface,
      ),
      bodySmall: base.copyWith(
        fontSize: 12,
        height: 16 / 12,
        fontWeight: FontWeight.w400,
        color: scheme.onSurfaceVariant,
      ),
      labelLarge: base.copyWith(
        fontSize: 14,
        height: 20 / 14,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.1,
      ),
      labelMedium: base.copyWith(
        fontSize: 12,
        height: 16 / 12,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.2,
      ),
      labelSmall: base.copyWith(
        fontSize: 11,
        height: 16 / 11,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.3,
      ),
    );
  }
}

extension ExpressiveTextStyleX on TextStyle {
  TextStyle get tabular => copyWith(
        fontFeatures: const [FontFeature.tabularFigures()],
      );
}

