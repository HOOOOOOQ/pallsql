import 'dart:io';

import 'package:pallsql/services/app_bootstrap.dart';
import 'package:pallsql/services/mariadb/mariadb_config.dart';
import 'package:pallsql/services/native_bridge.dart';
import 'package:sqflite_common/utils/utils.dart' show lockWarningDuration;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// sqflite arms a 10 second "database locked" warning timer around every
/// operation. It is only used now for the legacy migration reader, but a
/// pending timer would still trip the widget test invariant.
void disableSqfliteLockWarning() {
  // ignore: deprecated_member_use
  lockWarningDuration = null;
}

/// True when the environment provides a live MariaDB server.
///
/// CI starts a real `mariadb-server` and exports these variables; a developer
/// machine can do the same. Widget tests that need the database are skipped -
/// never faked - when no server is available.
bool get hasLiveMariaDb => Platform.environment['PALLSQL_MARIADB_IT'] == '1';

MariaDbConfig _testConfig(String user) => MariaDbConfig(
      host: Platform.environment['PALLSQL_MARIADB_HOST'] ?? '127.0.0.1',
      port: int.tryParse(Platform.environment['PALLSQL_MARIADB_PORT'] ?? '') ??
          3306,
      user: Platform.environment['PALLSQL_MARIADB_USER'] ?? 'pallsql',
      password: Platform.environment['PALLSQL_MARIADB_PASSWORD'] ?? '',
    );

/// Schema used by the tests; created and dropped by the suites themselves.
const String testMariaDbSchema = 'pallsql_widget_test';

/// Creates a real bootstrap against a temporary workspace.
///
/// The database engine is MariaDB over TCP, exactly like on the phone. The
/// native server manager is replaced by [NativeBridge.unavailable], which
/// reports "not installed" - the tests never pretend a process was started.
Future<AppBootstrap> createTestBootstrap({Directory? workspaceRoot}) async {
  disableSqfliteLockWarning();
  sqfliteFfiInit();
  final Directory root =
      workspaceRoot ?? await Directory.systemTemp.createTemp('pallsql_test_');
  return AppBootstrap.create(
    workspaceRoot: root,
    native: NativeBridge.unavailable(),
    startServerIfConfigured: false,
    // The server is started by the test harness, not by the app.
    startDatabaseIfConfigured: false,
    mariaDbConfig: _testConfig(
      Platform.environment['PALLSQL_MARIADB_USER'] ?? 'pallsql',
    ),
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

/// Creates the shared test schema on the server (idempotent).
Future<void> prepareTestSchema(AppBootstrap bootstrap) async {
  final dynamic existing = await bootstrap.databases.listDatabases();
  final bool present = (existing as List<dynamic>)
      .any((dynamic info) => info.name == testMariaDbSchema);
  if (!present) {
    await bootstrap.databases.createDatabase(testMariaDbSchema);
  }
}

/// Drops the shared test schema so every suite starts clean.
Future<void> dropTestSchema(AppBootstrap bootstrap) async {
  try {
    await bootstrap.databases.deleteDatabase(testMariaDbSchema);
  } on Object {
    // Nothing to drop the first time.
  }
}
