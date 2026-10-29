import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../core/constants/app_info.dart';
import '../../models/log_entry.dart';
import '../../models/service_status.dart';
import '../log_sink.dart';
import '../native_bridge.dart';
import 'mariadb_client.dart';
import 'mariadb_config.dart';
import 'mysql_connection.dart';
import 'mysql_protocol.dart';

/// Lifecycle of the native MariaDB server process.
///
/// The values map onto [ServiceState] but keep one extra distinction the UI
/// needs: `notInstalled` is different from `unavailable` because the fix is
/// "build/install the runtime", not "start it".
enum MariaDbRuntimeState {
  notInstalled,
  stopped,
  initializing,
  starting,
  running,
  stopping,
  error;

  ServiceState get serviceState {
    switch (this) {
      case MariaDbRuntimeState.notInstalled:
      case MariaDbRuntimeState.stopped:
        return ServiceState.stopped;
      case MariaDbRuntimeState.initializing:
      case MariaDbRuntimeState.starting:
        return ServiceState.starting;
      case MariaDbRuntimeState.running:
        return ServiceState.running;
      case MariaDbRuntimeState.stopping:
        return ServiceState.stopping;
      case MariaDbRuntimeState.error:
        return ServiceState.error;
    }
  }

  String get label {
    switch (this) {
      case MariaDbRuntimeState.notInstalled:
        return 'Not installed';
      case MariaDbRuntimeState.stopped:
        return 'Stopped';
      case MariaDbRuntimeState.initializing:
        return 'Initializing';
      case MariaDbRuntimeState.starting:
        return 'Starting';
      case MariaDbRuntimeState.running:
        return 'Running';
      case MariaDbRuntimeState.stopping:
        return 'Stopping';
      case MariaDbRuntimeState.error:
        return 'Error';
    }
  }
}

/// What the native layer reports about the bundled runtime.
class MariaDbRuntimeInfo {
  const MariaDbRuntimeInfo({
    required this.installed,
    required this.serverBinary,
    required this.supportBinaries,
    required this.abies,
    required this.reason,
    this.baseDirectory,
    this.version,
  });

  final bool installed;
  final String? serverBinary;
  final List<String> supportBinaries;
  final List<String> abies;

  /// Precise technical reason when [installed] is false.
  final String reason;
  final String? baseDirectory;
  final String? version;

  static const MariaDbRuntimeInfo missing = MariaDbRuntimeInfo(
    installed: false,
    serverBinary: null,
    supportBinaries: <String>[],
    abies: <String>[],
    reason: 'Runtime check has not run yet',
  );
}

/// Snapshot handed to the UI after every state change.
class MariaDbStatus {
  const MariaDbStatus({
    required this.state,
    required this.message,
    required this.runtime,
    this.pid,
    this.port,
    this.version,
    this.dataDirectory,
    this.errorLogPath,
    this.uptimeSeconds,
    this.connectionId,
    this.updatedAt,
  });

  final MariaDbRuntimeState state;
  final String message;
  final MariaDbRuntimeInfo runtime;
  final int? pid;
  final int? port;
  final String? version;
  final String? dataDirectory;
  final String? errorLogPath;
  final int? uptimeSeconds;
  final int? connectionId;
  final DateTime? updatedAt;

  bool get isRunning => state == MariaDbRuntimeState.running;

  ServiceStatus toServiceStatus() => ServiceStatus(
        state.serviceState,
        message: message,
        updatedAt: updatedAt,
      );

  MariaDbStatus copyWith({
    MariaDbRuntimeState? state,
    String? message,
    MariaDbRuntimeInfo? runtime,
    int? pid,
    int? port,
    String? version,
    String? dataDirectory,
    String? errorLogPath,
    int? uptimeSeconds,
    int? connectionId,
    DateTime? updatedAt,
  }) {
    return MariaDbStatus(
      state: state ?? this.state,
      message: message ?? this.message,
      runtime: runtime ?? this.runtime,
      pid: pid ?? this.pid,
      port: port ?? this.port,
      version: version ?? this.version,
      dataDirectory: dataDirectory ?? this.dataDirectory,
      errorLogPath: errorLogPath ?? this.errorLogPath,
      uptimeSeconds: uptimeSeconds ?? this.uptimeSeconds,
      connectionId: connectionId ?? this.connectionId,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}

/// The single owner of the MariaDB server lifecycle.
///
/// * the **process** is started and stopped by the native layer
///   (`MariaDbProcessManager.kt`), which exec()s the bundled `mariadbd`;
/// * the **health** of the server is always proven by a real protocol
///   connection ([MariaDbClient]), never by "the process exists";
/// * the data directory is initialised exactly once, and an existing data
///   directory is never re-initialised.
class MariaDBServiceManager {
  MariaDBServiceManager({
    required this.workspaceRoot,
    required this.native,
    required this.logs,
    MariaDbConfig? config,
    MariaDbConfigStore? configStore,
    MariaDbClient? client,
  })  : _config = config ?? MariaDbConfig.defaults,
        _configStore = configStore ??
            MariaDbConfigStore(
              directory: Directory(p.join(workspaceRoot, 'config', 'server')),
            ),
        _client = client;

  /// `PALLSQL/` root.
  final String workspaceRoot;
  final NativeBridge native;
  final LogSink logs;
  final MariaDbConfigStore _configStore;

  MariaDbConfig _config;
  MariaDbClient? _client;
  MariaDbRuntimeInfo _runtime = MariaDbRuntimeInfo.missing;
  MariaDbRuntimeState _state = MariaDbRuntimeState.stopped;
  String _message = 'MariaDB has not been started yet';
  int? _pid;
  String? _version;
  int? _uptime;
  bool _busy = false;
  bool _initialisedOnce = false;

  final StreamController<MariaDbStatus> _changes =
      StreamController<MariaDbStatus>.broadcast();

  MariaDbConfig get config => _config;

  MariaDbRuntimeInfo get runtime => _runtime;

  MariaDbRuntimeState get state => _state;

  bool get isBusy => _busy;

  Stream<MariaDbStatus> get changes => _changes.stream;

  /// Creates (or reuses) the protocol client for the current config.
  MariaDbClient get client {
    final MariaDbClient? existing = _client;
    if (existing != null) {
      return existing;
    }
    final MariaDbClient created = MariaDbClient(
      MariaDbConnectionConfig(
        host: _config.host,
        port: _config.port,
        user: _config.user,
        password: _config.password,
        database: _config.user.isEmpty ? null : null,
      ),
      logs: logs,
    );
    _client = created;
    return created;
  }

  String get dataDirectory => p.join(workspaceRoot, 'database', 'mariadb', 'data');

  String get runtimeDirectory => p.join(workspaceRoot, 'database', 'mariadb');

  String get errorLogPath => p.join(workspaceRoot, 'logs', 'mariadb-error.log');

  String get socketPath => p.join(runtimeDirectory, _config.socketName);

  MariaDbStatus snapshot() => MariaDbStatus(
        state: _state,
        message: _message,
        runtime: _runtime,
        pid: _pid,
        port: _config.port,
        version: _version,
        dataDirectory: dataDirectory,
        errorLogPath: errorLogPath,
        uptimeSeconds: _uptime,
        connectionId: _client?.connectionId,
        updatedAt: DateTime.now(),
      );

  void _emit(MariaDbStatus status) {
    if (!_changes.isClosed) {
      _changes.add(status);
    }
  }

  void _set(
    MariaDbRuntimeState state,
    String message, {
    int? pid,
    String? version,
    int? uptime,
  }) {
    _state = state;
    _message = message;
    if (pid != null) {
      _pid = pid;
    }
    if (version != null) {
      _version = version;
    }
    if (uptime != null) {
      _uptime = uptime;
    }
    _emit(snapshot());
  }

  Future<void> loadConfig() async {
    _config = await _configStore.load();
  }

  Future<void> saveConfig(MariaDbConfig next) async {
    final List<String> problems = next.validate();
    if (problems.isNotEmpty) {
      throw ArgumentError(problems.join('\n'));
    }
    final MariaDbConfig previous = _config;
    _config = next;
    await _configStore.save(next);
    final String? base = _runtime.baseDirectory;
    if (base != null) {
      await _configStore.writeCnf(
        config: next,
        dataDirectory: dataDirectory,
        baseDirectory: base,
        socketPath: next.skipNetworking ? socketPath : null,
        errorLogPath: errorLogPath,
        pidFile: p.join(runtimeDirectory, 'mariadb.pid'),
      );
    }
    if (previous.port != next.port ||
        previous.user != next.user ||
        previous.password != next.password ||
        previous.host != next.host) {
      await _client?.reconfigure(
        MariaDbConnectionConfig(
          host: next.host,
          port: next.port,
          user: next.user,
          password: next.password,
        ),
      );
    }
    logs.info(
      LogSource.database,
      'MariaDB config saved (port ${next.port}, bind ${next.bindAddress})',
    );
  }

  /// Asks the native layer which binaries are packaged for this ABI.
  Future<MariaDbRuntimeInfo> refreshRuntime() async {
    final Map<String, Object?>? raw =
        await native.mariaDbRuntimeInfo();
    if (raw == null) {
      _runtime = const MariaDbRuntimeInfo(
        installed: false,
        serverBinary: null,
        supportBinaries: <String>[],
        abies: <String>[],
        reason: 'The native layer did not answer '
            '(running on a platform without the MariaDB runtime)',
      );
      return _runtime;
    }
    final List<String> support = (raw['supportBinaries'] as List<Object?>? ??
            const <Object?>[])
        .map((Object? value) => value.toString())
        .toList(growable: false);
    final List<String> abies =
        (raw['abies'] as List<Object?>? ?? const <Object?>[])
            .map((Object? value) => value.toString())
            .toList(growable: false);
    _runtime = MariaDbRuntimeInfo(
      installed: raw['installed'] == true,
      serverBinary: raw['serverBinary']?.toString(),
      supportBinaries: support,
      abies: abies,
      reason: raw['reason']?.toString() ?? '',
      baseDirectory: raw['baseDirectory']?.toString(),
      version: raw['version']?.toString(),
    );
    if (!_runtime.installed) {
      _state = MariaDbRuntimeState.notInstalled;
      _message = _runtime.reason.isEmpty
          ? 'The MariaDB server binary is not packaged in this build'
          : _runtime.reason;
      _emit(snapshot());
    }
    return _runtime;
  }

  /// Reads the real state: process alive? TCP answers? version?
  Future<MariaDbStatus> refresh() async {
    if (_runtime.installed == false) {
      await refreshRuntime();
    }
    final Map<String, Object?>? process = await native.mariadbProcessStatus();
    final int? pid = (process?['pid'] as num?)?.toInt();
    final bool alive = process?['running'] == true;
    if (!alive) {
      if (_state == MariaDbRuntimeState.running ||
          _state == MariaDbRuntimeState.starting) {
        _client = null;
        _set(MariaDbRuntimeState.stopped, 'MariaDB is not running');
      } else if (_state != MariaDbRuntimeState.error) {
        _set(MariaDbRuntimeState.stopped, 'MariaDB is stopped');
      }
      return snapshot();
    }
    final EngineAvailabilityProbe probe = await _probe();
    if (probe.ok) {
      _set(
        MariaDbRuntimeState.running,
        'MariaDB ${probe.version ?? ''} answering on '
                '${_config.host}:${_config.port}'
            .trim(),
        pid: pid,
        version: probe.version,
        uptime: probe.uptime,
      );
    } else {
      _set(
        MariaDbRuntimeState.error,
        'mariadbd is alive (pid $pid) but does not accept connections: '
        '${probe.reason}',
        pid: pid,
      );
    }
    return snapshot();
  }

  Future<EngineAvailabilityProbe> _probe() async {
    try {
      final MariaDbBatch batch = await client.query(
        'SELECT VERSION() AS version',
        timeout: const Duration(seconds: 6),
      );
      final String version = batch.last?.rows.isNotEmpty == true
          ? (batch.last!.rows.first.first ?? '')
          : '';
      if (version.isEmpty) {
        return EngineAvailabilityProbe.failed(
          batch.error?.message ?? 'no version returned',
        );
      }
      int? uptime;
      try {
        final MariaDbBatch status =
            await client.query("SHOW STATUS LIKE 'Uptime'");
        uptime = int.tryParse(status.last?.rows.first.last ?? '');
      } on Object {
        uptime = null;
      }
      return EngineAvailabilityProbe.ok(version, uptime: uptime);
    } on MysqlServerException catch (error) {
      return EngineAvailabilityProbe.failed(
        '${error.code}: ${error.message}',
      );
    } on MysqlProtocolException catch (error) {
      return EngineAvailabilityProbe.failed(error.message);
    }
  }

  /// Initialises `database/mariadb/data` when (and only when) it is empty.
  Future<bool> initialize({bool force = false}) async {
    if (!_runtime.installed) {
      await refreshRuntime();
      if (!_runtime.installed) {
        _set(MariaDbRuntimeState.notInstalled, _runtime.reason);
        return false;
      }
    }
    if (_busy) {
      return false;
    }
    _busy = true;
    _set(MariaDbRuntimeState.initializing, 'Preparing the MariaDB data directory');
    try {
      await Directory(dataDirectory).create(recursive: true);
      await Directory(p.join(workspaceRoot, 'logs')).create(recursive: true);
      final Map<String, Object?>? result = await native.mariadbInitialize(
        dataDirectory: dataDirectory,
        baseDirectory: _runtime.baseDirectory ?? '',
        configPath: _configStore.cnfFile.path,
        force: force && !_initialisedOnce,
      );
      if (result == null) {
        _set(
          MariaDbRuntimeState.error,
          'The native layer did not answer the initialisation request',
        );
        return false;
      }
      final bool ok = result['ok'] == true;
      final String output = result['output']?.toString() ?? '';
      final bool alreadyInitialised = result['alreadyInitialised'] == true;
      if (!ok) {
        _set(
          MariaDbRuntimeState.error,
          'Data directory initialisation failed: '
          '${result['reason'] ?? 'unknown error'}',
        );
        logs.error(LogSource.database, 'mariadb init failed: $output');
        return false;
      }
      _initialisedOnce = true;
      logs.info(
        LogSource.database,
        alreadyInitialised
            ? 'MariaDB data directory already initialised, kept as is'
            : 'MariaDB data directory initialised in $dataDirectory',
      );
      _set(
        MariaDbRuntimeState.stopped,
        alreadyInitialised
            ? 'Data directory already initialised'
            : 'Data directory initialised',
      );
      return true;
    } finally {
      _busy = false;
    }
  }

  /// Starts the server and waits until it really answers.
  Future<bool> start({bool initializeIfNeeded = true}) async {
    if (_busy) {
      _set(_state, 'A MariaDB operation is already running');
      return false;
    }
    _busy = true;
    try {
      if (!_runtime.installed) {
        await refreshRuntime();
        if (!_runtime.installed) {
          _set(MariaDbRuntimeState.notInstalled, _runtime.reason);
          return false;
        }
      }
      // Existing data is never re-initialised; a missing data dir is.
      final bool ready = await _ensureInitialised(initializeIfNeeded);
      if (!ready) {
        return false;
      }
      _set(MariaDbRuntimeState.starting, 'Starting mariadbd on port ${_config.port}');
      final List<String> problems = _config.validate();
      if (problems.isNotEmpty) {
        _set(MariaDbRuntimeState.error, problems.join('; '));
        return false;
      }
      if (_config.isLoopbackOnly || _config.skipNetworking) {
        // Local only: nothing else on the LAN can reach it.
      }
      final Map<String, Object?>? started = await native.mariadbStart(
        dataDirectory: dataDirectory,
        baseDirectory: _runtime.baseDirectory ?? '',
        configPath: _configStore.cnfFile.path,
        port: _config.port,
        host: _config.host,
        socketPath: socketPath,
        pidFile: p.join(runtimeDirectory, 'mariadb.pid'),
        errorLogPath: errorLogPath,
        bindAddress: _config.bindAddress,
        skipNetworking: _config.skipNetworking,
      );
      if (started == null || started['ok'] != true) {
        _client = null;
        final String reason = started?['reason']?.toString() ??
            'the native layer did not start mariadbd';
        _set(
          MariaDbRuntimeState.error,
          'MariaDB could not start: $reason',
        );
        logs.error(LogSource.database, 'mariadb start failed: $reason');
        return false;
      }
      _pid = (started['pid'] as num?)?.toInt();
      // Wait for the real handshake instead of assuming success.
      for (int attempt = 0; attempt < 40; attempt++) {
        await Future<void>.delayed(const Duration(milliseconds: 250));
        final EngineAvailabilityProbe probe = await _probe();
        if (probe.ok) {
          _set(
            MariaDbRuntimeState.running,
            'MariaDB ${probe.version} is running on '
            '${_config.host}:${_config.port}',
            pid: _pid,
            version: probe.version,
            uptime: probe.uptime,
          );
          logs.info(
            LogSource.database,
            'MariaDB ${probe.version} started (pid $_pid)',
          );
          return true;
        }
      }
      final String tail = await readErrorLogTail(20);
      _set(
        MariaDbRuntimeState.error,
        'mariadbd started (pid $_pid) but no connection succeeded within 10 s.'
        '${tail.isEmpty ? '' : '\n$tail'}',
      );
      return false;
    } finally {
      _busy = false;
    }
  }

  Future<bool> _ensureInitialised(bool allowed) async {
    final Directory data = Directory(dataDirectory);
    bool hasData = false;
    if (await data.exists()) {
      await for (final FileSystemEntity entity in data.list()) {
        if (entity is File && entity.path.endsWith('ibdata1')) {
          hasData = true;
          break;
        }
      }
    }
    if (hasData) {
      logs.debug(LogSource.database, 'Reusing existing MariaDB data directory');
      return true;
    }
    if (!allowed) {
      _set(
        MariaDbRuntimeState.error,
        'The MariaDB data directory is empty and automatic initialisation '
        'is disabled',
      );
      return false;
    }
    return initialize();
  }

  /// Stops the server: clean shutdown first, then the process is killed.
  Future<bool> stop() async {
    if (_busy) {
      return false;
    }
    _busy = true;
    try {
      _set(MariaDbRuntimeState.stopping, 'Stopping MariaDB');
      // A clean shutdown goes through the protocol: `SHUTDOWN` flushes InnoDB
      // and closes the server the same way mariadb-admin does.
      bool closedCleanly = false;
      try {
        final MariaDbBatch shutdown = await client.query(
          'SHUTDOWN',
          timeout: const Duration(seconds: 10),
        );
        closedCleanly = shutdown.error == null;
      } on Object catch (error) {
        logs.warning(LogSource.database, 'SHUTDOWN command failed: $error');
      }
      final Map<String, Object?>? result = await native.mariadbStop(
        pid: _pid,
        gracefulTimeoutMs: 8000,
      );
      await _client?.close();
      _client = null;
      final bool ok = result?['ok'] == true;
      _set(
        ok
            ? MariaDbRuntimeState.stopped
            : MariaDbRuntimeState.error,
        ok
            ? (closedCleanly
                ? 'MariaDB stopped (clean shutdown)'
                : 'MariaDB process stopped')
            : 'MariaDB could not be stopped: '
                '${result?['reason'] ?? 'unknown error'}',
      );
      if (ok) {
        logs.info(LogSource.database, 'MariaDB stopped');
      }
      return ok;
    } finally {
      _busy = false;
    }
  }

  Future<bool> restart() async {
    final bool stopped = await stop();
    if (!stopped) {
      return false;
    }
    await Future<void>.delayed(const Duration(milliseconds: 400));
    return start();
  }

  /// Detects a port conflict before starting, with a real TCP probe.
  Future<bool> isPortFree() async {
    try {
      final Socket socket = await Socket.connect(
        _config.host,
        _config.port,
        timeout: const Duration(milliseconds: 600),
      );
      socket.destroy();
      return false;
    } on SocketException {
      return true;
    }
  }

  Future<String> readErrorLogTail([int lines = 40]) async {
    final File file = File(errorLogPath);
    if (!await file.exists()) {
      return '';
    }
    try {
      final List<String> all = await file.readAsLines();
      if (all.length <= lines) {
        return all.join('\n');
      }
      return all.sublist(all.length - lines).join('\n');
    } on Object catch (error) {
      return 'Could not read ${file.path}: $error';
    }
  }

  /// Recovery path used by the loading screen and the Serers tab.
  Future<bool> recover() async {
    _set(MariaDbRuntimeState.starting, 'Recovering the MariaDB server');
    final Map<String, Object?>? killed = await native.mariadbKillStale();
    logs.warning(
      LogSource.database,
      'Stale mariadbd cleanup: ${killed?['output'] ?? 'nothing to do'}',
    );
    _client = null;
    return start();
  }

  Future<void> dispose() async {
    await _client?.close();
    _client = null;
    await _changes.close();
  }
}

/// Result of a real connectivity probe.
class EngineAvailabilityProbe {
  const EngineAvailabilityProbe._({
    required this.ok,
    this.version,
    this.uptime,
    this.reason = '',
  });

  factory EngineAvailabilityProbe.ok(String version, {int? uptime}) =>
      EngineAvailabilityProbe._(ok: true, version: version, uptime: uptime);

  factory EngineAvailabilityProbe.failed(String reason) =>
      EngineAvailabilityProbe._(ok: false, reason: reason);

  final bool ok;
  final String? version;
  final int? uptime;
  final String reason;
}
