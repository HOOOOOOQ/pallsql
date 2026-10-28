import 'dart:io';

import 'package:pallsql/services/app_bootstrap.dart';
import 'package:pallsql/services/native_bridge.dart';
import 'package:sqflite_common/utils/utils.dart' show lockWarningDuration;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// sqflite arms a 10 second "database locked" warning timer around every
/// operation. `flutter_test` runs on a fake clock, so a timer armed by work
/// still in flight when a test ends stays pending and trips the
/// "A Timer is still pending" invariant. The warning is only diagnostic, so it
/// is turned off for tests.
void disableSqfliteLockWarning() {
  // ignore: deprecated_member_use
  lockWarningDuration = null;
}

/// Creates a real bootstrap against a temporary workspace with an FFI SQLite
/// factory, so tests exercise the same services the app uses on Android.
Future<AppBootstrap> createTestBootstrap({Directory? workspaceRoot}) async {
  disableSqfliteLockWarning();
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
