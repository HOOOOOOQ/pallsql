import 'dart:io';

import 'package:path/path.dart' as p;

import '../core/constants/app_info.dart';
import '../core/errors/app_failure.dart';
import '../core/utils/path_guard.dart';

/// Result of a recursive storage measurement.
class StorageUsage {
  const StorageUsage({
    required this.totalBytes,
    required this.fileCount,
    required this.directoryCount,
  });

  final int totalBytes;
  final int fileCount;
  final int directoryCount;

  static const StorageUsage empty =
      StorageUsage(totalBytes: 0, fileCount: 0, directoryCount: 0);
}

/// The PALLSQL workspace: a single sandboxed directory tree inside the app's
/// private storage.
class Workspace {
  Workspace(this.root);

  final Directory root;

  PathGuard get guard => PathGuard(root.path);

  String get rootPath => root.path;

  Directory get htdocs => _dir('htdocs');
  Directory get projects => _dir('projects');
  Directory get database => _dir('database');
  Directory get backups => _dir('backups');
  Directory get logs => _dir('logs');
  Directory get config => _dir('config');
  Directory get phpConfig => _dir('config/php');
  Directory get serverConfig => _dir('config/server');
  Directory get queries => _dir('config/queries');
  Directory get extensions => _dir('extensions');
  Directory get terminal => _dir('terminal');
  Directory get tmp => _dir('tmp');

  File get settingsFile => File(p.join(config.path, 'settings.json'));

  /// Relative paths of the folders exposed as shortcuts in Settings.
  static const List<String> shortcutFolders = <String>[
    'htdocs',
    'projects',
    'database',
    'logs',
  ];

  /// Absolute path of a workspace relative folder, validated by [guard].
  String pathOf(String relative) => guard.resolveRelative(relative);

  /// Human readable location of the workspace for Settings and Dashboard.
  String get locationLabel => rootPath;
  File get projectsFile => File(p.join(config.path, 'projects.json'));
  File get queryHistoryFile => File(p.join(config.path, 'query_history.json'));
  File get appLogFile => File(p.join(logs.path, 'app.log'));

  Directory _dir(String name) => Directory(p.join(root.path, name));

  /// Creates the workspace tree, a default landing page and a hello world PHP
  /// sample when they do not exist yet.
  Future<void> ensureStructure() async {
    await root.create(recursive: true);
    for (final String folder in AppInfo.workspaceFolders) {
      await _dir(folder).create(recursive: true);
    }
    final File index = File(p.join(htdocs.path, 'index.html'));
    if (!await index.exists()) {
      await index.writeAsString(_defaultIndexHtml, flush: true);
    }
    final Directory phpSample = Directory(p.join(projects.path, 'hello-php'));
    if (!await phpSample.exists()) {
      await phpSample.create(recursive: true);
      await File(p.join(phpSample.path, 'index.php'))
          .writeAsString(_phpSample, flush: true);
    }
  }

  /// Measures the workspace (bounded to keep the UI responsive).
  Future<StorageUsage> measure({int maxEntries = 20000}) async {
    int total = 0;
    int files = 0;
    int directories = 0;
    int seen = 0;
    try {
      await for (final FileSystemEntity entity
          in root.list(recursive: true, followLinks: false)) {
        if (seen++ > maxEntries) {
          break;
        }
        if (entity is File) {
          files++;
          try {
            total += await entity.length();
          } on FileSystemException {
            // Ignore files that disappear while measuring.
          }
        } else if (entity is Directory) {
          directories++;
        }
      }
    } on FileSystemException {
      // A partially unreadable workspace should never crash the dashboard.
    }
    return StorageUsage(
      totalBytes: total,
      fileCount: files,
      directoryCount: directories,
    );
  }

  /// Resolves the effective document root: the active project or `htdocs`.
  Future<Directory> resolveDocumentRoot(String activeProjectId) async {
    if (activeProjectId.isEmpty) {
      return htdocs;
    }
    if (activeProjectId == '__htdocs__') {
      return htdocs;
    }
    final String path = guard.resolveRelative('projects/$activeProjectId');
    final Directory directory = Directory(path);
    if (await directory.exists()) {
      return directory;
    }
    return htdocs;
  }

  /// Creates a timestamped copy helper path inside `tmp`.
  Future<File> createTempFile(String prefix, String suffix) async {
    await tmp.create(recursive: true);
    final String stamp = DateTime.now().millisecondsSinceEpoch.toString();
    return File(p.join(tmp.path, '$prefix-$stamp$suffix'));
  }

  /// Removes the contents of `tmp` (never the folder itself).
  Future<int> clearTemp() async {
    int removed = 0;
    if (!await tmp.exists()) {
      return removed;
    }
    await for (final FileSystemEntity entity in tmp.list(followLinks: false)) {
      try {
        await entity.delete(recursive: true);
        removed++;
      } on FileSystemException catch (error) {
        throw AppFailure('Could not clean temporary files',
            details: error.message);
      }
    }
    return removed;
  }

  static Future<Workspace> open(Directory root) async {
    final Workspace workspace = Workspace(root);
    await workspace.ensureStructure();
    return workspace;
  }

  /// Landing page written once, when `htdocs/index.html` does not exist yet.
  ///
  /// It is never overwritten: a user who edits their landing page keeps their
  /// edits across app restarts and upgrades.
  static const String _defaultIndexHtml = '''
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>PALLSQL Local Server</title>
  <style>
    :root { color-scheme: dark; }
    * { box-sizing: border-box; }
    body {
      margin: 0; min-height: 100vh; display: grid; place-items: center;
      background: #101311; color: #e4e9e4; padding: 1.25rem;
      font: 16px/1.65 -apple-system, system-ui, "Segoe UI", Roboto, sans-serif;
    }
    main {
      width: 100%; max-width: 34rem; padding: 1.75rem;
      background: #181d19; border: 1px solid #303a32; border-radius: 16px;
    }
    .badge {
      display: inline-block; padding: .25rem .65rem; border-radius: 999px;
      background: #232e20; color: #b6d8a8; font-size: .72rem;
      letter-spacing: .14em; text-transform: uppercase;
    }
    h1 { color: #e4e9e4; font-size: 1.45rem; margin: 1rem 0 .5rem; }
    h1 span { color: #9bcb91; }
    p { color: #a0aaa1; margin: 0 0 .85rem; }
    code {
      color: #b6d8a8; background: #202721; padding: .1rem .35rem;
      border-radius: 5px; font-size: .9em;
    }
    ul { margin: 0; padding-left: 1.1rem; color: #a0aaa1; }
    li { margin-bottom: .35rem; }
    .status {
      margin-top: 1.25rem; padding-top: .9rem; font-size: .82rem;
      color: #7b857c; border-top: 1px solid #303a32;
    }
    @media (max-width: 420px) {
      main { padding: 1.25rem; }
      h1 { font-size: 1.25rem; }
    }
  </style>
</head>
<body>
  <main>
    <span class="badge">PALLSQL</span>
    <h1>Your local server is <span>running</span></h1>
    <p>
      This page is a local file, served from
      <code>PALLSQL/htdocs/index.html</code> by the built-in PALLSQL HTTP
      server. Nothing here is downloaded from the internet.
    </p>
    <p>Everything below works offline, entirely on this device:</p>
    <ul>
      <li>Static <code>HTML</code>, <code>CSS</code>, <code>JavaScript</code></li>
      <li>Images, fonts and other assets</li>
      <li>MariaDB schemas, the SQL editor and the SQL terminal</li>
    </ul>
    <p class="status">
      PHP scripts answer HTTP 501 until a PHP runtime is installed. MariaDB
      runs from the native runtime shipped in the APK; when that runtime is
      missing the Database tab reports it as not installed instead of falling
      back to another engine. Static sites work today.
    </p>
  </main>
</body>
</html>
''';

  static const String _phpSample = '''
<?php
// PALLSQL sample project. Requires a PHP runtime installed in the workspace.
header('Content-Type: text/html; charset=utf-8');
\$version = PHP_VERSION;
echo "<!doctype html><html><head><meta charset='utf-8'>";
echo "<title>PALLSQL PHP sample</title></head><body>";
echo "<h1>Hello from PHP \${version}</h1>";
echo "<p>Served by the PALLSQL local server.</p>";
echo "</body></html>";
''';
}
