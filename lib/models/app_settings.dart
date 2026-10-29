import '../core/constants/app_info.dart';
import '../core/utils/validators.dart';

/// Colour scheme preference. Dark is the PALLSQL default.
enum AppThemeMode {
  dark,
  light,
  system;

  String get label {
    switch (this) {
      case AppThemeMode.dark:
        return 'Dark';
      case AppThemeMode.light:
        return 'Light';
      case AppThemeMode.system:
        return 'System';
    }
  }

  static AppThemeMode parse(Object? raw) {
    final String value = raw?.toString() ?? '';
    for (final AppThemeMode mode in AppThemeMode.values) {
      if (mode.name == value) {
        return mode;
      }
    }
    return AppThemeMode.dark;
  }
}

/// User configurable application settings, persisted as
/// `PALLSQL/config/settings.json`.
class AppSettings {
  const AppSettings({
    this.httpPort = AppInfo.defaultHttpPort,
    this.lanAccess = false,
    this.autoStartServer = false,
    this.editorFontSize = 13,
    this.editorWordWrap = false,
    this.showLineNumbers = true,
    this.maxLogEntries = 500,
    this.phpBinaryPath = '',
    this.notificationsEnabled = true,
    this.databaseEngine = 'sqlite',
    this.activeProjectId = '',
    this.themeMode = AppThemeMode.dark,
    this.uiTextScale = 1.0,
  });

  final int httpPort;

  /// When true the local server binds to all interfaces (LAN exposure).
  /// Default is loopback only.
  final bool lanAccess;
  final bool autoStartServer;
  final double editorFontSize;
  final bool editorWordWrap;
  final bool showLineNumbers;
  final int maxLogEntries;

  /// Optional path to a `php-cgi` compatible binary. Empty means auto detect.
  final String phpBinaryPath;

  final bool notificationsEnabled;

  /// Engine selected in the UI. `sqlite` is the only bundled engine.
  final String databaseEngine;

  /// Project id whose folder is served as document root. Empty means the
  /// shared `htdocs` folder.
  final String activeProjectId;

  /// Dark / light / follow the system.
  final AppThemeMode themeMode;

  /// Global text scale (1.0 = system default), clamped to a comfortable range.
  final double uiTextScale;

  bool get bindToLan => lanAccess;

  AppSettings copyWith({
    int? httpPort,
    bool? lanAccess,
    bool? autoStartServer,
    double? editorFontSize,
    bool? editorWordWrap,
    bool? showLineNumbers,
    int? maxLogEntries,
    String? phpBinaryPath,
    bool? notificationsEnabled,
    String? databaseEngine,
    String? activeProjectId,
    AppThemeMode? themeMode,
    double? uiTextScale,
  }) {
    return AppSettings(
      httpPort: httpPort ?? this.httpPort,
      lanAccess: lanAccess ?? this.lanAccess,
      autoStartServer: autoStartServer ?? this.autoStartServer,
      editorFontSize: editorFontSize ?? this.editorFontSize,
      editorWordWrap: editorWordWrap ?? this.editorWordWrap,
      showLineNumbers: showLineNumbers ?? this.showLineNumbers,
      maxLogEntries: maxLogEntries ?? this.maxLogEntries,
      phpBinaryPath: phpBinaryPath ?? this.phpBinaryPath,
      notificationsEnabled: notificationsEnabled ?? this.notificationsEnabled,
      databaseEngine: databaseEngine ?? this.databaseEngine,
      activeProjectId: activeProjectId ?? this.activeProjectId,
      themeMode: themeMode ?? this.themeMode,
      uiTextScale: uiTextScale ?? this.uiTextScale,
    );
  }

  /// Returns human readable validation problems (empty when valid).
  List<String> validate() {
    final List<String> issues = <String>[];
    final String? portIssue = Validators.portError(httpPort);
    if (portIssue != null) {
      issues.add(portIssue);
    }
    if (editorFontSize < 10 || editorFontSize > 28) {
      issues.add('Editor font size must be between 10 and 28');
    }
    if (maxLogEntries < 50 || maxLogEntries > 5000) {
      issues.add('Log buffer must be between 50 and 5000 entries');
    }
    if (phpBinaryPath.isNotEmpty &&
        !Validators.isSafeRelativePath(phpBinaryPath)) {
      issues
          .add('PHP binary path must be a relative path inside the workspace');
    }
    if (uiTextScale < 0.85 || uiTextScale > 1.3) {
      issues.add('Text size must be between 0.85x and 1.3x');
    }
    return issues;
  }

  bool get isValid => validate().isEmpty;

  Map<String, Object?> toJson() => <String, Object?>{
        'httpPort': httpPort,
        'lanAccess': lanAccess,
        'autoStartServer': autoStartServer,
        'editorFontSize': editorFontSize,
        'editorWordWrap': editorWordWrap,
        'showLineNumbers': showLineNumbers,
        'maxLogEntries': maxLogEntries,
        'phpBinaryPath': phpBinaryPath,
        'notificationsEnabled': notificationsEnabled,
        'databaseEngine': databaseEngine,
        'activeProjectId': activeProjectId,
        'themeMode': themeMode.name,
        'uiTextScale': uiTextScale,
      };

  /// Tolerant parser: unknown or invalid values fall back to defaults.
  static AppSettings fromJson(Map<String, Object?> json) {
    const AppSettings defaults = AppSettings();
    int readPort() {
      final Object? raw = json['httpPort'];
      final int? parsed = raw is num ? raw.toInt() : int.tryParse('$raw');
      if (parsed == null || Validators.portError(parsed) != null) {
        return defaults.httpPort;
      }
      return parsed;
    }

    double readFontSize() {
      final Object? raw = json['editorFontSize'];
      final double? parsed =
          raw is num ? raw.toDouble() : double.tryParse('$raw');
      if (parsed == null || parsed < 10 || parsed > 28) {
        return defaults.editorFontSize;
      }
      return parsed;
    }

    int readLogBuffer() {
      final Object? raw = json['maxLogEntries'];
      final int? parsed = raw is num ? raw.toInt() : int.tryParse('$raw');
      if (parsed == null || parsed < 50 || parsed > 5000) {
        return defaults.maxLogEntries;
      }
      return parsed;
    }

    double readTextScale() {
      final Object? raw = json['uiTextScale'];
      final double? parsed =
          raw is num ? raw.toDouble() : double.tryParse('$raw');
      if (parsed == null || parsed < 0.85 || parsed > 1.3) {
        return defaults.uiTextScale;
      }
      return parsed;
    }

    return AppSettings(
      httpPort: readPort(),
      lanAccess: json['lanAccess'] == true,
      autoStartServer: json['autoStartServer'] == true,
      editorFontSize: readFontSize(),
      editorWordWrap: json['editorWordWrap'] == true,
      showLineNumbers: json['showLineNumbers'] != false,
      maxLogEntries: readLogBuffer(),
      phpBinaryPath: Validators.isSafeRelativePath(
        json['phpBinaryPath']?.toString() ?? '',
      )
          ? json['phpBinaryPath'].toString()
          : '',
      notificationsEnabled: json['notificationsEnabled'] != false,
      databaseEngine: json['databaseEngine']?.toString() == 'mariadb'
          ? 'mariadb'
          : 'sqlite',
      activeProjectId: Validators.isSafeDirectoryName(
        json['activeProjectId']?.toString() ?? '',
      )
          ? json['activeProjectId'].toString()
          : '',
      themeMode: AppThemeMode.parse(json['themeMode']),
      uiTextScale: readTextScale(),
    );
  }
}
