import 'dart:io';

import '../../models/file_entry.dart';
import '../../models/log_entry.dart';
import '../../models/project.dart';
import '../../repositories/project_repository.dart';
import '../../services/php_runtime_service.dart';

/// Contract implemented by the web-server controller.
///
/// Every method returns `null` on success and a user presentable error message
/// on failure, so the UI never has to guess whether an action worked.
abstract class ServerController {
  Future<String?> start();

  Future<String?> stop();

  Future<String?> restart();

  /// Applies a changed port/LAN configuration (restarts when running).
  Future<String?> applyNetworkSettings();

  /// Opens the served URL in an external browser. `false` means no browser.
  Future<bool> openWebsite();
}

/// Contract for probing and reporting the PHP runtime.
///
/// The runtime is optional: implementations must report `available == false`
/// honestly instead of pretending PHP works.
abstract class PhpRuntimeController {
  Future<PhpRuntimeInfo?> refresh();
}

/// Contract for the database layer as seen by the UI.
abstract class DatabaseController {
  Future<void> refresh();

  Future<String?> createDatabase(String name);

  Future<String?> deleteDatabase(String name);
}

/// Contract for project management.
abstract class ProjectController {
  Future<void> reload();

  Future<String?> create({
    required String name,
    required ProjectTemplate template,
    String description,
  });

  Future<String?> duplicate(Project project, String newName);

  Future<String?> delete(Project project);

  Future<String?> importZip(File archive, {String? name});

  Future<File?> exportZip(Project project);

  Future<void> activate(Project? project);
}

/// Contract for sandboxed file operations.
abstract class FileSystemController {
  Future<List<FileEntry>> list(
    String relativePath, {
    bool showHidden,
    FileSortOrder order,
  });

  Future<String> readText(String relativePath, {int maxBytes});

  Future<void> writeText(String relativePath, String content);

  Future<FileEntry> createFile(
    String parentRelative,
    String name, {
    String content,
  });

  Future<FileEntry> createDirectory(String parentRelative, String name);

  Future<void> rename(String relativePath, String newName);

  Future<void> copy(String fromRelative, String toRelative);

  Future<void> move(String fromRelative, String toRelative);

  Future<void> delete(String relativePath);

  Future<List<FileEntry>> search(String query, {int limit});
}

/// Contract for the structured log buffer.
abstract class LogController {
  List<LogEntry> get entries;

  void log(LogLevel level, LogSource source, String message);

  List<LogEntry> filtered({LogLevel? level, LogSource? source, String query});

  Future<void> clear();
}
