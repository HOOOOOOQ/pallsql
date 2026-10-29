import '../core/utils/sql_utils.dart';

/// A metadata statement written in MySQL/MariaDB syntax.
enum SqlCompatibilityKind {
  showDatabases,
  showTables,
  describeTable,
  showColumns,
  showCreateTable,
  showIndexes,
  selectVersion,
  selectDatabase,

  /// Recognised MySQL syntax that PALLSQL deliberately refuses.
  unsupported,
}

/// Result of recognising a MySQL-style statement.
class SqlCompatibilityCommand {
  const SqlCompatibilityCommand({
    required this.kind,
    required this.original,
    this.table,
    this.database,
    this.token = '',
  });

  final SqlCompatibilityKind kind;

  /// The statement exactly as the user typed it.
  final String original;

  /// Table the statement refers to, unquoted.
  final String? table;

  /// Database the statement refers to, unquoted (`SHOW TABLES FROM x`).
  final String? database;

  /// Leading MySQL keywords, used for the "not supported" explanation.
  final String token;
}

/// PALLSQL's SQLite ⇄ MySQL metadata bridge.
///
/// It only translates statements that can be answered from **real** SQLite
/// metadata (`sqlite_master`, `PRAGMA table_info`, `PRAGMA index_list`) plus the
/// real database list of the workspace. Anything else is refused with a message
/// that names the active dialect, the reason and a working alternative.
///
/// This is a metadata compatibility layer, **not** MySQL support: no MySQL data
/// types, no `AUTO_INCREMENT`, no storage engines, no `mysql` schema.
class SqlCompatibility {
  const SqlCompatibility._();

  /// Label shown in the SQL editor header.
  static String engineLabel(String version) {
    final String trimmed = version.trim();
    if (trimmed.isEmpty) {
      return 'SQLite — SQLite dialect';
    }
    return 'SQLite $trimmed — SQLite dialect';
  }

  static String databaseLabel(String name) => '$name.db';

  /// Recognises [sql] as a MySQL-style metadata statement.
  ///
  /// Returns `null` when the statement should be executed by SQLite as-is.
  static SqlCompatibilityCommand? parse(String sql) {
    final String normalised = _normalise(sql);
    if (normalised.isEmpty) {
      return null;
    }
    final String upper = normalised.toUpperCase();
    final List<String> tokens = _tokens(normalised);
    if (tokens.isEmpty) {
      return null;
    }
    final String head = tokens.first.toUpperCase();
    if (head == 'SHOW') {
      return _parseShow(normalised, tokens);
    }
    if (head == 'DESCRIBE' || head == 'DESC') {
      if (tokens.length < 2) {
        return SqlCompatibilityCommand(
          kind: SqlCompatibilityKind.unsupported,
          original: normalised,
          token: head,
        );
      }
      return SqlCompatibilityCommand(
        kind: SqlCompatibilityKind.describeTable,
        original: normalised,
        table: _identifier(tokens[1]),
      );
    }
    if (head == 'SELECT') {
      final String compact = upper.replaceAll(RegExp(r'\s+'), '');
      if (compact == 'SELECTVERSION()' ||
          compact == 'SELECT@@VERSION' ||
          compact == 'SELECT@@GLOBAL.VERSION') {
        return SqlCompatibilityCommand(
          kind: SqlCompatibilityKind.selectVersion,
          original: normalised,
        );
      }
      if (compact == 'SELECTDATABASE()' || compact == 'SELECTSCHEMA()') {
        return SqlCompatibilityCommand(
          kind: SqlCompatibilityKind.selectDatabase,
          original: normalised,
        );
      }
      return null;
    }
    const Set<String> mysqlOnly = <String>{
      'USE',
      'SET',
      'FLUSH',
      'GRANT',
      'REVOKE',
      'RENAME',
      'LOCK',
      'UNLOCK',
      'KILL',
      'RESET',
      'OPTIMIZE',
      'REPAIR',
      'CHECKSUM',
      'HANDLER',
      'LOAD',
      'CALL',
      'DELIMITER',
    };
    if (mysqlOnly.contains(head)) {
      return SqlCompatibilityCommand(
        kind: SqlCompatibilityKind.unsupported,
        original: normalised,
        token: head,
      );
    }
    if (upper.startsWith('CREATE DATABASE') ||
        upper.startsWith('CREATE SCHEMA') ||
        upper.startsWith('DROP DATABASE') ||
        upper.startsWith('DROP SCHEMA') ||
        upper.startsWith('SHOW')) {
      return SqlCompatibilityCommand(
        kind: SqlCompatibilityKind.unsupported,
        original: normalised,
        token: head,
      );
    }
    return null;
  }

  static SqlCompatibilityCommand _parseShow(
    String normalised,
    List<String> tokens,
  ) {
    final String subject = tokens.length > 1 ? tokens[1].toUpperCase() : '';
    switch (subject) {
      case 'DATABASES':
      case 'SCHEMAS':
        return SqlCompatibilityCommand(
          kind: SqlCompatibilityKind.showDatabases,
          original: normalised,
        );
      case 'TABLES':
        return SqlCompatibilityCommand(
          kind: SqlCompatibilityKind.showTables,
          original: normalised,
          database: _fromTarget(tokens),
        );
      case 'CREATE':
        if (tokens.length >= 3 && tokens[2].toUpperCase() == 'TABLE') {
          return SqlCompatibilityCommand(
            kind: SqlCompatibilityKind.showCreateTable,
            original: normalised,
            table: tokens.length > 3 ? _identifier(tokens[3]) : null,
          );
        }
        return SqlCompatibilityCommand(
          kind: SqlCompatibilityKind.unsupported,
          original: normalised,
          token: 'SHOW CREATE',
        );
      case 'COLUMNS':
      case 'FIELDS':
        return SqlCompatibilityCommand(
          kind: SqlCompatibilityKind.showColumns,
          original: normalised,
          table: _fromTarget(tokens),
        );
      case 'INDEX':
      case 'INDEXES':
      case 'KEYS':
        return SqlCompatibilityCommand(
          kind: SqlCompatibilityKind.showIndexes,
          original: normalised,
          table: _fromTarget(tokens),
        );
      default:
        return SqlCompatibilityCommand(
          kind: SqlCompatibilityKind.unsupported,
          original: normalised,
          token: subject.isEmpty ? 'SHOW' : 'SHOW $subject',
        );
    }
  }

  /// Finds the first `FROM x` / `IN x` target in [tokens].
  static String? _fromTarget(List<String> tokens) {
    for (int i = 2; i < tokens.length - 1; i++) {
      final String token = tokens[i].toUpperCase();
      if (token == 'FROM' || token == 'IN') {
        final String value = _identifier(tokens[i + 1]);
        if (value.isNotEmpty) {
          return value;
        }
      }
    }
    return null;
  }

  static String _identifier(String raw) {
    String value = raw.trim();
    while (value.isNotEmpty && (value.endsWith(',') || value.endsWith(';'))) {
      value = value.substring(0, value.length - 1).trimRight();
    }
    if (value.length >= 2) {
      final String first = value[0];
      final String last = value[value.length - 1];
      if ((first == '`' && last == '`') ||
          (first == '"' && last == '"') ||
          (first == "'" && last == "'") ||
          (first == '[' && last == ']')) {
        value = value.substring(1, value.length - 1);
      }
    }
    return value.trim();
  }

  static List<String> _tokens(String sql) {
    return sql
        .split(RegExp(r'\s+'))
        .map((String token) => token.trim())
        .where((String token) => token.isNotEmpty)
        .toList(growable: false);
  }

  static String _normalise(String sql) {
    String value = SqlUtils.stripLeadingComments(sql).trim();
    while (value.endsWith(';')) {
      value = value.substring(0, value.length - 1).trimRight();
    }
    return value;
  }

  /// Explanation returned for statements PALLSQL cannot honour.
  static String unsupportedMessage({
    required String statement,
    required String engineVersion,
    String? token,
  }) {
    final String dialect = engineLabel(engineVersion);
    final String keyword = token == null || token.isEmpty ? statement : token;
    final StringBuffer buffer = StringBuffer()
      ..writeln('$keyword is MySQL/MariaDB syntax, not part of SQLite.')
      ..writeln('Active dialect: $dialect.')
      ..write('Nothing was executed, so no data changed.');
    return buffer.toString();
  }

  /// Suggested SQLite replacement, shown under an unsupported statement.
  static String? alternativeFor(SqlCompatibilityCommand command) {
    switch (command.kind) {
      case SqlCompatibilityKind.unsupported:
        final String token = command.token;
        if (token == 'USE') {
          return 'SQLite has one database per file: pick the database in the '
              'SQL editor, or use "use <name>" in the SQL console.';
        }
        if (token.startsWith('SET') || token == 'SET') {
          return 'Use PRAGMA instead, for example: PRAGMA foreign_keys = ON;';
        }
        if (token.contains('DATABASE') || token.contains('SCHEMA')) {
          return 'Create or delete a database with the buttons in the Database '
              'tab; SHOW DATABASES lists the existing files.';
        }
        return 'See "help sql" in the terminal for the statements PALLSQL can '
            'translate.';
      case SqlCompatibilityKind.showDatabases:
      case SqlCompatibilityKind.showTables:
      case SqlCompatibilityKind.describeTable:
      case SqlCompatibilityKind.showColumns:
      case SqlCompatibilityKind.showCreateTable:
      case SqlCompatibilityKind.showIndexes:
      case SqlCompatibilityKind.selectVersion:
      case SqlCompatibilityKind.selectDatabase:
        return null;
    }
  }
}
