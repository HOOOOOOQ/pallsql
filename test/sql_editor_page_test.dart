import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pallsql/core/theme/pallsql_theme.dart';
import 'package:pallsql/features/database/database_page.dart';
import 'package:pallsql/features/database/sql_editor_page.dart';
import 'package:pallsql/models/database_models.dart';
import 'package:pallsql/providers/app_providers.dart';
import 'package:pallsql/services/app_bootstrap.dart';
import 'package:pallsql/widgets/query_result_view.dart';

import 'support/test_bootstrap.dart';

/// Every text on screen, used in failure reasons so CI logs stay diagnosable.
String _screenText(WidgetTester tester) => tester
    .widgetList<Text>(find.byType(Text))
    .map((Text text) => text.data ?? '')
    .where((String value) => value.isNotEmpty)
    .join(' // ');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppBootstrap bootstrap;
  late String schema;

  setUp(() async {
    bootstrap = await createTestBootstrap();
    // MariaDB DDL is not rolled back, so every test owns a unique schema.
    schema = await createScratchSchema(bootstrap, 'pallsql_editor');
  });

  tearDown(() async {
    await dropScratchSchema(bootstrap, schema);
    await disposeTestBootstrap(bootstrap);
  });

  /// Alternates real async progress with frames so sqflite/file IO finishes
  /// inside a widget test without relying on `pumpAndSettle` (the app has
  /// indeterminate progress indicators that never settle).
  Future<void> settle(WidgetTester tester, {int rounds = 16}) async {
    for (int i = 0; i < rounds; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 15)),
      );
      await tester.pump(const Duration(milliseconds: 15));
    }
  }

  /// Pumps real async progress until [finder] matches, so a slow runner cannot
  /// turn a working query into a flaky failure.
  Future<void> waitFor(
    WidgetTester tester,
    Finder finder, {
    int rounds = 200,
  }) async {
    for (int i = 0; i < rounds && finder.evaluate().isEmpty; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 10));
    }
  }

  /// Lets Material snackbars expire so no timer outlives the test.
  Future<void> drainSnackBars(WidgetTester tester) async {
    for (int i = 0; i < 6; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
  }

  Future<void> pumpEditor(
    WidgetTester tester, {
    String? database,
    Widget? home,
  }) async {
    // A tall surface so the result card is laid out without scrolling.
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[bootstrapProvider.overrideWithValue(bootstrap)],
        child: MaterialApp(
          theme: PallSqlTheme.dark(),
          home: home ?? SqlEditorPage(initialDatabase: database),
        ),
      ),
    );
    await settle(tester);
  }

  testWidgets('opens the SQL editor without a database preselected',
      (WidgetTester tester) async {
    await pumpEditor(tester);

    expect(find.byType(SqlEditorPage), findsOneWidget);
    expect(find.text('SQL editor'), findsOneWidget);
    // The chooser is empty until the user picks a schema, and the page says so
    // instead of silently running against an arbitrary MariaDB schema.
    expect(find.text('Select a database'), findsOneWidget);
    expect(find.text('No database selected'), findsOneWidget);
    expect(find.text(schema), findsNothing);

    // Executing without a schema must be refused before any statement is sent.
    await tester.tap(find.text('Execute'));
    await settle(tester, rounds: 8);
    expect(find.text('Select a database first'), findsOneWidget);
    await drainSnackBars(tester);
    expect(tester.takeException(), isNull);
  });

  testWidgets('preselects the database it was opened with',
      (WidgetTester tester) async {
    await pumpEditor(tester, database: schema);

    expect(find.text('Running against $schema'), findsOneWidget);
    expect(find.text(schema), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('runs a SELECT and shows the stored row',
      (WidgetTester tester) async {
    await pumpEditor(tester, database: schema);

    await tester.enterText(
      find.byType(TextField),
      'CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT NOT NULL);\n'
      "INSERT INTO users (name) VALUES ('PALLSQL');\n"
      'SELECT * FROM users;',
    );
    await tester.pump();
    await tester.tap(find.text('Execute'));
    await waitFor(tester, find.byType(QueryResultView));

    expect(find.byType(QueryResultView), findsOneWidget,
        reason: 'DEBUG screen: ${_screenText(tester)}');
    expect(find.text('PALLSQL'), findsOneWidget,
        reason: 'DEBUG screen: ${_screenText(tester)}');
    expect(find.textContaining('1 row'), findsWidgets);
    expect(tester.takeException(), isNull);

    // The row must really be in the database, not only on screen.
    final QueryResult? persisted = await tester.runAsync(
      () => bootstrap.databases.execute(
        schema,
        'SELECT name FROM users;',
        recordHistory: false,
      ),
    );
    expect(persisted?.rows.single.single, 'PALLSQL');
  });

  testWidgets('reports an invalid statement without crashing',
      (WidgetTester tester) async {
    await pumpEditor(tester, database: schema);

    await tester.enterText(
      find.byType(TextField),
      'SELECT * FROM missing_table;',
    );
    await tester.pump();
    await tester.tap(find.text('Execute'));
    await settle(tester, rounds: 30);

    // The error is rendered inside the result card and repeated in a snackbar.
    expect(find.byType(QueryResultView), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (Widget widget) =>
            widget is SelectableText &&
            (widget.data ?? '').contains('missing_table'),
      ),
      findsOneWidget,
    );
    expect(find.textContaining('missing_table'), findsWidgets);
    expect(tester.takeException(), isNull);
    await drainSnackBars(tester);
  });

  testWidgets('rejects an empty statement', (WidgetTester tester) async {
    await pumpEditor(tester, database: schema);

    await tester.tap(find.text('Execute'));
    await settle(tester, rounds: 8);

    expect(find.text('Enter a SQL statement'), findsOneWidget);
    await drainSnackBars(tester);
  });

  testWidgets('records executed statements in the history',
      (WidgetTester tester) async {
    await pumpEditor(tester, database: schema);

    await tester.enterText(find.byType(TextField), 'SELECT 1 AS one;');
    await tester.pump();
    await tester.tap(find.text('Execute'));
    await settle(tester, rounds: 30);

    final ProviderContainer container = ProviderScope.containerOf(
      tester.element(find.byType(SqlEditorPage)),
    );
    final List<QueryHistoryEntry> history =
        container.read(queryHistoryProvider);
    expect(history, isNotEmpty);
    expect(history.first.sql, contains('SELECT 1'));
    expect(history.first.database, schema);
    expect(history.first.succeeded, isTrue);
    expect(find.byType(QueryResultView), findsOneWidget);
  });

  testWidgets('the Database tab opens the SQL editor from both entry points',
      (WidgetTester tester) async {
    await pumpEditor(tester, home: const DatabasePage());

    // Entry point 1: the app bar shortcut.
    await tester.tap(find.byTooltip('SQL editor'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await settle(tester);
    expect(find.byType(SqlEditorPage), findsOneWidget);
    expect(find.textContaining('Running against'), findsOneWidget);

    // Back to the Database tab, then entry point 2: the primary button.
    await tester.pageBack();
    await tester.pump(const Duration(milliseconds: 400));
    await settle(tester);
    expect(find.byType(DatabasePage), findsOneWidget);

    final Finder openButton = find.text('Open SQL editor');
    await tester.scrollUntilVisible(
      openButton,
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(openButton);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await settle(tester);

    expect(find.byType(SqlEditorPage), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a database created from the editor becomes selectable',
      (WidgetTester tester) async {
    final String created = 'pallsql_from_editor_'
        '${DateTime.now().microsecondsSinceEpoch % 100000000}';
    await pumpEditor(tester);

    // Without any schema the header offers the empty-state shortcut.
    await tester.scrollUntilVisible(
      find.text('New'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('New').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    await tester.enterText(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      ),
      created,
    );
    await tester.pump();
    await tester.tap(find.text('Create'));
    await settle(tester, rounds: 30);

    expect(find.text('Running against $created'), findsOneWidget);
    final List<String>? names = await tester.runAsync(() async {
      final List<DatabaseInfo> databases =
          await bootstrap.databases.listDatabases();
      return databases.map((DatabaseInfo info) => info.name).toList();
    });
    expect(names, contains(created));
    await drainSnackBars(tester);
    // Leave the server exactly as it was found.
    await tester.runAsync(
      () => bootstrap.databases.deleteDatabase(created),
    );
  });
}
