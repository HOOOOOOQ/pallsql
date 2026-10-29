import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart' as sqflite;

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
import '../services/legacy_sqlite_migration.dart';
import '../services/link_opener.dart';
import '../services/mariadb/mariadb_service.dart';
import '../services/native_bridge.dart';
import '../services/php_runtime_service.dart';
import '../services/query_store.dart';
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
    Provider<NativeDeviceInfo?>(
        (Ref ref) => ref.watch(bootstrapProvider).deviceInfo);

final Provider<FileRepository> fileRepositoryProvider =
    Provider<FileRepository>(
  (Ref ref) => ref.watch(bootstrapProvider).files,
);

final Provider<ProjectRepository> projectRepositoryProvider =
    Provider<ProjectRepository>(
        (Ref ref) => ref.watch(bootstrapProvider).projects);

final Provider<MariaDbRepository> databaseRepositoryProvider =
    Provider<MariaDbRepository>(
  (Ref ref) => ref.watch(bootstrapProvider).databases,
);

final Provider<BackupService> backupServiceProvider = Provider<BackupService>(
  (Ref ref) => ref.watch(bootstrapProvider).backups,
);

/// Saved SQL snippets live in `PALLSQL/config/queries`.
final Provider<QueryStore> queryStoreProvider = Provider<QueryStore>(
  (Ref ref) => QueryStore(ref.watch(bootstrapProvider).workspace.queries),
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
    required this.mariadb,
    required this.runtime,
    required this.databases,
    required this.loadedAt,
  });

  /// Availability of the MariaDB **engine** (a real connection succeeded).
  final EngineAvailability mariadb;

  /// State of the native server process.
  final MariaDbStatus runtime;

  final List<DatabaseInfo> databases;
  final DateTime loadedAt;

  bool get isRunning => runtime.isRunning;

  ServiceStatus toStatus() {
    if (!mariadb.available) {
      return ServiceStatus(
        runtime.state.serviceState,
        message: runtime.message.isEmpty
            ? (mariadb.reason ?? 'MariaDB is not running')
            : runtime.message,
      );
    }
    return ServiceStatus(
      ServiceState.running,
      message: 'MariaDB ${mariadb.version ?? ''}'.trim(),
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
    final MariaDbRepository repository =
        ref.read(databaseRepositoryProvider);
    final AppBootstrap bootstrap = ref.read(bootstrapProvider);
    // Touch the process state first: the engine probe below is a real TCP +
    // protocol round trip, so it can only succeed when a server is running.
    final MariaDbStatus runtime = await bootstrap.mariadb.refresh();
    final EngineAvailability mariadb = await repository.availability();
    List<DatabaseInfo> databases = <DatabaseInfo>[];
    if (mariadb.available) {
      try {
        databases = await repository.listDatabases();
      } on Object catch (error) {
        bootstrap.logs.warning(
          LogSource.database,
          'SHOW DATABASES failed: $error',
        );
      }
    } else {
      bootstrap.logs.debug(
        LogSource.database,
        'MariaDB unavailable: ${mariadb.reason ?? 'unknown'}',
      );
    }
    return DatabaseOverview(
      mariadb: mariadb,
      runtime: runtime,
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
    final MariaDbRepository repository =
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
    final MariaDbRepository repository =
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

/// The native MariaDB service manager (lifecycle, config, logs).
/// Reader for the SQLite files PALLSQL 0.1/0.2 created.
///
/// This is the **only** provider that imports sqflite, and the only way the app
/// can still open an SQLite file: read-only, on explicit user request, to copy
/// the data into MariaDB. Nothing in the write path can reach it, so SQLite
/// cannot come back as an engine.
final Provider<LegacySqliteMigration> legacyMigrationProvider =
    Provider<LegacySqliteMigration>((Ref ref) {
  final AppBootstrap bootstrap = ref.watch(bootstrapProvider);
  return LegacySqliteMigration(
    directory: Directory(p.join(bootstrap.workspace.rootPath, 'database')),
    repository: bootstrap.databases,
    factory: sqflite.databaseFactory,
    logs: bootstrap.logs,
  );
});

final Provider<MariaDBServiceManager> mariadbServiceProvider =
    Provider<MariaDBServiceManager>(
  (Ref ref) => ref.watch(bootstrapProvider).mariadb,
);

/// Live status of the MariaDB server, updated by the manager itself.
final StreamProvider<MariaDbStatus> mariadbStatusProvider =
    StreamProvider<MariaDbStatus>((Ref ref) {
  final MariaDBServiceManager manager = ref.watch(mariadbServiceProvider);
  return manager.changes;
});

final AsyncNotifierProvider<DatabaseNotifier, DatabaseOverview>
    databaseProvider =
    AsyncNotifierProvider<DatabaseNotifier, DatabaseOverview>(
  DatabaseNotifier.new,
);

/// Reactive view of the SQL editor history.
///
/// The repository owns the data (it persists `config/query_history.json`), the
/// notifier only mirrors it into the widget tree and tells the UI when to
/// rebuild after a statement ran somewhere else.
class QueryHistoryNotifier extends Notifier<List<QueryHistoryEntry>> {
  @override
  List<QueryHistoryEntry> build() => _current(watch: true);

  void refresh() {
    state = _current(watch: false);
  }

  List<QueryHistoryEntry> _current({required bool watch}) {
    final MariaDbRepository repository = watch
        ? ref.watch(databaseRepositoryProvider)
        : ref.read(databaseRepositoryProvider);
    return List<QueryHistoryEntry>.from(repository.history);
  }

  Future<void> clear() async {
    await ref.read(databaseRepositoryProvider).clearHistory();
    refresh();
  }
}

final NotifierProvider<QueryHistoryNotifier, List<QueryHistoryEntry>>
    queryHistoryProvider =
    NotifierProvider<QueryHistoryNotifier, List<QueryHistoryEntry>>(
  QueryHistoryNotifier.new,
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
    final List<Project> projects =
        await ref.read(projectRepositoryProvider).load();
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
      await ref.read(projectRepositoryProvider).importZip(archive, name: name);
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
    final List<BackupInfo> backups =
        await ref.read(backupServiceProvider).list();
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
    final MariaDbRepository repository =
        ref.read(databaseRepositoryProvider);
    return repository.listDatabases();
  }

  @override
  Future<List<TableInfo>> tables(String database) =>
      ref.read(databaseRepositoryProvider).listTables(database);

  @override
  Future<QueryResult> runSql(
    String database,
    String sql, {
    bool allowDestructive = false,
  }) async {
    final QueryResult result =
        await ref.read(databaseRepositoryProvider).execute(
              database,
              sql,
              allowDestructive: allowDestructive,
            );
    ref.read(queryHistoryProvider.notifier).refresh();
    await ref.read(databaseProvider.notifier).refresh();
    return result;
  }

  @override
  Future<void> createDatabase(String name) async {
    final String? error =
        await ref.read(databaseProvider.notifier).createDatabase(name);
    if (error != null) {
      throw AppFailure(error);
    }
  }

  @override
  Future<EngineAvailability> databaseAvailability() =>
      ref.read(databaseRepositoryProvider).availability();

  @override
  MariaDbStatus get mariaDbStatus => ref.read(mariadbServiceProvider).snapshot();

  @override
  Future<String> startMariaDb() async {
    final MariaDBServiceManager manager = ref.read(mariadbServiceProvider);
    final bool ok = await manager.start();
    await ref.read(databaseProvider.notifier).refresh();
    final MariaDbStatus status = manager.snapshot();
    return ok ? status.message : 'MariaDB did not start: ${status.message}';
  }

  @override
  Future<String> stopMariaDb() async {
    final MariaDBServiceManager manager = ref.read(mariadbServiceProvider);
    final bool ok = await manager.stop();
    await ref.read(databaseProvider.notifier).refresh();
    return ok ? 'MariaDB stopped' : 'MariaDB could not be stopped';
  }

  @override
  Future<String> restartMariaDb() async {
    final MariaDBServiceManager manager = ref.read(mariadbServiceProvider);
    final bool ok = await manager.restart();
    await ref.read(databaseProvider.notifier).refresh();
    return ok ? manager.snapshot().message : 'MariaDB restart failed';
  }

  @override
  Future<String> initializeMariaDb() async {
    final MariaDBServiceManager manager = ref.read(mariadbServiceProvider);
    final bool ok = await manager.initialize();
    return ok
        ? 'Data directory ready at ${manager.dataDirectory}'
        : manager.snapshot().message;
  }

  @override
  Future<String> mariaDbLogTail() =>
      ref.read(mariadbServiceProvider).readErrorLogTail(30);

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
    final StorageUsage usage =
        await ref.read(bootstrapProvider).workspace.measure();
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
