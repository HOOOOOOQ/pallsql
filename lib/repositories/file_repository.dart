import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../core/constants/app_info.dart';
import '../core/contracts/controllers.dart';
import '../core/errors/app_failure.dart';
import '../core/utils/path_guard.dart';
import '../core/utils/validators.dart';
import '../models/file_entry.dart';
import '../models/log_entry.dart';
import '../services/log_sink.dart';
import '../services/workspace_service.dart';

/// Filesystem operations confined to the PALLSQL workspace.
class FileRepository implements FileSystemController {
  FileRepository({required Workspace workspace, required LogSink logs})
      : _workspace = workspace,
        _logs = logs;

  final Workspace _workspace;
  final LogSink _logs;

  PathGuard get guard => _workspace.guard;

  String get rootPath => _workspace.rootPath;

  String absolutePath(String relativePath) =>
      guard.resolveRelative(relativePath);

  @override
  Future<List<FileEntry>> list(
    String relativePath, {
    bool showHidden = false,
    FileSortOrder order = FileSortOrder.nameAsc,
  }) async {
    final Directory directory = Directory(absolutePath(relativePath));
    if (!await directory.exists()) {
      throw const NotFoundFailure('Folder not found');
    }
    final List<FileEntry> entries = <FileEntry>[];
    try {
      await for (final FileSystemEntity entity
          in directory.list(followLinks: false)) {
        final String name = p.basename(entity.path);
        if (!showHidden && name.startsWith('.')) {
          continue;
        }
        final FileStat stat = await entity.stat();
        entries.add(
          FileEntry(
            name: name,
            relativePath: guard.toRelative(entity.path),
            isDirectory: stat.type == FileSystemEntityType.directory,
            sizeBytes: stat.type == FileSystemEntityType.file ? stat.size : 0,
            modifiedAt: stat.modified,
          ),
        );
      }
    } on FileSystemException catch (error) {
      throw AppFailure('Could not read folder', details: error.message);
    }
    entries.sort((FileEntry a, FileEntry b) => _compare(a, b, order));
    return entries;
  }

  int _compare(FileEntry a, FileEntry b, FileSortOrder order) {
    // Directories always sort before files for a predictable browser.
    if (a.isDirectory != b.isDirectory) {
      return a.isDirectory ? -1 : 1;
    }
    switch (order) {
      case FileSortOrder.nameAsc:
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      case FileSortOrder.nameDesc:
        return b.name.toLowerCase().compareTo(a.name.toLowerCase());
      case FileSortOrder.sizeAsc:
        return a.sizeBytes.compareTo(b.sizeBytes);
      case FileSortOrder.sizeDesc:
        return b.sizeBytes.compareTo(a.sizeBytes);
      case FileSortOrder.modifiedDesc:
        return b.modifiedAt.compareTo(a.modifiedAt);
    }
  }

  Future<FileEntry> stat(String relativePath) async {
    final String absolute = absolutePath(relativePath);
    final FileSystemEntityType type =
        await FileSystemEntity.type(absolute, followLinks: false);
    if (type == FileSystemEntityType.notFound) {
      throw const NotFoundFailure('Path not found');
    }
    final FileStat stat = await FileStat.stat(absolute);
    return FileEntry(
      name: p.basename(absolute),
      relativePath: relativePath.isEmpty ? '' : guard.toRelative(absolute),
      isDirectory: type == FileSystemEntityType.directory,
      sizeBytes: stat.size,
      modifiedAt: stat.modified,
    );
  }

  Future<bool> exists(String relativePath) async {
    try {
      return await FileSystemEntity.type(absolutePath(relativePath)) !=
          FileSystemEntityType.notFound;
    } on AppFailure {
      return false;
    }
  }

  @override
  Future<FileEntry> createFile(
    String parentRelative,
    String name, {
    String content = '',
  }) async {
    final String? error = Validators.entryNameError(name);
    if (error != null) {
      throw ValidationFailure(error);
    }
    final String target = guard.resolveSegment(parentRelative, name.trim());
    final File file = File(target);
    if (await file.exists() || await Directory(target).exists()) {
      throw ValidationFailure('"${name.trim()}" already exists');
    }
    await file.parent.create(recursive: true);
    await file.writeAsString(content, flush: true);
    _logs.info(LogSource.files, 'Created file ${p.basename(target)}');
    return stat(guard.toRelative(target));
  }

  @override
  Future<FileEntry> createDirectory(String parentRelative, String name) async {
    final String? error = Validators.entryNameError(name);
    if (error != null) {
      throw ValidationFailure(error);
    }
    final String target = guard.resolveSegment(parentRelative, name.trim());
    if (await Directory(target).exists() || await File(target).exists()) {
      throw ValidationFailure('"${name.trim()}" already exists');
    }
    await Directory(target).create(recursive: true);
    _logs.info(LogSource.files, 'Created folder ${p.basename(target)}');
    return stat(guard.toRelative(target));
  }

  /// Reads a text file, refusing anything that is not valid UTF-8.
  @override
  Future<String> readText(
    String relativePath, {
    int maxBytes = AppInfo.maxEditorBytes,
  }) async {
    final File file = File(absolutePath(relativePath));
    if (!await file.exists()) {
      throw const NotFoundFailure('File not found');
    }
    final int length = await file.length();
    if (length > maxBytes) {
      throw ValidationFailure(
        'File is too large to open in the editor '
        '(${length ~/ 1024} KB > ${maxBytes ~/ 1024} KB)',
      );
    }
    final List<int> bytes = await file.readAsBytes();
    try {
      return utf8.decode(bytes);
    } on FormatException {
      throw const ValidationFailure(
        'This file is not UTF-8 text and cannot be edited here',
      );
    }
  }

  @override
  Future<void> writeText(String relativePath, String content) async {
    final File file = File(absolutePath(relativePath));
    await file.parent.create(recursive: true);
    await file.writeAsString(content, flush: true);
    _logs.info(LogSource.files, 'Saved ${p.basename(file.path)}');
  }

  @override
  Future<void> rename(String relativePath, String newName) async {
    final String? error = Validators.entryNameError(newName);
    if (error != null) {
      throw ValidationFailure(error);
    }
    final String source = absolutePath(relativePath);
    if (relativePath.isEmpty) {
      throw const ValidationFailure('The workspace root cannot be renamed');
    }
    final String destination = guard.ensureInside(
      p.join(p.dirname(source), newName.trim()),
    );
    if (await FileSystemEntity.type(destination) !=
        FileSystemEntityType.notFound) {
      throw ValidationFailure('"${newName.trim()}" already exists');
    }
    await _moveEntity(source, destination);
    _logs.info(LogSource.files, 'Renamed to ${newName.trim()}');
  }

  @override
  Future<void> move(String fromRelative, String toRelative) async {
    final String source = absolutePath(fromRelative);
    final String destination = absolutePath(toRelative);
    if (fromRelative.isEmpty) {
      throw const ValidationFailure('The workspace root cannot be moved');
    }
    if (destination == source || p.isWithin(source, destination)) {
      throw const ValidationFailure('Cannot move a folder into itself');
    }
    if (await FileSystemEntity.type(destination) !=
        FileSystemEntityType.notFound) {
      throw const ValidationFailure('Destination already exists');
    }
    await _moveEntity(source, destination);
    _logs.info(LogSource.files, 'Moved ${p.basename(source)}');
  }

  @override
  Future<void> copy(String fromRelative, String toRelative) async {
    final String source = absolutePath(fromRelative);
    final String destination = absolutePath(toRelative);
    if (await FileSystemEntity.type(destination) !=
        FileSystemEntityType.notFound) {
      throw const ValidationFailure('Destination already exists');
    }
    final FileSystemEntityType type =
        await FileSystemEntity.type(source, followLinks: false);
    if (type == FileSystemEntityType.notFound) {
      throw const NotFoundFailure('Source not found');
    }
    if (type == FileSystemEntityType.directory) {
      await _copyDirectory(Directory(source), Directory(destination));
    } else {
      await File(source).copy(destination);
    }
    _logs.info(LogSource.files, 'Copied ${p.basename(source)}');
  }

  @override
  Future<void> delete(String relativePath) async {
    if (relativePath.isEmpty ||
        guard.resolveRelative(relativePath) == guard.normalizedRoot) {
      throw const ValidationFailure('The workspace root cannot be deleted');
    }
    final String target = absolutePath(relativePath);
    final FileSystemEntityType type =
        await FileSystemEntity.type(target, followLinks: false);
    if (type == FileSystemEntityType.notFound) {
      throw const NotFoundFailure('Path not found');
    }
    if (type == FileSystemEntityType.directory) {
      await Directory(target).delete(recursive: true);
    } else {
      await File(target).delete();
    }
    _logs.warning(LogSource.files, 'Deleted ${p.basename(target)}');
  }

  /// Recursive case insensitive search limited to [limit] hits.
  @override
  Future<List<FileEntry>> search(String query, {int limit = 200}) async {
    final String needle = query.trim().toLowerCase();
    if (needle.isEmpty) {
      return const <FileEntry>[];
    }
    final List<FileEntry> hits = <FileEntry>[];
    await for (final FileSystemEntity entity
        in _workspace.root.list(recursive: true, followLinks: false)) {
      if (hits.length >= limit) {
        break;
      }
      final String name = p.basename(entity.path);
      if (name.startsWith('.')) {
        continue;
      }
      if (!name.toLowerCase().contains(needle)) {
        continue;
      }
      final FileStat stat = await entity.stat();
      hits.add(
        FileEntry(
          name: name,
          relativePath: guard.toRelative(entity.path),
          isDirectory: stat.type == FileSystemEntityType.directory,
          sizeBytes: stat.size,
          modifiedAt: stat.modified,
        ),
      );
    }
    hits.sort(
        (FileEntry a, FileEntry b) => a.relativePath.compareTo(b.relativePath));
    return hits;
  }

  /// Copies a workspace file out to [targetDirectory] (used for export).
  Future<File> exportFile(
      String relativePath, Directory targetDirectory) async {
    final File source = File(absolutePath(relativePath));
    if (!await source.exists()) {
      throw const NotFoundFailure('File not found');
    }
    await targetDirectory.create(recursive: true);
    final File target =
        File(p.join(targetDirectory.path, p.basename(source.path)));
    await source.copy(target.path);
    return target;
  }

  /// Moves a file that Android's document picker copied into `tmp` into the
  /// workspace proper.
  Future<FileEntry> importPickedFile(
      String temporaryPath, String destinationRelative) async {
    final File source = File(temporaryPath);
    if (!await source.exists()) {
      throw const NotFoundFailure('Imported file is missing');
    }
    if (!guard.contains(temporaryPath)) {
      throw const PathSecurityFailure('Imported file is outside the workspace');
    }
    final String destination = guard.resolveRelative(destinationRelative);
    if (await FileSystemEntity.type(destination) !=
        FileSystemEntityType.notFound) {
      throw const ValidationFailure('Destination already exists');
    }
    await source.rename(destination);
    _logs.info(LogSource.files, 'Imported ${p.basename(destination)}');
    return stat(guard.toRelative(destination));
  }

  Future<void> _moveEntity(String source, String destination) async {
    final FileSystemEntityType type =
        await FileSystemEntity.type(source, followLinks: false);
    await Directory(p.dirname(destination)).create(recursive: true);
    if (type == FileSystemEntityType.directory) {
      await Directory(source).rename(destination);
    } else if (type == FileSystemEntityType.file) {
      await File(source).rename(destination);
    } else {
      throw const NotFoundFailure('Source not found');
    }
  }

  Future<void> _copyDirectory(Directory source, Directory destination) async {
    await destination.create(recursive: true);
    await for (final FileSystemEntity entity
        in source.list(recursive: false, followLinks: false)) {
      final String name = p.basename(entity.path);
      final String targetPath = p.join(destination.path, name);
      if (entity is Directory) {
        await _copyDirectory(entity, Directory(targetPath));
      } else if (entity is File) {
        await entity.copy(targetPath);
      }
    }
  }
}
