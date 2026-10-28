import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants/app_info.dart';
import '../../core/theme/pallsql_colors.dart';
import '../../core/theme/pallsql_theme.dart';
import '../../core/utils/formatters.dart';
import '../../models/log_entry.dart';
import '../../models/project.dart';
import '../../models/service_status.dart';
import '../../providers/app_providers.dart';
import '../../services/app_bootstrap.dart';
import '../../services/php_runtime_service.dart';
import '../../services/web_server_service.dart';
import '../../widgets/pallsql_app_bar.dart';
import '../../widgets/pallsql_card.dart';
import '../../widgets/pallsql_dialogs.dart';
import '../../widgets/server_status_card.dart';
import '../../widgets/service_control_button.dart';
import '../../widgets/status_dot.dart';
import '../backups/backups_page.dart';
import '../database/database_page.dart';
import '../logs/logs_page.dart';
import '../php/php_page.dart';
import '../projects/projects_page.dart';
import '../servers/servers_page.dart';
import '../terminal/terminal_page.dart';

/// Home tab: environment overview with live service state.
class DashboardPage extends ConsumerStatefulWidget {
  const DashboardPage({super.key});

  @override
  ConsumerState<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends ConsumerState<DashboardPage> {
  bool _busy = false;

  Future<void> _run(Future<String?> Function() action, {String? success}) async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    final String? error = await action();
    if (!mounted) {
      return;
    }
    setState(() => _busy = false);
    if (error != null) {
      showPallSqlSnack(messenger, error, error: true);
    } else if (success != null) {
      showPallSqlSnack(messenger, success);
    }
  }

  Future<void> _openWebsite() async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final bool opened = await ref.read(webServerProvider.notifier).openWebsite();
    if (!mounted || opened) {
      return;
    }
    showPallSqlSnack(
      messenger,
      'No browser available for ${ref.read(webServerProvider).primaryUrl}',
      error: true,
    );
  }

  void _push(Widget page) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (BuildContext context) => page),
    );
  }

  @override
  Widget build(BuildContext context) {
    final WebServerSnapshot server = ref.watch(webServerProvider);
    final ServiceStatus phpStatus = ref.watch(phpStatusProvider);
    final ServiceStatus databaseStatus = ref.watch(databaseStatusProvider);
    final ServiceAggregate aggregate = ref.watch(serviceAggregateProvider);
    final PhpRuntimeInfo? php = ref.watch(phpRuntimeProvider).valueOrNull;
    final List<Project> projects =
        ref.watch(projectsProvider).valueOrNull ?? const <Project>[];
    final Project? active = ref.watch(activeProjectProvider);
    final AsyncValue<StorageReport> storage = ref.watch(storageReportProvider);
    final List<LogEntry> logs =
        ref.watch(logEntriesProvider).valueOrNull ?? const <LogEntry>[];

    return Scaffold(
      appBar: PallSQLAppBar(
        title: AppInfo.appName,
        subtitle: AppInfo.tagline,
        showLogo: true,
        actions: <Widget>[
          IconButton(
            tooltip: 'Refresh storage',
            icon: const Icon(Icons.refresh_rounded, size: 19),
            onPressed: () {
              ref.invalidate(storageReportProvider);
              ref.invalidate(databaseProvider);
            },
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: RefreshIndicator(
        color: PallSqlColors.accent,
        backgroundColor: PallSqlColors.surfaceElevated,
        onRefresh: () async {
          ref.invalidate(storageReportProvider);
          await ref.read(databaseProvider.notifier).refresh();
        },
        child: ListView(
          padding: const EdgeInsets.fromLTRB(14, 6, 14, 24),
          children: <Widget>[
            _EnvironmentHeader(
              aggregate: aggregate,
              server: server,
              busy: _busy,
              onStartAll: () => _run(
                () async {
                  await ref.read(databaseProvider.notifier).refresh();
                  return ref.read(webServerProvider.notifier).start();
                },
                success: 'Environment started',
              ),
              onStopAll: () => _run(
                () => ref.read(webServerProvider.notifier).stop(),
                success: 'Environment stopped',
              ),
              onOpenWebsite: server.isRunning ? _openWebsite : null,
            ),
            const SizedBox(height: 18),
            const PallSqlSectionHeader(title: 'Services'),
            ServerStatusCard(
              title: 'Web server',
              icon: Icons.lan_rounded,
              status: server.toStatus(),
              subtitle: server.isRunning
                  ? server.urls.join('  ')
                  : 'Dart HTTP server on 127.0.0.1',
              details: <String>[
                'port      ${server.port ?? ref.watch(settingsProvider).httpPort}',
                'address   ${server.bindAddress ?? (ref.watch(settingsProvider).lanAccess ? '0.0.0.0' : '127.0.0.1')}',
                'requests  ${server.requestCount}',
              ],
              actions: <Widget>[
                ServiceControlButton(
                  label: server.isRunning ? 'Stop' : 'Start',
                  filled: !server.isRunning,
                  busy: _busy || server.state.isTransitional,
                  icon: server.isRunning
                      ? Icons.stop_rounded
                      : Icons.play_arrow_rounded,
                  onPressed: () => server.isRunning
                      ? _run(
                          () => ref.read(webServerProvider.notifier).stop(),
                          success: 'Server stopped',
                        )
                      : _run(
                          () => ref.read(webServerProvider.notifier).start(),
                          success: 'Server started',
                        ),
                ),
                ServiceControlButton(
                  label: 'Details',
                  icon: Icons.tune_rounded,
                  onPressed: () => _push(const ServersPage(embedded: true)),
                ),
              ],
            ),
            const SizedBox(height: 10),
            ServerStatusCard(
              title: 'PHP runtime',
              icon: Icons.code_rounded,
              status: phpStatus,
              subtitle: phpStatus.isRunning
                  ? 'PHP ${php?.version ?? ''} - ${php?.extensions.length ?? 0} extensions'
                  : 'Not installed in this build',
              details: phpStatus.isRunning
                  ? <String>[
                      'binary    ${php?.binaryPath ?? '-'}',
                      'ini       ${php?.iniPath ?? '-'}',
                    ]
                  : <String>[
                      'status    unavailable - no binary bundled',
                      'see       PHP page for installation notes',
                    ],
              actions: <Widget>[
                ServiceControlButton(
                  label: 'PHP settings',
                  icon: Icons.settings_suggest_rounded,
                  onPressed: () => _push(const PhpPage()),
                ),
                ServiceControlButton(
                  label: 'Re-detect',
                  icon: Icons.search_rounded,
                  onPressed: () => _run(
                    () async {
                      await ref.read(phpRuntimeProvider.notifier).refresh();
                      return null;
                    },
                    success: 'PHP runtime re-detected',
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            ServerStatusCard(
              title: 'Database',
              icon: Icons.storage_rounded,
              status: databaseStatus,
              subtitle: 'SQLite - offline, file based',
              details: <String>[
                'engine    ${ref.watch(databaseProvider).valueOrNull?.sqlite.version ?? 'SQLite'}',
                'databases ${ref.watch(databaseProvider).valueOrNull?.databases.length ?? 0}',
              ],
              actions: <Widget>[
                ServiceControlButton(
                  label: 'Open database',
                  icon: Icons.table_chart_rounded,
                  onPressed: () => _push(const DatabasePage()),
                ),
                ServiceControlButton(
                  label: 'Query logs',
                  icon: Icons.receipt_long_rounded,
                  onPressed: () => _push(const LogsPage(initialSource: LogSource.database)),
                ),
              ],
            ),
            const SizedBox(height: 20),
            const PallSqlSectionHeader(title: 'Environment'),
            PallSqlCard(
              child: Column(
                children: <Widget>[
                  PallSqlKeyValue(
                    label: 'HTTP port',
                    value: '${ref.watch(settingsProvider).httpPort}',
                    monospace: true,
                  ),
                  PallSqlKeyValue(
                    label: 'Localhost',
                    value: server.isRunning
                        ? server.primaryUrl
                        : 'http://127.0.0.1:${ref.watch(settingsProvider).httpPort}/',
                    monospace: true,
                    valueColor: server.isRunning
                        ? PallSqlColors.accent
                        : PallSqlColors.textSecondary,
                  ),
                  PallSqlKeyValue(
                    label: 'Document root',
                    value: active == null
                        ? 'PALLSQL/htdocs'
                        : 'PALLSQL/projects/${active.directory}',
                    monospace: true,
                  ),
                  PallSqlKeyValue(
                    label: 'Projects',
                    value: '${projects.length}',
                    monospace: true,
                  ),
                  PallSqlKeyValue(
                    label: 'Storage',
                    value: storage.when(
                      data: (StorageReport report) =>
                          '${Formatters.bytes(report.workspaceBytes)} in '
                          '${Formatters.count(report.workspaceFiles, 'file')}',
                      loading: () => 'measuring...',
                      error: (Object error, StackTrace stack) =>
                          'unavailable ($error)',
                    ),
                    monospace: true,
                  ),
                  PallSqlKeyValue(
                    label: 'Device free',
                    value: storage.valueOrNull?.deviceFreeBytes == null
                        ? 'n/a'
                        : Formatters.bytes(storage.valueOrNull!.deviceFreeBytes!),
                    monospace: true,
                  ),
                  PallSqlKeyValue(
                    label: 'Workspace',
                    value: ref.watch(bootstrapProvider).workspace.rootPath,
                    monospace: true,
                    maxLines: 2,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            PallSqlSectionHeader(
              title: 'Quick actions',
              trailing: Text(
                AppInfo.appName,
                style: const TextStyle(
                  fontSize: 10,
                  letterSpacing: 1.6,
                  color: PallSqlColors.textDisabled,
                ),
              ),
            ),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                _QuickAction(
                  icon: Icons.folder_special_rounded,
                  label: 'Projects',
                  onTap: () => _push(const ProjectsPage()),
                ),
                _QuickAction(
                  icon: Icons.terminal_rounded,
                  label: 'Terminal',
                  onTap: () => _push(const TerminalPage()),
                ),
                _QuickAction(
                  icon: Icons.archive_rounded,
                  label: 'Backups',
                  onTap: () => _push(const BackupsPage()),
                ),
                _QuickAction(
                  icon: Icons.article_rounded,
                  label: 'Logs',
                  onTap: () => _push(const LogsPage()),
                ),
              ],
            ),
            const SizedBox(height: 20),
            PallSqlSectionHeader(
              title: 'Recent log',
              trailing: TextButton(
                onPressed: () => _push(const LogsPage()),
                style: TextButton.styleFrom(
                  minimumSize: Size.zero,
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: const Text('All logs', style: TextStyle(fontSize: 11)),
              ),
            ),
            PallSqlCard(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: logs.isEmpty
                  ? const Padding(
                      padding: EdgeInsets.symmetric(vertical: 14),
                      child: Text(
                        'No log entries yet',
                        style: TextStyle(
                          color: PallSqlColors.textDisabled,
                          fontSize: 12,
                        ),
                      ),
                    )
                  : Column(
                      children: <Widget>[
                        for (final LogEntry entry in logs.take(5))
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 4),
                            child: Row(
                              children: <Widget>[
                                Text(
                                  Formatters.clock(entry.timestamp),
                                  style: const TextStyle(
                                    fontFamily: PallSqlColors.monoFontFamily,
                                    fontSize: 10,
                                    color: PallSqlColors.textDisabled,
                                  ),
                                ),
                                const SizedBox(width: 6),
                                Text(
                                  entry.source.label,
                                  style: const TextStyle(
                                    fontFamily: PallSqlColors.monoFontFamily,
                                    fontSize: 10,
                                    color: PallSqlColors.textSecondary,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    entry.message,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: entry.level == LogLevel.error
                                          ? PallSqlColors.error
                                          : PallSqlColors.textPrimary,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EnvironmentHeader extends StatelessWidget {
  const _EnvironmentHeader({
    required this.aggregate,
    required this.server,
    required this.busy,
    required this.onStartAll,
    required this.onStopAll,
    this.onOpenWebsite,
  });

  final ServiceAggregate aggregate;
  final WebServerSnapshot server;
  final bool busy;
  final VoidCallback onStartAll;
  final VoidCallback onStopAll;
  final VoidCallback? onOpenWebsite;

  @override
  Widget build(BuildContext context) {
    final Color stateColor = PallSqlTheme.stateColor(aggregate.overallState);
    return PallSqlCard(
      accentColor: stateColor,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              const Expanded(child: PallSqlWordmark()),
              PallSqlPill(
                label: aggregate.overallLabel,
                color: stateColor,
                icon: Icons.circle,
              ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: <Widget>[
              StatusDot(
                state: aggregate.overallState,
                size: 9,
                pulse: aggregate.overallState == ServiceState.running,
              ),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  server.isRunning
                      ? 'Serving ${server.primaryUrl}'
                      : 'Server stopped - start it to serve your project',
                  style: const TextStyle(
                    fontSize: 12,
                    color: PallSqlColors.textSecondary,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: <Widget>[
              Expanded(
                child: ServiceControlButton(
                  label: 'Start all',
                  icon: Icons.play_arrow_rounded,
                  filled: true,
                  busy: busy,
                  onPressed: onStartAll,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: ServiceControlButton(
                  label: 'Stop all',
                  icon: Icons.stop_rounded,
                  busy: busy,
                  onPressed: onStopAll,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ServiceControlButton(
            label: onOpenWebsite == null
                ? 'Start the server to open your site'
                : 'Open ${server.primaryUrl}',
            icon: Icons.open_in_browser_rounded,
            compact: true,
            onPressed: onOpenWebsite,
          ),
        ],
      ),
    );
  }
}

class _QuickAction extends StatelessWidget {
  const _QuickAction({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 96,
      child: PallSqlCard(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
        onTap: onTap,
        child: Column(
          children: <Widget>[
            Icon(icon, size: 18, color: PallSqlColors.accent),
            const SizedBox(height: 6),
            Text(
              label,
              style: const TextStyle(
                fontSize: 11,
                color: PallSqlColors.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
