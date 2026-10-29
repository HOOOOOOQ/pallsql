import 'dart:io';

import '../models/database_models.dart';

/// Everything the UI is allowed to ask a database backend.
///
/// PALLSQL's only implementation is [MariaDbRepository]: every method below
/// ends up as SQL on a real MariaDB server through the MariaDB wire protocol.
/// The interface exists so widgets stay testable, **not** so SQLite can be
/// plugged in again - the migration removed that engine from the app.
abstract class DatabaseRepository {
  /// Engine identity and version reported by the server itself.
  Future<EngineAvailability> availability();

  /// Schemas that exist on the server (`SHOW DATABASES`).
  Future<List<DatabaseInfo>> listDatabases();

  Future<DatabaseInfo> createDatabase(String name);

  /// Drops a schema. Callers must confirm with the user first.
  Future<void> deleteDatabase(String name);

  Future<List<TableInfo>> listTables(String database);

  Future<List<ColumnInfo>> describeTable(String database, String table);

  /// Runs one or more statements.
  ///
  /// [cancel] stops a long statement through `KILL QUERY` on a second
  /// connection, which is a real server side cancellation, not a client side
  /// flag.
  Future<QueryResult> execute(
    String database,
    String sql, {
    bool allowDestructive = true,
    bool recordHistory = true,
    SqlCancelToken? cancel,
  });

  /// Runs a script inside a transaction (used by SQL import).
  Future<QueryResult> runScript(String database, String sql);

  Future<QueryResult> selectRows(
    String database,
    String table, {
    int limit = 100,
    int offset = 0,
  });

  Future<QueryResult> insertRow(
    String database,
    String table,
    Map<String, Object?> values, {
    bool allowDestructive = true,
  });

  Future<QueryResult> updateRow(
    String database,
    String table,
    Map<String, Object?> values, {
    required String keyColumn,
    required Object? keyValue,
    bool allowDestructive = true,
  });

  Future<QueryResult> deleteRow(
    String database,
    String table, {
    required String keyColumn,
    required Object? keyValue,
    bool allowDestructive = true,
  });

  /// SQL dump (schema + data) produced from the live server.
  Future<String> exportSql(String database, {int maxRowsPerTable = 20000});

  /// Consistent snapshot written into [targetDirectory].
  Future<File> backupDatabase(String database, Directory targetDirectory);

  /// Restores a dump produced by [backupDatabase] or [exportSql].
  Future<void> restoreDatabase(File source, String database);

  List<QueryHistoryEntry> get history;

  Future<void> loadHistory();

  Future<void> clearHistory();

  /// Server level statistics for the dashboard.
  Future<Map<String, Object?>> describeStatistics(String database);

  Future<void> dispose();
}
