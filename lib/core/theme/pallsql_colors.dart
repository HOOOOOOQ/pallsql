import 'package:flutter/material.dart';

/// PALLSQL palette.
///
/// The 0.2 palette is deliberately calm: deep neutral green-grey surfaces with a
/// single soft green accent. Neon green is *not* used for borders, body text or
/// whole buttons, so long editing sessions stay comfortable.
class PallSqlColors {
  const PallSqlColors._();

  // Dark theme surfaces.
  static const Color background = Color(0xFF101311);
  static const Color surface = Color(0xFF181D19);
  static const Color surfaceElevated = Color(0xFF202721);
  static const Color surfaceMuted = Color(0xFF232B25);
  static const Color border = Color(0xFF303A32);

  // Accent green (soft, not neon).
  static const Color accent = Color(0xFF9BCB91);
  static const Color accentSoft = Color(0xFFB6D8A8);
  static const Color accentMuted = Color(0xFF232E20);
  static const Color accentDeep = Color(0xFF6F9E68);

  // Text.
  static const Color textPrimary = Color(0xFFE4E9E4);
  static const Color textSecondary = Color(0xFFA0AAA1);
  static const Color textDisabled = Color(0xFF6C766E);

  // Semantic colours.
  static const Color success = Color(0xFF8FCB97);
  static const Color warning = Color(0xFFD6B477);
  static const Color error = Color(0xFFD77C7C);
  static const Color info = Color(0xFF8FB8CC);
  static const Color stopped = Color(0xFF8A938B);

  /// Ink used on top of an accent-filled surface.
  static const Color onAccent = Color(0xFF101713);

  // Light theme surfaces (optional theme).
  static const Color lightBackground = Color(0xFFF4F6F2);
  static const Color lightSurface = Color(0xFFFFFFFF);
  static const Color lightSurfaceElevated = Color(0xFFECF0EA);
  static const Color lightSurfaceMuted = Color(0xFFE3E8E0);
  static const Color lightBorder = Color(0xFFC7D0C3);
  static const Color lightAccent = Color(0xFF4E7A4A);
  static const Color lightAccentMuted = Color(0xFFDDEBD7);
  static const Color lightTextPrimary = Color(0xFF18201A);
  static const Color lightTextSecondary = Color(0xFF4F5B50);
  static const Color lightTextDisabled = Color(0xFF8B968C);
  static const Color lightError = Color(0xFFA4453F);
  static const Color lightWarning = Color(0xFF8A6A25);
  static const Color lightSuccess = Color(0xFF3D6F45);

  /// Monospace stack used by the editor, terminal and query results.
  static const String monoFontFamily = 'monospace';
}
