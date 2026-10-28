import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../core/errors/app_failure.dart';
import '../models/app_settings.dart';
import '../models/backup_info.dart';
import '../models/database_models.dart';
import '../models/file_entry.dart';
import '../models/log_entry.dart';
import '../models/project.dart';
import '../models/service_status.dart';
import '../repositories/database_repository.dart';
import '../repositories/file_repository.dart';
import '../repositories/log_repository.dart';
import '../repositories/project_repository.dart';
import '../core/contracts/controllers.dart';
import '../services/app_bootstrap.dart';
import '../services/backup_service.dart';
import '../services/link_opener.dart';
import '../services/native_bridge.dart';
import '../services/php_runtime_service.dart';
import '../services/terminal_service.dart';
import '../services/web_server_service.dart';
import '../services/workspace_service.dart';

/// Overridden in `main()` (and in tests) with a fully wired bootstrap.
final Provider<AppBootstrap> bootstrapProvider = Provider<AppBootstrap>(
  (Ref ref) => throw UnimplementedError(
    'bootstrapProvider must be overridden with AppBootstrap.create(...)',
  ),
);

/// The current bootstrap instance, without watching it.
AppBootstrap bootstrapOf(Ref ref) => ref.read(bootstrapProvider);

final Provider<LogRepository> logRepositoryProvider = Provider<LogRepository>(
  (Ref ref) => ref.watch(bootstrapProvider).logs,
);

/// Live log stream for the log viewer and dashboard.
final StreamProvider<List<LogEntry>> logEntriesProvider =
    StreamProvider<List<LogEntry>>((Ref ref) {
  final LogRepository repository = ref.watch(logRepositoryProvider);
  return repository.changes;
});

final Provider<NativeBridge> nativeBridgeProvider = Provider<NativeBridge>(
  (Ref ref) => ref.watch(bootstrapProvider).native,
);

final Provider<NativeDeviceInfo?> deviceInfoProvider =
    Provider<NativeDeviceInfo?>((Ref ref) => ref.watch(bootstrapProvider).deviceInfo);

final Provider<FileRepository> fileRepositoryProvider = Provider<FileRepository>(
  (Ref ref) => ref.watch(bootstrapProvider).files,
);

final Provider<ProjectRepository> projectRepositoryProvider =
    Provider<ProjectRepository>((Ref ref) => ref.watch(bootstrapProvider).projects);

final Provider<SqliteDatabaseRepository> databaseRepositoryProvider =
    Provider<SqliteDatabaseRepository>(
  (Ref ref) => ref.watch(bootstrapProvider).databases,
);

final Provider<BackupService> backupServiceProvider = Provider<BackupService>(
  (Ref ref) => ref.watch(bootstrapProvider).backups,
);

final Provider<LinkOpener> linkOpenerProvider = Provider<LinkOpener>((Ref ref) {
  final AppBootstrap bootstrap = ref.watch(bootstrapProvider);
  return NativeLinkOpener(native: bootstrap.native, logs: bootstrap.logs);
});

/// ---------------------------------------------------------------------------
/// Settings
/// ---------------------------------------------------------------------------

class SettingsController extends Notifier<AppSettings> {
  @override
  AppSettings build() => ref.watch(bootstrapProvider).settings;

  /// Persists [next] and applies runtime side effects. Returns an error message
  /// when saving failed.
  Future<String?> update(AppSettings next) async {
    final AppBootstrap bootstrap = ref.read(bootstrapProvider);
    final List<String> issues = next.validate();
    if (issues.isNotEmpty) {
      return issues.first;
    }
    try {
      await bootstrap.updateSettings(next);
      state = next;
      return null;
    } on Object catch (error) {
      bootstrap.logs.error(LogSource.app, 'Could not save settings: $error');
      return 'Could not save settings: $error';
    }
  }

  Future<String?> setActiveProject(String projectId) async {
    return update(state.copyWith(activeProjectId: projectId));
  }
}

final NotifierProvider<SettingsController, AppSettings> settingsProvider =
    NotifierProvider<SettingsController, AppSettings>(SettingsController.new);

/// ---------------------------------------------------------------------------
/// Web server
/// ---------------------------------------------------------------------------

class WebServerNotifier extends Notifier<WebServerSnapshot>
    implements ServerController {
  late final WebServerService _service;
  bool _disposed = false;

  @override
  WebServerSnapshot build() {
    final AppBootstrap bootstrap = ref.watch(bootstrapProvider);
    _service = bootstrap.webServer;
    final StreamSubscription<WebServerSnapshot> subscription =
        _service.changes.listen(_handleChange);
    ref.onDispose(() {
      _disposed = true;
      subscription.cancel();
    });
    return _service.snapshot;
  }

  void _handleChange(WebServerSnapshot snapshot) {
    if (!_disposed) {
      state = snapshot;
    }
  }

  WebServerService get service => _service;

  /// Aligns the served folder with the active project.
  Future<void> _applyDocumentRoot() async {
    final AppBootstrap bootstrap = ref.read(bootstrapProvider);
    final AppSettings settings = ref.read(settingsProvider);
    final Directory directory =
        await bootstrap.workspace.resolveDocumentRoot(settings.activeProjectId);
    if (p.normalize(directory.path) != p.normalize(_service.documentRoot)) {
      _service.updateDocumentRoot(directory);
    }
  }

  @override
  Future<String?> start() async {
    final AppBootstrap bootstrap = ref.read(bootstrapProvider);
    final AppSettings settings = ref.read(settingsProvider);
    try {
      await _applyDocumentRoot();
      final WebServerSnapshot snapshot = await _service.start(
        port: settings.httpPort,
        lanAccess: settings.lanAccess,
      );
      if (settings.notificationsEnabled) {
        await bootstrap.native.startForegroundService(
          title: 'PALLSQL server running',
          text: 'Port ${snapshot.port ?? settings.httpPort} - '
              '${snapshot.primaryUrl}',
        );
      }
      return null;
    } on AppFailure catch (failure) {
      bootstrap.logs.error(LogSource.webServer, failure.combined);
      return failure.combined;
    } on Object catch (error) {
      bootstrap.logs.error(LogSource.webServer, 'Start failed: $error');
      return 'Could not start the server: $error';
    }
  }

  @override
  Future<String?> stop() async {
    final AppBootstrap bootstrap = ref.read(bootstrapProvider);
    try {
      await _service.stop();
      await bootstrap.native.stopForegroundService();
      return null;
    } on Object catch (error) {
      return 'Could not stop the server: $error';
    }
  }

  @override
  Future<String?> restart() async {
    final AppBootstrap bootstrap = ref.read(bootstrapProvider);
    final bool wasRunning = _service.snapshot.isRunning;
    try {
      await _service.stop();
      await _applyDocumentRoot();
      if (wasRunning) {
        return await start();
      }
      return null;
    } on Object catch (error) {
      bootstrap.logs.error(LogSource.webServer, 'Restart failed: $error');
      return 'Could not restart the server: $error';
    }
  }

  /// Applies a new port/LAN setting; restarts when the server is running.
  @override
  Future<String?> applyNetworkSettings() async {
    return restart();
  }

  @override
  Future<bool> openWebsite() async {
    final String url = state.primaryUrl;
    return ref.read(linkOpenerProvider).open(url);
  }
}

final NotifierProvider<WebServerNotifier, WebServerSnapshot> webServerProvider =
    NotifierProvider<WebServerNotifier, WebServerSnapshot>(
  WebServerNotifier.new,
);

/// ---------------------------------------------------------------------------
/// PHP runtime
/// ---------------------------------------------------------------------------

class PhpRuntimeNotifier extends AsyncNotifier<PhpRuntimeInfo>
    implements PhpRuntimeController {
  bool _disposed = false;

  @override
  Future<PhpRuntimeInfo> build() async {
    final AppBootstrap bootstrap = ref.watch(bootstrapProvider);
    ref.onDispose(() {
      _disposed = true;
    });
    final PhpRuntimeInfo cached = bootstrap.php.info;
    if (cached.checkedAt != null) {
      return cached;
    }
    return bootstrap.php.refresh();
  }

  @override
  Future<PhpRuntimeInfo?> refresh() async {
    final AppBootstrap bootstrap = ref.read(bootstrapProvider);
    if (!_disposed) {
      state = const AsyncValue<PhpRuntimeInfo>.loading();
    }
    final PhpRuntimeInfo info = await bootstrap.php.refresh();
    if (!_disposed) {
      state = AsyncValue<PhpRuntimeInfo>.data(info);
    }
    return info;
  }
}

final AsyncNotifierProvider<PhpRuntimeNotifier, PhpRuntimeInfo>
    phpRuntimeProvider =
    AsyncNotifierProvider<PhpRuntimeNotifier, PhpRuntimeInfo>(
  PhpRuntimeNotifier.new,
);

final Provider<ServiceStatus> phpStatusProvider = Provider<ServiceStatus>(
  (Ref ref) {
    final AsyncValue<PhpRuntimeInfo> value = ref.watch(phpRuntimeProvider);
    final PhpRuntimeInfo? info = value.valueOrNull;
    if (info == null) {
      return const ServiceStatus.unavailable('Checking PHP runtime...');
    }
    return info.toStatus();
  },
);

/// ---------------------------------------------------------------------------
/// Database
/// ---------------------------------------------------------------------------

class DatabaseOverview {
  const DatabaseOverview({
    required this.sqlite,
    required this.mariadb,
    required this.databases,
    required this.loadedAt,
  });

  final EngineAvailability sqlite;
  final EngineAvailability mariadb;
  final List<DatabaseInfo> databases;
  final DateTime loadedAt;

  ServiceStatus toStatus() {
    if (!sqlite.available) {
      return ServiceStatus.unavailable(sqlite.reason ?? 'SQLite unavailable');
    }
    return ServiceStatus(
      ServiceState.running,
      message: 'SQLite ${sqlite.version ?? ''}'.trim(),
    );
  }
}

class DatabaseNotifier extends AsyncNotifier<DatabaseOverview>
    implements DatabaseController {
  bool _disposed = false;

  @override
  Future<DatabaseOverview> build() async {
    ref.onDispose(() {
      _disposed = true;
    });
    return _load();
  }

  Future<DatabaseOverview> _load() async {
    final SqliteDatabaseRepository repository =
        ref.read(databaseRepositoryProvider);
    final AppBootstrap bootstrap = ref.read(bootstrapProvider);
    final EngineAvailability sqlite = await repository.availability();
    final EngineAvailability mariadb = EngineAvailability.unavailable(
      DatabaseEngineId.mariadb,
      'MariaDB is not bundled with this build. See the Database tab for the '
          'evaluation notes.',
    );
    List<DatabaseInfo> databases = <DatabaseInfo>[];
    if (sqlite.available) {
      databases = await repository.listDatabases();
    } else {
      bootstrap.logs.warning(
        LogSource.database,
        'SQLite unavailable: ${sqlite.reason ?? 'unknown'}',
      );
    }
    return DatabaseOverview(
      sqlite: sqlite,
      mariadb: mariadb,
      databases: databases,
      loadedAt: DateTime.now(),
    );
  }

  @override
  Future<void> refresh() async {
    if (_disposed) {
      return;
    }
    state = const AsyncValue<DatabaseOverview>.loading();
    final AsyncValue<DatabaseOverview> next =
        await AsyncValue.guard<DatabaseOverview>(_load);
    if (!_disposed) {
      state = next;
    }
  }

  @override
  Future<String?> createDatabase(String name) async {
    final SqliteDatabaseRepository repository =
        ref.read(databaseRepositoryProvider);
    try {
      await repository.createDatabase(name);
      await refresh();
      return null;
    } on AppFailure catch (failure) {
      return failure.combined;
    }
  }

  @override
  Future<String?> deleteDatabase(String name) async {
    final SqliteDatabaseRepository repository =
        ref.read(databaseRepositoryProvider);
    try {
      await repository.deleteDatabase(name);
      await refresh();
      return null;
    } on AppFailure catch (failure) {
      return failure.combined;
    }
  }
}

final AsyncNotifierProvider<DatabaseNotifier, DatabaseOverview>
    databaseProvider =
    AsyncNotifierProvider<DatabaseNotifier, DatabaseOverview>(
  DatabaseNotifier.new,
);

final Provider<ServiceStatus> databaseStatusProvider = Provider<ServiceStatus>(
  (Ref ref) {
    final AsyncValue<DatabaseOverview> value = ref.watch(databaseProvider);
    final DatabaseOverview? overview = value.valueOrNull;
    if (overview == null) {
      return const ServiceStatus.unavailable('Checking database engine...');
    }
    return overview.toStatus();
  },
);

/// ---------------------------------------------------------------------------
/// Projects
/// ---------------------------------------------------------------------------

class ProjectsNotifier extends AsyncNotifier<List<Project>>
    implements ProjectController {
  bool _disposed = false;

  @override
  Future<List<Project>> build() async {
    ref.onDispose(() {
      _disposed = true;
    });
    return ref.watch(projectRepositoryProvider).load();
  }

  @override
  Future<void> reload() async {
    final List<Project> projects = await ref.read(projectRepositoryProvider).load();
    if (!_disposed) {
      state = AsyncValue<List<Project>>.data(projects);
    }
  }

  @override
  Future<String?> create({
    required String name,
    required ProjectTemplate template,
    String description = '',
  }) async {
    try {
      final Project project = await ref.read(projectRepositoryProvider).create(
            name: name,
            template: template,
            description: description,
          );
      await reload();
      await activate(project);
      return null;
    } on AppFailure catch (failure) {
      return failure.combined;
    }
  }

  @override
  Future<String?> duplicate(Project project, String newName) async {
    try {
      await ref
          .read(projectRepositoryProvider)
          .duplicate(project, newName: newName);
      await reload();
      return null;
    } on AppFailure catch (failure) {
      return failure.combined;
    }
  }

  @override
  Future<String?> delete(Project project) async {
    final SettingsController settings = ref.read(settingsProvider.notifier);
    final AppSettings current = ref.read(settingsProvider);
    if (current.activeProjectId == project.id) {
      await settings.setActiveProject('');
      await ref.read(webServerProvider.notifier).restart();
    }
    try {
      await ref.read(projectRepositoryProvider).delete(project);
      await reload();
      return null;
    } on AppFailure catch (failure) {
      return failure.combined;
    }
  }

  @override
  Future<String?> importZip(File archive, {String? name}) async {
    try {
      await ref
          .read(projectRepositoryProvider)
          .importZip(archive, name: name);
      await reload();
      return null;
    } on AppFailure catch (failure) {
      return failure.combined;
    }
  }

  /// Exports a project ZIP into `tmp` and returns the file for sharing.
  @override
  Future<File?> exportZip(Project project) async {
    final AppBootstrap bootstrap = ref.read(bootstrapProvider);
    final File destination =
        await bootstrap.workspace.createTempFile('export', '.zip');
    try {
      return await ref
          .read(projectRepositoryProvider)
          .exportZip(project, destination);
    } on AppFailure catch (failure) {
      bootstrap.logs.error(LogSource.app, failure.combined);
      return null;
    }
  }

  @override
  Future<void> activate(Project? project) async {
    final SettingsController settings = ref.read(settingsProvider.notifier);
    await settings.setActiveProject(project?.id ?? '');
    await ref.read(webServerProvider.notifier).restart();
  }
}

final AsyncNotifierProvider<ProjectsNotifier, List<Project>> projectsProvider =
    AsyncNotifierProvider<ProjectsNotifier, List<Project>>(
  ProjectsNotifier.new,
);

final Provider<Project?> activeProjectProvider = Provider<Project?>((Ref ref) {
  final AppSettings settings = ref.watch(settingsProvider);
  final List<Project>? projects = ref.watch(projectsProvider).valueOrNull;
  if (settings.activeProjectId.isEmpty || projects == null) {
    return null;
  }
  for (final Project project in projects) {
    if (project.id == settings.activeProjectId) {
      return project;
    }
  }
  return null;
});

/// ---------------------------------------------------------------------------
/// Backups
/// ---------------------------------------------------------------------------

class BackupsNotifier extends AsyncNotifier<List<BackupInfo>> {
  bool _disposed = false;

  @override
  Future<List<BackupInfo>> build() async {
    ref.onDispose(() {
      _disposed = true;
    });
    return ref.watch(backupServiceProvider).list();
  }

  Future<void> reload() async {
    final List<BackupInfo> backups = await ref.read(backupServiceProvider).list();
    if (!_disposed) {
      state = AsyncValue<List<BackupInfo>>.data(backups);
    }
  }

  Future<String?> create({
    bool includeProjects = true,
    bool includeWebRoot = true,
    bool includeDatabases = true,
    bool includeConfig = true,
  }) async {
    try {
      await ref.read(backupServiceProvider).create(
            includeProjects: includeProjects,
            includeWebRoot: includeWebRoot,
            includeDatabases: includeDatabases,
            includeConfig: includeConfig,
          );
      await reload();
      return null;
    } on AppFailure catch (failure) {
      return failure.combined;
    }
  }

  Future<String?> restore(BackupInfo backup) async {
    try {
      await ref.read(backupServiceProvider).restore(backup);
      await reload();
      await ref.read(projectsProvider.notifier).reload();
      await ref.read(databaseProvider.notifier).refresh();
      return null;
    } on AppFailure catch (failure) {
      return failure.combined;
    }
  }

  Future<String?> delete(BackupInfo backup) async {
    try {
      await ref.read(backupServiceProvider).delete(backup);
      await reload();
      return null;
    } on AppFailure catch (failure) {
      return failure.combined;
    }
  }
}

final AsyncNotifierProvider<BackupsNotifier, List<BackupInfo>> backupsProvider =
    AsyncNotifierProvider<BackupsNotifier, List<BackupInfo>>(
  BackupsNotifier.new,
);

/// ---------------------------------------------------------------------------
/// Storage & dashboard aggregate
/// ---------------------------------------------------------------------------

final FutureProvider<StorageReport> storageReportProvider =
    FutureProvider<StorageReport>((Ref ref) async {
  final AppBootstrap bootstrap = ref.watch(bootstrapProvider);
  return bootstrap.storageReport();
});

final Provider<ServiceAggregate> serviceAggregateProvider =
    Provider<ServiceAggregate>((Ref ref) {
  final ServiceStatus php = ref.watch(phpStatusProvider);
  final ServiceStatus database = ref.watch(databaseStatusProvider);
  final WebServerSnapshot server = ref.watch(webServerProvider);
  return ServiceAggregate(
    webServer: server.toStatus(),
    phpRuntime: php,
    database: database,
  );
});

/// ---------------------------------------------------------------------------
/// Terminal
/// ---------------------------------------------------------------------------

class AppTerminalApi implements TerminalApi {
  AppTerminalApi(this.ref);

  final Ref ref;

  @override
  String get workspaceRoot => ref.read(bootstrapProvider).workspace.rootPath;

  @override
  AppSettings get settings => ref.read(settingsProvider);

  @override
  WebServerSnapshot get serverSnapshot => ref.read(webServerProvider);

  @override
  Future<List<FileEntry>> listFiles(String relativePath) =>
      ref.read(fileRepositoryProvider).list(relativePath);

  @override
  Future<String> readTextFile(String relativePath) async {
    final String text = await ref.read(fileRepositoryProvider).readText(
          relativePath,
          maxBytes: 256 * 1024,
        );
    return text;
  }

  @override
  Future<String> startServer() async {
    final String? error = await ref.read(webServerProvider.notifier).start();
    if (error != null) {
      return 'start failed: $error';
    }
    return 'server started on port ${ref.read(webServerProvider).port}';
  }

  @override
  Future<String> stopServer() async {
    final String? error = await ref.read(webServerProvider.notifier).stop();
    if (error != null) {
      return 'stop failed: $error';
    }
    return 'server stopped';
  }

  @override
  Future<String> restartServer() async {
    final String? error = await ref.read(webServerProvider.notifier).restart();
    if (error != null) {
      return 'restart failed: $error';
    }
    return 'server restarted on port ${ref.read(webServerProvider).port}';
  }

  @override
  Future<PhpRuntimeInfo> phpInfo({bool refresh = false}) async {
    if (refresh) {
      final PhpRuntimeInfo? info =
          await ref.read(phpRuntimeProvider.notifier).refresh();
      if (info != null) {
        return info;
      }
    }
    return ref.read(bootstrapProvider).php.info;
  }

  @override
  Future<List<DatabaseInfo>> databases() async {
    final SqliteDatabaseRepository repository =
        ref.read(databaseRepositoryProvider);
    return repository.listDatabases();
  }

  @override
  Future<List<TableInfo>> tables(String database) =>
      ref.read(databaseRepositoryProvider).listTables(database);

  @override
  Future<EngineAvailability> databaseAvailability() =>
      ref.read(databaseRepositoryProvider).availability();

  @override
  Future<List<Project>> projects() =>
      ref.read(projectRepositoryProvider).load();

  @override
  List<LogEntry> recentLogs({LogSource? source, int limit = 20}) {
    return ref
        .read(logRepositoryProvider)
        .filtered(source: source)
        .take(limit)
        .toList(growable: false);
  }

  @override
  Future<String> storageSummary() async {
    final StorageUsage usage = await ref.read(bootstrapProvider).workspace.measure();
    final NativeStorageStats? native =
        await ref.read(nativeBridgeProvider).storageStats();
    final StringBuffer buffer = StringBuffer()
      ..writeln('workspace: ${ref.read(bootstrapProvider).workspace.rootPath}')
      ..writeln('files: ${usage.fileCount}')
      ..writeln('bytes: ${usage.totalBytes}');
    if (native != null) {
      buffer.writeln('device free: ${native.freeBytes} bytes');
    }
    return buffer.toString().trimRight();
  }
}

final Provider<TerminalApi> terminalApiProvider = Provider<TerminalApi>(
  (Ref ref) => AppTerminalApi(ref),
);

final Provider<TerminalService> terminalServiceProvider =
    Provider<TerminalService>(
  (Ref ref) => TerminalService(ref.watch(terminalApiProvider)),
);
