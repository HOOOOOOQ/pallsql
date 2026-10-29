import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pallsql/core/theme/pallsql_colors.dart';
import 'package:pallsql/core/theme/pallsql_theme.dart';
import 'package:pallsql/models/service_status.dart';

void main() {
  test('the 0.2 palette matches the design brief', () {
    expect(PallSqlColors.background, const Color(0xFF101311));
    expect(PallSqlColors.surface, const Color(0xFF181D19));
    expect(PallSqlColors.surfaceElevated, const Color(0xFF202721));
    expect(PallSqlColors.border, const Color(0xFF303A32));
    expect(PallSqlColors.textPrimary, const Color(0xFFE4E9E4));
    expect(PallSqlColors.textSecondary, const Color(0xFFA0AAA1));
    expect(PallSqlColors.accent, const Color(0xFF9BCB91));
    expect(PallSqlColors.accentSoft, const Color(0xFFB6D8A8));
    expect(PallSqlColors.error, const Color(0xFFD77C7C));
    expect(PallSqlColors.warning, const Color(0xFFD6B477));
  });

  test('the accent is a soft green, not a neon green', () {
    final HSLColor accent = HSLColor.fromColor(PallSqlColors.accent);
    expect(accent.hue, inInclusiveRange(90, 150));
    expect(accent.saturation, lessThan(0.5),
        reason: 'neon green would push saturation close to 1');
    expect(accent.lightness, greaterThan(0.4));
    expect(accent.lightness, lessThan(0.85));
  });

  test('body text has comfortable contrast on the background', () {
    final double text = PallSqlColors.textPrimary.computeLuminance();
    final double background = PallSqlColors.background.computeLuminance();
    expect(text, greaterThan(0.6));
    expect(background, lessThan(0.1));
    final double contrast = (text + 0.05) / (background + 0.05);
    expect(contrast, greaterThan(7.0));
  });

  test('both themes build and stay Material 3', () {
    final ThemeData dark = PallSqlTheme.dark();
    expect(dark.useMaterial3, isTrue);
    expect(dark.colorScheme.brightness, Brightness.dark);
    expect(dark.scaffoldBackgroundColor, PallSqlColors.background);
    expect(dark.colorScheme.primary, PallSqlColors.accent);
    expect(dark.colorScheme.onPrimary, PallSqlColors.onAccent);

    final ThemeData light = PallSqlTheme.light();
    expect(light.useMaterial3, isTrue);
    expect(light.colorScheme.brightness, Brightness.light);
    expect(light.scaffoldBackgroundColor, PallSqlColors.lightBackground);
    expect(light.colorScheme.onSurface.computeLuminance(), lessThan(0.2));
  });

  test('state colours are driven by the real service state', () {
    expect(PallSqlTheme.stateColor(ServiceState.running),
        PallSqlColors.success);
    expect(PallSqlTheme.stateColor(ServiceState.error), PallSqlColors.error);
    expect(PallSqlTheme.stateColor(ServiceState.starting),
        PallSqlColors.warning);
    expect(PallSqlTheme.stateColor(ServiceState.unavailable),
        PallSqlColors.textDisabled);
  });
}
