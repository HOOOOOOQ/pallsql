import 'package:flutter/material.dart';

import 'core/constants/app_info.dart';
import 'core/theme/pallsql_theme.dart';
import 'features/shell/home_shell.dart';

/// Root widget of PALLSQL.
class PallSqlApp extends StatelessWidget {
  const PallSqlApp({super.key, this.initialTab = 0});

  final int initialTab;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: AppInfo.appName,
      debugShowCheckedModeBanner: false,
      theme: PallSqlTheme.dark(),
      darkTheme: PallSqlTheme.dark(),
      themeMode: ThemeMode.dark,
      home: HomeShell(initialIndex: initialTab),
    );
  }
}
