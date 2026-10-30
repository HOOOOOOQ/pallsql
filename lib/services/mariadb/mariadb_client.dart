import 'dart:async';

import '../../models/log_entry.dart';
import '../log_sink.dart';
import 'mysql_connection.dart';
import 'mysql_protocol.dart';

/// Serialised, self-healing client for one MariaDB server.
///
/// * one TCP connection, commands are queued so two screens can never
///   interleave packets on the same socket;
/// * a connection that died (server restart, phone doze) is reopened once and
///   the command is retried, which is what a desktop client would do;
/// * the session remembers the `USE`d database so the UI can show it.
class MariaDbClient {
  MariaDbClient(
    this.config, {
    LogSink logs = const NullLogSink(),
  }) : _logs = logs;

  MariaDbConnectionConfig config;
  final LogSink _logs;

  MariaDbConnection? _connection;
  Future<void> _tail = Future<void>.value();
  bool _closed = false;

  String? _currentDatabase;
  String? _serverVersion;
  String _status = '';
  int _reconnects = 0;
  DateTime? _connectedAt;

  MariaDbConnectionConfig get currentConfig => config;

  /// Database selected by the last successful `USE`/`selectDatabase`.
  String? get currentDatabase => _currentDatabase;

  /// Real server version string, `null` until a handshake succeeded.
  String? get serverVersion => _serverVersion;

  /// Value of `SHOW STATUS LIKE 'Ssl_cipher'`-style connection status line.
  String get connectionStatus => _status;

  bool get isConnected => _connection?.isOpen ?? false;

  int get reconnectCount => _reconnects;

  DateTime? get connectedAt => _connectedAt;

  int get connectionId => _connection?.connectionId ?? 0;

  /// Serialises work on the single socket.
  Future<T> _serialize<T>(Future<T> Function() action) {
    final Completer<T> completer = Completer<T>();
    final Future<void> previous = _tail;
    _tail = previous.then((void _) async {
      if (_closed) {
        if (!completer.isCompleted) {
          completer.completeError(
            const MysqlProtocolException('MariaDB client is closed'),
          );
        }
        return;
      }
      try {
        final T value = await action();
        if (!completer.isCompleted) {
          completer.complete(value);
        }
      } on Object catch (error, stack) {
        if (!completer.isCompleted) {
          completer.completeError(error, stack);
        }
      }
    });
    return completer.future;
  }

  Future<MariaDbConnection> _connectionOrOpen() async {
    final MariaDbConnection? existing = _connection;
    if (existing != null && existing.isOpen) {
      return existing;
    }
    final MariaDbConnection created = await MariaDbConnection.open(config);
    _connection = created;
    _serverVersion = created.serverVersion;
    _connectedAt = DateTime.now();
    _currentDatabase = config.database;
    _status = 'connected to ${config.endpoint} '
        '(thread ${created.connectionId}, ${created.serverVersion})';
    _logs.info(
      LogSource.database,
      'MariaDB connection opened: ${config.describe()} -> '
      '${created.serverVersion}',
    );
    return created;
  }

  Future<T> _withConnection<T>(
    Future<T> Function(MariaDbConnection connection) action, {
    bool allowRetry = true,
  }) {
    return _serialize(() async {
      MariaDbConnection connection = await _connectionOrOpen();
      try {
        return await action(connection);
      } on MysqlProtocolException catch (error) {
        final bool looksClosed = !connection.isOpen ||
            error.message.contains('closed') ||
            error.message.contains('failed') ||
            error.message.contains('did not answer');
        if (!allowRetry || !looksClosed) {
          rethrow;
        }
        _logs.warning(
          LogSource.database,
          'MariaDB connection lost (${error.message}); reconnecting once',
        );
        _reconnects++;
        _connection = null;
        await connection.close(gracefully: false);
        connection = await _connectionOrOpen();
        if (_currentDatabase != null) {
          await connection.selectDatabase(_currentDatabase!);
        }
        return await action(connection);
      }
    });
  }

  /// Runs [sql] on the server. Never touches SQLite.
  Future<MariaDbBatch> query(String sql, {Duration? timeout}) {
    return _withConnection((MariaDbConnection connection) async {
      final MariaDbBatch batch = await connection.query(sql, timeout: timeout);
      _rememberDatabaseFrom(sql);
      return batch;
    });
  }

  /// Executes `USE <database>` through the protocol (`COM_INIT_DB`).
  Future<void> useDatabase(String database) {
    return _withConnection((MariaDbConnection connection) async {
      await connection.selectDatabase(database);
      _currentDatabase = database;
      config = config.copyWith(database: database);
    });
  }

  Future<MariaDbPreparedStatement> prepare(String sql) {
    return _withConnection(
      (MariaDbConnection connection) => connection.prepare(sql),
    );
  }

  /// Runs a parameterised statement and closes it afterwards.
  Future<MariaDbBatch> execute(
    String sql,
    List<Object?> parameters, {
    Duration? timeout,
  }) {
    return _withConnection((MariaDbConnection connection) async {
      final Stopwatch stopwatch = Stopwatch()..start();
      final MariaDbPreparedStatement statement = await connection.prepare(sql);
      try {
        final MariaDbResult result =
            await statement.execute(parameters, timeout: timeout);
        stopwatch.stop();
        return MariaDbBatch(
          results: <MariaDbResult>[result],
          error: null,
          statementsExecuted: 1,
          duration: stopwatch.elapsed,
        );
      } on MysqlServerException catch (error) {
        stopwatch.stop();
        return MariaDbBatch(
          results: const <MariaDbResult>[],
          error: error,
          statementsExecuted: 0,
          duration: stopwatch.elapsed,
        );
      } finally {
        await statement.close();
      }
    });
  }

  Future<bool> ping() async {
    try {
      return await _withConnection(
        (MariaDbConnection connection) => connection.ping(),
        allowRetry: false,
      );
    } on Object {
      return false;
    }
  }

  void _rememberDatabaseFrom(String sql) {
    final RegExpMatch? match =
        RegExp(r'^\s*use\s+`?([A-Za-z0-9_$]+)`?\s*;?\s*$', caseSensitive: false)
            .firstMatch(sql.trim());
    if (match != null) {
      _currentDatabase = match.group(1);
    }
  }

  Future<void> close() async {
    _closed = true;
    final MariaDbConnection? connection = _connection;
    _connection = null;
    if (connection != null) {
      await connection.close();
    }
  }

  /// Replaces the credentials/endpoint, dropping the current connection.
  Future<void> reconfigure(MariaDbConnectionConfig next) async {
    await _serialize(() async {
      final MariaDbConnection? connection = _connection;
      _connection = null;
      if (connection != null) {
        await connection.close();
      }
      config = next;
      _currentDatabase = next.database;
      _serverVersion = null;
    });
  }

  /// Real server variables used by the dashboard.
  Future<Map<String, String>> serverStatus() async {
    final MariaDbBatch batch = await query("SHOW GLOBAL STATUS LIKE 'Uptime'");
    final MariaDbResult? uptime = batch.last;
    final Map<String, String> values = <String, String>{};
    for (final List<String?> row in uptime?.rows ?? const <List<String?>>[]) {
      if (row.length >= 2) {
        values[row[0] ?? ''] = row[1] ?? '';
      }
    }
    final MariaDbBatch version = await query('SELECT VERSION() AS version');
    final List<String?>? row =
        version.last?.rows.isNotEmpty == true ? version.last!.rows.first : null;
    if (row != null && row.isNotEmpty) {
      _serverVersion = row.first;
      values['version'] = row.first ?? '';
    }
    final MariaDbBatch threads =
        await query("SHOW STATUS LIKE 'Threads_connected'");
    for (final List<String?> item
        in threads.last?.rows ?? const <List<String?>>[]) {
      if (item.length >= 2) {
        values[item[0] ?? ''] = item[1] ?? '';
      }
    }
    return values;
  }
}
