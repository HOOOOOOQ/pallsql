/// Coarse classification of a SQL statement.
enum SqlStatementKind {
  query,
  mutation,
  ddl,
  transaction,
  pragma,
  forbidden,
  unknown,
}

/// A single statement extracted from a script.
class SqlStatement {
  const SqlStatement(
      {required this.sql, required this.keyword, required this.kind});

  final String sql;
  final String keyword;
  final SqlStatementKind kind;

  bool get returnsRows =>
      kind == SqlStatementKind.query || kind == SqlStatementKind.pragma;

  @override
  String toString() => '$keyword (${kind.name}): $sql';
}

/// SQL parsing helpers used by the database layer and the SQL editor.
///
/// The splitter understands single/double quotes, backticks, brackets, line
/// comments (`--`) and block comments (`/* */`) so that scripts with semicolons
/// inside literals are handled correctly.
class SqlUtils {
  const SqlUtils._();

  static const Set<String> _queryKeywords = <String>{
    'SELECT',
    'WITH',
    'VALUES',
    'EXPLAIN',
  };

  static const Set<String> _pragmaKeywords = <String>{'PRAGMA'};

  static const Set<String> _mutationKeywords = <String>{
    'INSERT',
    'UPDATE',
    'DELETE',
    'REPLACE',
  };

  static const Set<String> _ddlKeywords = <String>{
    'CREATE',
    'DROP',
    'ALTER',
    'TRUNCATE',
    'VACUUM',
    'REINDEX',
    'ANALYZE',
    'ATTACH',
    'DETACH',
  };

  static const Set<String> _transactionKeywords = <String>{
    'BEGIN',
    'COMMIT',
    'END',
    'ROLLBACK',
    'SAVEPOINT',
    'RELEASE',
  };

  static const Set<String> _forbiddenKeywords = <String>{'ATTACH', 'DETACH'};

  /// Splits a script into executable statements.
  static List<SqlStatement> splitStatements(String script) {
    final List<SqlStatement> statements = <SqlStatement>[];
    final StringBuffer current = StringBuffer();
    String state = 'normal';
    String closingQuote = '';
    for (int i = 0; i < script.length; i++) {
      final String char = script[i];
      final String next = i + 1 < script.length ? script[i + 1] : '';
      if (state == 'normal') {
        if (char == '-' && next == '-') {
          state = 'lineComment';
          current.write(char);
          continue;
        }
        if (char == '/' && next == '*') {
          state = 'blockComment';
          current.write(char);
          continue;
        }
        if (char == "'" || char == '"' || char == '`' || char == '[') {
          state = 'quoted';
          closingQuote = char == '[' ? ']' : char;
          current.write(char);
          continue;
        }
        if (char == ';') {
          _flush(current, statements);
          continue;
        }
        current.write(char);
        continue;
      }
      if (state == 'lineComment') {
        current.write(char);
        if (char == '\n') {
          state = 'normal';
        }
        continue;
      }
      if (state == 'blockComment') {
        current.write(char);
        if (char == '*' && next == '/') {
          current.write(next);
          i++;
          state = 'normal';
        }
        continue;
      }
      // state == 'quoted'
      current.write(char);
      if (char == closingQuote) {
        if (next == closingQuote && closingQuote != ']') {
          // SQL escapes a quote by doubling it; stay inside the literal.
          current.write(next);
          i++;
        } else {
          state = 'normal';
          closingQuote = '';
        }
      }
    }
    _flush(current, statements);
    return statements;
  }

  static void _flush(StringBuffer buffer, List<SqlStatement> target) {
    final String raw = buffer.toString();
    buffer.clear();
    final String trimmed = stripLeadingComments(raw).trim();
    if (trimmed.isEmpty) {
      return;
    }
    if (trimmed == ';') {
      return;
    }
    target.add(classify(trimmed));
  }

  /// Removes leading whitespace and comments without touching the payload.
  static String stripLeadingComments(String sql) {
    String remaining = sql;
    while (true) {
      final String trimmed = remaining.trimLeft();
      if (trimmed.startsWith('--')) {
        final int newline = trimmed.indexOf('\n');
        if (newline < 0) {
          return '';
        }
        remaining = trimmed.substring(newline + 1);
        continue;
      }
      if (trimmed.startsWith('/*')) {
        final int end = trimmed.indexOf('*/');
        if (end < 0) {
          return '';
        }
        remaining = trimmed.substring(end + 2);
        continue;
      }
      // Also drop statements that are only comments in the middle.
      return trimmed;
    }
  }

  static String leadingKeyword(String sql) {
    final String cleaned = stripLeadingComments(sql);
    final RegExpMatch? match = RegExp(r'^[A-Za-z]+').firstMatch(cleaned);
    return match?.group(0)?.toUpperCase() ?? '';
  }

  static SqlStatement classify(String sql) {
    final String keyword = leadingKeyword(sql);
    SqlStatementKind kind;
    if (_forbiddenKeywords.contains(keyword)) {
      kind = SqlStatementKind.forbidden;
    } else if (_queryKeywords.contains(keyword)) {
      kind = SqlStatementKind.query;
    } else if (_pragmaKeywords.contains(keyword)) {
      kind = SqlStatementKind.pragma;
    } else if (_mutationKeywords.contains(keyword)) {
      kind = SqlStatementKind.mutation;
    } else if (_ddlKeywords.contains(keyword)) {
      kind = SqlStatementKind.ddl;
    } else if (_transactionKeywords.contains(keyword)) {
      kind = SqlStatementKind.transaction;
    } else {
      kind = SqlStatementKind.unknown;
    }
    return SqlStatement(sql: sql, keyword: keyword, kind: kind);
  }

  /// Statements that can destroy data and therefore need confirmation.
  static bool isDestructive(String sql) {
    final String keyword = leadingKeyword(sql);
    final String upper = sql.toUpperCase();
    if (keyword == 'DROP' || keyword == 'TRUNCATE') {
      return true;
    }
    if (keyword == 'ALTER' && upper.contains('DROP')) {
      return true;
    }
    if (keyword == 'DELETE') {
      return !_containsWhereClause(sql);
    }
    if (keyword == 'UPDATE') {
      return !_containsWhereClause(sql);
    }
    return false;
  }

  static bool _containsWhereClause(String sql) {
    final RegExpMatch? match =
        RegExp(r'\bWHERE\b', caseSensitive: false).firstMatch(sql);
    if (match == null) {
      return false;
    }
    // A WHERE clause followed by nothing is not protective either.
    final String tail = sql.substring(match.end).trim();
    return tail.isNotEmpty && tail != ';';
  }

  /// The PALLSQL sandbox refuses ATTACH/DETACH so a script cannot escape the
  /// workspace directory.
  static SqlStatement? findForbidden(List<SqlStatement> statements) {
    for (final SqlStatement statement in statements) {
      if (statement.kind == SqlStatementKind.forbidden) {
        return statement;
      }
    }
    return null;
  }

  static const Set<String> _keywords = <String>{
    'SELECT',
    'FROM',
    'WHERE',
    'GROUP',
    'BY',
    'ORDER',
    'HAVING',
    'LIMIT',
    'OFFSET',
    'INSERT',
    'INTO',
    'VALUES',
    'UPDATE',
    'SET',
    'DELETE',
    'CREATE',
    'TABLE',
    'VIEW',
    'INDEX',
    'UNIQUE',
    'DROP',
    'ALTER',
    'ADD',
    'COLUMN',
    'RENAME',
    'TO',
    'PRIMARY',
    'KEY',
    'FOREIGN',
    'REFERENCES',
    'NOT',
    'NULL',
    'DEFAULT',
    'AUTOINCREMENT',
    'AS',
    'AND',
    'OR',
    'ON',
    'JOIN',
    'LEFT',
    'RIGHT',
    'INNER',
    'OUTER',
    'CROSS',
    'USING',
    'IN',
    'IS',
    'LIKE',
    'GLOB',
    'BETWEEN',
    'EXISTS',
    'CASE',
    'WHEN',
    'THEN',
    'ELSE',
    'END',
    'DISTINCT',
    'UNION',
    'ALL',
    'EXCEPT',
    'INTERSECT',
    'ASC',
    'DESC',
    'WITH',
    'RECURSIVE',
    'PRAGMA',
    'BEGIN',
    'COMMIT',
    'ROLLBACK',
    'TRANSACTION',
    'SAVEPOINT',
    'RELEASE',
    'EXPLAIN',
    'QUERY',
    'PLAN',
    'IF',
    'INTEGER',
    'TEXT',
    'REAL',
    'BLOB',
    'NUMERIC',
    'VARCHAR',
    'CHAR',
    'BOOLEAN',
    'DATE',
    'DATETIME',
    'CHECK',
    'COLLATE',
    'CAST',
    'COUNT',
    'SUM',
    'AVG',
    'MIN',
    'MAX',
  };

  /// Words that start a new line in formatted SQL.
  static const Set<String> _clauseWords = <String>{
    'SELECT',
    'FROM',
    'WHERE',
    'HAVING',
    'LIMIT',
    'OFFSET',
    'VALUES',
    'SET',
    'UNION',
    'EXCEPT',
    'INTERSECT',
    'JOIN',
  };

  /// Light, deterministic SQL formatter used by the editor's Format button.
  ///
  /// It only normalises keyword casing, whitespace and clause line breaks. It
  /// never changes the meaning of a statement: string literals, quoted
  /// identifiers and comments are copied verbatim.
  static String format(String sql) {
    final List<SqlStatement> statements = splitStatements(sql);
    if (statements.isEmpty) {
      return sql.trim();
    }
    final List<String> formatted = statements
        .map((SqlStatement statement) => _formatStatement(statement.sql))
        .where((String value) => value.isNotEmpty)
        .toList(growable: false);
    if (formatted.isEmpty) {
      return sql.trim();
    }
    return '${formatted.join(';\n\n')};';
  }

  static String _formatStatement(String sql) {
    final StringBuffer out = StringBuffer();
    final StringBuffer word = StringBuffer();
    bool single = false;
    bool doubleQuote = false;
    bool backtick = false;
    bool lineComment = false;
    bool blockComment = false;
    int depth = 0;

    void flushWord() {
      if (word.isEmpty) {
        return;
      }
      final String raw = word.toString();
      word.clear();
      final String upper = raw.toUpperCase();
      if (depth == 0 && _clauseWords.contains(upper)) {
        final String trimmed = out.toString().trimRight();
        out
          ..clear()
          ..write(trimmed);
        if (trimmed.isNotEmpty) {
          out.write('\n');
        }
        out.write(upper);
        return;
      }
      out.write(_keywords.contains(upper) ? upper : raw);
    }

    for (int i = 0; i < sql.length; i++) {
      final String char = sql[i];
      final String next = i + 1 < sql.length ? sql[i + 1] : '';
      if (lineComment) {
        out.write(char);
        if (char == '\n') {
          lineComment = false;
        }
        continue;
      }
      if (blockComment) {
        out.write(char);
        if (char == '*' && next == '/') {
          out.write(next);
          i++;
          blockComment = false;
        }
        continue;
      }
      if (single || doubleQuote || backtick) {
        out.write(char);
        if (single && char == "'") {
          if (next == "'") {
            out.write(next);
            i++;
          } else {
            single = false;
          }
        } else if (doubleQuote && char == '"') {
          if (next == '"') {
            out.write(next);
            i++;
          } else {
            doubleQuote = false;
          }
        } else if (backtick && char == '`') {
          backtick = false;
        }
        continue;
      }
      if (char == '-' && next == '-') {
        flushWord();
        out.write('--');
        i++;
        lineComment = true;
        continue;
      }
      if (char == '/' && next == '*') {
        flushWord();
        out.write('/*');
        i++;
        blockComment = true;
        continue;
      }
      if (char == "'") {
        flushWord();
        single = true;
        out.write(char);
        continue;
      }
      if (char == '"') {
        flushWord();
        doubleQuote = true;
        out.write(char);
        continue;
      }
      if (char == '`') {
        flushWord();
        backtick = true;
        out.write(char);
        continue;
      }
      if (char == '(') {
        flushWord();
        depth++;
        out.write(char);
        continue;
      }
      if (char == ')') {
        flushWord();
        if (depth > 0) {
          depth--;
        }
        out.write(char);
        continue;
      }
      if (char == ',') {
        flushWord();
        out.write(',');
        out.write(depth == 0 ? '\n  ' : ' ');
        continue;
      }
      if (char.trim().isEmpty) {
        flushWord();
        final String current = out.toString();
        if (current.isNotEmpty &&
            !current.endsWith(' ') &&
            !current.endsWith('\n')) {
          out.write(' ');
        }
        continue;
      }
      word.write(char);
    }
    flushWord();
    final List<String> lines = out
        .toString()
        .split('\n')
        .map((String line) => line.trimRight())
        .toList(growable: false);
    return lines.join('\n').trim();
  }

  /// Pretty label shown in the query results header.
  static String describe(SqlStatement statement) {
    switch (statement.kind) {
      case SqlStatementKind.query:
        return 'Query';
      case SqlStatementKind.mutation:
        return 'Modification';
      case SqlStatementKind.ddl:
        return 'Schema change';
      case SqlStatementKind.transaction:
        return 'Transaction';
      case SqlStatementKind.pragma:
        return 'Pragma';
      case SqlStatementKind.forbidden:
        return 'Refused';
      case SqlStatementKind.unknown:
        return statement.keyword.isEmpty ? 'Statement' : statement.keyword;
    }
  }
}
