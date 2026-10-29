import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pallsql/models/database_models.dart';
import 'package:pallsql/repositories/database_repository.dart';
import 'package:pallsql/services/log_sink.dart';
import 'package:pallsql/services/sql_compatibility.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();

  group('SqlCompatibility.parse', () {
    test('recognises the MySQL metadata statements', () {
      expect(SqlCompatibility.parse('SHOW DATABASES;')?.kind,
          SqlCompatibilityKind.showDatabases);
      expect(SqlCompatibility.parse('SHOW SCHEMAS')?.kind,
          SqlCompatibilityKind.showDatabases);
      expect(SqlCompatibility.parse('SHOW TABLES;')?.kind,
          SqlCompatibilityKind.showTables);
      expect(SqlCompatibility.parse('DESCRIBE `users`;')?.kind,
          SqlCompatibilityKind.describeTable);
      expect(SqlCompatibility.parse('DESC users')?.kind,
          SqlCompatibilityKind.describeTable);
      expect(SqlCompatibility.parse('SHOW COLUMNS FROM users')?.kind,
          SqlCompatibilityKind.showColumns);
      expect(SqlCompatibility.parse('SHOW CREATE TABLE users')?.kind,
          SqlCompatibilityKind.showCreateTable);
      expect(SqlCompatibility.parse('SHOW INDEX FROM users')?.kind,
          SqlCompatibilityKind.showIndexes);
      expect(SqlCompatibility.parse('SELECT VERSION();')?.kind,
          SqlCompatibilityKind.selectVersion);
      expect(SqlCompatibility.parse('SELECT DATABASE()')?.kind,
          SqlCompatibilityKind.selectDatabase);
    });

    test('extracts table and database names, quoted or not', () {
      expect(SqlCompatibility.parse('DESCRIBE "users";')?.table, 'users');
      expect(SqlCompatibility.parse('SHOW TABLES FROM app')?.database, 'app');
      expect(SqlCompatibility.parse('SHOW TABLES IN `app`')?.database, 'app');
      expect(SqlCompatibility.parse('SHOW CREATE TABLE [users]')?.table,
          'users');
      expect(SqlCompatibility.parse('-- note\nSHOW TABLES')?.kind,
          SqlCompatibilityKind.showTables);
    });

    test('leaves normal SQLite statements alone', () {
      expect(SqlCompatibility.parse('SELECT * FROM users;'), isNull);
      expect(SqlCompatibility.parse('PRAGMA table_info(users);'), isNull);
      expect(SqlCompatibility.parse('EXPLAIN QUERY PLAN SELECT 1;'), isNull);
      expect(
        SqlCompatibility.parse("INSERT INTO logs VALUES ('SHOW TABLES');"),
        isNull,
      );
      expect(SqlCompatibility.parse('CREATE TABLE t (id INTEGER);'), isNull);
    });

    test('flags MySQL-only statements as unsupported', () {
      expect(SqlCompatibility.parse('USE app;')?.kind,
          SqlCompatibilityKind.unsupported);
      expect(SqlCompatibility.parse('SET autocommit = 1;')?.kind,
          SqlCompatibilityKind.unsupported);
      expect(SqlCompatibility.parse('SHOW STATUS;')?.kind,
          SqlCompatibilityKind.unsupported);
      expect(SqlCompatibility.parse('FLUSH PRIVILEGES;')?.kind,
          SqlCompatibilityKind.unsupported);
    });

    test('the dialect label never claims to be MySQL', () {
      final String label = SqlCompatibility.engineLabel('3.45.0');
      expect(label, contains('SQLite'));
      expect(label, contains('3.45.0'));
      expect(label.toLowerCase(), contains('dialect'));
      expect(label.toLowerCase(), isNot(contains('mysql')));
    });

    test('unsupported statements explain dialect, reason and alternative', () {
      final SqlCompatibilityCommand command =
          SqlCompatibility.parse('SHOW VARIABLES;')!;
      final String message = SqlCompatibility.unsupportedMessage(
        statement: command.original,
        engineVersion: '3.45.0',
        token: command.token,
      );
      expect(message, contains('Active dialect'));
      expect(message, contains('SQLite'));
      expect(message, contains('not part of SQLite'));
      expect(SqlCompatibility.alternativeFor(command), isNotNull);
    });
  });

  group('SQLite + compatibility layer', () {
    late Directory directory;
    late SqliteDatabaseRepository repository;

    setUp(() async {
      directory = await Directory.systemTemp.createTemp('pallsql_compat_');
      repository = SqliteDatabaseRepository(
        directory: directory,
        factory: databaseFactoryFfi,
        logs: const NullLogSink(),
        historyFile: File('${directory.path}/query_history.json'),
      );
      await repository.createDatabase('app');
    });

    tearDown(() async {
      await repository.dispose();
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    });

    test('SHOW DATABASES lists the real workspace files', () async {
      await repository.createDatabase('second');
      final QueryResult result = await repository.execute(
        'app',
        'SHOW DATABASES;',
        recordHistory: false,
      );

      expect(result.error, isNull);
      expect(result.columns, <String>['Database']);
      final List<String?> names =
          result.rows.map((List<String?> row) => row.single).toList();
      expect(names, containsAll(<String>['app', 'second']));
    });

    test('SHOW TABLES and DESCRIBE read real SQLite metadata', () async {
      await repository.execute(
        'app',
        'CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT NOT NULL);',
        recordHistory: false,
      );

      final QueryResult tables = await repository.execute(
        'app',
        'SHOW TABLES;',
        recordHistory: false,
      );
      expect(tables.columns.single, 'Tables_in_app');
      expect(tables.rows.length, 1);
      expect(tables.rows.single.single, 'users');

      final QueryResult described = await repository.execute(
        'app',
        'DESCRIBE users;',
        recordHistory: false,
      );
      expect(described.columns,
          <String>['Field', 'Type', 'Null', 'Key', 'Default', 'Extra']);
      final List<String?> idRow = described.rows.first;
      expect(idRow[0], 'id');
      expect(idRow[1], 'INTEGER');
      expect(idRow[3], 'PRI');
      final List<String?> nameRow = described.rows[1];
      expect(nameRow[0], 'name');
      expect(nameRow[2], 'NO');
    });

    test('SHOW CREATE TABLE returns the stored DDL', () async {
      const String ddl =
          'CREATE TABLE notes (id INTEGER PRIMARY KEY, body TEXT)';
      await repository.execute('app', '$ddl;', recordHistory: false);

      final QueryResult result = await repository.execute(
        'app',
        'SHOW CREATE TABLE notes;',
        recordHistory: false,
      );
      expect(result.columns, <String>['Table', 'Create Table']);
      expect(result.rows.single.first, 'notes');
      expect(result.rows.single.last, contains('CREATE TABLE notes'));
      expect(result.rows.single.last, endsWith(';'));
    });

    test('SHOW INDEX reports indexes that really exist', () async {
      await repository.execute(
        'app',
        'CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT);',
        recordHistory: false,
      );
      final QueryResult before = await repository.execute(
        'app',
        'SHOW INDEX FROM users;',
        recordHistory: false,
      );
      expect(before.error, isNull);
      expect(before.columns.contains('Key_name'), isTrue);

      await repository.execute(
        'app',
        'CREATE INDEX idx_users_name ON users(name);',
        recordHistory: false,
      );
      final QueryResult after = await repository.execute(
        'app',
        'SHOW INDEX FROM users;',
        recordHistory: false,
      );
      final List<String> keys = after.rows
          .map((List<String?> row) => row[2] ?? '')
          .toList(growable: false);
      expect(keys, contains('idx_users_name'));
    });

    test('SELECT VERSION() reports the real SQLite version', () async {
      final QueryResult result = await repository.execute(
        'app',
        'SELECT VERSION();',
        recordHistory: false,
      );
      expect(result.error, isNull);
      expect(result.columns.single, 'VERSION()');
      final String version = result.rows.single.single ?? '';
      expect(RegExp(r'^\d+\.\d+').hasMatch(version), isTrue,
          reason: 'expected a real version, got "$version"');
      expect(result.notices.join(' ').toLowerCase(), contains('sqlite'));
    });

    test('SELECT DATABASE() returns the selected file', () async {
      final QueryResult result = await repository.execute(
        'app',
        'SELECT DATABASE();',
        recordHistory: false,
      );
      expect(result.rows.single.single, 'app');
    });

    test('unsupported statements fail with an explanation, not a fake row',
        () async {
      final QueryResult result = await repository.execute(
        'app',
        'USE other;',
        recordHistory: false,
      );
      expect(result.isError, isTrue);
      final String error = result.error ?? '';
      expect(error, contains('Active dialect'));
      expect(error, contains('SQLite'));
      expect(error, contains('MySQL'));
      expect(result.rows, isEmpty);
    });

    test('DESCRIBE of a missing table is a clear error', () async {
      final QueryResult result = await repository.execute(
        'app',
        'DESCRIBE missing;',
        recordHistory: false,
      );
      expect(result.isError, isTrue);
      expect(result.error, contains('missing'));
      expect(result.error, contains('does not exist'));
    });

    test('the cancel token stops a script between statements', () async {
      final SqlCancelToken token = SqlCancelToken()..cancel();
      final QueryResult result = await repository.execute(
        'app',
        'SELECT 1; SELECT 2; SELECT 3;',
        cancel: token,
        recordHistory: false,
      );
      expect(result.cancelled, isTrue);
      expect(result.statementsExecuted, 0);
      expect(result.error, isNull);
      expect(result.notices.join(' '), contains('Stopped by the user'));
    });
  });
}
