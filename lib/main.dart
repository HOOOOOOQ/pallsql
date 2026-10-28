import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sqflite/sqflite.dart' as sqflite;

import 'app.dart';
import 'core/theme/pallsql_colors.dart';
import 'core/theme/pallsql_theme.dart';
import 'providers/app_providers.dart';
import 'services/app_bootstrap.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    final AppBootstrap bootstrap = await AppBootstrap.create(
      databaseFactory: sqflite.databaseFactory,
    );
    runApp(
      ProviderScope(
        overrides: <Override>[
          bootstrapProvider.overrideWithValue(bootstrap),
        ],
        child: const PallSqlApp(),
      ),
    );
  } on Object catch (error, stackTrace) {
    debugPrint('PALLSQL startup failed: $error\n$stackTrace');
    runApp(_StartupFailureApp(error: error));
  }
}

/// Shown when the workspace could not be created (for example a storage error).
class _StartupFailureApp extends StatelessWidget {
  const _StartupFailureApp({required this.error});

  final Object error;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: PallSqlTheme.dark(),
      home: Scaffold(
        body: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                const Icon(
                  Icons.error_outline_rounded,
                  color: PallSqlColors.error,
                  size: 40,
                ),
                const SizedBox(height: 14),
                const Text(
                  'PALLSQL could not start',
                  style: TextStyle(
                    color: PallSqlColors.textPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '$error',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: PallSqlColors.textSecondary,
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  'Check that the app storage is writable, then reopen PALLSQL.',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: PallSqlColors.textDisabled,
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
