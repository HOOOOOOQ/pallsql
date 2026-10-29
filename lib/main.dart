import 'package:flutter/material.dart';
import 'package:sqflite/sqflite.dart' as sqflite;

import 'features/startup/startup_gate.dart';
import 'services/app_bootstrap.dart';

/// Entry point.
///
/// `runApp` happens immediately: the Android launch window hands over to the in
/// app loading screen, which builds the workspace, PHP probe, SQLite engine and
/// web server before the dashboard appears. A failure (or a timeout) shows a
/// readable error with Retry instead of an endless spinner.
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    StartupGate(
      createBootstrap: (void Function(String step) onProgress) =>
          AppBootstrap.create(
        databaseFactory: sqflite.databaseFactory,
        onProgress: onProgress,
      ),
    ),
  );
}
