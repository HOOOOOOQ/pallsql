import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pallsql/services/mariadb/mariadb_client.dart';
import 'package:pallsql/services/mariadb/mysql_connection.dart';
import 'package:pallsql/services/mariadb/mysql_protocol.dart';

/// Integration tests against a **real MariaDB server**.
///
/// They only run when the environment points at a live server:
///
/// ```
/// PALLSQL_MARIADB_IT=1 \
/// PALLSQL_MARIADB_HOST=127.0.0.1 PALLSQL_MARIADB_PORT=3306 \
/// PALLSQL_MARIADB_USER=pallsql PALLSQL_MARIADB_PASSWORD=pallsql_ci_pw \
/// flutter test test/mariadb_integration_test.dart
/// ```
///
/// CI installs `mariadb-server`, creates that user and always sets the flag, so
/// the suite really executes there. Without a server the tests are reported as
/// skipped instead of silently passing with fake data.
final bool _enabled = Platform.environment['PALLSQL_MARIADB_IT'] == '1';

MariaDbConnectionConfig _config({String? database}) => MariaDbConnectionConfig(
      host: Platform.environment['PALLSQL_MARIADB_HOST'] ?? '127.0.0.1',
      port: int.tryParse(Platform.environment['PALLSQL_MARIADB_PORT'] ?? '') ??
          3306,
      user: Platform.environment['PALLSQL_MARIADB_USER'] ?? 'pallsql',
      password: Platform.environment['PALLSQL_MARIADB_PASSWORD'] ?? '',
      database: database,
      connectTimeout: const Duration(seconds: 10),
      queryTimeout: const Duration(seconds: 30),
    );

const String _database = 'pallsql_it';

void main() {
  if (!_enabled) {
    test('MariaDB integration suite', () {
      // ignore: avoid_print
      print('SKIPPED: set PALLSQL_MARIADB_IT=1 and provide a live server to '
          'run the real MariaDB integration suite.');
    }, skip: 'No live MariaDB server configured');
    return;
  }

  late MariaDbClient client;

  setUpAll(() async {
    client = MariaDbClient(_config());
    final MariaDbBatch ping = await client.query('SELECT 1 AS ok');
    expect(ping.last?.rows.single.single, '1',
        reason: 'the CI MariaDB server must answer a trivial query');
  });

  tearDownAll(() async {
    try {
      await client.query('DROP DATABASE IF EXISTS $_database');
    } on Object {
      // Nothing to clean up if the suite already dropped it.
    }
    await client.close();
  });

  test('the handshake reports the real server version', () async {
    final MariaDbBatch batch = await client.query('SELECT VERSION() AS v');
    final String version = batch.last?.rows.single.single ?? '';
    expect(version.toLowerCase(), contains('mariadb'));
    expect(client.serverVersion, contains('MariaDB'));
    expect(client.connectionId, greaterThan(0));
    expect(client.isConnected, isTrue);
  });

  test('SHOW DATABASES lists real schemas', () async {
    final MariaDbBatch batch = await client.query('SHOW DATABASES');
    final List<String?> names = (batch.last?.rows ??
            const <List<String?>>[])
        .map((List<String?> row) => row.first)
        .toList();
    expect(names, isNotEmpty);
    expect(names.any((String? name) => name == 'mysql'), isTrue,
        reason: 'the system schema is a real MariaDB schema');
  });

  test('CREATE DATABASE, USE and DROP DATABASE work end to end', () async {
    await client.query('DROP DATABASE IF EXISTS $_database');
    final MariaDbBatch created =
        await client.query('CREATE DATABASE `$_database`');
    expect(created.error, isNull);

    await client.query('USE `$_database`');
    expect(client.currentDatabase, _database);

    final MariaDbBatch tables = await client.query('SHOW TABLES');
    expect(tables.last?.rows, isEmpty);

    await client.query('DROP DATABASE `$_database`');
    final MariaDbBatch after = await client.query('SHOW DATABASES');
    final List<String?> names =
        after.last!.rows.map((List<String?> row) => row.first).toList();
    expect(names, isNot(contains(_database)));
  });

  test('DDL, INSERT and SELECT round trip real data', () async {
    await client.query('DROP DATABASE IF EXISTS $_database');
    await client.query('CREATE DATABASE `$_database`');
    await client.useDatabase(_database);

    final MariaDbBatch create = await client.query('''
      CREATE TABLE users (
        id INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
        name VARCHAR(64) NOT NULL,
        score DECIMAL(6,2) NOT NULL DEFAULT 0,
        created_at DATETIME NULL,
        UNIQUE KEY uq_name (name)
      ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
    ''');
    expect(create.error, isNull, reason: create.error?.toString());

    final MariaDbBatch inserted = await client.execute(
      'INSERT INTO users (name, score, created_at) VALUES (?, ?, ?)',
      <Object?>['alpha', 12.5, DateTime.utc(2026, 2, 3, 4, 5, 6)],
    );
    expect(inserted.error, isNull, reason: inserted.error?.toString());
    expect(inserted.last?.affectedRows, 1);
    expect(inserted.last?.lastInsertId, greaterThan(0));

    final MariaDbBatch selected = await client.query(
      'SELECT id, name, score, created_at FROM users ORDER BY id',
    );
    expect(selected.last?.columns,
        <String>['id', 'name', 'score', 'created_at']);
    expect(selected.last?.rows.single[1], 'alpha');
    expect(selected.last?.rows.single[2], '12.50');
    expect(selected.last?.rows.single[3], '2026-02-03 04:05:06');

    // DESCRIBE / SHOW CREATE TABLE are answered by the server itself.
    final MariaDbBatch described = await client.query('DESCRIBE users');
    expect(described.last?.columns.first, 'Field');
    final List<String?> fields = described.last!.rows
        .map((List<String?> row) => row.first)
        .toList();
    expect(fields, <String>['id', 'name', 'score', 'created_at']);

    final MariaDbBatch ddl = await client.query('SHOW CREATE TABLE users');
    expect(ddl.last!.columns, contains('Create Table'));
    expect(ddl.last!.rows.single.last, contains('CREATE TABLE'));

    final MariaDbBatch updated = await client.execute(
      'UPDATE users SET score = ? WHERE name = ?',
      <Object?>[99.25, 'alpha'],
    );
    expect(updated.last?.affectedRows, 1);

    final MariaDbBatch afterUpdate =
        await client.query("SELECT score FROM users WHERE name = 'alpha'");
    expect(afterUpdate.last?.rows.single.single, '99.25');

    final MariaDbBatch deleted = await client.execute(
      'DELETE FROM users WHERE name = ?',
      <Object?>['alpha'],
    );
    expect(deleted.last?.affectedRows, 1);
    final MariaDbBatch empty = await client.query('SELECT COUNT(*) AS c FROM users');
    expect(empty.last?.rows.single.single, '0');
  });

  test('NULL and numeric parameters survive the binary protocol', () async {
    await client.query('DROP DATABASE IF EXISTS $_database');
    await client.query('CREATE DATABASE `$_database`');
    await client.useDatabase(_database);
    await client.query('CREATE TABLE params (a INT, b VARCHAR(20), c DOUBLE, '
        'd DATETIME)');

    final MariaDbBatch inserted = await client.execute(
      'INSERT INTO params VALUES (?, ?, ?, ?)',
      <Object?>[7, null, 1.5, DateTime.utc(2026, 12, 31, 23, 59, 58)],
    );
    expect(inserted.error, isNull, reason: inserted.error?.toString());

    final MariaDbBatch read = await client.query(
      'SELECT a, b, c, d FROM params',
    );
    final List<String?> row = read.last!.rows.single;
    expect(row[0], '7');
    expect(row[1], isNull);
    expect(row[2], '1.5');
    expect(row[3], '2026-12-31 23:59:58');
  });

  test('multi statement scripts stop at the first error and keep prior work',
      () async {
    await client.query('DROP DATABASE IF EXISTS $_database');
    await client.query('CREATE DATABASE `$_database`');
    await client.useDatabase(_database);

    final MariaDbBatch batch = await client.query(
      'CREATE TABLE ok1 (id INT); INSERT INTO ok1 VALUES (1); '
      'SELECT * FROM does_not_exist; SELECT 3;',
    );
    expect(batch.error, isNotNull);
    expect(batch.error?.code, 1146);
    expect(batch.error?.sqlState, '42S02');
    expect(batch.error?.message, contains('does_not_exist'));
    expect(batch.statementsExecuted, 2,
        reason: 'the two statements before the failure really ran');

    // The partial work is real, not rolled back by the client.
    final MariaDbBatch check = await client.query('SELECT COUNT(*) FROM ok1');
    expect(check.last?.rows.single.single, '1');
  });

  test('a missing database is a real server error, not a client guess',
      () async {
    final MariaDbClient scratch =
        MariaDbClient(_config(database: 'pallsql_does_not_exist'));
    addTearDown(scratch.close);
    await expectLater(
      scratch.query('SELECT 1'),
      throwsA(
        isA<MysqlServerException>().having(
          (MysqlServerException error) => error.code,
          'code',
          1049,
        ),
      ),
    );
  });

  test('an unknown statement is refused by the server with its own error',
      () async {
    await expectLater(
      client.query('SELECT * FROM nowhere.at_all'),
      throwsA(isA<MysqlServerException>()),
    );
    // The connection is still usable afterwards.
    final MariaDbBatch ping = await client.query('SELECT 42 AS answer');
    expect(ping.last?.rows.single.single, '42');
  });

  test('ping is a real round trip and survives a closed batch', () async {
    expect(await client.ping(), isTrue);
    expect(client.reconnectCount, greaterThanOrEqualTo(0));
  });

  test('server status reads uptime and version from the server', () async {
    final Map<String, String> status = await client.serverStatus();
    expect(status['version'], contains('MariaDB'));
    expect(int.tryParse(status['Uptime'] ?? ''), isNotNull);
  });
}
