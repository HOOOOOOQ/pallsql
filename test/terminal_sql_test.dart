import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pallsql/models/database_models.dart';
import 'package:pallsql/models/log_entry.dart';
import 'package:pallsql/providers/app_providers.dart';
import 'package:pallsql/services/app_bootstrap.dart';
import 'package:pallsql/services/terminal_service.dart';

import 'support/test_bootstrap.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppBootstrap bootstrap;
  late ProviderContainer container;

  setUp(() async {
    bootstrap = await createTestBootstrap();
    container = ProviderContainer(
      overrides: <Override>[bootstrapProvider.overrideWithValue(bootstrap)],
    );
  });

  tearDown(() async {
    container.dispose();
    await disposeTestBootstrap(bootstrap);
  });

  TerminalService service() => container.read(terminalServiceProvider);

  String text(TerminalResult result) =>
      result.lines.map((TerminalLine line) => line.text).join('\n');

  test('help lists the SQL console and hides nothing', () async {
    final TerminalResult result = await service().execute('help');
    final String output = text(result);
    expect(output, contains('sql'));
    expect(output, contains('no shell'));
  });

  test('unknown shell commands explain what to do next', () async {
    final TerminalResult result = await service().execute('rm -rf /');
    expect(result.lines.single.level, LogLevel.error);
    expect(result.lines.single.text, contains('Unknown command'));
    expect(result.lines.single.text, contains('sql'));
  });

  test('the sql command lists databases when none exists yet', () async {
    final TerminalResult result = await service().execute('sql');
    expect(text(result), contains('No databases yet'));
    expect(service().sqlMode, isFalse);
  });

  test('SQL console runs real statements against a real database', () async {
    final TerminalService terminal = service();
    final TerminalResult created =
        await terminal.execute('database create app');
    expect(text(created), contains('app.db'));

    final TerminalResult enter = await terminal.execute('sql app');
    expect(text(enter), contains('SQL console'));
    expect(terminal.sqlMode, isTrue);
    expect(terminal.prompt, 'sql(app)>');
    expect(terminal.currentDatabase, 'app');

    final TerminalResult create = await terminal.execute(
      'CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT NOT NULL);',
    );
    expect(text(create), isNot(contains('Error')));
    expect(text(create), contains('statement'));

    await terminal.execute("INSERT INTO users (name) VALUES ('pallxXx');");

    final TerminalResult select =
        await terminal.execute('SELECT * FROM users;');
    final String table = text(select);
    expect(table, contains('id'));
    expect(table, contains('name'));
    expect(table, contains('pallxXx'));
    expect(table, contains('1 row'));

    // The data really landed in the file, not only in the console.
    final QueryResult persisted = await bootstrap.databases.execute(
      'app',
      'SELECT name FROM users;',
      recordHistory: false,
    );
    expect(persisted.rows.single.single, 'pallxXx');
  });

  test('metadata commands are translated for the console', () async {
    final TerminalService terminal = service();
    await bootstrap.databases.createDatabase('app');
    await terminal.execute('sql app');
    await terminal.execute('CREATE TABLE users (id INTEGER PRIMARY KEY);');

    expect(text(await terminal.execute('SHOW TABLES;')), contains('users'));
    expect(text(await terminal.execute('DESCRIBE users;')), contains('Field'));
    expect(text(await terminal.execute('SHOW DATABASES;')), contains('app'));
    expect(text(await terminal.execute('SELECT VERSION();')), contains('3.'));

    // MySQL-only syntax is refused with an explanation.
    final TerminalResult refused = await terminal.execute('SHOW STATUS;');
    expect(refused.lines.first.level, LogLevel.error);
    expect(text(refused), contains('Active dialect'));
  });

  test('dot commands drive the console without leaving it', () async {
    final TerminalService terminal = service();
    await bootstrap.databases.createDatabase('app');
    await bootstrap.databases.createDatabase('other');
    await terminal.execute('sql app');

    expect(text(await terminal.execute('.databases')), contains('other'));
    expect(text(await terminal.execute('.use other')), contains('other'));
    expect(terminal.currentDatabase, 'other');
    expect(text(await terminal.execute('.help')), contains('.use'));
    expect(text(await terminal.execute('.nope')), contains('Unknown'));

    await terminal.execute('\\q');
    expect(terminal.sqlMode, isFalse);
    expect(terminal.prompt, '>');
  });

  test('destructive statements need an explicit .force on', () async {
    final TerminalService terminal = service();
    await bootstrap.databases.createDatabase('app');
    await terminal.execute('sql app');
    await terminal.execute(
      'CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT);',
    );
    await terminal.execute("INSERT INTO users (name) VALUES ('keep me');");

    final TerminalResult blocked = await terminal.execute('DELETE FROM users;');
    expect(blocked.lines.first.level, LogLevel.error);
    expect(text(blocked), contains('blocked'));

    final QueryResult stillThere = await bootstrap.databases.execute(
      'app',
      'SELECT COUNT(*) AS c FROM users;',
      recordHistory: false,
    );
    expect(stillThere.rows.single.single, '1');

    await terminal.execute('.force on');
    final TerminalResult forced = await terminal.execute('DELETE FROM users;');
    expect(text(forced).toLowerCase(), contains('row'));
    expect(text(forced), isNot(contains('blocked')));
  });

  test('tables, desc and database info use the selected database', () async {
    final TerminalService terminal = service();
    await bootstrap.databases.createDatabase('app');
    await terminal.execute('use app');
    await terminal.execute('sql app');
    await terminal.execute('CREATE TABLE items (id INTEGER PRIMARY KEY);');

    expect(text(await terminal.execute('.tables')), contains('items'));
    expect(text(await terminal.execute('desc items')), contains('Field'));
    expect(text(await terminal.execute('.read nope.sql')), contains('nope'));
  });

  test('the PALLSQL shell never fakes an engine', () async {
    final TerminalResult status = await service().execute('database status');
    final String output = text(status);
    expect(output, contains('SQLite'));
    expect(output.toLowerCase(), contains('not mysql/mariadb'));
  });
}
