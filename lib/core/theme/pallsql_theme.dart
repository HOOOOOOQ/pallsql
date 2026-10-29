import 'package:flutter/material.dart';

import '../../models/service_status.dart';
import 'pallsql_colors.dart';

/// The single source of truth for PALLSQL's look and feel.
///
/// Two themes share one shape language: dark (default) and light. Accent green
/// is reserved for primary actions, active indicators and links; everything
/// else uses neutral surfaces so the UI never glares.
class PallSqlTheme {
  const PallSqlTheme._();

  static ThemeData dark() {
    const ColorScheme scheme = ColorScheme(
      brightness: Brightness.dark,
      primary: PallSqlColors.accent,
      onPrimary: PallSqlColors.onAccent,
      primaryContainer: PallSqlColors.accentMuted,
      onPrimaryContainer: PallSqlColors.accentSoft,
      secondary: PallSqlColors.info,
      onSecondary: Color(0xFF0C1A20),
      secondaryContainer: Color(0xFF1B2B31),
      onSecondaryContainer: PallSqlColors.info,
      tertiary: PallSqlColors.warning,
      onTertiary: Color(0xFF20180A),
      error: PallSqlColors.error,
      onError: Color(0xFF200F0F),
      surface: PallSqlColors.surface,
      onSurface: PallSqlColors.textPrimary,
      surfaceContainerHighest: PallSqlColors.surfaceElevated,
      onSurfaceVariant: PallSqlColors.textSecondary,
      outline: PallSqlColors.border,
      outlineVariant: Color(0xFF262F28),
      shadow: Color(0xFF000000),
      scrim: Color(0xFF000000),
      inverseSurface: Color(0xFFE4E9E4),
      onInverseSurface: Color(0xFF141815),
      inversePrimary: Color(0xFF3D6238),
    );

    final ThemeData base = ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: scheme,
      scaffoldBackgroundColor: PallSqlColors.background,
      splashFactory: InkRipple.splashFactory,
      pageTransitionsTheme: _transitions(),
    );

    return _apply(
      base,
      background: PallSqlColors.background,
      surface: PallSqlColors.surface,
      surfaceElevated: PallSqlColors.surfaceElevated,
      surfaceMuted: PallSqlColors.surfaceMuted,
      border: PallSqlColors.border,
      onAccent: PallSqlColors.onAccent,
      accent: PallSqlColors.accent,
      textPrimary: PallSqlColors.textPrimary,
      textSecondary: PallSqlColors.textSecondary,
    );
  }

  static ThemeData light() {
    const ColorScheme scheme = ColorScheme(
      brightness: Brightness.light,
      primary: PallSqlColors.lightAccent,
      onPrimary: Color(0xFFFFFFFF),
      primaryContainer: PallSqlColors.lightAccentMuted,
      onPrimaryContainer: Color(0xFF1F331C),
      secondary: Color(0xFF3B5F6B),
      onSecondary: Color(0xFFFFFFFF),
      secondaryContainer: Color(0xFFDDE7EA),
      onSecondaryContainer: Color(0xFF20333A),
      tertiary: PallSqlColors.lightWarning,
      onTertiary: Color(0xFFFFFFFF),
      error: PallSqlColors.lightError,
      onError: Color(0xFFFFFFFF),
      surface: PallSqlColors.lightSurface,
      onSurface: PallSqlColors.lightTextPrimary,
      surfaceContainerHighest: PallSqlColors.lightSurfaceElevated,
      onSurfaceVariant: PallSqlColors.lightTextSecondary,
      outline: PallSqlColors.lightBorder,
      outlineVariant: Color(0xFFDCE3D9),
      shadow: Color(0xFF000000),
      scrim: Color(0xFF000000),
      inverseSurface: Color(0xFF20261F),
      onInverseSurface: Color(0xFFF1F4EF),
      inversePrimary: PallSqlColors.accentSoft,
    );

    final ThemeData base = ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      colorScheme: scheme,
      scaffoldBackgroundColor: PallSqlColors.lightBackground,
      splashFactory: InkRipple.splashFactory,
      pageTransitionsTheme: _transitions(),
    );

    return _apply(
      base,
      background: PallSqlColors.lightBackground,
      surface: PallSqlColors.lightSurface,
      surfaceElevated: PallSqlColors.lightSurfaceElevated,
      surfaceMuted: PallSqlColors.lightSurfaceMuted,
      border: PallSqlColors.lightBorder,
      onAccent: Colors.white,
      accent: PallSqlColors.lightAccent,
      textPrimary: PallSqlColors.lightTextPrimary,
      textSecondary: PallSqlColors.lightTextSecondary,
    );
  }

  /// Short, quiet page transitions (no long zoom or slide animations).
  static PageTransitionsTheme _transitions() {
    return const PageTransitionsTheme(
      builders: <TargetPlatform, PageTransitionsBuilder>{
        TargetPlatform.android: FadeUpwardsPageTransitionsBuilder(),
        TargetPlatform.iOS: FadeUpwardsPageTransitionsBuilder(),
        TargetPlatform.linux: FadeUpwardsPageTransitionsBuilder(),
        TargetPlatform.macOS: FadeUpwardsPageTransitionsBuilder(),
        TargetPlatform.windows: FadeUpwardsPageTransitionsBuilder(),
      },
    );
  }

  static ThemeData _apply(
    ThemeData base, {
    required Color background,
    required Color surface,
    required Color surfaceElevated,
    required Color surfaceMuted,
    required Color border,
    required Color onAccent,
    required Color accent,
    required Color textPrimary,
    required Color textSecondary,
  }) {
    final BorderRadius buttonRadius = BorderRadius.circular(10);
    return base.copyWith(
      textTheme: _textTheme(base.textTheme, textPrimary, textSecondary),
      appBarTheme: AppBarTheme(
        backgroundColor: background,
        foregroundColor: textPrimary,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          color: textPrimary,
          fontSize: 17,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.2,
        ),
        iconTheme: IconThemeData(color: textSecondary, size: 20),
      ),
      cardTheme: CardThemeData(
        color: surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        margin: EdgeInsets.zero,
      ),
      dividerTheme: DividerThemeData(color: border, thickness: 1, space: 1),
      iconTheme: IconThemeData(color: textSecondary, size: 20),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: surfaceElevated,
        contentTextStyle: TextStyle(color: textPrimary),
        actionTextColor: accent,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
        ),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: accent,
        linearTrackColor: surfaceMuted,
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: surfaceElevated,
          borderRadius: const BorderRadius.all(Radius.circular(6)),
          border: Border.all(color: border),
        ),
        textStyle: TextStyle(color: textPrimary, fontSize: 12),
      ),
      inputDecorationTheme: InputDecorationTheme(
        isDense: true,
        filled: true,
        fillColor: background,
        hintStyle: TextStyle(color: base.colorScheme.onSurfaceVariant),
        labelStyle: TextStyle(color: textSecondary, fontSize: 12.5),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(9),
          borderSide: BorderSide(color: border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(9),
          borderSide: BorderSide(color: border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(9),
          borderSide: BorderSide(color: accent),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: ButtonStyle(
          foregroundColor: WidgetStatePropertyAll<Color>(accent),
          overlayColor: WidgetStatePropertyAll<Color>(
            accent.withValues(alpha: 0.10),
          ),
          textStyle: const WidgetStatePropertyAll<TextStyle>(
            TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
          ),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: ButtonStyle(
          backgroundColor: WidgetStatePropertyAll<Color>(accent),
          foregroundColor: WidgetStatePropertyAll<Color>(onAccent),
          overlayColor: WidgetStatePropertyAll<Color>(
            onAccent.withValues(alpha: 0.12),
          ),
          elevation: const WidgetStatePropertyAll<double>(0),
          shape: WidgetStatePropertyAll<OutlinedBorder>(
            RoundedRectangleBorder(borderRadius: buttonRadius),
          ),
        ),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith<Color?>(
          (Set<WidgetState> states) => states.contains(WidgetState.selected)
              ? accent
              : null,
        ),
        trackColor: WidgetStateProperty.resolveWith<Color?>(
          (Set<WidgetState> states) => states.contains(WidgetState.selected)
              ? accent.withValues(alpha: 0.35)
              : null,
        ),
      ),
      sliderTheme: SliderThemeData(
        activeTrackColor: accent,
        inactiveTrackColor: surfaceMuted,
        thumbColor: accent,
        overlayColor: accent.withValues(alpha: 0.12),
      ),
      extensions: const <ThemeExtension<dynamic>>[],
    );
  }

  static TextTheme _textTheme(
    TextTheme base,
    Color primary,
    Color secondary,
  ) {
    return base
        .apply(bodyColor: primary, displayColor: primary)
        .copyWith(
          headlineSmall:
              base.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
          titleLarge: base.titleLarge?.copyWith(fontWeight: FontWeight.w600),
          titleMedium: base.titleMedium?.copyWith(
            fontWeight: FontWeight.w600,
            letterSpacing: 0.1,
          ),
          bodyMedium: base.bodyMedium?.copyWith(height: 1.4),
          bodySmall: base.bodySmall?.copyWith(color: secondary),
          labelLarge: base.labelLarge?.copyWith(fontWeight: FontWeight.w600),
        );
  }

  /// Colour associated with a runtime service state.
  static Color stateColor(ServiceState state) {
    switch (state) {
      case ServiceState.running:
        return PallSqlColors.success;
      case ServiceState.starting:
      case ServiceState.stopping:
        return PallSqlColors.warning;
      case ServiceState.error:
        return PallSqlColors.error;
      case ServiceState.stopped:
        return PallSqlColors.stopped;
      case ServiceState.unavailable:
        return PallSqlColors.textDisabled;
    }
  }
}
