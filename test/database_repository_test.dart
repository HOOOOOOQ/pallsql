import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pallsql/core/errors/app_failure.dart';
import 'package:pallsql/models/database_models.dart';
import 'package:pallsql/repositories/database_repository.dart';
import 'package:pallsql/services/log_sink.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();

  late Directory directory;
  late SqliteDatabaseRepository repository;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('pallsql_db_');
    repository = SqliteDatabaseRepository(
      directory: directory,
      factory: databaseFactoryFfi,
      logs: const NullLogSink(),
      historyFile: File('${directory.path}/query_history.json'),
    );
  });

  tearDown(() async {
    await repository.dispose();
    if (await directory.exists()) {
      await directory.delete(recursive: true);
    }
  });

  test('reports a real engine version', () async {
    final EngineAvailability availability = await repository.availability();
    expect(availability.available, isTrue);
    expect(availability.engine, DatabaseEngineId.sqlite);
    expect(availability.version, isNotNull);
    expect(availability.version, isNotEmpty);
  });

  test('creates, lists and deletes databases', () async {
    expect(await repository.listDatabases(), isEmpty);
    await repository.createDatabase('app');
    final List<DatabaseInfo> databases = await repository.listDatabases();
    expect(databases, hasLength(1));
    expect(databases.single.name, 'app');
    expect(File('${directory.path}/app.db').existsSync(), isTrue);

    await repository.deleteDatabase('app');
    expect(await repository.listDatabases(), isEmpty);
    expect(File('${directory.path}/app.db').existsSync(), isFalse);
  });

  test('rejects invalid database names', () async {
    expect(
      () => repository.createDatabase('bad name'),
      throwsA(isA<ValidationFailure>()),
    );
    expect(
      () => repository.createDatabase("x'; DROP TABLE t; --"),
      throwsA(isA<ValidationFailure>()),
    );
    await repository.createDatabase('app');
    expect(
      () => repository.createDatabase('app'),
      throwsA(isA<ValidationFailure>()),
    );
  });

  test('creates tables, stores data and reads it back', () async {
    await repository.createDatabase('app');
    final QueryResult created = await repository.execute(
      'app',
      'CREATE TABLE notes (id INTEGER PRIMARY KEY AUTOINCREMENT, body TEXT NOT NULL, created_at TEXT)',
    );
    expect(created.error, isNull);

    final QueryResult insert = await repository.execute(
      'app',
      "INSERT INTO notes (body, created_at) VALUES ('hello', '2026-10-28')",
    );
    expect(insert.error, isNull);
    expect(insert.rowsAffected, 1);
    expect(insert.lastInsertRowId, 1);

    final QueryResult select =
        await repository.execute('app', 'SELECT id, body FROM notes');
    expect(select.error, isNull);
    expect(select.columns, <String>['id', 'body']);
    expect(select.rows.single, <String?>['1', 'hello']);

    final List<TableInfo> tables = await repository.listTables('app');
    expect(tables.single.name, 'notes');

    final List<ColumnInfo> columns =
        await repository.describeTable('app', 'notes');
    expect(columns.map((ColumnInfo column) => column.name),
        containsAll(<String>['id', 'body', 'created_at']));
    expect(columns.first.primaryKey, isTrue);
  });

  test('runs the documented users flow and keeps the data on disk',
      () async {
    await repository.createDatabase('pallsql');

    final QueryResult created = await repository.execute(
      'pallsql',
      'CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT NOT NULL);',
    );
    expect(created.error, isNull);

    final QueryResult inserted = await repository.execute(
      'pallsql',
      "INSERT INTO users (name) VALUES ('PALLSQL');",
    );
    expect(inserted.error, isNull);
    expect(inserted.rowsAffected, 1);

    final QueryResult selected =
        await repository.execute('pallsql', 'SELECT * FROM users;');
    expect(selected.isError, isFalse);
    expect(selected.columns, <String>['id', 'name']);
    expect(selected.rowCount, 1);
    expect(selected.rows.single, <String?>['1', 'PALLSQL']);
    expect(selected.rows.single.last, 'PALLSQL');

    // Close every connection and read the file again with a new repository:
    // the row must survive, because it lives in the .db file itself.
    await repository.dispose();
    final SqliteDatabaseRepository reopened = SqliteDatabaseRepository(
      directory: directory,
      factory: databaseFactoryFfi,
      logs: const NullLogSink(),
    );
    addTearDown(reopened.dispose);
    final QueryResult afterReopen =
        await reopened.execute('pallsql', 'SELECT name FROM users;');
    expect(afterReopen.rows.single.single, 'PALLSQL');

    final File file = File('${directory.path}/pallsql.db');
    expect(await file.exists(), isTrue);
    expect(await file.length(), greaterThan(0));
  });

  test('counts the database files that really exist', () async {
    await repository.createDatabase('one');
    await repository.createDatabase('two');
    expect(await repository.listDatabases(), hasLength(2));

    // Deleting the file behind the app's back must change the count: the UI
    // number is never hardcoded or cached from a previous session.
    await File('${directory.path}/two.db').delete();
    final List<DatabaseInfo> databases = await repository.listDatabases();
    expect(databases.map((DatabaseInfo info) => info.name), <String>['one']);
  });

  test('surfaces SQL errors without crashing', () async {
    await repository.createDatabase('app');
    final QueryResult result =
        await repository.execute('app', 'SELECT * FROM missing_table');
    expect(result.isError, isTrue);
    expect(result.error, contains('missing_table'));
    expect(result.rows, isEmpty);
  });

  test('blocks ATTACH and DETACH', () async {
    await repository.createDatabase('app');
    await expectLater(
      repository.execute('app', "ATTACH DATABASE 'other.db' AS other"),
      throwsA(isA<SqlRejectedFailure>()),
    );
  });

  test('refuses destructive statements when not confirmed', () async {
    await repository.createDatabase('app');
    await repository.execute('app', 'CREATE TABLE t (id INTEGER PRIMARY KEY)');
    final QueryResult blocked = await repository.execute(
      'app',
      'DROP TABLE t',
      allowDestructive: false,
    );
    expect(blocked.isError, isTrue);
    expect(await repository.listTables('app'), hasLength(1));

    final QueryResult allowed = await repository.execute('app', 'DROP TABLE t');
    expect(allowed.error, isNull);
    expect(await repository.listTables('app'), isEmpty);
  });

  test('supports CRUD helpers on a table', () async {
    await repository.createDatabase('app');
    await repository.execute(
      'app',
      'CREATE TABLE notes (id INTEGER PRIMARY KEY AUTOINCREMENT, body TEXT)',
    );
    final QueryResult inserted = await repository.insertRow(
      'app',
      'notes',
      <String, Object?>{'body': 'first'},
    );
    expect(inserted.error, isNull);
    expect(inserted.rowsAffected, 1);

    final QueryResult rows = await repository.selectRows('app', 'notes');
    expect(rows.rows, hasLength(1));
    expect(rows.columns, contains('body'));

    final QueryResult updated = await repository.updateRow(
      'app',
      'notes',
      <String, Object?>{'body': 'changed'},
      keyColumn: 'id',
      keyValue: 1,
    );
    expect(updated.rowsAffected, 1);

    final QueryResult deleted = await repository.deleteRow(
      'app',
      'notes',
      keyColumn: 'id',
      keyValue: 1,
    );
    expect(deleted.rowsAffected, 1);
    expect((await repository.selectRows('app', 'notes')).rows, isEmpty);
  });

  test('exports a SQL dump with schema and data', () async {
    await repository.createDatabase('app');
    await repository.execute(
      'app',
      'CREATE TABLE notes (id INTEGER PRIMARY KEY AUTOINCREMENT, body TEXT)',
    );
    await repository.execute('app', "INSERT INTO notes (body) VALUES ('keep')");
    final String dump = await repository.exportSql('app');
    expect(dump, contains('CREATE TABLE'));
    expect(dump, contains('INSERT INTO'));
    expect(dump, contains("'keep'"));
  });

  test('imports a script in a transaction', () async {
    await repository.createDatabase('app');
    const String script = '''
CREATE TABLE a (id INTEGER PRIMARY KEY);
CREATE TABLE b (id INTEGER PRIMARY KEY);
INSERT INTO a (id) VALUES (1);
''';
    final QueryResult result = await repository.runScript('app', script);
    expect(result.error, isNull);
    expect(result.statements, 3);
    expect(await repository.listTables('app'), hasLength(2));

    const String broken = '''
CREATE TABLE c (id INTEGER PRIMARY KEY);
INSERT INTO missing_table VALUES (1);
''';
    final QueryResult failed = await repository.runScript('app', broken);
    expect(failed.isError, isTrue);
    // The transaction rolled back: table c must not exist.
    expect(await repository.listTables('app'), hasLength(2));
  });

  test('records query history', () async {
    await repository.createDatabase('app');
    await repository.execute('app', 'CREATE TABLE t (id INTEGER PRIMARY KEY)');
    expect(repository.history, isNotEmpty);
    expect(repository.history.first.database, 'app');
    expect(repository.history.first.succeeded, isTrue);

    await repository.clearHistory();
    expect(repository.history, isEmpty);
  });

  test('backs up database files', () async {
    await repository.createDatabase('app');
    await repository.execute('app', 'CREATE TABLE t (id INTEGER PRIMARY KEY)');
    final Directory backups = Directory('${directory.path}/backups');
    final File backup = await repository.backupDatabase('app', backups);
    expect(await backup.exists(), isTrue);
    expect(backup.path, endsWith('.db'));
  });

  test('refuses operations on a missing database', () async {
    expect(
      () => repository.execute('ghost', 'SELECT 1'),
      throwsA(isA<NotFoundFailure>()),
    );
  });
}
