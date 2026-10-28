import 'dart:io';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;

import '../core/errors/app_failure.dart';
import '../core/utils/path_guard.dart';
import '../models/backup_info.dart';
import '../models/log_entry.dart';
import 'log_sink.dart';
import 'workspace_service.dart';

/// Result of inspecting a backup archive before restoring it.
class BackupValidation {
  const BackupValidation({
    required this.valid,
    required this.entryCount,
    required this.totalBytes,
    required this.issues,
  });

  final bool valid;
  final int entryCount;
  final int totalBytes;
  final List<String> issues;

  static const BackupValidation invalid = BackupValidation(
      valid: false, entryCount: 0, totalBytes: 0, issues: <String>[]);
}

/// Creates, inspects and restores ZIP backups of the workspace.
class BackupService {
  BackupService({
    required Workspace workspace,
    required LogSink logs,
    DateTime Function()? clock,
  })  : _workspace = workspace,
        _logs = logs,
        _clock = clock ?? DateTime.now;

  static const int maxEntries = 20000;
  static const int maxTotalBytes = 512 * 1024 * 1024;

  /// Folders a backup may contain. Restore refuses anything else.
  static const Set<String> allowedRoots = <String>{
    'htdocs',
    'projects',
    'database',
    'config',
    'logs',
  };

  final Workspace _workspace;
  final LogSink _logs;
  final DateTime Function() _clock;

  Directory get backupDirectory => _workspace.backups;

  Future<List<BackupInfo>> list() async {
    if (!await backupDirectory.exists()) {
      return const <BackupInfo>[];
    }
    final List<BackupInfo> backups = <BackupInfo>[];
    await for (final FileSystemEntity entity
        in backupDirectory.list(followLinks: false)) {
      if (entity is! File || p.extension(entity.path).toLowerCase() != '.zip') {
        continue;
      }
      final FileStat stat = await entity.stat();
      backups.add(
        BackupInfo(
          fileName: p.basename(entity.path),
          path: entity.path,
          sizeBytes: stat.size,
          createdAt: BackupInfo.timestampFromName(entity.path) ?? stat.modified,
        ),
      );
    }
    backups.sort(
        (BackupInfo a, BackupInfo b) => b.createdAt.compareTo(a.createdAt));
    return backups;
  }

  /// Creates a ZIP backup and returns its metadata.
  Future<BackupInfo> create({
    bool includeProjects = true,
    bool includeWebRoot = true,
    bool includeDatabases = true,
    bool includeConfig = true,
    bool includeLogs = false,
  }) async {
    final List<String> roots = <String>[
      if (includeWebRoot) 'htdocs',
      if (includeProjects) 'projects',
      if (includeDatabases) 'database',
      if (includeConfig) 'config',
      if (includeLogs) 'logs',
    ];
    if (roots.isEmpty) {
      throw const ValidationFailure('Select at least one item to back up');
    }
    final Archive archive = Archive();
    int bytes = 0;
    for (final String root in roots) {
      final Directory directory =
          Directory(_workspace.guard.resolveRelative(root));
      if (!await directory.exists()) {
        continue;
      }
      await for (final FileSystemEntity entity
          in directory.list(recursive: true, followLinks: false)) {
        final String relative =
            _workspace.guard.toRelative(entity.path).replaceAll('\\', '/');
        if (entity is Directory) {
          archive.addFile(ArchiveFile('$relative/', 0, <int>[]));
        } else if (entity is File) {
          final List<int> data = await entity.readAsBytes();
          bytes += data.length;
          archive.addFile(ArchiveFile(relative, data.length, data));
        }
      }
    }
    if (archive.files.isEmpty) {
      throw const ValidationFailure('Nothing to back up yet');
    }
    final List<int>? encoded = ZipEncoder().encode(archive);
    if (encoded == null) {
      throw const ArchiveFailure('Backup could not be created');
    }
    final DateTime now = _clock();
    final String fileName = 'pallsql-backup-${_stamp(now)}.zip';
    await backupDirectory.create(recursive: true);
    final File file = File(p.join(backupDirectory.path, fileName));
    await file.writeAsBytes(encoded, flush: true);
    _logs.info(
      LogSource.backup,
      'Created $fileName (${archive.files.length} entries, $bytes bytes)',
    );
    return BackupInfo(
      fileName: fileName,
      path: file.path,
      sizeBytes: encoded.length,
      createdAt: now,
      entryCount: archive.files.length,
    );
  }

  /// Verifies an archive before it is restored.
  Future<BackupValidation> validate(BackupInfo info) async {
    final List<String> issues = <String>[];
    final File file = File(info.path);
    if (!await file.exists()) {
      return const BackupValidation(
        valid: false,
        entryCount: 0,
        totalBytes: 0,
        issues: <String>['Backup file is missing'],
      );
    }
    Archive archive;
    try {
      archive =
          ZipDecoder().decodeBytes(await file.readAsBytes(), verify: true);
    } on Object catch (error) {
      return BackupValidation(
        valid: false,
        entryCount: 0,
        totalBytes: 0,
        issues: <String>['Archive is corrupted: $error'],
      );
    }
    int totalBytes = 0;
    int count = 0;
    for (final ArchiveFile entry in archive.files) {
      count++;
      totalBytes += entry.size;
      try {
        final String normalized = _normalizeEntry(entry.name);
        if (normalized.isEmpty) {
          continue;
        }
        final String root = normalized.split('/').first;
        if (!allowedRoots.contains(root)) {
          issues.add('Refusing entry outside the workspace: ${entry.name}');
        }
      } on AppFailure catch (failure) {
        issues.add('${failure.message}: ${entry.name}');
      }
    }
    if (count > maxEntries) {
      issues.add('Archive has too many entries');
    }
    if (totalBytes > maxTotalBytes) {
      issues.add('Archive expands beyond the restore limit');
    }
    return BackupValidation(
      valid: issues.isEmpty,
      entryCount: count,
      totalBytes: totalBytes,
      issues: issues,
    );
  }

  /// Restores a backup. A safety backup of the current state is created first.
  Future<void> restore(BackupInfo info) async {
    final BackupValidation validation = await validate(info);
    if (!validation.valid) {
      throw ArchiveFailure(
        'Backup validation failed',
        details: validation.issues.take(3).join('; '),
      );
    }
    await create();
    final Archive archive = ZipDecoder().decodeBytes(
      await File(info.path).readAsBytes(),
      verify: true,
    );
    final PathGuard guard = _workspace.guard;
    int restored = 0;
    for (final ArchiveFile entry in archive.files) {
      final String normalized = _normalizeEntry(entry.name);
      if (normalized.isEmpty) {
        continue;
      }
      final String target = guard.resolveRelative(normalized);
      if (entry.isFile) {
        final List<int>? data = entry.content as List<int>?;
        final File out = File(target);
        await out.parent.create(recursive: true);
        await out.writeAsBytes(data ?? const <int>[], flush: true);
        restored++;
      } else {
        await Directory(target).create(recursive: true);
      }
    }
    _logs.warning(
      LogSource.backup,
      'Restored ${info.fileName} ($restored files)',
    );
  }

  Future<void> delete(BackupInfo info) async {
    final File file = File(info.path);
    if (!_workspace.guard.contains(file.path)) {
      throw const PathSecurityFailure('Backup is outside the workspace');
    }
    if (await file.exists()) {
      await file.delete();
      _logs.warning(LogSource.backup, 'Deleted ${info.fileName}');
    }
  }

  /// Copies a backup out of the app sandbox (for sharing/export).
  Future<File> export(BackupInfo info, Directory targetDirectory) async {
    final File source = File(info.path);
    if (!await source.exists()) {
      throw const NotFoundFailure('Backup file is missing');
    }
    await targetDirectory.create(recursive: true);
    final File target = File(p.join(targetDirectory.path, info.fileName));
    await source.copy(target.path);
    return target;
  }

  String _normalizeEntry(String rawName) {
    String name = rawName.replaceAll('\\', '/');
    name = name.replaceFirst(RegExp(r'^\./'), '');
    if (name.startsWith('/') || RegExp(r'^[A-Za-z]:').hasMatch(name)) {
      throw const ArchiveFailure('Archive contains an absolute path');
    }
    final List<String> segments = <String>[];
    for (final String segment in name.split('/')) {
      if (segment.isEmpty || segment == '.') {
        continue;
      }
      if (segment == '..') {
        throw const ArchiveFailure('Archive contains a parent path segment');
      }
      segments.add(segment);
    }
    return segments.join('/');
  }

  String _stamp(DateTime now) {
    String two(int value) => value.toString().padLeft(2, '0');
    return '${now.year}${two(now.month)}${two(now.day)}-'
        '${two(now.hour)}${two(now.minute)}${two(now.second)}';
  }
}
