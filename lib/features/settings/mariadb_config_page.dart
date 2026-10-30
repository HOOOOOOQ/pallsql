import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/pallsql_colors.dart';
import '../../models/log_entry.dart';
import '../../providers/app_providers.dart';
import '../../services/mariadb/mariadb_config.dart';
import '../../services/mariadb/mariadb_service.dart';
import '../../widgets/pallsql_app_bar.dart';
import '../../widgets/pallsql_card.dart';
import '../../widgets/pallsql_components.dart';
import '../../widgets/pallsql_dialogs.dart';
import '../logs/logs_page.dart';

/// Configuration and diagnostics of the local MariaDB server.
///
/// Every value written here goes to `PALLSQL/config/server/mariadb.json` and to
/// the generated `mariadb.cnf` that the native process reads. The screen never
/// invents a state: the badge, the version, the PID and the data directory come
/// from [MariaDBServiceManager.snapshot], and "Running" only appears after a
/// real protocol probe succeeded.
class MariaDbConfigPage extends ConsumerStatefulWidget {
  const MariaDbConfigPage({super.key});

  @override
  ConsumerState<MariaDbConfigPage> createState() => _MariaDbConfigPageState();
}

class _MariaDbConfigPageState extends ConsumerState<MariaDbConfigPage> {
  final TextEditingController _port = TextEditingController();
  final TextEditingController _host = TextEditingController();
  final TextEditingController _bind = TextEditingController();
  final TextEditingController _charset = TextEditingController();
  final TextEditingController _collation = TextEditingController();
  final TextEditingController _maxConnections = TextEditingController();
  final TextEditingController _bufferPool = TextEditingController();
  final TextEditingController _logFileSize = TextEditingController();
  final TextEditingController _socketName = TextEditingController();
  final TextEditingController _user = TextEditingController();
  final TextEditingController _password = TextEditingController();

  bool _skipNetworking = false;
  bool _allowLan = false;
  bool _busy = false;
  bool _loaded = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_loaded) {
      _loadFrom(ref.read(mariadbServiceProvider).config);
      _loaded = true;
    }
  }

  @override
  void dispose() {
    for (final TextEditingController controller in <TextEditingController>[
      _port,
      _host,
      _bind,
      _charset,
      _collation,
      _maxConnections,
      _bufferPool,
      _logFileSize,
      _socketName,
      _user,
      _password,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  void _loadFrom(MariaDbConfig config) {
    _port.text = '${config.port}';
    _host.text = config.host;
    _bind.text = config.bindAddress;
    _charset.text = config.characterSet;
    _collation.text = config.collation;
    _maxConnections.text = '${config.maxConnections}';
    _bufferPool.text = '${config.bufferPoolSizeMb}';
    _logFileSize.text = '${config.innodbLogFileSizeMb}';
    _socketName.text = config.socketName;
    _user.text = config.user;
    _password.text = config.password;
    _skipNetworking = config.skipNetworking;
    _allowLan = config.allowLan;
  }

  MariaDbConfig _collect() {
    final MariaDbConfig current = ref.read(mariadbServiceProvider).config;
    return current.copyWith(
      port: int.tryParse(_port.text.trim()) ?? current.port,
      host: _host.text.trim(),
      characterSet: _charset.text.trim(),
      collation: _collation.text.trim(),
      maxConnections:
          int.tryParse(_maxConnections.text.trim()) ?? current.maxConnections,
      bufferPoolSizeMb:
          int.tryParse(_bufferPool.text.trim()) ?? current.bufferPoolSizeMb,
      innodbLogFileSizeMb:
          int.tryParse(_logFileSize.text.trim()) ?? current.innodbLogFileSizeMb,
      socketName: _socketName.text.trim(),
      user: _user.text.trim(),
      password: _password.text,
      skipNetworking: _skipNetworking,
      allowLan: _allowLan,
      // Networking plus a non loopback bind is the only way to expose the
      // server; keeping the previous bind address when the switch is off avoids
      // silently publishing MariaDB to the network.
      bindAddress: _allowLan ? _bind.text.trim() : '127.0.0.1',
    );
  }

  Future<void> _save({bool restart = true}) async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final MariaDbConfig next = _collect();
    final List<String> problems = next.validate();
    if (problems.isNotEmpty) {
      showPallSqlSnack(messenger, problems.join(' · '), error: true);
      return;
    }
    final MariaDBServiceManager manager = ref.read(mariadbServiceProvider);
    final bool wasRunning = manager.snapshot().isRunning;
    if (wasRunning && restart) {
      final bool confirmed = await showConfirmDialog(
        context: context,
        title: 'Restart MariaDB?',
        message: 'The server is running. Saving the new configuration '
            '(port ${next.port}, bind ${next.bindAddress}) restarts it, and '
            'open sessions are closed.',
        confirmLabel: 'Save and restart',
      );
      if (!confirmed) {
        return;
      }
    }
    setState(() => _busy = true);
    try {
      await manager.saveConfig(next);
      bool restarted = false;
      if (wasRunning && restart) {
        restarted = await manager.restart();
      }
      if (mounted) {
        showPallSqlSnack(
          messenger,
          restarted
              ? 'Configuration saved, MariaDB restarted'
              : 'Configuration saved. Start the server to apply it.',
        );
      }
    } on Object catch (error) {
      if (mounted) {
        showPallSqlSnack(messenger, 'Configuration rejected: $error',
            error: true);
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
    await ref.read(databaseProvider.notifier).refresh();
  }

  Future<void> _lifecycle(Future<bool> Function() action, String label) async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    if (!mounted) {
      return;
    }
    setState(() => _busy = true);
    try {
      final bool ok = await action();
      final MariaDbStatus status = ref.read(mariadbServiceProvider).snapshot();
      if (mounted) {
        showPallSqlSnack(
          messenger,
          ok
              ? '$label: ${status.state.label}'
              : '$label failed: ${status.message}',
          error: !ok,
        );
      }
    } on Object catch (error) {
      if (mounted) {
        showPallSqlSnack(messenger, '$label failed: $error', error: true);
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
    await ref.read(databaseProvider.notifier).refresh();
  }

  @override
  Widget build(BuildContext context) {
    final MariaDBServiceManager manager = ref.watch(mariadbServiceProvider);
    final MariaDbStatus status = manager.snapshot();
    final MariaDbRuntimeInfo runtime = status.runtime;

    return Scaffold(
      appBar: const PallSQLAppBar(
        title: 'MariaDB server',
        subtitle: 'Native server configuration',
        showBack: true,
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
          children: <Widget>[
            PallSqlSectionHeader(
              title: 'Status',
              subtitle: manager.runtime.installed
                  ? '${status.state.label} · port ${status.port ?? manager.config.port}'
                  : 'Runtime not installed in this build',
              trailing: PallSQLStatusBadge(
                label: status.state.label,
                color: _stateColor(manager),
              ),
            ),
            PallSqlCard(
              child: Column(
                children: <Widget>[
                  PallSqlKeyValue(
                    label: 'State',
                    value: status.message,
                    monospace: true,
                  ),
                  PallSqlKeyValue(
                    label: 'Version',
                    value: status.version ?? runtime.version ?? 'unknown',
                    monospace: true,
                  ),
                  PallSqlKeyValue(
                    label: 'PID',
                    value: status.pid?.toString() ?? '-',
                    monospace: true,
                  ),
                  PallSqlKeyValue(
                    label: 'Data directory',
                    value: status.dataDirectory ?? manager.dataDirectory,
                    monospace: true,
                  ),
                  PallSqlKeyValue(
                    label: 'Server binary',
                    value: runtime.serverBinary ?? 'not packaged',
                    monospace: true,
                    valueColor: runtime.installed
                        ? PallSqlColors.textPrimary
                        : PallSqlColors.warning,
                  ),
                  PallSqlKeyValue(
                    label: 'ABIs in APK',
                    value: runtime.abies.isEmpty
                        ? 'none'
                        : runtime.abies.join(', '),
                    monospace: true,
                  ),
                  if (!runtime.installed) ...<Widget>[
                    const SizedBox(height: 8),
                    Text(
                      runtime.reason,
                      style: const TextStyle(
                        fontSize: 11.5,
                        height: 1.45,
                        color: PallSqlColors.warning,
                      ),
                    ),
                  ],
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: <Widget>[
                      PallSQLButton(
                        label: 'Start',
                        icon: Icons.play_arrow_rounded,
                        expand: false,
                        onPressed: _busy || !runtime.installed
                            ? null
                            : () => _lifecycle(() => manager.start(), 'Start'),
                      ),
                      PallSQLButton(
                        label: 'Stop',
                        icon: Icons.stop_rounded,
                        variant: PallSQLButtonVariant.secondary,
                        expand: false,
                        onPressed: _busy || !manager.snapshot().isRunning
                            ? null
                            : () => _lifecycle(() => manager.stop(), 'Stop'),
                      ),
                      PallSQLButton(
                        label: 'Restart',
                        icon: Icons.refresh_rounded,
                        variant: PallSQLButtonVariant.secondary,
                        expand: false,
                        onPressed: _busy || !manager.snapshot().isRunning
                            ? null
                            : () =>
                                _lifecycle(() => manager.restart(), 'Restart'),
                      ),
                      PallSQLButton(
                        label: 'Error log',
                        icon: Icons.article_outlined,
                        variant: PallSQLButtonVariant.secondary,
                        expand: false,
                        onPressed: () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (BuildContext context) => const LogsPage(
                                initialSource: LogSource.database),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            const PallSqlSectionHeader(
              title: 'Connection',
              subtitle: 'Loopback only by default; the SQL client uses this',
            ),
            PallSqlCard(
              child: Column(
                children: <Widget>[
                  PallSQLTextField(
                    controller: _host,
                    label: 'Client host',
                    hint: '127.0.0.1',
                    monospace: true,
                    helper: 'What PALLSQL connects to. Loopback unless you '
                        'explicitly share the server.',
                  ),
                  const SizedBox(height: 10),
                  PallSQLTextField(
                    controller: _port,
                    label: 'Port',
                    hint: '3306',
                    keyboardType: TextInputType.number,
                    monospace: true,
                    helper: '3306 is the MariaDB default. Change it when the '
                        'port is already taken.',
                  ),
                  const SizedBox(height: 10),
                  PallSQLTextField(
                    controller: _bind,
                    label: 'Bind address',
                    hint: '127.0.0.1',
                    monospace: true,
                    enabled: _allowLan,
                    helper: _allowLan
                        ? '0.0.0.0 exposes MariaDB to your network. Keep '
                            '127.0.0.1 unless you really need it.'
                        : 'Locked to 127.0.0.1 while "Share on LAN" is off.',
                  ),
                  _SwitchRow(
                    title: 'Share on LAN',
                    subtitle: 'Allow the bind address above to be reachable '
                        'from other devices. Off by default.',
                    value: _allowLan,
                    onChanged: _busy
                        ? null
                        : (bool value) => setState(() => _allowLan = value),
                  ),
                  _SwitchRow(
                    title: 'Unix socket only',
                    subtitle: 'Skip TCP entirely and listen on the socket file '
                        'below. PALLSQL then talks through the socket.',
                    value: _skipNetworking,
                    onChanged: _busy
                        ? null
                        : (bool value) =>
                            setState(() => _skipNetworking = value),
                  ),
                  const SizedBox(height: 4),
                  PallSQLTextField(
                    controller: _socketName,
                    label: 'Socket file name',
                    hint: 'pallsql.sock',
                    monospace: true,
                    helper: 'Stored inside PALLSQL/database/mariadb.',
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            const PallSqlSectionHeader(
              title: 'Server',
              subtitle: 'Written to the generated mariadb.cnf',
            ),
            PallSqlCard(
              child: Column(
                children: <Widget>[
                  PallSQLTextField(
                    controller: _charset,
                    label: 'Character set',
                    hint: 'utf8mb4',
                    monospace: true,
                  ),
                  const SizedBox(height: 10),
                  PallSQLTextField(
                    controller: _collation,
                    label: 'Collation',
                    hint: 'utf8mb4_unicode_ci',
                    monospace: true,
                  ),
                  const SizedBox(height: 10),
                  PallSQLTextField(
                    controller: _maxConnections,
                    label: 'max_connections',
                    hint: '20',
                    keyboardType: TextInputType.number,
                    monospace: true,
                    helper: 'Between 1 and 500.',
                  ),
                  const SizedBox(height: 10),
                  PallSQLTextField(
                    controller: _bufferPool,
                    label: 'InnoDB buffer pool (MB)',
                    hint: '32',
                    keyboardType: TextInputType.number,
                    monospace: true,
                    helper: '8-1024 MB. A phone does not need more than 128 MB '
                        'for a local workspace.',
                  ),
                  const SizedBox(height: 10),
                  PallSQLTextField(
                    controller: _logFileSize,
                    label: 'InnoDB log file (MB)',
                    hint: '24',
                    keyboardType: TextInputType.number,
                    monospace: true,
                    helper: 'Minimum 8 MB. Changing it only affects a data '
                        'directory that is initialised afterwards.',
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            const PallSqlSectionHeader(
              title: 'Administrator account',
              subtitle: 'Created once, when the data directory is initialised',
            ),
            PallSqlCard(
              child: Column(
                children: <Widget>[
                  PallSQLTextField(
                    controller: _user,
                    label: 'User',
                    hint: 'root',
                    monospace: true,
                  ),
                  const SizedBox(height: 10),
                  PallSQLTextField(
                    controller: _password,
                    label: 'Password',
                    obscure: true,
                    monospace: true,
                    helper:
                        'Stored in config/server/mariadb.json with chmod 600 '
                        'and never written to a log. An empty password is '
                        'refused while the server listens on TCP.',
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            PallSQLButton(
              label: 'Save configuration',
              icon: Icons.save_rounded,
              variant: PallSQLButtonVariant.primary,
              busy: _busy,
              onPressed: _busy ? null : () => _save(),
            ),
            const SizedBox(height: 8),
            PallSQLButton(
              label: 'Reset to defaults',
              icon: Icons.restart_alt_rounded,
              variant: PallSQLButtonVariant.secondary,
              onPressed: _busy
                  ? null
                  : () {
                      setState(() => _loadFrom(MariaDbConfig.defaults));
                      showPallSqlSnack(
                        ScaffoldMessenger.of(context),
                        'Form reset. Save to persist it.',
                      );
                    },
            ),
            const SizedBox(height: 12),
            Text(
              'The server binary is the one packaged in the APK '
              '(${runtime.serverBinary ?? 'missing'}). PALLSQL never substitutes '
              'another engine and never reports "Running" without a successful '
              'protocol connection.',
              style: const TextStyle(
                fontSize: 11,
                height: 1.5,
                color: PallSqlColors.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SwitchRow extends StatelessWidget {
  const _SwitchRow({
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 13,
                    color: PallSqlColors.textPrimary,
                  ),
                ),
                Text(
                  subtitle,
                  style: const TextStyle(
                    fontSize: 11,
                    height: 1.4,
                    color: PallSqlColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          Switch(value: value, onChanged: onChanged),
        ],
      ),
    );
  }
}

/// Colour used for the status pill; never a "green means fine" guess, the
/// state itself decides.
Color _stateColor(MariaDBServiceManager manager) {
  switch (manager.state) {
    case MariaDbRuntimeState.running:
      return PallSqlColors.accent;
    case MariaDbRuntimeState.starting:
    case MariaDbRuntimeState.initializing:
    case MariaDbRuntimeState.stopping:
      return PallSqlColors.warning;
    case MariaDbRuntimeState.error:
      return PallSqlColors.error;
    case MariaDbRuntimeState.stopped:
    case MariaDbRuntimeState.notInstalled:
      return PallSqlColors.textSecondary;
  }
}
