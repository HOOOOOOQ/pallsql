import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pallsql/features/shell/home_shell.dart';
import 'package:pallsql/features/startup/pallsql_splash.dart';
import 'package:pallsql/features/startup/startup_gate.dart';
import 'package:pallsql/services/app_bootstrap.dart';

import 'support/test_bootstrap.dart';

/// Every text on screen, used in failure reasons so CI logs stay diagnosable.
String _screenText(WidgetTester tester) => tester
    .widgetList<Text>(find.byType(Text))
    .map((Text text) => text.data ?? '')
    .where((String value) => value.isNotEmpty)
    .join(' | ');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the loading screen shows the brand, tagline and current step',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: PallsqlSplashScreen(
          step: 'SQLite engine ready',
          progress: 0.5,
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('PALLSQL'), findsOneWidget);
    expect(find.text('Mobile Development Environment'), findsOneWidget);
    expect(find.text('Initializing local environment'), findsOneWidget);
    expect(find.text('SQLite engine ready'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the failure screen offers a working Retry button',
      (WidgetTester tester) async {
    int retries = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: StartupFailureScreen(
          message: 'The workspace could not be prepared.',
          detail: 'FileSystemException: read-only file system',
          onRetry: () => retries++,
        ),
      ),
    );

    expect(find.text('PALLSQL could not start'), findsOneWidget);
    expect(find.textContaining('read-only'), findsOneWidget);
    await tester.tap(find.text('Retry'));
    await tester.pump();
    expect(retries, 1);
  });

  testWidgets('the gate boots the workspace and opens the dashboard',
      (WidgetTester tester) async {
    // Real file I/O has to run outside the fake async zone of a widget test.
    final AppBootstrap bootstrap = (await tester.runAsync(createTestBootstrap))!;
    addTearDown(() async {
      await tester.runAsync(() => disposeTestBootstrap(bootstrap));
    });

    // A pending future is what the splash is for: the real bootstrap is slow,
    // so the gate must show the loading screen until it resolves.
    final Completer<AppBootstrap> pending = Completer<AppBootstrap>();
    await tester.pumpWidget(
      StartupGate(
        timeout: const Duration(seconds: 10),
        createBootstrap: (void Function(String step) onProgress) {
          onProgress('Workspace folders ready');
          onProgress('SQLite engine ready');
          return pending.future;
        },
      ),
    );
    await tester.pump();
    expect(find.byType(PallsqlSplashScreen), findsOneWidget,
        reason: 'DEBUG screen: ${_screenText(tester)}');
    expect(find.text('SQLite engine ready'), findsOneWidget);

    pending.complete(bootstrap);

    for (int i = 0; i < 24; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 40));
    }

    expect(find.byType(HomeShell), findsOneWidget,
        reason: 'DEBUG screen: ${_screenText(tester)}');
    expect(find.text('Home'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a failed boot shows the error instead of an endless spinner',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      StartupGate(
        timeout: const Duration(seconds: 10),
        createBootstrap: (void Function(String step) onProgress) async {
          throw StateError('disk is full');
        },
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));

    expect(find.byType(PallsqlSplashScreen), findsNothing);
    expect(find.text('PALLSQL could not start'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    expect(find.textContaining('disk is full'), findsOneWidget);
  });
}
