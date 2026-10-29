import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/constants/app_info.dart';
import 'core/theme/pallsql_theme.dart';
import 'features/shell/home_shell.dart';
import 'models/app_settings.dart';
import 'providers/app_providers.dart';

/// Root widget of PALLSQL.
///
/// It only needs the bootstrap to exist (see `lib/features/startup`); theme mode
/// and text size come from the persisted settings so a change in Settings is
/// visible immediately without restarting the app.
class PallSqlApp extends ConsumerWidget {
  const PallSqlApp({super.key, this.initialTab = 0});

  final int initialTab;

  static ThemeMode themeModeFor(AppThemeMode mode) {
    switch (mode) {
      case AppThemeMode.dark:
        return ThemeMode.dark;
      case AppThemeMode.light:
        return ThemeMode.light;
      case AppThemeMode.system:
        return ThemeMode.system;
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppSettings settings = ref.watch(settingsProvider);
    return MaterialApp(
      title: AppInfo.appName,
      debugShowCheckedModeBanner: false,
      theme: PallSqlTheme.light(),
      darkTheme: PallSqlTheme.dark(),
      themeMode: themeModeFor(settings.themeMode),
      builder: (BuildContext context, Widget? child) {
        final MediaQueryData media = MediaQuery.of(context);
        return MediaQuery(
          data: media.copyWith(
            textScaler: TextScaler.linear(settings.uiTextScale),
          ),
          child: child ?? const SizedBox.shrink(),
        );
      },
      home: HomeShell(initialIndex: initialTab),
    );
  }
}
