import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../core/errors/app_failure.dart';
import '../core/utils/sql_utils.dart';
import '../core/utils/validators.dart';
import '../models/database_models.dart';
import '../models/log_entry.dart';
import '../services/log_sink.dart';
import '../services/mariadb/mariadb_client.dart';
import '../services/mariadb/mysql_connection.dart';
import '../services/mariadb/mysql_protocol.dart';
import '../services/mariadb/mysql_values.dart';
import 'database_contract.dart';

/// MariaDB implementation of [DatabaseRepository].
///
/// Every call in this class is real SQL executed by a MariaDB server the user
/// started from PALLSQL (see `MariaDBServiceManager`). There is no embedded
/// engine and no fallback: when the server is not reachable the call fails with
/// the server's own error and the UI shows `Unavailable`.
class MariaDbRepository implements DatabaseRepository {
  MariaDbRepository({
    required MariaDbClient client,
    required LogSink logs,
    this.historyFile,
    DateTime Function()? clock,
    this.maxHistory = 50,
  })  : _client = client,
        _logs = logs,
        _clock = clock ?? DateTime.now;

  final MariaDbClient _client;
  final LogSink _logs;
  final File? historyFile;
  final DateTime Function() _clock;
  final int maxHistory;

  final List<QueryHistoryEntry> _history = <QueryHistoryEntry>[];
  bool _disposed = false;

  MariaDbClient get client => _client;

  /// Schemas MariaDB ships with; they are listed but flagged as system schemas
  /// so the UI can hide them by default.
  static const Set<String> systemSchemas = <String>{
    'information_schema',
    'mysql',
    'performance_schema',
    'sys',
  };

  @override
  List<QueryHistoryEntry> get history =>
      List<QueryHistoryEntry>.unmodifiable(_history);

  @override
  Future<EngineAvailability> availability() async {
    try {
      final MariaDbBatch batch = await _client.query(
        'SELECT VERSION() AS version',
        timeout: const Duration(seconds: 8),
      );
      final MariaDbResult? result = batch.last;
      final String version = result?.rows.isNotEmpty == true
          ? (result!.rows.first.first ?? '')
          : '';
      if (version.isEmpty) {
        return EngineAvailability.unavailable(
          DatabaseEngineId.mariadb,
          batch.error?.toString() ?? 'MariaDB answered without a version',
        );
      }
      return EngineAvailability(
        engine: DatabaseEngineId.mariadb,
        available: true,
        version: version,
      );
    } on MysqlServerException catch (error) {
      return EngineAvailability.unavailable(
        DatabaseEngineId.mariadb,
        '${error.code} ${error.sqlState}: ${error.message}',
      );
    } on MysqlProtocolException catch (error) {
      return EngineAvailability.unavailable(
        DatabaseEngineId.mariadb,
        '${error.message}${error.detail == null ? '' : ' (${error.detail})'}',
      );
    } on Object catch (error) {
      return EngineAvailability.unavailable(
        DatabaseEngineId.mariadb,
        '$error',
      );
    }
  }

  /// Opens the schema for the connection so unqualified statements work.
  Future<void> _use(String database) async {
    final String? current = _client.currentDatabase;
    if (current == database) {
      return;
    }
    await _client.useDatabase(database);
  }

  String _guardedDatabase(String database) {
    if (!Validators.isValidDatabaseName(database)) {
      throw ValidationFailure(
        Validators.databaseNameError(database) ?? 'Invalid database name',
      );
    }
    return database;
  }

  // -------------------------------------------------------------------
  // Schemas
  // -------------------------------------------------------------------

  @override
  Future<List<DatabaseInfo>> listDatabases() async {
    final MariaDbBatch schemas = await _client.query('SHOW DATABASES');
    final List<String> names = (schemas.last?.rows ?? const <List<String?>>[])
        .map((List<String?> row) => row.first ?? '')
        .where((String name) => name.isNotEmpty)
        .toList(growable: false);
    if (names.isEmpty) {
      return const <DatabaseInfo>[];
    }

    // Real sizes and table counts straight from information_schema.
    final Map<String, int> sizes = <String, int>{};
    final Map<String, int> tables = <String, int>{};
    try {
      final MariaDbBatch stats = await _client.query(
        'SELECT TABLE_SCHEMA AS schema_name, '
        'COALESCE(SUM(DATA_LENGTH + INDEX_LENGTH), 0) AS bytes, '
        'COUNT(*) AS table_count '
        'FROM information_schema.TABLES '
        "WHERE TABLE_TYPE = 'BASE TABLE' GROUP BY TABLE_SCHEMA",
      );
      for (final List<String?> row
          in stats.last?.rows ?? const <List<String?>>[]) {
        if (row.isEmpty) {
          continue;
        }
        final String schema = row[0] ?? '';
        sizes[schema] = int.tryParse(row.length > 1 ? row[1] ?? '' : '') ?? 0;
        tables[schema] = int.tryParse(row.length > 2 ? row[2] ?? '' : '') ?? 0;
      }
    } on Object catch (error) {
      // Sizes are a convenience; the schema list itself is already real.
      _logs.warning(
        LogSource.database,
        'information_schema sizes unavailable: $error',
      );
    }

    final DateTime now = _clock();
    return names
        .map(
          (String name) => DatabaseInfo(
            name: name,
            path: '${_client.currentConfig.endpoint}/$name',
            sizeBytes: sizes[name] ?? 0,
            modifiedAt: now,
            tableCount: tables[name],
          ),
        )
        .toList(growable: false);
  }

  @override
  Future<DatabaseInfo> createDatabase(String name) async {
    final String safe = _guardedDatabase(name);
    final MariaDbBatch batch = await _client.query(
      'CREATE DATABASE ${quoteIdentifier(safe)} '
      'CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci',
    );
    if (batch.error != null) {
      throw SqlRejectedFailure(
        batch.error!.message,
        details: 'MariaDB error ${batch.error!.code} '
            '(${batch.error!.sqlState})',
      );
    }
    _logs.info(LogSource.database, 'Created database $safe');
    return DatabaseInfo(
      name: safe,
      path: '${_client.currentConfig.endpoint}/$safe',
      sizeBytes: 0,
      modifiedAt: _clock(),
      tableCount: 0,
    );
  }

  @override
  Future<void> deleteDatabase(String name) async {
    final String safe = _guardedDatabase(name);
    if (systemSchemas.contains(safe)) {
      throw SqlRejectedFailure('$safe is a MariaDB system schema');
    }
    final MariaDbBatch batch = await _client.query(
      'DROP DATABASE ${quoteIdentifier(safe)}',
    );
    if (batch.error != null) {
      throw SqlRejectedFailure(
        batch.error!.message,
        details: 'MariaDB error ${batch.error!.code}',
      );
    }
    if (_client.currentDatabase == safe) {
      _client.config = _client.currentConfig.copyWith(clearDatabase: true);
    }
    _logs.warning(LogSource.database, 'Dropped database $safe');
  }

  @override
  Future<List<TableInfo>> listTables(String database) async {
    final String safe = _guardedDatabase(database);
    final MariaDbBatch batch = await _client.execute(
      'SELECT TABLE_NAME, TABLE_TYPE, TABLE_ROWS '
      'FROM information_schema.TABLES WHERE TABLE_SCHEMA = ? '
      'ORDER BY TABLE_TYPE DESC, TABLE_NAME',
      <Object?>[safe],
    );
    if (batch.error != null) {
      throw SqlRejectedFailure(batch.error!.message);
    }
    return (batch.last?.rows ?? const <List<String?>>[])
        .map(
          (List<String?> row) => TableInfo(
            name: row.isNotEmpty ? row[0] ?? '' : '',
            type: (row.length > 1 ? row[1] ?? '' : '').toUpperCase() == 'VIEW'
                ? 'view'
                : 'table',
            rowCount: row.length > 2 ? int.tryParse(row[2] ?? '') : null,
          ),
        )
        .where((TableInfo info) => info.name.isNotEmpty)
        .toList(growable: false);
  }

  @override
  Future<List<ColumnInfo>> describeTable(String database, String table) async {
    final String safe = _guardedDatabase(database);
    final MariaDbBatch batch = await _client.execute(
      'SELECT COLUMN_NAME, COLUMN_TYPE, IS_NULLABLE, COLUMN_KEY, '
      'COLUMN_DEFAULT, EXTRA FROM information_schema.COLUMNS '
      'WHERE TABLE_SCHEMA = ? AND TABLE_NAME = ? ORDER BY ORDINAL_POSITION',
      <Object?>[safe, table],
    );
    if (batch.error != null) {
      throw SqlRejectedFailure(batch.error!.message);
    }
    return (batch.last?.rows ?? const <List<String?>>[])
        .map(
          (List<String?> row) => ColumnInfo(
            name: row.isNotEmpty ? row[0] ?? '' : '',
            type: row.length > 1 ? row[1] ?? '' : '',
            notNull: (row.length > 2 ? row[2] ?? '' : '').toUpperCase() == 'NO',
            primaryKey: (row.length > 3 ? row[3] ?? '' : '') == 'PRI',
            defaultValue: row.length > 4 ? row[4] : null,
          ),
        )
        .toList(growable: false);
  }

  // -------------------------------------------------------------------
  // Query execution
  // -------------------------------------------------------------------

  @override
  Future<QueryResult> execute(
    String database,
    String sql, {
    bool allowDestructive = true,
    bool recordHistory = true,
    SqlCancelToken? cancel,
  }) async {
    final String safe = _guardedDatabase(database);
    final List<SqlStatement> statements = SqlUtils.splitStatements(sql);
    if (statements.isEmpty) {
      throw const ValidationFailure('Enter a SQL statement');
    }
    if (!allowDestructive &&
        statements.any((SqlStatement s) => SqlUtils.isDestructive(s.sql))) {
      return QueryResult.failure(
        'Statement blocked: destructive SQL requires confirmation',
      );
    }

    final Stopwatch stopwatch = Stopwatch()..start();
    await _use(safe);
    final int threadId = _client.connectionId;
    cancel?.attach(() => _killQuery(threadId));

    MariaDbBatch batch;
    try {
      batch = await _client.query(sql);
    } on MysqlServerException catch (error) {
      stopwatch.stop();
      return QueryResult.failure(
        _describeError(error),
        duration: stopwatch.elapsed,
      );
    } on MysqlProtocolException catch (error) {
      stopwatch.stop();
      return QueryResult.failure(
        '${error.message}${error.detail == null ? '' : ' (${error.detail})'}',
        duration: stopwatch.elapsed,
      );
    } finally {
      cancel?.attach(null);
    }
    stopwatch.stop();
    final QueryResult result = _toQueryResult(
      batch,
      database: safe,
      sql: sql,
      duration: stopwatch.elapsed,
    );
    if (recordHistory) {
      await _recordHistory(
        QueryHistoryEntry(
          database: safe,
          sql: sql,
          executedAt: _clock(),
          succeeded: result.error == null,
          durationMs: result.duration.inMilliseconds,
        ),
      );
    }
    if (result.error == null) {
      _logs.debug(
        LogSource.database,
        'Executed ${result.statementsExecuted} statement(s) on '
        '$safe in ${result.duration.inMilliseconds} ms',
      );
    } else {
      _logs.error(LogSource.database, 'SQL failed on $safe: ${result.error}');
    }
    return result;
  }

  /// Real server side cancellation: `KILL QUERY <thread>` over a second
  /// connection. MariaDB stops the statement and answers ER_QUERY_INTERRUPTED.
  Future<void> _killQuery(int? threadId) async {
    if (threadId == null || threadId <= 0) {
      return;
    }
    try {
      final MariaDbClient killer = MariaDbClient(_client.currentConfig);
      await killer.query('KILL QUERY $threadId');
      await killer.close();
      _logs.warning(LogSource.database, 'KILL QUERY $threadId sent');
    } on Object catch (error) {
      _logs.warning(LogSource.database, 'KILL QUERY failed: $error');
    }
  }

  String _describeError(MysqlServerException error) {
    final StringBuffer buffer = StringBuffer()
      ..writeln('MariaDB error ${error.code} (${error.sqlState})')
      ..write(error.message);
    final String hint = _hintFor(error.code);
    if (hint.isNotEmpty) {
      buffer
        ..writeln()
        ..write(hint);
    }
    return buffer.toString();
  }

  String _hintFor(int code) {
    switch (code) {
      case 1045:
        return 'Check the MariaDB user and password in Settings.';
      case 1049:
        return 'That database does not exist yet. Create it first.';
      case 1142:
        return 'The user has no privilege for this object.';
      case 1146:
        return 'Run SHOW TABLES to see the tables that really exist.';
      case 1317:
        return 'The query was stopped.';
      case 1064:
        return 'Syntax error: MariaDB rejected the statement.';
      case 1040:
        return 'Too many connections: raise max_connections in the config.';
      default:
        return '';
    }
  }

  QueryResult _toQueryResult(
    MariaDbBatch batch, {
    required String database,
    required String sql,
    required Duration duration,
  }) {
    MariaDbResult? resultSet;
    int affected = 0;
    int? insertId;
    final List<String> notices = <String>[];
    for (final MariaDbResult result in batch.results) {
      if (result.hasResultSet) {
        resultSet = result;
      } else {
        affected += result.affectedRows;
        if (result.lastInsertId > 0) {
          insertId = result.lastInsertId;
        }
        if (result.info.isNotEmpty) {
          notices.add(result.info);
        }
      }
      if (result.warningCount > 0) {
        notices.add('${result.warningCount} warning(s) - run SHOW WARNINGS');
      }
    }
    final MysqlServerException? error = batch.error;
    return QueryResult(
      columns: error == null
          ? (resultSet?.columns ?? const <String>[])
          : const <String>[],
      rows: error == null
          ? (resultSet?.rows ?? const <List<String?>>[])
          : const <List<String?>>[],
      statements: SqlUtils.splitStatements(sql).length,
      duration: duration,
      rowsAffected: affected,
      lastInsertRowId: insertId,
      notices: <String>[
        ...notices,
        'Engine: MariaDB ${_client.serverVersion ?? ''}'.trim(),
        'Database: $database',
      ],
      error: error == null ? null : _describeError(error),
      statementsExecuted: batch.statementsExecuted,
    );
  }

  @override
  Future<QueryResult> runScript(String database, String sql) async {
    final List<SqlStatement> statements = SqlUtils.splitStatements(sql);
    if (statements.isEmpty) {
      throw const ValidationFailure('The script does not contain statements');
    }
    final String safe = _guardedDatabase(database);
    final StringBuffer script = StringBuffer()
      ..writeln('START TRANSACTION;')
      ..writeln(sql.trim().endsWith(';') ? sql.trim() : '${sql.trim()};')
      ..writeln('COMMIT;');
    final Stopwatch stopwatch = Stopwatch()..start();
    await _use(safe);
    try {
      final MariaDbBatch batch = await _client.query(
        script.toString(),
        timeout: const Duration(minutes: 10),
      );
      stopwatch.stop();
      if (batch.error != null) {
        // MariaDB keeps the work of the statements that already ran inside the
        // transaction, so an explicit rollback is issued to leave no half
        // migrated data behind.
        await _client.query('ROLLBACK');
        return QueryResult.failure(
          '${_describeError(batch.error!)}\n'
          'ROLLBACK issued: nothing from this script was imported.',
          duration: stopwatch.elapsed,
        );
      }
      return _toQueryResult(
        batch,
        database: safe,
        sql: sql,
        duration: stopwatch.elapsed,
      );
    } on Object catch (error) {
      stopwatch.stop();
      return QueryResult.failure('$error', duration: stopwatch.elapsed);
    }
  }

  // -------------------------------------------------------------------
  // Row level operations (parameterised on the server)
  // -------------------------------------------------------------------

  @override
  Future<QueryResult> selectRows(
    String database,
    String table, {
    int limit = 100,
    int offset = 0,
  }) async {
    final String safe = _guardedDatabase(database);
    await _use(safe);
    final Stopwatch stopwatch = Stopwatch()..start();
    final MariaDbBatch batch = await _client.execute(
      'SELECT * FROM ${quoteIdentifier(table)} LIMIT ? OFFSET ?',
      <Object?>[limit, offset],
    );
    stopwatch.stop();
    return _toQueryResult(
      batch,
      database: safe,
      sql: 'SELECT * FROM $table LIMIT $limit OFFSET $offset',
      duration: stopwatch.elapsed,
    );
  }

  @override
  Future<QueryResult> insertRow(
    String database,
    String table,
    Map<String, Object?> values, {
    bool allowDestructive = true,
  }) {
    if (values.isEmpty) {
      throw const ValidationFailure('No column values provided');
    }
    final String columns = values.keys.map(quoteIdentifier).join(', ');
    final String placeholders = values.keys.map((String _) => '?').join(', ');
    return _parameterised(
      database,
      'INSERT INTO ${quoteIdentifier(table)} ($columns) VALUES ($placeholders)',
      values.values.toList(growable: false),
    );
  }

  @override
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
        .map((String key) => '${quoteIdentifier(key)} = ?')
        .join(', ');
    return _parameterised(
      database,
      'UPDATE ${quoteIdentifier(table)} SET $assignments '
      'WHERE ${quoteIdentifier(keyColumn)} = ?',
      <Object?>[...values.values, keyValue],
    );
  }

  @override
  Future<QueryResult> deleteRow(
    String database,
    String table, {
    required String keyColumn,
    required Object? keyValue,
    bool allowDestructive = true,
  }) {
    return _parameterised(
      database,
      'DELETE FROM ${quoteIdentifier(table)} '
      'WHERE ${quoteIdentifier(keyColumn)} = ?',
      <Object?>[keyValue],
    );
  }

  Future<QueryResult> _parameterised(
    String database,
    String sql,
    List<Object?> arguments,
  ) async {
    final String safe = _guardedDatabase(database);
    await _use(safe);
    final Stopwatch stopwatch = Stopwatch()..start();
    final MariaDbBatch batch = await _client.execute(sql, arguments);
    stopwatch.stop();
    return _toQueryResult(
      batch,
      database: safe,
      sql: sql,
      duration: stopwatch.elapsed,
    );
  }

  // -------------------------------------------------------------------
  // Export, backup and restore (dump based, safe while the server runs)
  // -------------------------------------------------------------------

  @override
  Future<String> exportSql(String database,
      {int maxRowsPerTable = 20000}) async {
    final String safe = _guardedDatabase(database);
    await _use(safe);
    final StringBuffer buffer = StringBuffer()
      ..writeln('-- PALLSQL MariaDB export')
      ..writeln('-- Database: $safe')
      ..writeln('-- Server: ${_client.serverVersion ?? 'unknown'}')
      ..writeln('-- Generated: ${_clock().toIso8601String()}')
      ..writeln('SET NAMES utf8mb4;')
      ..writeln('SET FOREIGN_KEY_CHECKS = 0;')
      ..writeln()
      ..writeln('CREATE DATABASE IF NOT EXISTS ${quoteIdentifier(safe)};')
      ..writeln('USE ${quoteIdentifier(safe)};')
      ..writeln();

    final MariaDbBatch tables = await _client.query(
      'SELECT TABLE_NAME FROM information_schema.TABLES '
      "WHERE TABLE_SCHEMA = '${safe.replaceAll("'", "''")}' "
      "AND TABLE_TYPE = 'BASE TABLE' ORDER BY TABLE_NAME",
    );
    if (tables.error != null) {
      throw SqlRejectedFailure(tables.error!.message);
    }
    for (final List<String?> row
        in tables.last?.rows ?? const <List<String?>>[]) {
      final String table = row.first ?? '';
      if (table.isEmpty) {
        continue;
      }
      final MariaDbBatch ddl = await _client.query(
        'SHOW CREATE TABLE ${quoteIdentifier(table)}',
      );
      final List<String?>? createRow =
          ddl.last?.rows.isNotEmpty == true ? ddl.last!.rows.first : null;
      final String createSql =
          createRow != null && createRow.length > 1 ? createRow[1] ?? '' : '';
      buffer
        ..writeln('-- table $table')
        ..writeln('DROP TABLE IF EXISTS ${quoteIdentifier(table)};')
        ..writeln('${createSql.isEmpty ? '-- (no DDL returned)' : createSql};');
      final QueryResult rows =
          await selectRows(safe, table, limit: maxRowsPerTable);
      if (rows.error == null && rows.rows.isNotEmpty) {
        final String columnList = rows.columns.map(quoteIdentifier).join(', ');
        for (final List<String?> cells in rows.rows) {
          final String values = cells.map(_literalFor).join(', ');
          buffer.writeln(
            'INSERT INTO ${quoteIdentifier(table)} ($columnList) '
            'VALUES ($values);',
          );
        }
      }
      buffer.writeln();
    }
    buffer.writeln('SET FOREIGN_KEY_CHECKS = 1;');
    return buffer.toString();
  }

  String _literalFor(String? value) {
    if (value == null) {
      return 'NULL';
    }
    final String escaped = value
        .replaceAll('\\', '\\\\')
        .replaceAll("'", "\\'")
        .replaceAll('\n', '\\n')
        .replaceAll('\r', '\\r');
    return "'$escaped'";
  }

  @override
  Future<File> backupDatabase(
    String database,
    Directory targetDirectory,
  ) async {
    final String safe = _guardedDatabase(database);
    await targetDirectory.create(recursive: true);
    // A consistent snapshot is taken on the server; copying InnoDB files while
    // the server runs would not be safe.
    await _client.query('START TRANSACTION WITH CONSISTENT SNAPSHOT');
    String dump;
    try {
      dump = await exportSql(safe);
    } finally {
      await _client.query('COMMIT');
    }
    final String stamp = _clock()
        .toIso8601String()
        .replaceAll(RegExp(r'[:.]'), '-')
        .substring(0, 19);
    final File target =
        File(p.join(targetDirectory.path, '${safe}_$stamp.sql'));
    await target.writeAsString(dump, flush: true);
    _logs.info(
      LogSource.backup,
      'MariaDB dump of $safe written to ${target.path} '
      '(${await target.length()} bytes)',
    );
    return target;
  }

  @override
  Future<void> restoreDatabase(File source, String database) async {
    if (!await source.exists()) {
      throw NotFoundFailure('Backup file not found: ${source.path}');
    }
    final String safe = _guardedDatabase(database);
    final String script = await source.readAsString();
    if (script.trim().isEmpty) {
      throw const ValidationFailure('The dump file is empty');
    }
    if (await _isEmptySchema(safe)) {
      await _client
          .query('CREATE DATABASE IF NOT EXISTS ${quoteIdentifier(safe)}');
    }
    await _use(safe);
    final MariaDbBatch batch = await _client.query(
      script,
      timeout: const Duration(minutes: 10),
    );
    if (batch.error != null) {
      // MariaDB commits DDL implicitly, so a partial restore cannot be rolled
      // back. Saying so is more useful than a false promise.
      throw SqlRejectedFailure(
        'Restore failed at statement ${batch.statementsExecuted + 1}: '
        '${batch.error!.message}',
        details: 'MariaDB commits CREATE/ALTER/DROP implicitly, so the '
            'objects created before the failure are already in place. '
            'Drop the database and import again after fixing the dump.',
      );
    }
    _logs.warning(LogSource.backup, 'Restored $safe from ${source.path}');
  }

  /// True when the schema has no user tables yet.
  Future<bool> _isEmptySchema(String database) async {
    final MariaDbBatch batch = await _client.execute(
      'SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA = ?',
      <Object?>[database],
    );
    final String count = batch.last?.rows.first.first ?? '0';
    return (int.tryParse(count) ?? 0) == 0;
  }

  // -------------------------------------------------------------------
  // Statistics and history
  // -------------------------------------------------------------------

  @override
  Future<Map<String, Object?>> describeStatistics(String database) async {
    final Map<String, Object?> statistics = <String, Object?>{
      'engine': 'MariaDB',
      'engineVersion': _client.serverVersion,
      'endpoint': _client.currentConfig.endpoint,
      'database': database,
    };
    try {
      final MariaDbBatch status = await _client.query(
        "SHOW STATUS WHERE Variable_name IN "
        "('Uptime', 'Threads_connected', 'Threads_running', "
        "'Aborted_connects', 'Queries')",
      );
      for (final List<String?> row
          in status.last?.rows ?? const <List<String?>>[]) {
        if (row.length >= 2) {
          statistics[row[0] ?? ''] = row[1];
        }
      }
      final MariaDbBatch variables = await _client.query(
        "SHOW VARIABLES WHERE Variable_name IN "
        "('port', 'datadir', 'socket', 'version_comment', "
        "'character_set_server', 'collation_server', 'max_connections', "
        "'innodb_buffer_pool_size')",
      );
      for (final List<String?> row
          in variables.last?.rows ?? const <List<String?>>[]) {
        if (row.length >= 2) {
          statistics[row[0] ?? ''] = row[1];
        }
      }
      final MariaDbBatch size = await _client.query(
        'SELECT COALESCE(SUM(DATA_LENGTH + INDEX_LENGTH), 0) AS bytes '
        'FROM information_schema.TABLES '
        "WHERE TABLE_SCHEMA = '${database.replaceAll("'", "''")}'",
      );
      statistics['databaseBytes'] =
          int.tryParse(size.last?.rows.first.first ?? '') ?? 0;
    } on Object catch (error) {
      statistics['error'] = '$error';
    }
    return statistics;
  }

  @override
  Future<void> loadHistory() async {
    final File? file = historyFile;
    if (file == null || !await file.exists()) {
      return;
    }
    try {
      final Object? decoded = jsonDecode(await file.readAsString());
      if (decoded is! List) {
        return;
      }
      _history
        ..clear()
        ..addAll(
          decoded
              .whereType<Map<Object?, Object?>>()
              .map(
                (Map<Object?, Object?> entry) => QueryHistoryEntry.fromJson(
                  entry.map((Object? key, Object? value) =>
                      MapEntry<String, Object?>('$key', value)),
                ),
              )
              .take(maxHistory),
        );
    } on Object catch (error) {
      _logs.warning(LogSource.database, 'Query history unreadable: $error');
    }
  }

  @override
  Future<void> clearHistory() async {
    _history.clear();
    await _persistHistory();
  }

  Future<void> _recordHistory(QueryHistoryEntry entry) async {
    _history.insert(0, entry);
    while (_history.length > maxHistory) {
      _history.removeLast();
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
      await file.writeAsString(
        jsonEncode(
          _history.map((QueryHistoryEntry entry) => entry.toJson()).toList(),
        ),
        flush: true,
      );
    } on Object catch (error) {
      _logs.warning(LogSource.database, 'Query history not saved: $error');
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    await _client.close();
  }
}
