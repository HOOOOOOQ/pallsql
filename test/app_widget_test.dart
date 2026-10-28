import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pallsql/app.dart';
import 'package:pallsql/models/service_status.dart';
import 'package:pallsql/providers/app_providers.dart';
import 'package:pallsql/services/app_bootstrap.dart';
import 'package:pallsql/widgets/pallsql_card.dart';

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

    await tester.tap(find.byIcon(Icons.dns_rounded).last);
    for (int i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.text('Servers'), findsWidgets);
    expect(tester.takeException(), isNull);
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
