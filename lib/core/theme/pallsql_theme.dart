import 'package:flutter/material.dart';

import '../../models/service_status.dart';
import 'pallsql_colors.dart';

/// The single source of truth for PALLSQL's look and feel.
class PallSqlTheme {
  const PallSqlTheme._();

  static ThemeData dark() {
    const ColorScheme scheme = ColorScheme(
      brightness: Brightness.dark,
      primary: PallSqlColors.accent,
      onPrimary: Color(0xFF07130A),
      primaryContainer: PallSqlColors.accentMuted,
      onPrimaryContainer: PallSqlColors.accent,
      secondary: PallSqlColors.info,
      onSecondary: Color(0xFF04131B),
      secondaryContainer: Color(0xFF12232C),
      onSecondaryContainer: PallSqlColors.info,
      tertiary: PallSqlColors.warning,
      onTertiary: Color(0xFF1D1203),
      error: PallSqlColors.error,
      onError: Color(0xFF1B0505),
      surface: PallSqlColors.surface,
      onSurface: PallSqlColors.textPrimary,
      surfaceContainerHighest: PallSqlColors.surfaceElevated,
      onSurfaceVariant: PallSqlColors.textSecondary,
      outline: PallSqlColors.border,
      outlineVariant: Color(0xFF1B2620),
      shadow: Color(0xFF000000),
      scrim: Color(0xFF000000),
      inverseSurface: Color(0xFFE7EFE9),
      onInverseSurface: Color(0xFF0B100D),
      inversePrimary: Color(0xFF2F5A12),
    );

    final ThemeData base = ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: PallSqlColors.background,
      splashFactory: InkRipple.splashFactory,
    );

    return base.copyWith(
      textTheme: _textTheme(base.textTheme),
      appBarTheme: const AppBarTheme(
        backgroundColor: PallSqlColors.background,
        foregroundColor: PallSqlColors.textPrimary,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          color: PallSqlColors.textPrimary,
          fontSize: 17,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.2,
        ),
      ),
      cardTheme: const CardThemeData(
        color: PallSqlColors.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        margin: EdgeInsets.zero,
      ),
      dividerTheme: const DividerThemeData(
        color: PallSqlColors.border,
        thickness: 1,
        space: 1,
      ),
      iconTheme:
          const IconThemeData(color: PallSqlColors.textSecondary, size: 20),
      snackBarTheme: const SnackBarThemeData(
        backgroundColor: PallSqlColors.surfaceElevated,
        contentTextStyle: TextStyle(color: PallSqlColors.textPrimary),
        behavior: SnackBarBehavior.floating,
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(
        color: PallSqlColors.accent,
        linearTrackColor: PallSqlColors.surfaceMuted,
      ),
      tooltipTheme: const TooltipThemeData(
        decoration: BoxDecoration(
          color: PallSqlColors.surfaceElevated,
          borderRadius: BorderRadius.all(Radius.circular(6)),
        ),
        textStyle: TextStyle(color: PallSqlColors.textPrimary, fontSize: 12),
      ),
      extensions: const <ThemeExtension<dynamic>>[],
    );
  }

  static TextTheme _textTheme(TextTheme base) {
    return base.copyWith(
      headlineSmall: base.headlineSmall?.copyWith(
        fontWeight: FontWeight.w700,
        letterSpacing: -0.4,
      ),
      titleLarge: base.titleLarge?.copyWith(fontWeight: FontWeight.w600),
      titleMedium: base.titleMedium?.copyWith(
        fontWeight: FontWeight.w600,
        letterSpacing: 0.1,
      ),
      bodyMedium: base.bodyMedium?.copyWith(height: 1.35),
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
