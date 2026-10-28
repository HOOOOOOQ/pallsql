import 'dart:convert';

import '../core/errors/app_failure.dart';
import '../core/utils/path_guard.dart';
import '../core/utils/validators.dart';

/// Metadata of a website project managed by PALLSQL.
///
/// The project directory itself lives in `PALLSQL/projects/<directory>`; the
/// metadata (name, description, timestamps) is stored in
/// `PALLSQL/config/projects.json` and never contains an absolute path.
class Project {
  const Project({
    required this.id,
    required this.name,
    required this.directory,
    required this.createdAt,
    required this.updatedAt,
    this.description = '',
    this.isSample = false,
  });

  final String id;
  final String name;

  /// Folder name relative to the projects directory. Validated, never absolute.
  final String directory;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String description;
  final bool isSample;

  Project copyWith({
    String? name,
    String? directory,
    DateTime? updatedAt,
    String? description,
  }) {
    return Project(
      id: id,
      name: name ?? this.name,
      directory: directory ?? this.directory,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      description: description ?? this.description,
      isSample: isSample,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'id': id,
        'name': name,
        'directory': directory,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
        'description': description,
        'isSample': isSample,
      };

  static Project fromJson(Map<String, Object?> json) {
    final String directory = json['directory']?.toString() ?? '';
    if (!Validators.isSafeDirectoryName(directory)) {
      throw const ValidationFailure('Stored project has an invalid directory');
    }
    return Project(
      id: json['id']?.toString() ?? directory,
      name: json['name']?.toString() ?? directory,
      directory: directory,
      createdAt: DateTime.tryParse(json['createdAt']?.toString() ?? '') ??
          DateTime.now(),
      updatedAt: DateTime.tryParse(json['updatedAt']?.toString() ?? '') ??
          DateTime.now(),
      description: json['description']?.toString() ?? '',
      isSample: json['isSample'] == true,
    );
  }

  static List<Project> decodeList(String raw) {
    if (raw.trim().isEmpty) {
      return const <Project>[];
    }
    final Object? decoded = jsonDecode(raw);
    if (decoded is! List) {
      throw const ValidationFailure('Project metadata is not a JSON list');
    }
    final List<Project> projects = <Project>[];
    for (final Object? item in decoded) {
      if (item is Map<String, Object?>) {
        try {
          projects.add(Project.fromJson(item));
        } on ValidationFailure {
          // Skip corrupted entries instead of losing the whole list.
        }
      }
    }
    return projects;
  }

  static String encodeList(List<Project> projects) => const JsonEncoder.withIndent(
        '  ',
      ).convert(projects.map((Project p) => p.toJson()).toList());

  /// Document root of this project inside the workspace.
  String documentRootPath(PathGuard guard) {
    if (!Validators.isSafeDirectoryName(directory)) {
      throw const PathSecurityFailure('Project directory is not safe to use');
    }
    return guard.resolveRelative('projects/$directory');
  }
}
