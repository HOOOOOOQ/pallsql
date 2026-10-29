/// Static, compile-time facts about the PALLSQL application.
class AppInfo {
  const AppInfo._();

  static const String appName = 'PALLSQL';
  static const String packageName = 'com.pallsql.mobile';
  static const String version = '0.2.0';
  static const String buildNumber = '4';
  static const String tagline = 'Mobile development environment';

  /// Product tagline shown on the splash and the About page.
  static const String productTagline = 'Mobile Development Environment';

  static const String developer = 'pallxXx';
  static const String developerInstagramUrl =
      'https://www.instagram.com/pallemnih_?psln=MWNud3gxOHBvNTIyZw==';
  static const String developerInstagramHandle = '@pallemnih_';
  static const String copyright = '© 2026 PALLSQL. Developed by pallxXx.';
  static const String description =
      'PALLSQL - Offline mobile web development environment built with '
      'Flutter for Android.';

  /// Method channel shared by the Flutter UI and the Android host code.
  static const String nativeChannel = 'com.pallsql.mobile/native';

  static const int defaultHttpPort = 8080;
  static const int minPort = 1024;
  static const int maxPort = 65535;

  /// Internal HTTP endpoint used for health checks (served by the local server).
  static const String healthPath = '/__pallsql/health';

  /// Folders created below the PALLSQL workspace root.
  ///
  /// Nested entries (`config/php`, `config/server`, `config/queries`) are
  /// created recursively so every module agrees on one tree.
  static const List<String> workspaceFolders = <String>[
    'htdocs',
    'projects',
    'database',
    'backups',
    'logs',
    'config',
    'config/php',
    'config/server',
    'config/queries',
    'tmp',
    'extensions',
    'terminal',
  ];

  /// Maximum number of saved SQL snippets kept in `config/queries`.
  static const int maxSavedQueries = 40;

  /// Upper bound for a single SQL console / editor script.
  static const int maxSqlScriptBytes = 512 * 1024;

  /// File extensions the built-in editor can open as text.
  static const Set<String> editableExtensions = <String>{
    'html',
    'htm',
    'css',
    'js',
    'mjs',
    'json',
    'php',
    'sql',
    'txt',
    'md',
    'markdown',
    'xml',
    'svg',
    'yaml',
    'yml',
    'log',
    'ini',
    'conf',
    'env',
    'csv',
  };

  static const int maxEditorBytes = 2 * 1024 * 1024;
  static const int maxUploadBytes = 32 * 1024 * 1024;
}
