import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;

import '../core/errors/app_failure.dart';
import '../core/utils/path_guard.dart';
import '../core/utils/validators.dart';
import '../models/log_entry.dart';
import '../models/project.dart';
import '../services/log_sink.dart';
import '../services/workspace_service.dart';

/// Starter content offered when creating a project.
enum ProjectTemplate {
  staticSite('Static HTML site', 'index.html, style.css and a small script'),
  phpHello(
      'PHP hello world', 'A minimal index.php that prints the PHP version'),
  htmlForm('HTML form', 'A form posting to a PHP endpoint'),
  databaseSample(
    'Database sample',
    'PHP snippet reading the SQLite database (needs a PHP runtime)',
  );

  const ProjectTemplate(this.label, this.description);

  final String label;
  final String description;
}

/// Reads and writes project metadata in `PALLSQL/config/projects.json`.
class ProjectRepository {
  ProjectRepository({
    required Workspace workspace,
    required LogSink logs,
    DateTime Function()? clock,
  })  : _workspace = workspace,
        _logs = logs,
        _clock = clock ?? DateTime.now;

  static const int maxArchiveEntries = 2000;
  static const int maxArchiveBytes = 100 * 1024 * 1024;

  final Workspace _workspace;
  final LogSink _logs;
  final DateTime Function() _clock;

  PathGuard get guard => _workspace.guard;

  File get metadataFile => _workspace.projectsFile;

  Future<List<Project>> load() async {
    final List<Project> projects = <Project>[];
    try {
      if (await metadataFile.exists()) {
        projects.addAll(Project.decodeList(await metadataFile.readAsString()));
      }
    } on FormatException {
      _logs.warning(
          LogSource.app, 'Project metadata was corrupted; rebuilding');
    } on ValidationFailure catch (failure) {
      _logs.warning(
          LogSource.app, 'Project metadata rejected: ${failure.message}');
    }
    return _syncWithDisk(projects);
  }

  /// Adds directories that exist on disk but are missing from the metadata.
  Future<List<Project>> _syncWithDisk(List<Project> projects) async {
    final Set<String> known =
        projects.map((Project project) => project.directory).toSet();
    final Directory projectsDir = _workspace.projects;
    if (!await projectsDir.exists()) {
      await projectsDir.create(recursive: true);
      return projects;
    }
    bool changed = false;
    await for (final FileSystemEntity entity
        in projectsDir.list(followLinks: false)) {
      if (entity is! Directory) {
        continue;
      }
      final String name = p.basename(entity.path);
      if (name.startsWith('.') || known.contains(name)) {
        continue;
      }
      if (!Validators.isSafeDirectoryName(name)) {
        continue;
      }
      final FileStat stat = await entity.stat();
      projects.add(
        Project(
          id: name,
          name: name,
          directory: name,
          createdAt: stat.modified,
          updatedAt: stat.modified,
          description: 'Imported from the projects folder',
        ),
      );
      changed = true;
    }
    projects.sort((Project a, Project b) => a.name.toLowerCase().compareTo(
          b.name.toLowerCase(),
        ));
    if (changed) {
      await _save(projects);
    }
    return projects;
  }

  Future<void> _save(List<Project> projects) async {
    await metadataFile.parent.create(recursive: true);
    await metadataFile.writeAsString(Project.encodeList(projects), flush: true);
  }

  Future<Directory> directoryOf(Project project) async {
    final String path = guard.resolveRelative('projects/${project.directory}');
    final Directory directory = Directory(path);
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }
    return directory;
  }

  Future<Project> create({
    required String name,
    required ProjectTemplate template,
    String description = '',
    bool isSample = false,
  }) async {
    final String? error = Validators.projectNameError(name);
    if (error != null) {
      throw ValidationFailure(error);
    }
    final List<Project> projects = await load();
    final String base = Validators.slugify(name);
    String directory = base;
    int suffix = 2;
    while (await Directory(guard.resolveRelative('projects/$directory'))
        .exists()) {
      directory = '$base-$suffix';
      suffix++;
    }
    final String projectPath = guard.resolveRelative('projects/$directory');
    final Directory projectDirectory = Directory(projectPath);
    await projectDirectory.create(recursive: true);
    for (final MapEntry<String, String> entry
        in _templateFiles(template).entries) {
      final File file = File(p.join(projectPath, entry.key));
      await file.parent.create(recursive: true);
      await file.writeAsString(entry.value, flush: true);
    }
    final DateTime now = _clock();
    final Project project = Project(
      id: directory,
      name: name.trim(),
      directory: directory,
      createdAt: now,
      updatedAt: now,
      description: description.trim(),
      isSample: isSample,
    );
    projects.add(project);
    await _save(projects);
    _logs.info(LogSource.app, 'Created project ${project.name}');
    return project;
  }

  Future<Project> duplicate(Project project, {required String newName}) async {
    final String? error = Validators.projectNameError(newName);
    if (error != null) {
      throw ValidationFailure(error);
    }
    final List<Project> projects = await load();
    final String base = Validators.slugify(newName);
    String directory = base;
    int suffix = 2;
    while (await Directory(guard.resolveRelative('projects/$directory'))
        .exists()) {
      directory = '$base-$suffix';
      suffix++;
    }
    final String sourcePath =
        guard.resolveRelative('projects/${project.directory}');
    final Directory source = Directory(sourcePath);
    if (!await source.exists()) {
      throw const NotFoundFailure('Project folder not found');
    }
    final String destinationPath = guard.resolveRelative('projects/$directory');
    await _copyDirectory(source, Directory(destinationPath));
    final DateTime now = _clock();
    final Project copy = Project(
      id: directory,
      name: newName.trim(),
      directory: directory,
      createdAt: now,
      updatedAt: now,
      description: project.description,
    );
    projects.add(copy);
    await _save(projects);
    _logs.info(LogSource.app, 'Duplicated project ${project.name}');
    return copy;
  }

  Future<void> delete(Project project) async {
    final String path = guard.resolveRelative('projects/${project.directory}');
    final Directory directory = Directory(path);
    if (await directory.exists()) {
      await directory.delete(recursive: true);
    }
    final List<Project> projects = await load();
    projects.removeWhere((Project item) => item.id == project.id);
    await _save(projects);
    _logs.warning(LogSource.app, 'Deleted project ${project.name}');
  }

  /// Imports a ZIP archive into a new project folder.
  ///
  /// The archive is validated first: absolute paths, `..` segments, symlinks,
  /// oversized entries and too many entries are rejected before writing.
  Future<Project> importZip(File archive, {String? name}) async {
    if (!await archive.exists()) {
      throw const NotFoundFailure('Archive not found');
    }
    final List<int> bytes = await archive.readAsBytes();
    Archive decoded;
    try {
      decoded = ZipDecoder().decodeBytes(bytes, verify: true);
    } on Object catch (error) {
      throw ArchiveFailure('Archive could not be read', details: '$error');
    }
    if (decoded.files.length > maxArchiveEntries) {
      throw const ArchiveFailure('Archive contains too many entries');
    }
    int totalBytes = 0;
    for (final ArchiveFile file in decoded.files) {
      totalBytes += file.size;
      if (totalBytes > maxArchiveBytes) {
        throw const ArchiveFailure('Archive expands beyond the size limit');
      }
    }
    final String projectName =
        (name ?? p.basenameWithoutExtension(archive.path)).trim();
    final String? nameError = Validators.projectNameError(projectName);
    if (nameError != null) {
      throw ValidationFailure(nameError);
    }
    final List<Project> projects = await load();
    final String base = Validators.slugify(projectName);
    String directory = base;
    int suffix = 2;
    while (await Directory(guard.resolveRelative('projects/$directory'))
        .exists()) {
      directory = '$base-$suffix';
      suffix++;
    }
    final String projectPath = guard.resolveRelative('projects/$directory');
    await Directory(projectPath).create(recursive: true);
    final PathGuard projectGuard = PathGuard(projectPath);
    final List<String> entryNames = decoded.files
        .map((ArchiveFile file) => _normalizeEntryName(file.name))
        .where((String value) => value.isNotEmpty)
        .toList();
    final String commonPrefix = _commonRootPrefix(entryNames);
    for (final ArchiveFile file in decoded.files) {
      String entryName = _normalizeEntryName(file.name);
      if (entryName.isEmpty) {
        continue;
      }
      if (commonPrefix.isNotEmpty && entryName.startsWith('$commonPrefix/')) {
        entryName = entryName.substring(commonPrefix.length + 1);
      }
      if (entryName.isEmpty) {
        continue;
      }
      final String target = projectGuard.resolveRelative(entryName);
      if (file.isFile) {
        final List<int>? data = file.content as List<int>?;
        final File out = File(target);
        await out.parent.create(recursive: true);
        await out.writeAsBytes(data ?? const <int>[], flush: true);
      } else {
        await Directory(target).create(recursive: true);
      }
    }
    final DateTime now = _clock();
    final Project project = Project(
      id: directory,
      name: projectName,
      directory: directory,
      createdAt: now,
      updatedAt: now,
      description: 'Imported from ${p.basename(archive.path)}',
    );
    projects.add(project);
    await _save(projects);
    _logs.info(LogSource.app, 'Imported project ${project.name}');
    return project;
  }

  /// Exports a project folder as a ZIP archive at [destination].
  Future<File> exportZip(Project project, File destination) async {
    final Directory directory =
        Directory(guard.resolveRelative('projects/${project.directory}'));
    if (!await directory.exists()) {
      throw const NotFoundFailure('Project folder not found');
    }
    final Archive archive = Archive();
    final List<FileSystemEntity> entities =
        await directory.list(recursive: true, followLinks: false).toList();
    for (final FileSystemEntity entity in entities) {
      final String relative = guard
          .toRelative(entity.path)
          .replaceFirst('projects/${project.directory}/', '');
      if (entity is Directory) {
        archive.addFile(
            ArchiveFile('${project.directory}/$relative/', 0, <int>[]));
      } else if (entity is File) {
        final List<int> data = await entity.readAsBytes();
        archive.addFile(
          ArchiveFile('${project.directory}/$relative', data.length, data),
        );
      }
    }
    final List<int>? encoded = ZipEncoder().encode(archive);
    if (encoded == null) {
      throw const ArchiveFailure('Archive could not be created');
    }
    await destination.parent.create(recursive: true);
    await destination.writeAsBytes(encoded, flush: true);
    _logs.info(LogSource.app, 'Exported project ${project.name}');
    return destination;
  }

  String _normalizeEntryName(String rawName) {
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

  String _commonRootPrefix(List<String> names) {
    if (names.isEmpty) {
      return '';
    }
    String candidate = names.first.split('/').first;
    if (candidate.isEmpty) {
      return '';
    }
    for (final String name in names) {
      if (!name.startsWith('$candidate/') && name != candidate) {
        return '';
      }
    }
    // Only strip when every entry actually lives below that folder.
    final bool hasBareFile = names.any((String name) => !name.contains('/'));
    return hasBareFile ? '' : candidate;
  }

  Map<String, String> _templateFiles(ProjectTemplate template) {
    switch (template) {
      case ProjectTemplate.staticSite:
        return <String, String>{
          'index.html': _staticHtml,
          'assets/style.css': _staticCss,
          'assets/app.js': _staticJs,
        };
      case ProjectTemplate.phpHello:
        return <String, String>{'index.php': _phpHello};
      case ProjectTemplate.htmlForm:
        return <String, String>{
          'index.php': _formHtml,
          'submit.php': _formHandler,
        };
      case ProjectTemplate.databaseSample:
        return <String, String>{
          'index.php': _databaseSample,
          'README.md': _databaseSampleReadme,
        };
    }
  }

  Future<void> _copyDirectory(Directory source, Directory destination) async {
    await destination.create(recursive: true);
    await for (final FileSystemEntity entity
        in source.list(followLinks: false)) {
      final String target = p.join(destination.path, p.basename(entity.path));
      if (entity is Directory) {
        await _copyDirectory(entity, Directory(target));
      } else if (entity is File) {
        await entity.copy(target);
      }
    }
  }

  static String encodeProjects(List<Project> projects) =>
      const JsonEncoder.withIndent('  ').convert(
        projects.map((Project project) => project.toJson()).toList(),
      );

  static const String _staticHtml = '''
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>My PALLSQL project</title>
  <link rel="stylesheet" href="assets/style.css">
</head>
<body>
  <main>
    <h1>Hello from PALLSQL</h1>
    <p>This static site is served by the built in local web server.</p>
    <button id="ping">Test JavaScript</button>
    <p id="out"></p>
  </main>
  <script src="assets/app.js"></script>
</body>
</html>
''';

  static const String _staticCss = '''
:root { color-scheme: dark; }
body {
  margin: 0; min-height: 100vh; display: grid; place-items: center;
  background: #050706; color: #f1f7f2;
  font: 16px/1.6 system-ui, -apple-system, sans-serif;
}
main { max-width: 34rem; padding: 2rem; }
h1 { color: #9bff3d; font-size: 1.5rem; }
button {
  margin-top: 1rem; padding: .6rem 1rem; border-radius: .5rem;
  border: 1px solid #243129; background: #16201a; color: #9bff3d;
  font-weight: 600;
}
''';

  static const String _staticJs = '''
const button = document.getElementById('ping');
const out = document.getElementById('out');
button.addEventListener('click', () => {
  out.textContent = 'JavaScript is running at ' + new Date().toLocaleTimeString();
});
''';

  static const String _phpHello = '''
<?php
header('Content-Type: text/html; charset=utf-8');
?>
<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><title>PHP on PALLSQL</title></head>
<body style="font-family:system-ui;background:#050706;color:#f1f7f2;padding:2rem">
  <h1 style="color:#9bff3d">Hello from PHP <?= htmlspecialchars(PHP_VERSION) ?></h1>
  <p>This file is executed by the PHP runtime, never served as source code.</p>
</body>
</html>
''';

  static const String _formHtml = '''
<?php
header('Content-Type: text/html; charset=utf-8');
\$name = \$_POST['name'] ?? '';
?>
<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><title>PALLSQL form</title></head>
<body style="font-family:system-ui;background:#050706;color:#f1f7f2;padding:2rem">
  <h1 style="color:#9bff3d">Send a message</h1>
  <form method="post" action="submit.php">
    <label>Your name<br><input name="name" required value="<?= htmlspecialchars(\$name) ?>"></label><br><br>
    <label>Message<br><textarea name="message" rows="4" cols="30"></textarea></label><br><br>
    <button type="submit">Submit</button>
  </form>
</body>
</html>
''';

  static const String _formHandler = '''
<?php
header('Content-Type: text/html; charset=utf-8');
\$name = trim(\$_POST['name'] ?? '');
\$message = trim(\$_POST['message'] ?? '');
?>
<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><title>Submitted</title></head>
<body style="font-family:system-ui;background:#050706;color:#f1f7f2;padding:2rem">
  <h1 style="color:#9bff3d">Thanks<?= \$name === '' ? '' : ', ' . htmlspecialchars(\$name) ?></h1>
  <p><?= htmlspecialchars(\$message === '' ? 'No message received.' : \$message) ?></p>
  <p><a style="color:#9bff3d" href="index.php">Back to the form</a></p>
</body>
</html>
''';

  static const String _databaseSample = '''
<?php
// Requires a PHP runtime with the pdo_sqlite extension.
header('Content-Type: text/html; charset=utf-8');
\$database = __DIR__ . '/../../database/app.db';
try {
    \$pdo = new PDO('sqlite:' . \$database);
    \$pdo->setAttribute(PDO::ATTR_ERRMODE, PDO::ERRMODE_EXCEPTION);
    \$pdo->exec('CREATE TABLE IF NOT EXISTS notes (id INTEGER PRIMARY KEY AUTOINCREMENT, body TEXT NOT NULL, created_at TEXT NOT NULL)');
    \$pdo->prepare('INSERT INTO notes (body, created_at) VALUES (?, ?)')
        ->execute(['Created by the PALLSQL sample', date('c')]);
    \$rows = \$pdo->query('SELECT id, body, created_at FROM notes ORDER BY id DESC LIMIT 10')->fetchAll(PDO::FETCH_ASSOC);
    echo '<h1 style="color:#9bff3d">SQLite rows</h1><ul>';
    foreach (\$rows as \$row) {
        echo '<li>#' . htmlspecialchars((string)\$row['id']) . ' ' . htmlspecialchars(\$row['body']) . '</li>';
    }
    echo '</ul>';
} catch (Throwable \$error) {
    http_response_code(500);
    echo '<p>Database error: ' . htmlspecialchars(\$error->getMessage()) . '</p>';
}
''';

  static const String _databaseSampleReadme = '''
# Database sample

PALLSQL ships with SQLite as its offline database engine.

This sample uses PHP's `pdo_sqlite` extension to write to
`PALLSQL/database/app.db`. Create that database in the **Database** tab first
(or let the script create the table) and install a PHP runtime to execute it.

MariaDB is **not** bundled with this build; see `docs/database.md` in the
repository for the evaluation notes.
''';
}
