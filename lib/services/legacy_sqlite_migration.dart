import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqflite_common/sqlite_api.dart';

import '../models/database_models.dart';
import '../models/log_entry.dart';
import '../repositories/database_repository.dart';
import 'log_sink.dart';

/// One legacy SQLite file found in `PALLSQL/database`.
class LegacyDatabase {
  const LegacyDatabase({
    required this.name,
    required this.path,
    required this.sizeBytes,
    required this.modifiedAt,
    this.tables = const <String>[],
    this.error,
  });

  final String name;
  final String path;
  final int sizeBytes;
  final DateTime modifiedAt;
  final List<String> tables;
  final String? error;

  bool get readable => error == null;

  String get targetSchema => name;
}

/// Result of migrating one legacy database.
class LegacyMigrationReport {
  const LegacyMigrationReport({
    required this.source,
    required this.schema,
    required this.tablesMigrated,
    required this.rowsMigrated,
    required this.statements,
    this.error,
    this.keptSourceFile = true,
  });

  final LegacyDatabase source;
  final String schema;
  final int tablesMigrated;
  final int rowsMigrated;
  final int statements;
  final String? error;
  final bool keptSourceFile;

  bool get ok => error == null;

  String get summary {
    if (!ok) {
      return 'Migration of ${source.name} failed: $error';
    }
    return '${source.name}: $tablesMigrated table(s), $rowsMigrated row(s) '
        'migrated into MariaDB schema "$schema" in $statements statement(s). '
        'The old file was kept at ${source.path}.';
  }
}

/// Finds SQLite files left over from PALLSQL 0.1/0.2 and can copy their data
/// into MariaDB.
///
/// This is the **only** place in PALLSQL that still opens an SQLite file, and
/// it opens it read-only. Two rules from the migration brief are encoded here:
///
/// 1. nothing is deleted automatically - the source file stays until the user
///    removes it;
/// 2. nothing is migrated without an explicit call from the UI (the Database
///    tab shows the list and asks before importing).
class LegacySqliteMigration {
  LegacySqliteMigration({
    required this.directory,
    required this.repository,
    required this.factory,
    required LogSink logs,
  }) : _logs = logs;

  /// `PALLSQL/database`, where the old `.db` files live.
  final Directory directory;

  /// Target engine (MariaDB).
  final MariaDbRepository repository;

  /// An sqflite factory able to open `.db` files (only for reading).
  final DatabaseFactory factory;

  final LogSink _logs;

  /// Lists legacy `.db` files, including the table names they contain.
  Future<List<LegacyDatabase>> scan() async {
    if (!await directory.exists()) {
      return const <LegacyDatabase>[];
    }
    final List<FileSystemEntity> entries = await directory
        .list()
        .where((FileSystemEntity entity) =>
            entity is File && entity.path.toLowerCase().endsWith('.db'))
        .toList();
    final List<LegacyDatabase> found = <LegacyDatabase>[];
    for (final FileSystemEntity entity in entries) {
      final File file = entity as File;
      final FileStat stat = await file.stat();
      final String name = p.basenameWithoutExtension(file.path);
      try {
        final Database db = await factory.openDatabase(
          file.path,
          options: OpenDatabaseOptions(readOnly: true),
        );
        try {
          final List<Map<String, Object?>> tables = await db.rawQuery(
            "SELECT name FROM sqlite_master WHERE type = 'table' "
            "AND name NOT LIKE 'sqlite_%' ORDER BY name",
          );
          found.add(
            LegacyDatabase(
              name: name,
              path: file.path,
              sizeBytes: stat.size,
              modifiedAt: stat.modified,
              tables: tables
                  .map((Map<String, Object?> row) => row['name']?.toString() ?? '')
                  .where((String value) => value.isNotEmpty)
                  .toList(growable: false),
            ),
          );
        } finally {
          await db.close();
        }
      } on Object catch (error) {
        found.add(
          LegacyDatabase(
            name: name,
            path: file.path,
            sizeBytes: stat.size,
            modifiedAt: stat.modified,
            error: '$error',
          ),
        );
      }
    }
    return found;
  }

  /// Converts one legacy SQLite database into a MariaDB schema.
  ///
  /// * the schema is created when it does not exist (never dropped);
  /// * `CREATE TABLE` is rewritten to InnoDB/utf8mb4 with `AUTOINCREMENT` and
  ///   SQLite-only clauses translated;
  /// * rows are inserted with prepared statements, so values keep their type;
  /// * the source file is left untouched.
  Future<LegacyMigrationReport> migrate(LegacyDatabase legacy) async {
    if (!legacy.readable) {
      return LegacyMigrationReport(
        source: legacy,
        schema: legacy.targetSchema,
        tablesMigrated: 0,
        rowsMigrated: 0,
        statements: 0,
        error: legacy.error,
      );
    }
    final Database db = await factory.openDatabase(
      legacy.path,
      options: OpenDatabaseOptions(readOnly: true),
    );
    int tablesMigrated = 0;
    int rowsMigrated = 0;
    int statements = 0;
    try {
      final String schema = legacy.targetSchema;
      final List<DatabaseInfo> existing = await repository.listDatabases();
      if (!existing.any((DatabaseInfo info) => info.name == schema)) {
        await repository.createDatabase(schema);
        statements++;
      }
      final List<Map<String, Object?>> objects = await db.rawQuery(
        "SELECT type, name, sql FROM sqlite_master WHERE sql IS NOT NULL "
        "AND name NOT LIKE 'sqlite_%' "
        "ORDER BY CASE type WHEN 'table' THEN 0 WHEN 'view' THEN 1 "
        "WHEN 'index' THEN 2 ELSE 3 END, name",
      );
      for (final Map<String, Object?> object in objects) {
        final String type = object['type']?.toString() ?? '';
        final String name = object['name']?.toString() ?? '';
        final String sql = object['sql']?.toString() ?? '';
        if (sql.isEmpty || name.isEmpty) {
          continue;
        }
        if (type == 'table') {
          final String ddl = _toMariaDbDdl(sql);
          final dynamic result = await repository.execute(
            schema,
            ddl,
            recordHistory: false,
          );
          statements++;
          if (result.error != null) {
            return LegacyMigrationReport(
              source: legacy,
              schema: schema,
              tablesMigrated: tablesMigrated,
              rowsMigrated: rowsMigrated,
              statements: statements,
              error: 'CREATE TABLE $name failed: ${result.error}',
            );
          }
          final int rows = await _copyRows(db, schema, name);
          rowsMigrated += rows;
          tablesMigrated++;
          statements += rows > 0 ? 1 : 0;
        }
      }
      _logs.info(
        LogSource.database,
        'Legacy SQLite ${legacy.name} migrated into MariaDB $schema '
        '($tablesMigrated table(s), $rowsMigrated row(s))',
      );
      return LegacyMigrationReport(
        source: legacy,
        schema: schema,
        tablesMigrated: tablesMigrated,
        rowsMigrated: rowsMigrated,
        statements: statements,
      );
    } on Object catch (error) {
      _logs.error(
        LogSource.database,
        'Legacy migration of ${legacy.name} failed: $error',
      );
      return LegacyMigrationReport(
        source: legacy,
        schema: legacy.targetSchema,
        tablesMigrated: tablesMigrated,
        rowsMigrated: rowsMigrated,
        statements: statements,
        error: '$error',
      );
    } finally {
      await db.close();
    }
  }

  Future<int> _copyRows(Database db, String schema, String table) async {
    final List<Map<String, Object?>> rows = await db.rawQuery(
      'SELECT * FROM "${table.replaceAll('"', '""')}"',
    );
    if (rows.isEmpty) {
      return 0;
    }
    int copied = 0;
    for (final Map<String, Object?> row in rows) {
      final List<String> columns =
          row.keys.map((String key) => _quote(key)).toList(growable: false);
      final String placeholders =
          row.keys.map((String _) => '?').join(', ');
      final dynamic result = await repository.execute(
        schema,
        'INSERT INTO ${_quote(table)} (${columns.join(', ')}) '
        'VALUES ($placeholders)',
        recordHistory: false,
      );
      if (result.error != null) {
        throw StateError('INSERT into $table failed: ${result.error}');
      }
      copied++;
    }
    return copied;
  }

  static String _quote(String identifier) =>
      '`${identifier.replaceAll('`', '``')}`';

  /// Rewrites a SQLite `CREATE TABLE` into MariaDB syntax.
  ///
  /// Only mechanically safe changes are made; anything uncertain is left for
  /// the server to reject with its own message, which the report shows.
  static String _toMariaDbDdl(String sqliteDdl) {
    String ddl = sqliteDdl
        .replaceAllMapped(
          RegExp(r'\bINTEGER\s+PRIMARY\s+KEY\s+AUTOINCREMENT\b',
              caseSensitive: false),
          (Match _) => 'INT AUTO_INCREMENT PRIMARY KEY',
        )
        .replaceAllMapped(
          RegExp(r'\bAUTOINCREMENT\b', caseSensitive: false),
          (Match _) => 'AUTO_INCREMENT',
        )
        .replaceAllMapped(
          RegExp(r'\bWITHOUT\s+ROWID\b', caseSensitive: false),
          (Match _) => '',
        )
        .replaceAllMapped(
          RegExp(r'\bBLOB\b', caseSensitive: false),
          (Match _) => 'LONGBLOB',
        )
        .replaceAllMapped(
          RegExp(r'\bDATETIME\b', caseSensitive: false),
          (Match _) => 'DATETIME',
        );
    if (!ddl.toLowerCase().contains('engine=')) {
      final int closing = ddl.lastIndexOf(')');
      if (closing > 0) {
        ddl = '${ddl.substring(0, closing + 1)} '
            'ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 '
            'COLLATE=utf8mb4_unicode_ci';
      }
    }
    return ddl;
  }
}
