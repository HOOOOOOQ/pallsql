import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:sqflite_common/sqlite_api.dart';

import '../core/errors/app_failure.dart';
import '../core/utils/sql_utils.dart';
import '../core/utils/validators.dart';
import '../models/database_models.dart';
import '../models/log_entry.dart';
import '../services/database_engine.dart';
import '../services/log_sink.dart';
import '../services/sql_compatibility.dart';

/// SQLite implementation of [DatabaseEngine].
///
/// Every database is a real SQLite file inside `PALLSQL/database`. The
/// repository is engine agnostic in its public surface: on Android it is built
/// with `databaseFactory` (sqflite) and in tests with `databaseFactoryFfi`.
class SqliteDatabaseRepository implements DatabaseEngine {
  SqliteDatabaseRepository({
    required this.directory,
    required DatabaseFactory factory,
    required LogSink logs,
    this.historyFile,
    DateTime Function()? clock,
    this.maxHistory = 50,
  })  : _factory = factory,
        _logs = logs,
        _clock = clock ?? DateTime.now;

  final Directory directory;
  final DatabaseFactory _factory;
  final LogSink _logs;
  final File? historyFile;
  final DateTime Function() _clock;
  final int maxHistory;

  final Map<String, Database> _open = <String, Database>{};
  final Map<String, String> _versions = <String, String>{};
  final List<QueryHistoryEntry> _history = <QueryHistoryEntry>[];
  bool _disposed = false;

  @override
  DatabaseEngineId get id => DatabaseEngineId.sqlite;

  List<QueryHistoryEntry> get history =>
      List<QueryHistoryEntry>.unmodifiable(_history);

  @override
  Future<EngineAvailability> availability() async {
    try {
      final Database probe = await _factory.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(readOnly: false),
      );
      final List<Map<String, Object?>> rows =
          await probe.rawQuery('SELECT sqlite_version() AS version');
      await probe.close();
      final Object? version = rows.isEmpty ? null : rows.first['version'];
      return EngineAvailability(
        engine: DatabaseEngineId.sqlite,
        available: true,
        version: version?.toString(),
      );
    } on Object catch (error) {
      return EngineAvailability.unavailable(
        DatabaseEngineId.sqlite,
        'SQLite engine could not be opened: $error',
      );
    }
  }

  String _pathFor(String name) {
    if (!Validators.isValidDatabaseName(name)) {
      throw ValidationFailure(
        Validators.databaseNameError(name) ?? 'Invalid database name',
      );
    }
    return p.join(directory.path, '$name.db');
  }

  Future<void> _ensureDirectory() async {
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }
  }

  Future<Database> _openDatabase(String name) async {
    final Database? cached = _open[name];
    if (cached != null && cached.isOpen) {
      return cached;
    }
    final String path = _pathFor(name);
    await _ensureDirectory();
    final Database db = await _factory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 1,
        onConfigure: (Database db) async {
          await db.rawQuery('PRAGMA foreign_keys = ON');
        },
      ),
    );
    _open[name] = db;
    return db;
  }

  Future<Database> _existingDatabase(String name) async {
    final String path = _pathFor(name);
    if (!await File(path).exists()) {
      throw NotFoundFailure('Database $name does not exist');
    }
    return _openDatabase(name);
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    await closeAll();
  }

  Future<void> closeAll() async {
    for (final Database db in _open.values.toList(growable: false)) {
      try {
        await db.close();
      } on Object {
        // Closing twice is harmless.
      }
    }
    _open.clear();
  }

  Future<void> closeDatabase(String name) async {
    final Database? db = _open.remove(name);
    if (db != null) {
      try {
        await db.close();
      } on Object {
        // Ignore.
      }
    }
  }

  Future<List<DatabaseInfo>> listDatabases() async {
    await _ensureDirectory();
    final List<DatabaseInfo> databases = <DatabaseInfo>[];
    try {
      await for (final FileSystemEntity entity
          in directory.list(followLinks: false)) {
        if (entity is! File) {
          continue;
        }
        final String name = p.basenameWithoutExtension(entity.path);
        if (p.extension(entity.path).toLowerCase() != '.db') {
          continue;
        }
        if (!Validators.isValidDatabaseName(name)) {
          continue;
        }
        final FileStat stat = await entity.stat();
        int? tableCount;
        final Database? opened = _open[name];
        if (opened != null && opened.isOpen) {
          try {
            final List<Map<String, Object?>> rows = await opened.rawQuery(
              "SELECT COUNT(*) AS c FROM sqlite_master WHERE type = 'table' "
              "AND name NOT LIKE 'sqlite_%'",
            );
            tableCount = (rows.first['c'] as num?)?.toInt();
          } on Object {
            tableCount = null;
          }
        }
        databases.add(
          DatabaseInfo(
            name: name,
            path: entity.path,
            sizeBytes: stat.size,
            modifiedAt: stat.modified,
            tableCount: tableCount,
          ),
        );
      }
    } on FileSystemException catch (error) {
      throw AppFailure('Could not list databases', details: error.message);
    }
    databases
        .sort((DatabaseInfo a, DatabaseInfo b) => a.name.compareTo(b.name));
    return databases;
  }

  Future<DatabaseInfo> createDatabase(String name) async {
    final String? error = Validators.databaseNameError(name);
    if (error != null) {
      throw ValidationFailure(error);
    }
    await _ensureDirectory();
    final String path = _pathFor(name);
    if (await File(path).exists()) {
      throw ValidationFailure('Database $name already exists');
    }
    final Database db = await _openDatabase(name);
    try {
      await db.rawQuery('SELECT 1');
    } finally {
      await closeDatabase(name);
    }
    final FileStat stat = await File(path).stat();
    _logs.info(LogSource.database, 'Created database $name');
    return DatabaseInfo(
      name: name,
      path: path,
      sizeBytes: stat.size,
      modifiedAt: stat.modified,
      tableCount: 0,
    );
  }

  Future<void> deleteDatabase(String name) async {
    final String path = _pathFor(name);
    await closeDatabase(name);
    final File file = File(path);
    if (!await file.exists()) {
      throw NotFoundFailure('Database $name does not exist');
    }
    await file.delete();
    for (final String suffix in <String>['-wal', '-shm', '-journal']) {
      final File sidecar = File('$path$suffix');
      if (await sidecar.exists()) {
        await sidecar.delete();
      }
    }
    _logs.warning(LogSource.database, 'Deleted database $name');
  }

  Future<List<TableInfo>> listTables(String database) async {
    final Database db = await _existingDatabase(database);
    final List<Map<String, Object?>> rows = await db.rawQuery(
      "SELECT name, type FROM sqlite_master WHERE type IN ('table', 'view') "
      "AND name NOT LIKE 'sqlite_%' ORDER BY type, name",
    );
    return rows
        .map((Map<String, Object?> row) => TableInfo(
              name: row['name']?.toString() ?? '',
              type: row['type']?.toString() ?? 'table',
            ))
        .where((TableInfo table) => table.name.isNotEmpty)
        .toList(growable: false);
  }

  Future<List<ColumnInfo>> describeTable(String database, String table) async {
    final List<TableInfo> tables = await listTables(database);
    if (!tables.any((TableInfo info) => info.name == table)) {
      throw NotFoundFailure('Table $table does not exist');
    }
    final Database db = await _existingDatabase(database);
    final List<Map<String, Object?>> rows = await db.rawQuery(
      'PRAGMA table_info(${Validators.quoteSqlIdentifier(table)})',
    );
    return rows
        .map((Map<String, Object?> row) => ColumnInfo(
              name: row['name']?.toString() ?? '',
              type: row['type']?.toString() ?? '',
              notNull: (row['notnull'] as num?)?.toInt() == 1,
              defaultValue: row['dflt_value']?.toString(),
              primaryKey: ((row['pk'] as num?)?.toInt() ?? 0) > 0,
            ))
        .toList(growable: false);
  }

  /// Executes one or more statements and returns the last result set.
  ///
  /// [allowDestructive] must be confirmed by the UI (PALLSQL asks before
  /// running DROP/TRUNCATE or a DELETE/UPDATE without WHERE).
  ///
  /// MySQL-style metadata statements (`SHOW DATABASES`, `DESCRIBE`, ...) are
  /// answered by [SqlCompatibility] from real SQLite metadata instead of being
  /// sent to SQLite, which would fail with a syntax error.
  Future<QueryResult> execute(
    String database,
    String sql, {
    bool allowDestructive = true,
    bool recordHistory = true,
    SqlCancelToken? cancel,
  }) async {
    final Stopwatch stopwatch = Stopwatch()..start();
    final List<SqlStatement> statements = SqlUtils.splitStatements(sql);
    if (statements.isEmpty) {
      throw const ValidationFailure('Enter a SQL statement');
    }
    final SqlStatement? forbidden = SqlUtils.findForbidden(statements);
    if (forbidden != null) {
      throw SqlRejectedFailure(
        '${forbidden.keyword} is not allowed',
        details: 'PALLSQL blocks ATTACH/DETACH so a script cannot open files '
            'outside the workspace database folder.',
      );
    }
    if (!allowDestructive &&
        statements.any((SqlStatement s) => SqlUtils.isDestructive(s.sql))) {
      return QueryResult.failure(
        'Statement blocked: destructive SQL requires confirmation',
      );
    }

    final Database db = await _existingDatabase(database);
    final String engineVersion = await _sqliteVersion(db, database);
    final List<String> notices = <String>[];
    List<String> columns = <String>[];
    List<List<String?>> rows = <List<String?>>[];
    int rowsAffected = 0;
    int? lastInsertRowId;
    String? error;
    bool cancelled = false;
    int executed = 0;

    for (final SqlStatement statement in statements) {
      if (cancel != null && cancel.isCancelled) {
        cancelled = true;
        notices.add('Stopped by the user after $executed statement(s)');
        break;
      }
      try {
        final SqlCompatibilityCommand? compat =
            SqlCompatibility.parse(statement.sql);
        if (compat != null) {
          final _CompatOutcome outcome =
              await _compatibility(db, database, compat, engineVersion);
          if (outcome.error != null) {
            error = outcome.error;
            break;
          }
          if (outcome.columns.isNotEmpty) {
            columns = outcome.columns;
            rows = outcome.rows;
          }
          notices.addAll(outcome.notices);
        } else if (statement.returnsRows) {
          final List<Map<String, Object?>> result =
              await db.rawQuery(statement.sql);
          columns = _columnsOf(result, statement.sql);
          rows = result
              .map((Map<String, Object?> row) => columns
                  .map((String column) => _stringify(row[column]))
                  .toList())
              .toList(growable: false);
        } else if (statement.kind == SqlStatementKind.mutation) {
          final int affected = await db.rawUpdate(statement.sql);
          rowsAffected += affected;
          if (statement.keyword == 'INSERT' ||
              statement.keyword == 'REPLACE') {
            final List<Map<String, Object?>> idRows =
                await db.rawQuery('SELECT last_insert_rowid() AS id');
            final Object? id = idRows.isEmpty ? null : idRows.first['id'];
            if (id is num) {
              lastInsertRowId = id.toInt();
            }
          }
          notices.add('${statement.keyword}: $affected row(s) affected');
        } else {
          await db.execute(statement.sql);
          notices.add('${statement.keyword}: ok');
        }
        executed++;
      } on Object catch (exception) {
        error = _cleanMessage(exception);
        _logs.error(LogSource.database, 'SQL failed on $database: $error');
        break;
      }
    }

    stopwatch.stop();
    final QueryResult result = QueryResult(
      columns: error == null ? columns : const <String>[],
      rows:
          error == null && columns.isNotEmpty ? rows : const <List<String?>>[],
      statements: statements.length,
      duration: stopwatch.elapsed,
      rowsAffected: rowsAffected,
      lastInsertRowId: lastInsertRowId,
      notices: notices,
      error: error,
      cancelled: cancelled,
      statementsExecuted: executed,
    );
    if (recordHistory) {
      await _recordHistory(
        QueryHistoryEntry(
          database: database,
          sql: sql,
          executedAt: _clock(),
          succeeded: error == null,
          durationMs: stopwatch.elapsedMilliseconds,
        ),
      );
    }
    if (error == null) {
      _logs.debug(
        LogSource.database,
        'Executed $executed statement(s) on $database in '
        '${stopwatch.elapsedMilliseconds} ms',
      );
    }
    return result;
  }

  /// Real engine version, cached per database file.
  Future<String> _sqliteVersion(Database db, String database) async {
    final String? cached = _versions[database];
    if (cached != null) {
      return cached;
    }
    try {
      final List<Map<String, Object?>> rows =
          await db.rawQuery('SELECT sqlite_version() AS v');
      final String version =
          rows.isEmpty ? '' : (rows.first['v']?.toString() ?? '');
      _versions[database] = version;
      return version;
    } on Object {
      return '';
    }
  }

  Future<Database?> _openIfExists(String name) async {
    try {
      return await _existingDatabase(name);
    } on Object {
      return null;
    }
  }

  /// Answers a MySQL-style metadata statement from real SQLite metadata.
  Future<_CompatOutcome> _compatibility(
    Database db,
    String database,
    SqlCompatibilityCommand command,
    String engineVersion,
  ) async {
    switch (command.kind) {
      case SqlCompatibilityKind.unsupported:
        {
          final String message = SqlCompatibility.unsupportedMessage(
            statement: command.original,
            engineVersion: engineVersion,
            token: command.token,
          );
          final String? alternative = SqlCompatibility.alternativeFor(command);
          return _CompatOutcome(
            error: alternative == null ? message : '$message\n\n$alternative',
          );
        }
      case SqlCompatibilityKind.showDatabases:
        {
          final List<DatabaseInfo> files = await listDatabases();
          return _CompatOutcome(
            columns: const <String>['Database'],
            rows: files
                .map((DatabaseInfo info) => <String?>[info.name])
                .toList(growable: false),
            notices: <String>[
              '${files.length} database file(s) found in PALLSQL/database',
            ],
          );
        }
      case SqlCompatibilityKind.showTables:
        {
          final String target = command.database ?? database;
          final Database? source =
              target == database ? db : await _openIfExists(target);
          if (source == null) {
            return _CompatOutcome(error: 'Unknown database: $target');
          }
          final List<Map<String, Object?>> objects = await source.rawQuery(
            "SELECT name FROM sqlite_master WHERE type IN ('table', 'view') "
            "AND name NOT LIKE 'sqlite_%' ORDER BY type, name",
          );
          return _CompatOutcome(
            columns: <String>['Tables_in_$target'],
            rows: objects
                .map((Map<String, Object?> row) => <String?>[
                      row['name']?.toString(),
                    ])
                .toList(growable: false),
            notices: <String>[
              '${objects.length} object(s) read from sqlite_master of $target',
            ],
          );
        }
      case SqlCompatibilityKind.describeTable:
      case SqlCompatibilityKind.showColumns:
        {
          final String? missingTable = command.table;
          if (missingTable == null || missingTable.isEmpty) {
            return const _CompatOutcome(
              error: 'Missing table name. Usage: DESCRIBE <table>;',
            );
          }
          final List<Map<String, Object?>> tableInfo = await db.rawQuery(
            'PRAGMA table_info(${Validators.quoteSqlIdentifier(missingTable)})',
          );
          if (tableInfo.isEmpty) {
            return _CompatOutcome(
              error: "Table '$missingTable' does not exist in $database",
            );
          }
          final List<List<String?>> described = tableInfo.map(
            (Map<String, Object?> row) {
              final bool primaryKey = ((row['pk'] as num?)?.toInt() ?? 0) > 0;
              final bool notNull =
                  ((row['notnull'] as num?)?.toInt() ?? 0) == 1;
              return <String?>[
                row['name']?.toString() ?? '',
                row['type']?.toString() ?? '',
                notNull ? 'NO' : 'YES',
                primaryKey ? 'PRI' : '',
                row['dflt_value']?.toString(),
                primaryKey ? 'PRIMARY KEY' : '',
              ];
            },
          ).toList(growable: false);
          return _CompatOutcome(
            columns: const <String>[
              'Field',
              'Type',
              'Null',
              'Key',
              'Default',
              'Extra',
            ],
            rows: described,
            notices: <String>[
              'Translated from PRAGMA table_info by the compatibility layer',
            ],
          );
        }
      case SqlCompatibilityKind.showCreateTable:
        {
          final String? createTable = command.table;
          if (createTable == null || createTable.isEmpty) {
            return const _CompatOutcome(
              error: 'Missing table name. Usage: SHOW CREATE TABLE <table>;',
            );
          }
          final List<Map<String, Object?>> found = await db.rawQuery(
            "SELECT name, sql FROM sqlite_master WHERE name = ? "
            "AND type IN ('table', 'view') LIMIT 1",
            <Object?>[createTable],
          );
          if (found.isEmpty) {
            return _CompatOutcome(
              error: "Table '$createTable' does not exist in $database",
            );
          }
          final String definition = found.first['sql']?.toString() ?? '';
          return _CompatOutcome(
            columns: const <String>['Table', 'Create Table'],
            rows: <List<String?>>[
              <String?>[
                createTable,
                definition.isEmpty ? '' : '$definition;',
              ],
            ],
            notices: <String>[
              'Definition read from sqlite_master (the real stored DDL)',
            ],
          );
        }
      case SqlCompatibilityKind.showIndexes:
        {
          final String? indexedTable = command.table;
          if (indexedTable == null || indexedTable.isEmpty) {
            return const _CompatOutcome(
              error: 'Missing table name. Usage: SHOW INDEX FROM <table>;',
            );
          }
          final List<Map<String, Object?>> indexList = await db.rawQuery(
            'PRAGMA index_list(${Validators.quoteSqlIdentifier(indexedTable)})',
          );
          final List<List<String?>> indexRows = <List<String?>>[];
          for (final Map<String, Object?> index in indexList) {
            final String indexName = index['name']?.toString() ?? '';
            final bool unique = ((index['unique'] as num?)?.toInt() ?? 0) == 1;
            final List<Map<String, Object?>> indexColumns = await db.rawQuery(
              'PRAGMA index_info(${Validators.quoteSqlIdentifier(indexName)})',
            );
            if (indexColumns.isEmpty) {
              indexRows.add(
                <String?>[indexedTable, unique ? '0' : '1', indexName, ''],
              );
              continue;
            }
            for (final Map<String, Object?> column in indexColumns) {
              indexRows.add(<String?>[
                indexedTable,
                unique ? '0' : '1',
                indexName,
                column['name']?.toString() ?? '',
              ]);
            }
          }
          return _CompatOutcome(
            columns: const <String>[
              'Table',
              'Non_unique',
              'Key_name',
              'Column_name',
            ],
            rows: indexRows,
            notices: <String>[
              '${indexList.length} index(es) read from PRAGMA index_list',
            ],
          );
        }
      case SqlCompatibilityKind.selectVersion:
        {
          final List<Map<String, Object?>> versionRows =
              await db.rawQuery('SELECT sqlite_version() AS v');
          final String version = versionRows.isEmpty
              ? engineVersion
              : (versionRows.first['v']?.toString() ?? engineVersion);
          return _CompatOutcome(
            columns: const <String>['VERSION()'],
            rows: <List<String?>>[
              <String?>[version],
            ],
            notices: <String>[
              'That is the SQLite engine version. PALLSQL runs the SQLite '
                  'dialect - it is not MySQL or MariaDB.',
            ],
          );
        }
      case SqlCompatibilityKind.selectDatabase:
        return _CompatOutcome(
          columns: const <String>['DATABASE()'],
          rows: <List<String?>>[
            <String?>[database],
          ],
          notices: <String>[
            'The selected file is PALLSQL/database/$database.db',
          ],
        );
    }
  }

  /// Runs a script inside a transaction (used by SQL import).
  Future<QueryResult> runScript(String database, String sql) async {
    final List<SqlStatement> statements = SqlUtils.splitStatements(sql);
    if (statements.isEmpty) {
      throw const ValidationFailure('The script does not contain statements');
    }
    final SqlStatement? forbidden = SqlUtils.findForbidden(statements);
    if (forbidden != null) {
      throw SqlRejectedFailure(
          '${forbidden.keyword} is not allowed in imports');
    }
    final Database db = await _existingDatabase(database);
    final Stopwatch stopwatch = Stopwatch()..start();
    int executed = 0;
    int affected = 0;
    try {
      await db.transaction((Transaction txn) async {
        for (final SqlStatement statement in statements) {
          if (statement.keyword == 'BEGIN' ||
              statement.keyword == 'COMMIT' ||
              statement.keyword == 'END' ||
              statement.keyword == 'ROLLBACK') {
            continue;
          }
          if (statement.returnsRows) {
            await txn.rawQuery(statement.sql);
          } else if (statement.kind == SqlStatementKind.mutation) {
            affected += await txn.rawUpdate(statement.sql);
          } else {
            await txn.execute(statement.sql);
          }
          executed++;
        }
      });
    } on Object catch (exception) {
      final String message = _cleanMessage(exception);
      _logs.error(LogSource.database, 'Import failed on $database: $message');
      stopwatch.stop();
      return QueryResult.failure(message, duration: stopwatch.elapsed);
    }
    stopwatch.stop();
    _logs.info(
      LogSource.database,
      'Imported $executed statement(s) into $database',
    );
    return QueryResult(
      columns: const <String>[],
      rows: const <List<String?>>[],
      statements: executed,
      duration: stopwatch.elapsed,
      rowsAffected: affected,
      notices: <String>['$executed statement(s) applied inside a transaction'],
    );
  }

  /// Reads a page of rows. Tables without a `rowid` (WITHOUT ROWID or views)
  /// fall back to a plain `SELECT *`.
  Future<QueryResult> selectRows(
    String database,
    String table, {
    int limit = 100,
    int offset = 0,
  }) async {
    final String quoted = Validators.quoteSqlIdentifier(table);
    final QueryResult withRowId = await execute(
      database,
      'SELECT rowid AS _rowid_, * FROM $quoted LIMIT $limit OFFSET $offset',
      recordHistory: false,
    );
    if (withRowId.error == null) {
      return withRowId;
    }
    return execute(
      database,
      'SELECT * FROM $quoted LIMIT $limit OFFSET $offset',
      recordHistory: false,
    );
  }

  Future<QueryResult> insertRow(
    String database,
    String table,
    Map<String, Object?> values, {
    bool allowDestructive = true,
  }) {
    if (values.isEmpty) {
      throw const ValidationFailure('No column values provided');
    }
    final String columns =
        values.keys.map(Validators.quoteSqlIdentifier).join(', ');
    final String placeholders = values.keys.map((String _) => '?').join(', ');
    return _runParameterised(
      database,
      'INSERT INTO ${Validators.quoteSqlIdentifier(table)} ($columns) '
      'VALUES ($placeholders)',
      values.values.toList(),
      allowDestructive: allowDestructive,
    );
  }

  Future<QueryResult> updateRow(
    String database,
    String table,
    Map<String, Object?> values, {
    required String keyColumn,
    required Object? keyValue,
    bool allowDestructive = true,
  }) {
    if (values.isEmpty) {
      throw const ValidationFailure('No column values provided');
    }
    final String assignments = values.keys
        .map((String key) => '${Validators.quoteSqlIdentifier(key)} = ?')
        .join(', ');
    final List<Object?> arguments = <Object?>[...values.values, keyValue];
    return _runParameterised(
      database,
      'UPDATE ${Validators.quoteSqlIdentifier(table)} SET $assignments '
      'WHERE ${Validators.quoteSqlIdentifier(keyColumn)} = ?',
      arguments,
      allowDestructive: allowDestructive,
    );
  }

  Future<QueryResult> deleteRow(
    String database,
    String table, {
    required String keyColumn,
    required Object? keyValue,
    bool allowDestructive = true,
  }) {
    return _runParameterised(
      database,
      'DELETE FROM ${Validators.quoteSqlIdentifier(table)} '
      'WHERE ${Validators.quoteSqlIdentifier(keyColumn)} = ?',
      <Object?>[keyValue],
      allowDestructive: allowDestructive,
    );
  }

  Future<QueryResult> _runParameterised(
    String database,
    String sql,
    List<Object?> arguments, {
    required bool allowDestructive,
  }) async {
    final Stopwatch stopwatch = Stopwatch()..start();
    final Database db = await _existingDatabase(database);
    try {
      final int affected = await db.rawUpdate(sql, arguments);
      stopwatch.stop();
      return QueryResult(
        columns: const <String>[],
        rows: const <List<String?>>[],
        statements: 1,
        duration: stopwatch.elapsed,
        rowsAffected: affected,
        notices: <String>['$affected row(s) affected'],
      );
    } on Object catch (exception) {
      stopwatch.stop();
      final String message = _cleanMessage(exception);
      _logs.error(LogSource.database, 'Row operation failed: $message');
      return QueryResult.failure(message, duration: stopwatch.elapsed);
    }
  }

  /// Generates a SQL dump (schema + data) for [database].
  Future<String> exportSql(String database,
      {int maxRowsPerTable = 20000}) async {
    final Database db = await _existingDatabase(database);
    final StringBuffer buffer = StringBuffer()
      ..writeln('-- PALLSQL SQL export')
      ..writeln('-- Database: $database')
      ..writeln('-- Generated: ${_clock().toIso8601String()}')
      ..writeln('PRAGMA foreign_keys = OFF;')
      ..writeln();
    final List<Map<String, Object?>> objects = await db.rawQuery(
      "SELECT type, name, sql FROM sqlite_master WHERE sql IS NOT NULL "
      "AND name NOT LIKE 'sqlite_%' ORDER BY CASE type "
      "WHEN 'table' THEN 0 WHEN 'view' THEN 1 WHEN 'index' THEN 2 ELSE 3 END, name",
    );
    for (final Map<String, Object?> object in objects) {
      final String type = object['type']?.toString() ?? '';
      final String name = object['name']?.toString() ?? '';
      final String createSql = object['sql']?.toString() ?? '';
      if (createSql.isEmpty) {
        continue;
      }
      buffer
        ..writeln('-- $type $name')
        ..writeln('${createSql.trim()};');
      if (type != 'table') {
        continue;
      }
      final List<Map<String, Object?>> rows = await db.rawQuery(
        'SELECT * FROM ${Validators.quoteSqlIdentifier(name)} '
        'LIMIT $maxRowsPerTable',
      );
      if (rows.isNotEmpty) {
        buffer.writeln(
          'INSERT INTO ${Validators.quoteSqlIdentifier(name)} VALUES',
        );
        final String values = rows.map((Map<String, Object?> row) {
          final String cells = row.values.map(_literal).join(', ');
          return '  ($cells)';
        }).join(',\n');
        buffer
          ..writeln(values)
          ..writeln(';');
      }
      buffer.writeln();
    }
    return buffer.toString();
  }

  /// Copies the database file into [targetDirectory] after closing it.
  Future<File> backupDatabase(
      String database, Directory targetDirectory) async {
    final String path = _pathFor(database);
    final File source = File(path);
    if (!await source.exists()) {
      throw NotFoundFailure('Database $database does not exist');
    }
    await closeDatabase(database);
    await targetDirectory.create(recursive: true);
    final String stamp = _timestamp();
    final File target =
        File(p.join(targetDirectory.path, '${database}_$stamp.db'));
    await source.copy(target.path);
    _logs.info(LogSource.database, 'Backed up $database to ${target.path}');
    return target;
  }

  /// Restores a backup file over an existing database (or creates it).
  Future<void> restoreDatabase(File source, String database) async {
    if (!await source.exists()) {
      throw NotFoundFailure('Backup file not found');
    }
    final String path = _pathFor(database);
    await closeDatabase(database);
    await File(path).parent.create(recursive: true);
    await source.copy(path);
    _logs.warning(LogSource.database, 'Restored $database from backup');
  }

  Future<void> loadHistory() async {
    final File? file = historyFile;
    if (file == null || !await file.exists()) {
      return;
    }
    try {
      final String raw = await file.readAsString();
      _history
        ..clear()
        ..addAll(QueryHistoryEntry.decodeList(raw).take(maxHistory));
    } on FileSystemException {
      // History is a convenience, never a hard dependency.
    }
  }

  Future<void> clearHistory() async {
    _history.clear();
    await _persistHistory();
  }

  Future<void> _recordHistory(QueryHistoryEntry entry) async {
    _history.insert(0, entry);
    if (_history.length > maxHistory) {
      _history.removeRange(maxHistory, _history.length);
    }
    await _persistHistory();
  }

  Future<void> _persistHistory() async {
    final File? file = historyFile;
    if (file == null) {
      return;
    }
    try {
      await file.parent.create(recursive: true);
      await file.writeAsString(QueryHistoryEntry.encodeList(_history),
          flush: false);
    } on FileSystemException {
      // Ignore persistence problems.
    }
  }

  String _timestamp() {
    final DateTime now = _clock();
    String two(int value) => value.toString().padLeft(2, '0');
    return '${now.year}${two(now.month)}${two(now.day)}-'
        '${two(now.hour)}${two(now.minute)}${two(now.second)}';
  }

  List<String> _columnsOf(List<Map<String, Object?>> rows, String sql) {
    if (rows.isNotEmpty) {
      return rows.first.keys.toList(growable: false);
    }
    return _parseSelectColumns(sql);
  }

  /// Best effort column extraction for empty result sets.
  List<String> _parseSelectColumns(String sql) {
    try {
      final String upper = sql.toUpperCase();
      final int selectIndex = upper.indexOf('SELECT');
      if (selectIndex < 0) {
        return const <String>[];
      }
      int fromIndex = upper.indexOf(' FROM ', selectIndex);
      if (fromIndex < 0) {
        fromIndex = sql.length;
      }
      final String projection =
          sql.substring(selectIndex + 6, fromIndex).trim();
      if (projection.isEmpty || projection.contains('*')) {
        return const <String>[];
      }
      final List<String> columns = <String>[];
      for (final String rawColumn in projection.split(',')) {
        final String column = rawColumn.trim();
        if (column.isEmpty) {
          continue;
        }
        final List<String> parts = column.split(RegExp(r'\s+'));
        String name = parts.last;
        if (parts.length >= 3 &&
            parts[parts.length - 2].toUpperCase() == 'AS') {
          name = parts.last;
        }
        name = name.replaceAll('"', '').replaceAll('`', '').replaceAll("'", '');
        if (name.isNotEmpty &&
            RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$').hasMatch(name)) {
          columns.add(name);
        }
      }
      return columns;
    } on Object {
      return const <String>[];
    }
  }

  String _literal(Object? value) {
    if (value == null) {
      return 'NULL';
    }
    if (value is int || value is double) {
      return value.toString();
    }
    if (value is bool) {
      return value ? '1' : '0';
    }
    if (value is Uint8List) {
      final String hex = value
          .map((int byte) => byte.toRadixString(16).padLeft(2, '0'))
          .join();
      return "X'$hex'";
    }
    return Validators.quoteSqlLiteral(value.toString());
  }

  String? _stringify(Object? value) {
    if (value == null) {
      return null;
    }
    if (value is Uint8List) {
      return '<blob ${value.length} bytes>';
    }
    if (value is List<int>) {
      return '<blob ${value.length} bytes>';
    }
    return value.toString();
  }

  String _cleanMessage(Object exception) {
    String message = exception.toString();
    // Never leak absolute workspace paths into the UI or logs.
    message = message.replaceAll(directory.path, '<workspace>/database');
    if (message.length > 800) {
      message = '${message.substring(0, 800)}…';
    }
    return message;
  }

  /// Diagnostic helper used by the terminal `database info` command.
  Future<Map<String, Object?>> describeStatistics(String database) async {
    final Database db = await _existingDatabase(database);
    final List<Map<String, Object?>> rows =
        await db.rawQuery('PRAGMA page_count');
    final List<Map<String, Object?>> pageSize =
        await db.rawQuery('PRAGMA page_size');
    final List<Map<String, Object?>> version =
        await db.rawQuery('SELECT sqlite_version() AS v');
    final int pages =
        rows.isEmpty ? 0 : (rows.first['page_count'] as num?)?.toInt() ?? 0;
    final int size = pageSize.isEmpty
        ? 0
        : (pageSize.first['page_size'] as num?)?.toInt() ?? 0;
    return <String, Object?>{
      'engine': 'SQLite',
      'engineVersion': version.isEmpty ? null : version.first['v'],
      'pageCount': pages,
      'pageSize': size,
      'estimatedBytes': pages * size,
      'journalMode': await _journalMode(db),
    };
  }

  Future<String?> _journalMode(Database db) async {
    try {
      final List<Map<String, Object?>> rows =
          await db.rawQuery('PRAGMA journal_mode');
      if (rows.isEmpty) {
        return null;
      }
      return rows.first.values.isEmpty
          ? null
          : rows.first.values.first?.toString();
    } on Object {
      return null;
    }
  }

  bool get isDisposed => _disposed;
}

/// Outcome of a MySQL-compatibility statement.
class _CompatOutcome {
  const _CompatOutcome({
    this.columns = const <String>[],
    this.rows = const <List<String?>>[],
    this.notices = const <String>[],
    this.error,
  });

  final List<String> columns;
  final List<List<String?>> rows;
  final List<String> notices;
  final String? error;
}
