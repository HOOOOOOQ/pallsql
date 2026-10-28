import 'package:path/path.dart' as p;

import '../core/constants/app_info.dart';

/// A file or directory inside the sandboxed PALLSQL workspace.
class FileEntry {
  const FileEntry({
    required this.name,
    required this.relativePath,
    required this.isDirectory,
    required this.sizeBytes,
    required this.modifiedAt,
  });

  final String name;

  /// Path relative to the workspace root, always using `/` separators.
  final String relativePath;
  final bool isDirectory;
  final int sizeBytes;
  final DateTime modifiedAt;

  String get extension =>
      isDirectory ? '' : p.extension(name).replaceFirst('.', '').toLowerCase();

  bool get isEditable => !isDirectory && AppInfo.editableExtensions.contains(extension);

  bool get isDatabaseFile =>
      !isDirectory && (extension == 'db' || extension == 'sqlite');

  String get displaySize {
    if (isDirectory) {
      return 'folder';
    }
    if (sizeBytes < 1024) {
      return '$sizeBytes B';
    }
    if (sizeBytes < 1024 * 1024) {
      return '${(sizeBytes / 1024).toStringAsFixed(1)} KB';
    }
    return '${(sizeBytes / (1024 * 1024)).toStringAsFixed(2)} MB';
  }

  String get parentRelativePath {
    final String parent = p.posix.dirname(relativePath.replaceAll('\\', '/'));
    return parent == '.' || parent == '/' ? '' : parent;
  }
}

/// Sort orders offered by the file manager.
enum FileSortOrder {
  nameAsc,
  nameDesc,
  sizeAsc,
  sizeDesc,
  modifiedDesc;

  String get label {
    switch (this) {
      case FileSortOrder.nameAsc:
        return 'Name A-Z';
      case FileSortOrder.nameDesc:
        return 'Name Z-A';
      case FileSortOrder.sizeAsc:
        return 'Smallest first';
      case FileSortOrder.sizeDesc:
        return 'Largest first';
      case FileSortOrder.modifiedDesc:
        return 'Newest first';
    }
  }
}
