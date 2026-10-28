import 'package:flutter/material.dart';

/// Dark developer palette used across PALLSQL.
class PallSqlColors {
  const PallSqlColors._();

  static const Color background = Color(0xFF050706);
  static const Color surface = Color(0xFF0E1411);
  static const Color surfaceElevated = Color(0xFF151D18);
  static const Color surfaceMuted = Color(0xFF1B241E);
  static const Color border = Color(0xFF243129);

  static const Color accent = Color(0xFF9BFF3D);
  static const Color accentMuted = Color(0xFF2A3D1C);
  static const Color accentDeep = Color(0xFF66B21F);

  static const Color textPrimary = Color(0xFFF1F7F2);
  static const Color textSecondary = Color(0xFF93A197);
  static const Color textDisabled = Color(0xFF5D6A61);

  static const Color success = Color(0xFF52D97A);
  static const Color warning = Color(0xFFFFB03A);
  static const Color error = Color(0xFFFF5D5D);
  static const Color info = Color(0xFF57C8FF);
  static const Color stopped = Color(0xFF7C8A80);

  /// Monospace stack used by the editor, terminal and query results.
  static const String monoFontFamily = 'monospace';
}
