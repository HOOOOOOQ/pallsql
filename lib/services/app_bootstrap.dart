import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/app_settings.dart';
import '../models/database_models.dart';
import '../models/log_entry.dart';
import '../repositories/database_repository.dart';
import '../repositories/file_repository.dart';
import '../repositories/log_repository.dart';
import '../repositories/project_repository.dart';
import '../repositories/settings_repository.dart';
import 'backup_service.dart';
import 'mariadb/mariadb_client.dart';
import 'mariadb/mariadb_config.dart';
import 'mariadb/mariadb_service.dart';
import 'mariadb/mysql_connection.dart';
import 'native_bridge.dart';
import 'php_runtime_service.dart';
import 'web_server_service.dart';
import 'workspace_service.dart';

/// Combined storage information for the dashboard/settings screens.
class StorageReport {
  const StorageReport({
    required this.workspaceBytes,
    required this.workspaceFiles,
    this.deviceFreeBytes,
    this.deviceTotalBytes,
    this.appBytes,
  });

  final int workspaceBytes;
  final int workspaceFiles;
  final int? deviceFreeBytes;
  final int? deviceTotalBytes;
  final int? appBytes;
}

/// Wires every PALLSQL service together exactly once at startup.
///
/// Widget tests build their own bootstrap with a temporary workspace and an
/// FFI SQLite factory, which is why this class never touches platform channels
/// unless it is asked to.
class AppBootstrap {
  AppBootstrap({
    required this.workspace,
    required this.logs,
    required this.settingsRepository,
    required this.settings,
    required this.native,
    required this.deviceInfo,
    required this.php,
    required this.webServer,
    required this.files,
    required this.projects,
    required this.databases,
    required this.backups,
    required this.mariadb,
  });

  final Workspace workspace;
  final LogRepository logs;
  final SettingsRepository settingsRepository;
  final NativeBridge native;
  final NativeDeviceInfo? deviceInfo;
  final PhpRuntimeService php;
  final WebServerService webServer;
  final FileRepository files;
  final ProjectRepository projects;
  final MariaDbRepository databases;

  /// Lifecycle owner of the native MariaDB server.
  final MariaDBServiceManager mariadb;
  final BackupService backups;
  AppSettings settings;

  /// Builds the whole object graph. [databaseFactory] must be a working
  /// sqflite factory (`databaseFactory` on Android, `databaseFactoryFfi` in
  /// tests).
  static Future<AppBootstrap> create({
    Directory? workspaceRoot,
    NativeBridge? native,
    bool startServerIfConfigured = true,
    bool startDatabaseIfConfigured = true,
    MariaDbConfig? mariaDbConfig,
    void Function(String step)? onProgress,
  }) async {
    onProgress?.call('Preparing workspace');
    final Directory root;
    if (workspaceRoot != null) {
      root = workspaceRoot;
    } else {
      final Directory documents = await getApplicationDocumentsDirectory();
      root = Directory(p.join(documents.path, 'PALLSQL'));
    }
    final Workspace workspace = await Workspace.open(root);
    onProgress?.call('Workspace folders ready');
    final SettingsRepository settingsRepository =
        SettingsRepository(workspace.settingsFile);
    final AppSettings settings = await settingsRepository.load();
    onProgress?.call('Configuration loaded');
    final LogRepository logs = LogRepository(
      file: workspace.appLogFile,
      maxEntries: settings.maxLogEntries,
    );
    await logs.load();
    onProgress?.call('Log buffer ready');
    logs.info(
      LogSource.app,
      'PALLSQL starting in ${workspace.rootPath}',
    );

    final NativeBridge bridge = native ?? NativeBridge(logs: logs);
    final NativeDeviceInfo? deviceInfo = await bridge.deviceInfo();
    onProgress?.call('Device information read');
    if (deviceInfo != null) {
      logs.info(
        LogSource.app,
        'Android ${deviceInfo.androidVersion} (API ${deviceInfo.sdkInt}), '
        'ABIs ${deviceInfo.abis.join(', ')}',
      );
    }

    final PhpRuntimeService php = PhpRuntimeService(
      workspace: workspace,
      logs: logs,
      configuredRelativePath: settings.phpBinaryPath,
      nativeLibraryDirProvider:
          bridge.isAvailable ? bridge.nativeLibraryDir : null,
    );
    await php.refresh();
    onProgress?.call(
      php.info.available ? 'PHP runtime detected' : 'No PHP runtime found',
    );

    final FileRepository files =
        FileRepository(workspace: workspace, logs: logs);
    final ProjectRepository projects =
        ProjectRepository(workspace: workspace, logs: logs);
    // ---------------------------------------------------------------
    // MariaDB: the only database engine in PALLSQL.
    // The server process is native, the client speaks the MariaDB wire
    // protocol; there is no embedded fallback.
    // ---------------------------------------------------------------
    final MariaDbConfigStore mariadbConfigStore = MariaDbConfigStore(
      directory: Directory(p.join(workspace.rootPath, 'config', 'server')),
    );
    final MariaDbConfig mariadbConfig = mariaDbConfig ??
        await mariadbConfigStore.load();
    final MariaDBServiceManager mariadb = MariaDBServiceManager(
      workspaceRoot: workspace.rootPath,
      native: bridge,
      logs: logs,
      config: mariadbConfig,
      configStore: mariadbConfigStore,
    );
    final MariaDbClient mariadbClient = MariaDbClient(
      MariaDbConnectionConfig(
        host: mariadbConfig.host,
        port: mariadbConfig.port,
        user: mariadbConfig.user,
        password: mariadbConfig.password,
      ),
      logs: logs,
    );
    final MariaDbRepository databases = MariaDbRepository(
      client: mariadbClient,
      logs: logs,
      historyFile: workspace.queryHistoryFile,
    );
    await databases.loadHistory();
    onProgress?.call('MariaDB runtime detected');
    if (startDatabaseIfConfigured) {
      final MariaDbRuntimeInfo runtime = await mariadb.refreshRuntime();
      if (runtime.installed) {
        final MariaDbStatus status = await mariadb.refresh();
        if (!status.isRunning) {
          logs.info(
            LogSource.database,
            'MariaDB runtime present but stopped; starting it',
          );
          await mariadb.start();
        }
      } else {
        logs.warning(
          LogSource.database,
          'MariaDB runtime unavailable: ${runtime.reason}',
        );
      }
    }
    final EngineAvailability mariadbAvailability = await databases.availability();
    logs.info(
      LogSource.database,
      mariadbAvailability.available
          ? 'MariaDB ${mariadbAvailability.version ?? ''} ready'.trim()
          : 'MariaDB unavailable: ${mariadbAvailability.reason ?? 'unknown'}',
    );
    onProgress?.call(
      mariadbAvailability.available
          ? 'MariaDB server ready'
          : 'MariaDB runtime not installed',
    );
    final BackupService backups =
        BackupService(workspace: workspace, logs: logs);

    try {
      await projects.load();
    } on Object catch (error) {
      logs.warning(LogSource.app, 'Project metadata could not be read: $error');
    }
    onProgress?.call('Project metadata loaded');

    final Directory documentRoot =
        await workspace.resolveDocumentRoot(settings.activeProjectId);
    final WebServerService webServer = WebServerService(
      documentRoot: documentRoot,
      logs: logs,
      phpBridge: php,
    );

    final AppBootstrap bootstrap = AppBootstrap(
      workspace: workspace,
      logs: logs,
      settingsRepository: settingsRepository,
      settings: settings,
      native: bridge,
      deviceInfo: deviceInfo,
      php: php,
      webServer: webServer,
      files: files,
      projects: projects,
      databases: databases,
      backups: backups,
      mariadb: mariadb,
    );

    if (startServerIfConfigured && settings.autoStartServer) {
      try {
        await webServer.start(
          port: settings.httpPort,
          lanAccess: settings.lanAccess,
        );
        if (settings.notificationsEnabled) {
          await bridge.startForegroundService(
            title: 'PALLSQL server running',
            text: 'Serving http://127.0.0.1:${settings.httpPort}/',
          );
        }
      } on Object catch (error) {
        logs.error(LogSource.webServer, 'Autostart failed: $error');
      }
    }
    onProgress?.call('Environment ready');
    return bootstrap;
  }

  /// Persists settings and applies the runtime side effects.
  Future<void> updateSettings(AppSettings next) async {
    final List<String> issues = next.validate();
    if (issues.isNotEmpty) {
      throw FormatException(issues.first);
    }
    await settingsRepository.save(next);
    logs.setMaxEntries(next.maxLogEntries);
    php.updateConfiguredPath(next.phpBinaryPath);
    settings = next;
    logs.info(
      LogSource.app,
      'Settings saved (port ${next.httpPort}, LAN ${next.lanAccess ? 'on' : 'off'})',
    );
  }

  Future<StorageReport> storageReport() async {
    final StorageUsage usage = await workspace.measure();
    final NativeStorageStats? stats = await native.storageStats();
    return StorageReport(
      workspaceBytes: usage.totalBytes,
      workspaceFiles: usage.fileCount,
      deviceFreeBytes: stats?.freeBytes,
      deviceTotalBytes: stats?.totalBytes,
      appBytes: stats?.appBytes,
    );
  }

  Future<void> dispose() async {
    await webServer.dispose();
    await databases.dispose();
    await native.dispose();
    await logs.dispose();
  }
}
