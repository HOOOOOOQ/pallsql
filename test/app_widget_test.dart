import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pallsql/app.dart';
import 'package:pallsql/core/theme/pallsql_theme.dart';
import 'package:pallsql/features/dashboard/dashboard_page.dart';
import 'package:pallsql/features/database/database_page.dart';
import 'package:pallsql/features/database/sql_editor_page.dart';
import 'package:pallsql/features/files/files_page.dart';
import 'package:pallsql/features/servers/servers_page.dart';
import 'package:pallsql/features/settings/settings_page.dart';
import 'package:pallsql/models/service_status.dart';
import 'package:pallsql/providers/app_providers.dart';
import 'package:pallsql/services/app_bootstrap.dart';
import 'package:pallsql/widgets/pallsql_bottom_navigation.dart';
import 'package:pallsql/widgets/pallsql_card.dart';

import 'support/test_bootstrap.dart';

/// Renders a captured layout error (including the offending widget location)
/// into a single readable string so CI annotations point at the real culprit.
String describeLayoutError(FlutterErrorDetails details) {
  final StringBuffer buffer = StringBuffer(details.exceptionAsString());
  final Iterable<DiagnosticsNode> info =
      details.informationCollector?.call() ?? const <DiagnosticsNode>[];
  for (final DiagnosticsNode node in info) {
    buffer
      ..writeln()
      ..writeln(node.toStringDeep().trim());
  }
  return buffer.toString();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppBootstrap bootstrap;

  setUp(() async {
    bootstrap = await createTestBootstrap();
  });

  tearDown(() async {
    await disposeTestBootstrap(bootstrap);
  });

  Future<void> pumpApp(WidgetTester tester, {int tab = 0}) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[bootstrapProvider.overrideWithValue(bootstrap)],
        child: PallSqlApp(initialTab: tab),
      ),
    );
    // Give the async providers (PHP probe, database availability) a chance to
    // resolve without waiting for an indefinite settle.
    for (int i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  testWidgets('app opens on the dashboard with the bottom navigation',
      (WidgetTester tester) async {
    await pumpApp(tester);

    expect(find.text('PALLSQL'), findsWidgets);
    expect(find.text('Home'), findsWidgets);
    expect(find.text('Servers'), findsWidgets);
    expect(find.text('Database'), findsWidgets);
    expect(find.text('Files'), findsWidgets);
    expect(find.text('Settings'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('tapping a destination switches the visible tab',
      (WidgetTester tester) async {
    await pumpApp(tester);

    final Finder serversTab = find.descendant(
      of: find.byType(PallSQLBottomNavigation),
      matching: find.byIcon(Icons.dns_rounded),
    );
    expect(serversTab, findsOneWidget);
    await tester.tap(serversTab);
    await tester.pump();
    final Object? exception = tester.takeException();
    expect(exception, isNull, reason: 'switching tabs raised: $exception');
    expect(
      tester.widget<IndexedStack>(find.byType(IndexedStack)).index,
      1,
      reason: 'the Servers tab should be selected',
    );
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull);
    expect(find.text('Servers'), findsWidgets);
  });

  testWidgets('dashboard shows the real stopped state, not a fake runtime',
      (WidgetTester tester) async {
    await pumpApp(tester);

    final Finder stateChips = find.byWidgetPredicate(
      (Widget widget) => widget is PallSqlPill,
    );
    expect(stateChips, findsWidgets);

    final ProviderContainer container = ProviderScope.containerOf(
      tester.element(find.byType(Scaffold).first),
    );
    expect(container.read(webServerProvider).state, ServiceState.stopped);
    expect(
      container.read(phpRuntimeProvider).valueOrNull?.available ?? false,
      isFalse,
    );
  });

  testWidgets('every tab renders on a phone sized surface without overflow',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    final List<FlutterErrorDetails> errors = <FlutterErrorDetails>[];
    final void Function(FlutterErrorDetails)? previousHandler =
        FlutterError.onError;
    FlutterError.onError = errors.add;
    addTearDown(() => FlutterError.onError = previousHandler);

    for (int tab = 0; tab < 5; tab++) {
      errors.clear();
      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[bootstrapProvider.overrideWithValue(bootstrap)],
          child: PallSqlApp(initialTab: tab),
        ),
      );
      for (int i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(
        errors,
        isEmpty,
        reason: 'tab $tab rendered badly on a 360x780 logical surface\n'
            '${errors.map(describeLayoutError).join('\n---\n')}',
      );
    }
  });

  testWidgets('each screen lays out on a phone sized surface',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    final List<FlutterErrorDetails> errors = <FlutterErrorDetails>[];
    final void Function(FlutterErrorDetails)? previousHandler =
        FlutterError.onError;
    FlutterError.onError = errors.add;
    addTearDown(() => FlutterError.onError = previousHandler);

    final Map<String, Widget> screens = <String, Widget>{
      'dashboard': const DashboardPage(),
      'servers': const ServersPage(),
      'database': const DatabasePage(),
      'files': const FilesPage(),
      'settings': const SettingsPage(),
      'sql editor': const SqlEditorPage(),
    };

    for (final MapEntry<String, Widget> entry in screens.entries) {
      errors.clear();
      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[bootstrapProvider.overrideWithValue(bootstrap)],
          child: MaterialApp(theme: PallSqlTheme.dark(), home: entry.value),
        ),
      );
      for (int i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(
        errors,
        isEmpty,
        reason: 'the ${entry.key} screen overflowed on a 360x780 surface\n'
            '${errors.map(describeLayoutError).join('\n---\n')}',
      );
    }
  });

  testWidgets('workspace folders exist after bootstrap',
      (WidgetTester tester) async {
    await pumpApp(tester);
    final Directory root = bootstrap.workspace.root;
    for (final String folder in <String>[
      'htdocs',
      'projects',
      'database',
      'backups',
      'logs',
      'config',
      'tmp',
    ]) {
      expect(
        Directory('${root.path}/$folder').existsSync(),
        isTrue,
        reason: 'missing $folder',
      );
    }
    expect(File('${root.path}/htdocs/index.html').existsSync(), isTrue);
  });
}
