import 'dart:convert';

import '../core/errors/app_failure.dart';

/// Identifier of the database engine currently backing the UI.
enum DatabaseEngineId {
  sqlite,
  mariadb;

  String get label {
    switch (this) {
      case DatabaseEngineId.sqlite:
        return 'SQLite';
      case DatabaseEngineId.mariadb:
        return 'MariaDB';
    }
  }

  String get storageDescription {
    switch (this) {
      case DatabaseEngineId.sqlite:
        return 'Embedded file based SQL engine bundled with the app.';
      case DatabaseEngineId.mariadb:
        return 'Full MariaDB server; requires a native Android runtime.';
    }
  }
}

/// Availability of a database engine inside this build.
class EngineAvailability {
  const EngineAvailability({
    required this.engine,
    required this.available,
    this.version,
    this.reason,
  });

  final DatabaseEngineId engine;
  final bool available;
  final String? version;
  final String? reason;

  static EngineAvailability unavailable(
    DatabaseEngineId engine,
    String reason,
  ) =>
      EngineAvailability(engine: engine, available: false, reason: reason);
}

/// A database file (SQLite) managed by PALLSQL.
class DatabaseInfo {
  const DatabaseInfo({
    required this.name,
    required this.path,
    required this.sizeBytes,
    required this.modifiedAt,
    this.tableCount,
  });

  final String name;
  final String path;
  final int sizeBytes;
  final DateTime modifiedAt;
  final int? tableCount;

  DatabaseInfo copyWith(
      {int? tableCount, int? sizeBytes, DateTime? modifiedAt}) {
    return DatabaseInfo(
      name: name,
      path: path,
      sizeBytes: sizeBytes ?? this.sizeBytes,
      modifiedAt: modifiedAt ?? this.modifiedAt,
      tableCount: tableCount ?? this.tableCount,
    );
  }
}

/// A table or view discovered in a database.
class TableInfo {
  const TableInfo({
    required this.name,
    required this.type,
    this.rowCount,
  });

  final String name;

  /// `table` or `view`.
  final String type;
  final int? rowCount;

  bool get isView => type == 'view';
}

/// Column metadata from `PRAGMA table_info`.
class ColumnInfo {
  const ColumnInfo({
    required this.name,
    required this.type,
    required this.notNull,
    this.defaultValue,
    this.primaryKey = false,
  });

  final String name;
  final String type;
  final bool notNull;
  final String? defaultValue;
  final bool primaryKey;

  String get summary {
    final List<String> parts = <String>[
      if (type.isNotEmpty) type,
      if (primaryKey) 'PRIMARY KEY',
      if (notNull && !primaryKey) 'NOT NULL',
      if (defaultValue != null) 'DEFAULT $defaultValue',
    ];
    return parts.isEmpty ? '-' : parts.join(' ');
  }
}

/// Cooperative cancellation token for multi-statement scripts.
///
/// SQLite cannot interrupt a single running statement through sqflite, so
/// PALLSQL only offers Stop for scripts: the token is checked between
/// statements, which is a real (documented) boundary.
class SqlCancelToken {
  bool _cancelled = false;

  bool get isCancelled => _cancelled;

  void cancel() => _cancelled = true;

  void reset() => _cancelled = false;
}

/// Result of a SQL statement executed by the user.
class QueryResult {
  const QueryResult({
    required this.columns,
    required this.rows,
    required this.statements,
    required this.duration,
    this.rowsAffected = 0,
    this.lastInsertRowId,
    this.notices = const <String>[],
    this.error,
    this.cancelled = false,
    this.statementsExecuted = 0,
  });

  final List<String> columns;
  final List<List<String?>> rows;
  final int statements;
  final Duration duration;
  final int rowsAffected;
  final int? lastInsertRowId;
  final List<String> notices;
  final String? error;

  /// True when the user stopped the script between two statements.
  final bool cancelled;

  /// How many statements actually ran (equal to [statements] when complete).
  final int statementsExecuted;

  bool get hasResultSet => columns.isNotEmpty;
  bool get isEmpty => rows.isEmpty;
  bool get isError => error != null;

  int get rowCount => rows.length;

  Map<String, Object?> toJson() => <String, Object?>{
        'columns': columns,
        'rows': rows,
        'statements': statements,
        'durationMs': duration.inMilliseconds,
        'rowsAffected': rowsAffected,
        'lastInsertRowId': lastInsertRowId,
        'notices': notices,
        'error': error,
        'cancelled': cancelled,
        'statementsExecuted': statementsExecuted,
      };

  static QueryResult fromJson(Map<String, Object?> json) {
    final List<String> columns =
        (json['columns'] as List<Object?>? ?? <Object?>[])
            .map((Object? e) => e?.toString() ?? '')
            .toList();
    final List<List<String?>> rows = <List<String?>>[];
    final Object? rawRows = json['rows'];
    if (rawRows is List) {
      for (final Object? row in rawRows) {
        if (row is List) {
          rows.add(row.map((Object? cell) => cell?.toString()).toList());
        }
      }
    }
    return QueryResult(
      columns: columns,
      rows: rows,
      statements: (json['statements'] as num?)?.toInt() ?? 1,
      duration:
          Duration(milliseconds: (json['durationMs'] as num?)?.toInt() ?? 0),
      rowsAffected: (json['rowsAffected'] as num?)?.toInt() ?? 0,
      lastInsertRowId: (json['lastInsertRowId'] as num?)?.toInt(),
      notices: (json['notices'] as List<Object?>? ?? <Object?>[])
          .map((Object? e) => e?.toString() ?? '')
          .toList(),
      error: json['error']?.toString(),
      cancelled: json['cancelled'] == true,
      statementsExecuted:
          (json['statementsExecuted'] as num?)?.toInt() ?? 0,
    );
  }

  static QueryResult failure(String message, {Duration? duration}) =>
      QueryResult(
        columns: const <String>[],
        rows: const <List<String?>>[],
        statements: 0,
        duration: duration ?? Duration.zero,
        error: message,
      );
}

/// One entry of the SQL editor history.
class QueryHistoryEntry {
  const QueryHistoryEntry({
    required this.database,
    required this.sql,
    required this.executedAt,
    required this.succeeded,
    required this.durationMs,
  });

  final String database;
  final String sql;
  final DateTime executedAt;
  final bool succeeded;
  final int durationMs;

  Map<String, Object?> toJson() => <String, Object?>{
        'database': database,
        'sql': sql,
        'executedAt': executedAt.toIso8601String(),
        'succeeded': succeeded,
        'durationMs': durationMs,
      };

  static QueryHistoryEntry fromJson(Map<String, Object?> json) {
    return QueryHistoryEntry(
      database: json['database']?.toString() ?? '',
      sql: json['sql']?.toString() ?? '',
      executedAt: DateTime.tryParse(json['executedAt']?.toString() ?? '') ??
          DateTime.now(),
      succeeded: json['succeeded'] == true,
      durationMs: (json['durationMs'] as num?)?.toInt() ?? 0,
    );
  }

  static List<QueryHistoryEntry> decodeList(String raw) {
    if (raw.trim().isEmpty) {
      return const <QueryHistoryEntry>[];
    }
    final Object? decoded = jsonDecode(raw);
    if (decoded is! List) {
      return const <QueryHistoryEntry>[];
    }
    final List<QueryHistoryEntry> entries = <QueryHistoryEntry>[];
    for (final Object? item in decoded) {
      if (item is Map<String, Object?>) {
        entries.add(QueryHistoryEntry.fromJson(item));
      }
    }
    return entries;
  }

  static String encodeList(List<QueryHistoryEntry> entries) => jsonEncode(
        entries.map((QueryHistoryEntry e) => e.toJson()).toList(),
      );
}

/// Raised when a SQL statement is rejected by the PALLSQL safety layer.
class SqlRejectedFailure extends AppFailure {
  const SqlRejectedFailure(super.message, {super.details});
}
