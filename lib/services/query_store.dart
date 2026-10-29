import 'dart:io';

import 'package:path/path.dart' as p;

import '../core/constants/app_info.dart';
import '../core/errors/app_failure.dart';
import '../core/utils/validators.dart';

/// A SQL snippet saved by the user.
class SavedQuery {
  const SavedQuery({
    required this.name,
    required this.sql,
    required this.modifiedAt,
    required this.sizeBytes,
  });

  /// Name without the `.sql` extension.
  final String name;
  final String sql;
  final DateTime modifiedAt;
  final int sizeBytes;

  String get fileName => '$name.sql';
}

/// Stores reusable SQL snippets as plain `.sql` files inside the workspace.
///
/// Using real files (instead of a private database) keeps the snippets visible
/// in the File Manager, exportable and diff-able, and they survive restarts.
class QueryStore {
  QueryStore(this.directory);

  final Directory directory;

  static const String extension = '.sql';

  String _pathFor(String name) =>
      p.join(directory.path, '${_cleanName(name)}$extension');

  static String _cleanName(String raw) {
    String name = raw.trim();
    if (name.toLowerCase().endsWith(extension)) {
      name = name.substring(0, name.length - extension.length);
    }
    final String? error = Validators.entryNameError(name);
    if (error != null) {
      throw ValidationFailure(error);
    }
    return name;
  }

  Future<List<SavedQuery>> list() async {
    if (!await directory.exists()) {
      return const <SavedQuery>[];
    }
    final List<SavedQuery> queries = <SavedQuery>[];
    try {
      await for (final FileSystemEntity entity
          in directory.list(followLinks: false)) {
        if (entity is! File ||
            p.extension(entity.path).toLowerCase() != extension) {
          continue;
        }
        final FileStat stat = await entity.stat();
        String sql = '';
        try {
          sql = await entity.readAsString();
        } on FileSystemException {
          continue;
        }
        queries.add(
          SavedQuery(
            name: p.basenameWithoutExtension(entity.path),
            sql: sql,
            modifiedAt: stat.modified,
            sizeBytes: stat.size,
          ),
        );
      }
    } on FileSystemException catch (error) {
      throw AppFailure('Could not read saved queries', details: error.message);
    }
    queries.sort(
      (SavedQuery a, SavedQuery b) => b.modifiedAt.compareTo(a.modifiedAt),
    );
    return queries;
  }

  Future<SavedQuery> save(String name, String sql) async {
    final String trimmed = sql.trim();
    if (trimmed.isEmpty) {
      throw const ValidationFailure('Nothing to save: the editor is empty');
    }
    if (trimmed.length > AppInfo.maxSqlScriptBytes) {
      throw const ValidationFailure('Query is too large to save');
    }
    final String clean = _cleanName(name);
    await directory.create(recursive: true);
    final File file = File(_pathFor(clean));
    await file.writeAsString('$trimmed\n', flush: true);
    final FileStat stat = await file.stat();
    await _prune();
    return SavedQuery(
      name: clean,
      sql: trimmed,
      modifiedAt: stat.modified,
      sizeBytes: stat.size,
    );
  }

  Future<String> read(String name) async {
    final File file = File(_pathFor(name));
    if (!await file.exists()) {
      throw NotFoundFailure('Saved query $name does not exist');
    }
    try {
      return await file.readAsString();
    } on FileSystemException catch (error) {
      throw AppFailure('Could not read $name', details: error.message);
    }
  }

  Future<void> delete(String name) async {
    final File file = File(_pathFor(name));
    if (await file.exists()) {
      await file.delete();
    }
  }

  /// Keeps the folder bounded so it cannot grow without limit.
  Future<void> _prune() async {
    final List<SavedQuery> queries = await list();
    for (final SavedQuery query
        in queries.skip(AppInfo.maxSavedQueries).toList(growable: false)) {
      await delete(query.name);
    }
  }
}
