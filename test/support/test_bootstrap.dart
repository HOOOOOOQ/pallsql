import 'dart:io';

import 'package:pallsql/services/app_bootstrap.dart';
import 'package:pallsql/services/native_bridge.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Creates a real bootstrap against a temporary workspace with an FFI SQLite
/// factory, so tests exercise the same services the app uses on Android.
Future<AppBootstrap> createTestBootstrap({Directory? workspaceRoot}) async {
  sqfliteFfiInit();
  final Directory root =
      workspaceRoot ?? await Directory.systemTemp.createTemp('pallsql_test_');
  return AppBootstrap.create(
    databaseFactory: databaseFactoryFfi,
    workspaceRoot: root,
    native: NativeBridge.unavailable(),
    startServerIfConfigured: false,
  );
}

/// Closes services and removes the workspace directory.
Future<void> disposeTestBootstrap(AppBootstrap bootstrap) async {
  final Directory root = bootstrap.workspace.root;
  await bootstrap.dispose();
  try {
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  } on FileSystemException {
    // Temporary directories are best effort.
  }
}
