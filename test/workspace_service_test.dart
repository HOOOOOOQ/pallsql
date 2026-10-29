import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pallsql/core/errors/app_failure.dart';
import 'package:pallsql/services/workspace_service.dart';

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('pallsql_workspace_');
  });

  tearDown(() async {
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  });

  test('creates the folder tree and a landing page', () async {
    final Workspace workspace = await Workspace.open(root);

    for (final Directory folder in <Directory>[
      workspace.htdocs,
      workspace.projects,
      workspace.database,
      workspace.backups,
      workspace.logs,
      workspace.config,
      workspace.tmp,
      workspace.extensions,
      workspace.terminal,
      workspace.phpConfig,
      workspace.serverConfig,
      workspace.queries,
    ]) {
      expect(await folder.exists(), isTrue, reason: folder.path);
    }

    final File index = File('${workspace.htdocs.path}/index.html');
    expect(await index.exists(), isTrue);
    final String html = await index.readAsString();
    expect(html, contains('<title>PALLSQL Local Server</title>'));
    expect(html, contains('Your local server is running'));
    expect(html, contains('PALLSQL/htdocs/index.html'));
    expect(html, contains('name="viewport"'));
    expect(html.toLowerCase(), contains('<!doctype html>'));
    // Dark surface with the soft green accent of the 0.2 palette.
    expect(html, contains('#101311'));
    expect(html, contains('#9bcb91'));
    expect(html.toLowerCase(), contains('offline'));
  });

  test('never overwrites an edited landing page', () async {
    final File index = File('${root.path}/htdocs/index.html');
    await index.parent.create(recursive: true);
    await index.writeAsString('<h1>my own page</h1>');

    final Workspace workspace = await Workspace.open(root);

    expect(await index.readAsString(), '<h1>my own page</h1>');
    expect(await workspace.htdocs.exists(), isTrue);
  });

  test('exposes workspace relative paths through the path guard', () async {
    final Workspace workspace = await Workspace.open(root);
    expect(workspace.pathOf('htdocs'), '${root.path}/htdocs');
    expect(workspace.locationLabel, workspace.rootPath);
    expect(
      () => workspace.pathOf('../escape'),
      throwsA(isA<PathSecurityFailure>()),
    );
  });

  test('resolves the document root from the active project', () async {
    final Workspace workspace = await Workspace.open(root);
    expect(
      (await workspace.resolveDocumentRoot('')).path,
      workspace.htdocs.path,
    );
    expect(
      (await workspace.resolveDocumentRoot('__htdocs__')).path,
      workspace.htdocs.path,
    );
    // A project that does not exist falls back to htdocs instead of failing.
    expect(
      (await workspace.resolveDocumentRoot('missing-project')).path,
      workspace.htdocs.path,
    );
  });
}
