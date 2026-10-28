import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pallsql/core/errors/app_failure.dart';
import 'package:pallsql/models/file_entry.dart';
import 'package:pallsql/repositories/file_repository.dart';
import 'package:pallsql/services/log_sink.dart';
import 'package:pallsql/services/workspace_service.dart';

void main() {
  late Directory root;
  late Workspace workspace;
  late FileRepository files;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('pallsql_files_');
    workspace = await Workspace.open(root);
    files = FileRepository(workspace: workspace, logs: const NullLogSink());
  });

  tearDown(() async {
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  });

  test('lists the workspace root with stable sorting', () async {
    final List<FileEntry> entries = await files.list('');
    expect(entries, isNotEmpty);
    final List<String> names =
        entries.map((FileEntry entry) => entry.name).toList();
    expect(names, contains('htdocs'));
    final List<String> sorted = List<String>.of(names)..sort();
    expect(names, sorted);

    final List<FileEntry> descending =
        await files.list('', order: FileSortOrder.nameDesc);
    expect(descending.first.name, names.last);
  });

  test('hides dotfiles unless asked', () async {
    await files.createFile('htdocs', '.env', content: 'SECRET=1');
    final List<FileEntry> hidden =
        await files.list('htdocs', showHidden: false);
    expect(hidden.map((FileEntry entry) => entry.name), isNot(contains('.env')));
    final List<FileEntry> all = await files.list('htdocs', showHidden: true);
    expect(all.map((FileEntry entry) => entry.name), contains('.env'));
  });

  test('creates folders and files, then reads and writes text', () async {
    await files.createDirectory('htdocs', 'assets');
    final FileEntry file =
        await files.createFile('htdocs/assets', 'notes.txt', content: 'one');
    expect(file.isEditable, isTrue);
    expect(file.extension, 'txt');

    await files.writeText('htdocs/assets/notes.txt', 'two');
    expect(await files.readText('htdocs/assets/notes.txt'), 'two');
  });

  test('refuses unsafe names and paths', () async {
    await expectLater(
      files.createFile('htdocs', '../escape.txt'),
      throwsA(isA<AppFailure>()),
    );
    await expectLater(
      files.createDirectory('..', 'outside'),
      throwsA(isA<AppFailure>()),
    );
    await expectLater(
      files.readText('../../etc/passwd'),
      throwsA(isA<AppFailure>()),
    );
    await expectLater(
      files.list('/etc'),
      throwsA(isA<AppFailure>()),
    );
  });

  test('renames, copies, moves and deletes', () async {
    await files.createFile('htdocs', 'a.txt', content: 'alpha');
    await files.rename('htdocs/a.txt', 'b.txt');
    expect(await files.exists('htdocs/a.txt'), isFalse);
    expect(await files.readText('htdocs/b.txt'), 'alpha');

    await files.copy('htdocs/b.txt', 'htdocs/c.txt');
    expect(await files.readText('htdocs/c.txt'), 'alpha');

    await files.createDirectory('htdocs', 'dest');
    await files.move('htdocs/c.txt', 'htdocs/dest/c.txt');
    expect(await files.exists('htdocs/dest/c.txt'), isTrue);

    await files.delete('htdocs/dest');
    expect(await files.exists('htdocs/dest'), isFalse);
  });

  test('searches by name inside the sandbox', () async {
    await files.createFile('htdocs', 'contact.html', content: 'x');
    await files.createFile('htdocs', 'about.html', content: 'y');
    final List<FileEntry> results = await files.search('contact');
    expect(results.map((FileEntry entry) => entry.name), contains('contact.html'));
    expect(results.map((FileEntry entry) => entry.name),
        isNot(contains('about.html')));
  });

  test('reports size and pretty printed metadata', () async {
    await files.createFile('htdocs', 'big.txt', content: 'x' * 2048);
    final FileEntry entry = await files.stat('htdocs/big.txt');
    expect(entry.sizeBytes, 2048);
    expect(entry.displaySize, contains('KB'));
    expect(entry.relativePath, 'htdocs/big.txt');
  });

  test('refuses to read binary or oversized files as text', () async {
    final File binary = File('${root.path}/htdocs/image.bin');
    await binary.writeAsBytes(<int>[0xff, 0xfe, 0x00, 0x01]);
    await expectLater(
      files.readText('htdocs/image.bin'),
      throwsA(isA<ValidationFailure>()),
    );
    await expectLater(
      files.readText('htdocs/big.txt', maxBytes: 10),
      throwsA(isA<ValidationFailure>()),
    );
  });
}
