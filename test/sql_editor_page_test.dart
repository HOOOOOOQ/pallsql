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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppBootstrap bootstrap;

  setUp(() async {
    bootstrap = await createTestBootstrap();
  });

  tearDown(() async {
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

  Future<void> createDatabase(WidgetTester tester, String name) async {
    await tester.runAsync(() => bootstrap.databases.createDatabase(name));
  }

  testWidgets('opens the SQL editor and asks for a database when there is none',
      (WidgetTester tester) async {
    await pumpEditor(tester);

    expect(find.byType(SqlEditorPage), findsOneWidget);
    expect(find.text('SQL editor'), findsOneWidget);
    expect(find.text('No databases yet'), findsOneWidget);
    expect(find.text('New database'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('preselects the database it was opened with',
      (WidgetTester tester) async {
    await createDatabase(tester, 'app');
    await pumpEditor(tester, database: 'app');

    expect(find.text('Running against app.db'), findsOneWidget);
    expect(find.text('app'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('runs a SELECT and shows the stored row',
      (WidgetTester tester) async {
    await createDatabase(tester, 'app');
    await pumpEditor(tester, database: 'app');

    await tester.enterText(
      find.byType(TextField),
      'CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT NOT NULL);\n'
      "INSERT INTO users (name) VALUES ('PALLSQL');\n"
      'SELECT * FROM users;',
    );
    await tester.pump();
    await tester.tap(find.text('Execute'));
    await settle(tester, rounds: 30);

    expect(find.text('PALLSQL'), findsOneWidget);
    expect(find.byType(QueryResultView), findsOneWidget);
    expect(find.textContaining('1 row'), findsWidgets);
    expect(tester.takeException(), isNull);

    // The row must really be in the database, not only on screen.
    final QueryResult? persisted = await tester.runAsync(
      () => bootstrap.databases.execute(
        'app',
        'SELECT name FROM users;',
        recordHistory: false,
      ),
    );
    expect(persisted?.rows.single.single, 'PALLSQL');
  });

  testWidgets('reports an invalid statement without crashing',
      (WidgetTester tester) async {
    await createDatabase(tester, 'app');
    await pumpEditor(tester, database: 'app');

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
    await createDatabase(tester, 'app');
    await pumpEditor(tester, database: 'app');

    await tester.tap(find.text('Execute'));
    await settle(tester, rounds: 8);

    expect(find.text('Enter a SQL statement'), findsOneWidget);
    await drainSnackBars(tester);
  });

  testWidgets('records executed statements in the history',
      (WidgetTester tester) async {
    await createDatabase(tester, 'app');
    await pumpEditor(tester, database: 'app');

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
    expect(history.first.database, 'app');
    expect(history.first.succeeded, isTrue);
    expect(find.byType(QueryResultView), findsOneWidget);
  });

  testWidgets('the Database tab opens the SQL editor from both entry points',
      (WidgetTester tester) async {
    await createDatabase(tester, 'app');
    await pumpEditor(tester, home: const DatabasePage());

    // Entry point 1: the app bar shortcut.
    await tester.tap(find.byTooltip('SQL editor'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await settle(tester);
    expect(find.byType(SqlEditorPage), findsOneWidget);
    expect(find.text('Running against app.db'), findsOneWidget);

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
    await pumpEditor(tester);

    await tester.tap(find.text('New database'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    await tester.enterText(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      ),
      'from_editor',
    );
    await tester.pump();
    await tester.tap(find.text('Create'));
    await settle(tester, rounds: 30);

    expect(find.text('Running against from_editor.db'), findsOneWidget);
    final List<String>? files = await tester.runAsync(() async {
      final List<DatabaseInfo> databases =
          await bootstrap.databases.listDatabases();
      return databases.map((DatabaseInfo info) => info.name).toList();
    });
    expect(files, contains('from_editor'));
    await drainSnackBars(tester);
  });
}
