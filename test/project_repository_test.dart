import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pallsql/models/project.dart';
import 'package:pallsql/repositories/project_repository.dart';
import 'package:pallsql/services/log_sink.dart';
import 'package:pallsql/services/workspace_service.dart';

void main() {
  late Directory root;
  late Workspace workspace;
  late ProjectRepository repository;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('pallsql_projects_');
    workspace = await Workspace.open(root);
    await workspace.ensureStructure();
    repository = ProjectRepository(
      workspace: workspace,
      logs: const NullLogSink(),
    );
  });

  tearDown(() async {
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  });

  test('creates a project with real files on disk', () async {
    final Project project = await repository.create(
      name: 'My Site',
      template: ProjectTemplate.staticSite,
      description: 'demo',
    );
    expect(project.name, 'My Site');
    expect(project.directory, isNotEmpty);

    final Directory directory = await repository.directoryOf(project);
    expect(directory.existsSync(), isTrue);
    expect(File('${directory.path}/index.html').existsSync(), isTrue);

    final List<Project> projects = await repository.load();
    expect(
      projects.map((Project item) => item.id),
      contains(project.id),
    );
  });

  test('rejects invalid names and keeps folder names unique', () async {
    await expectLater(
      repository.create(
          name: '../escape', template: ProjectTemplate.staticSite),
      throwsA(isA<Exception>()),
    );
    final Project first = await repository.create(
        name: 'Demo', template: ProjectTemplate.staticSite);
    final Project second = await repository.create(
        name: 'Demo', template: ProjectTemplate.staticSite);
    expect(second.directory, isNot(first.directory));
    expect(second.id, isNot(first.id));
  });

  test('every template ships real starter files', () async {
    for (final ProjectTemplate template in ProjectTemplate.values) {
      final Project project = await repository.create(
        name: 'T ${template.name}',
        template: template,
      );
      final Directory directory = await repository.directoryOf(project);
      final List<FileSystemEntity> entries = directory.listSync();
      expect(entries, isNotEmpty, reason: 'template ${template.name} is empty');
    }
  });

  test('duplicates and deletes a project', () async {
    final Project project = await repository.create(
        name: 'Base', template: ProjectTemplate.staticSite);
    final int before = (await repository.load()).length;
    final Project copy =
        await repository.duplicate(project, newName: 'Base copy');
    expect(copy.id, isNot(project.id));
    expect((await repository.load()).length, before + 1);

    await repository.delete(project);
    final List<Project> remaining = await repository.load();
    expect(remaining.map((Project item) => item.id), contains(copy.id));
    expect(
        remaining.map((Project item) => item.id), isNot(contains(project.id)));
    expect(
      Directory('${workspace.projects.path}/${project.directory}').existsSync(),
      isFalse,
    );
  });

  test('exports and imports a project archive', () async {
    final Project project = await repository.create(
      name: 'Round trip',
      template: ProjectTemplate.htmlForm,
    );
    final File archive = File('${root.path}/tmp/round-trip.zip');
    await repository.exportZip(project, archive);
    expect(archive.existsSync(), isTrue);

    final Project imported =
        await repository.importZip(archive, name: 'Imported');
    expect(imported.name, 'Imported');
    final Directory directory = await repository.directoryOf(imported);
    expect(directory.listSync(), isNotEmpty);
  });

  test('metadata survives a reload from projects.json', () async {
    final Project project = await repository.create(
      name: 'Persisted',
      template: ProjectTemplate.phpHello,
      description: 'kept',
    );
    final ProjectRepository reopened = ProjectRepository(
      workspace: workspace,
      logs: const NullLogSink(),
    );
    final List<Project> projects = await reopened.load();
    final Project loaded =
        projects.firstWhere((Project item) => item.id == project.id);
    expect(loaded.name, 'Persisted');
    expect(loaded.description, 'kept');
  });
}
