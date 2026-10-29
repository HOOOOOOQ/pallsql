import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pallsql/core/constants/app_info.dart';
import 'package:pallsql/core/theme/pallsql_theme.dart';
import 'package:pallsql/features/about/about_page.dart';
import 'package:pallsql/providers/app_providers.dart';
import 'package:pallsql/services/app_bootstrap.dart';

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

  testWidgets('the About page names the developer and links Instagram',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[bootstrapProvider.overrideWithValue(bootstrap)],
        child: MaterialApp(
          theme: PallSqlTheme.dark(),
          home: const AboutPage(),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('About'), findsOneWidget);
    expect(find.text('PALLSQL'), findsWidgets);
    expect(find.text('pallxXx'), findsOneWidget);
    expect(find.text('@pallemnih_'), findsOneWidget);
    expect(find.text(AppInfo.developerInstagramUrl), findsOneWidget);
    expect(find.text('Visit Instagram'), findsOneWidget);
    // A ListView only builds what is on screen, so the credits and the footer
    // are asserted after scrolling the way a user would.
    final Finder scrollable = find.byType(Scrollable).first;
    await tester.scrollUntilVisible(
      find.text('CREDITS AND LICENSES'),
      300,
      scrollable: scrollable,
    );
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.textContaining('MIT'), findsWidgets);
    expect(find.textContaining('Not bundled'), findsWidgets);

    await tester.scrollUntilVisible(
      find.text(AppInfo.copyright),
      300,
      scrollable: scrollable,
    );
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text(AppInfo.copyright), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the About page reports the real workspace path',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[bootstrapProvider.overrideWithValue(bootstrap)],
        child: MaterialApp(
          theme: PallSqlTheme.dark(),
          home: const AboutPage(),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text(bootstrap.workspace.rootPath), findsOneWidget);
  });
}
