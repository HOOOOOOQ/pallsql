/// Static, compile-time facts about the PALLSQL application.
class AppInfo {
  const AppInfo._();

  static const String appName = 'PALLSQL';
  static const String packageName = 'com.pallsql.mobile';
  static const String version = '0.1.0';
  static const String buildNumber = '1';
  static const String tagline = 'Offline mobile web development environment';
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
  static const List<String> workspaceFolders = <String>[
    'htdocs',
    'projects',
    'database',
    'backups',
    'logs',
    'config',
    'tmp',
  ];

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
