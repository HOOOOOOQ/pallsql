import 'package:flutter_test/flutter_test.dart';
import 'package:pallsql/core/utils/sql_utils.dart';

void main() {
  group('splitStatements', () {
    test('splits simple scripts', () {
      final List<SqlStatement> statements =
          SqlUtils.splitStatements('SELECT 1; SELECT 2;');
      expect(statements, hasLength(2));
      expect(statements.first.keyword, 'SELECT');
      expect(statements.last.keyword, 'SELECT');
    });

    test('keeps semicolons inside string literals', () {
      final List<SqlStatement> statements =
          SqlUtils.splitStatements("INSERT INTO t VALUES ('a;b');");
      expect(statements, hasLength(1));
      expect(statements.single.sql, contains("'a;b'"));
    });

    test('handles escaped quotes', () {
      final List<SqlStatement> statements = SqlUtils.splitStatements(
        "INSERT INTO t VALUES ('O''Brien; still inside');",
      );
      expect(statements, hasLength(1));
    });

    test('ignores line and block comments', () {
      final List<SqlStatement> statements = SqlUtils.splitStatements('''
-- a comment; with a semicolon
SELECT 1;
/* block; comment */
SELECT 2;
''');
      expect(statements, hasLength(2));
      expect(statements.first.keyword, 'SELECT');
    });

    test('drops empty statements', () {
      expect(SqlUtils.splitStatements('   ;;  \n'), isEmpty);
      expect(SqlUtils.splitStatements('-- only a comment'), isEmpty);
    });

    test('classifies statements', () {
      expect(SqlUtils.classify('SELECT * FROM t').kind, SqlStatementKind.query);
      expect(SqlUtils.classify('WITH x AS (SELECT 1) SELECT * FROM x').kind,
          SqlStatementKind.query);
      expect(SqlUtils.classify('INSERT INTO t VALUES (1)').kind,
          SqlStatementKind.mutation);
      expect(SqlUtils.classify('create table t (id integer)').kind,
          SqlStatementKind.ddl);
      expect(SqlUtils.classify('PRAGMA table_info(t)').kind,
          SqlStatementKind.pragma);
      expect(SqlUtils.classify('BEGIN').kind, SqlStatementKind.transaction);
      expect(SqlUtils.classify('ATTACH DATABASE x').kind,
          SqlStatementKind.forbidden);
      expect(SqlUtils.classify('VACUUM').kind, SqlStatementKind.ddl);
    });

    test('detects destructive statements', () {
      expect(SqlUtils.isDestructive('DROP TABLE t'), isTrue);
      expect(SqlUtils.isDestructive('DELETE FROM t'), isTrue);
      expect(SqlUtils.isDestructive('DELETE FROM t WHERE id = 1'), isFalse);
      expect(SqlUtils.isDestructive('UPDATE t SET a = 1'), isTrue);
      expect(
          SqlUtils.isDestructive('UPDATE t SET a = 1 WHERE id = 1'), isFalse);
      expect(
        SqlUtils.isDestructive('ALTER TABLE t DROP COLUMN a'),
        isTrue,
      );
      expect(SqlUtils.isDestructive('SELECT * FROM t'), isFalse);
    });

    test('finds forbidden statements', () {
      final List<SqlStatement> statements =
          SqlUtils.splitStatements('SELECT 1; ATTACH DATABASE x AS y;');
      expect(SqlUtils.findForbidden(statements), isNotNull);
      expect(
        SqlUtils.findForbidden(SqlUtils.splitStatements('SELECT 1')),
        isNull,
      );
    });

    test('describes statements for the UI', () {
      expect(
        SqlUtils.describe(SqlUtils.classify('SELECT 1')),
        'Query',
      );
    });
  });
}
