import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/pallsql_colors.dart';
import '../../core/utils/validators.dart';
import '../../models/app_settings.dart';
import '../../models/database_models.dart';
import '../../models/log_entry.dart';
import '../../models/service_status.dart';
import '../../providers/app_providers.dart';
import '../../services/php_runtime_service.dart';
import '../../services/web_server_service.dart';
import '../../widgets/database_card.dart';
import '../../widgets/pallsql_app_bar.dart';
import '../../widgets/pallsql_card.dart';
import '../../widgets/pallsql_dialogs.dart';
import '../../widgets/server_status_card.dart';
import '../../widgets/service_control_button.dart';
import '../../widgets/status_dot.dart';
import '../database/database_page.dart';
import '../logs/logs_page.dart';
import '../php/php_page.dart';

/// Servers tab: full control over the web server, PHP runtime and database.
class ServersPage extends ConsumerStatefulWidget {
  const ServersPage({super.key, this.embedded = false});

  final bool embedded;

  @override
  ConsumerState<ServersPage> createState() => _ServersPageState();
}

class _ServersPageState extends ConsumerState<ServersPage> {
  late final TextEditingController _portController = TextEditingController(
    text: '${ref.read(settingsProvider).httpPort}',
  );
  bool _busy = false;

  @override
  void dispose() {
    _portController.dispose();
    super.dispose();
  }

  Future<void> _run(
    Future<String?> Function() action, {
    String? success,
  }) async {
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

  Future<void> _applyPort() async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final int? port = int.tryParse(_portController.text.trim());
    if (port == null) {
      showPallSqlSnack(messenger, 'Enter a numeric port', error: true);
      return;
    }
    final String? portError = Validators.portError(port);
    if (portError != null) {
      showPallSqlSnack(messenger, portError, error: true);
      return;
    }
    final AppSettings current = ref.read(settingsProvider);
    final String? error = await ref
        .read(settingsProvider.notifier)
        .update(current.copyWith(httpPort: port));
    if (!mounted) {
      return;
    }
    if (error != null) {
      showPallSqlSnack(messenger, error, error: true);
      return;
    }
    if (ref.read(webServerProvider).isRunning) {
      await _run(
        () => ref.read(webServerProvider.notifier).restart(),
        success: 'Server restarted on port $port',
      );
    } else {
      showPallSqlSnack(messenger, 'Port saved');
    }
  }

  Future<void> _toggleLan(bool value) async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final AppSettings current = ref.read(settingsProvider);
    final String? error = await ref
        .read(settingsProvider.notifier)
        .update(current.copyWith(lanAccess: value));
    if (!mounted) {
      return;
    }
    if (error != null) {
      showPallSqlSnack(messenger, error, error: true);
      return;
    }
    if (ref.read(webServerProvider).isRunning) {
      await _run(
        () => ref.read(webServerProvider.notifier).restart(),
        success: value ? 'LAN access enabled' : 'LAN access disabled',
      );
    }
  }

  void _push(Widget page) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (BuildContext context) => page),
    );
  }

  @override
  Widget build(BuildContext context) {
    final WebServerSnapshot server = ref.watch(webServerProvider);
    final AppSettings settings = ref.watch(settingsProvider);
    final ServiceStatus phpStatus = ref.watch(phpStatusProvider);
    final PhpRuntimeInfo? php = ref.watch(phpRuntimeProvider).valueOrNull;
    final ServiceStatus databaseStatus = ref.watch(databaseStatusProvider);
    final EngineAvailability? sqlite =
        ref.watch(databaseProvider).valueOrNull?.sqlite;

    return Scaffold(
      appBar: PallSQLAppBar(
        title: 'Servers',
        subtitle: 'Web server, PHP runtime and database',
        showBack: !widget.embedded,
        actions: <Widget>[
          IconButton(
            tooltip: 'Server logs',
            icon: const Icon(Icons.receipt_long_rounded, size: 19),
            onPressed: () =>
                _push(const LogsPage(initialSource: LogSource.webServer)),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(14, 6, 14, 24),
        children: <Widget>[
          const PallSqlSectionHeader(title: 'Local web server'),
          ServerStatusCard(
            title: 'HTTP server',
            icon: Icons.lan_rounded,
            status: server.toStatus(),
            subtitle: server.isRunning
                ? server.urls.join('  ')
                : 'Serves PALLSQL/htdocs or the active project',
            details: <String>[
              'document root  ${server.documentRoot}',
              'requests       ${server.requestCount}',
              if (server.startedAt != null)
                'uptime         ${server.uptime.inMinutes}m ${server.uptime.inSeconds % 60}s',
            ],
            actions: <Widget>[
              ServiceControlButton(
                label: server.isRunning ? 'Stop' : 'Start',
                icon: server.isRunning
                    ? Icons.stop_rounded
                    : Icons.play_arrow_rounded,
                filled: !server.isRunning,
                busy: _busy || server.state.isTransitional,
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
                label: 'Restart',
                icon: Icons.restart_alt_rounded,
                busy: _busy,
                onPressed: () => _run(
                  () => ref.read(webServerProvider.notifier).restart(),
                  success: 'Server restarted',
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          PallSqlCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                const Text(
                  'NETWORK',
                  style: TextStyle(
                    fontSize: 10,
                    letterSpacing: 1.6,
                    fontWeight: FontWeight.w700,
                    color: PallSqlColors.textSecondary,
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  children: <Widget>[
                    Expanded(
                      child: TextField(
                        controller: _portController,
                        keyboardType: TextInputType.number,
                        inputFormatters: <TextInputFormatter>[
                          FilteringTextInputFormatter.digitsOnly,
                        ],
                        style: const TextStyle(
                          color: PallSqlColors.textPrimary,
                          fontSize: 13.5,
                          fontFamily: PallSqlColors.monoFontFamily,
                        ),
                        decoration: InputDecoration(
                          isDense: true,
                          labelText: 'HTTP port',
                          labelStyle: const TextStyle(
                            color: PallSqlColors.textSecondary,
                            fontSize: 12,
                          ),
                          filled: true,
                          fillColor: PallSqlColors.background,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 12,
                          ),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(9),
                            borderSide:
                                const BorderSide(color: PallSqlColors.border),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(9),
                            borderSide:
                                const BorderSide(color: PallSqlColors.border),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(9),
                            borderSide:
                                const BorderSide(color: PallSqlColors.accent),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    ServiceControlButton(
                      label: 'Apply',
                      icon: Icons.check_rounded,
                      expand: false,
                      compact: true,
                      onPressed: _busy ? null : _applyPort,
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                const Text(
                  'Changing the port restarts a running server. Ports below 1024 '
                  'are not available to Android apps.',
                  style: TextStyle(
                    fontSize: 11,
                    color: PallSqlColors.textDisabled,
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 10),
                _ServerSwitch(
                  title: 'LAN access',
                  subtitle: settings.lanAccess
                      ? 'Bound to 0.0.0.0 - other devices on your Wi-Fi can '
                          'reach this server'
                      : 'Bound to 127.0.0.1 only (recommended)',
                  value: settings.lanAccess,
                  onChanged: _busy ? null : (bool value) => _toggleLan(value),
                  warning: settings.lanAccess,
                ),
                _ServerSwitch(
                  title: 'Server notification',
                  subtitle:
                      'Keeps the process in the foreground so Android does not '
                      'suspend the server',
                  value: settings.notificationsEnabled,
                  onChanged: _busy
                      ? null
                      : (bool value) async {
                          final ScaffoldMessengerState messenger =
                              ScaffoldMessenger.of(context);
                          final AppSettings current =
                              ref.read(settingsProvider);
                          final String? error = await ref
                              .read(settingsProvider.notifier)
                              .update(
                                current.copyWith(notificationsEnabled: value),
                              );
                          if (!mounted) {
                            return;
                          }
                          if (error != null) {
                            showPallSqlSnack(messenger, error, error: true);
                          }
                        },
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          const PallSqlSectionHeader(title: 'PHP runtime'),
          ServerStatusCard(
            title: 'PHP',
            icon: Icons.code_rounded,
            status: phpStatus,
            subtitle: phpStatus.isRunning
                ? 'PHP ${php?.version ?? ''}'
                : 'No PHP interpreter bundled with this build',
            details: phpStatus.isRunning
                ? <String>[
                    'binary      ${php?.binaryPath ?? '-'}',
                    'extensions  ${php?.extensions.length ?? 0}',
                    'ini         ${php?.iniPath ?? '-'}',
                  ]
                : <String>[
                    'status      unavailable',
                    'php-cgi     ${settings.phpBinaryPath.isEmpty ? 'config/php/php-cgi (auto detect)' : settings.phpBinaryPath}',
                  ],
            actions: <Widget>[
              ServiceControlButton(
                label: 'PHP configuration',
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
          const SizedBox(height: 18),
          const PallSqlSectionHeader(title: 'Database engine'),
          if (sqlite != null)
            EngineCard(
              availability: sqlite,
              trailing: ServiceControlButton(
                label: 'Manage',
                icon: Icons.arrow_forward_rounded,
                expand: false,
                compact: true,
                onPressed: () => _push(const DatabasePage()),
              ),
            ),
          const SizedBox(height: 8),
          PallSqlCard(
            accentColor: PallSqlColors.warning,
            child: Row(
              children: <Widget>[
                const Icon(Icons.info_outline_rounded,
                    size: 16, color: PallSqlColors.warning),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    'MariaDB is not available in this build. SQLite is the '
                    'offline engine; see the Database tab for details.',
                    style: TextStyle(
                      fontSize: 11.5,
                      color: PallSqlColors.textSecondary,
                      height: 1.4,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                StatusDot(state: databaseStatus.state),
              ],
            ),
          ),
          const SizedBox(height: 18),
          const PallSqlSectionHeader(title: 'Android runtime limits'),
          const PallSqlCard(
            child: Text(
              'PALLSQL runs the HTTP server inside the Flutter engine and uses '
              'a foreground service to keep it alive while the app is in the '
              'background. Android may still stop the process under memory '
              'pressure, and the server always stops when the app is force '
              'stopped. No root access is required and no extra permissions '
              'are requested for the server itself.',
              style: TextStyle(
                fontSize: 11.5,
                color: PallSqlColors.textSecondary,
                height: 1.45,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ServerSwitch extends StatelessWidget {
  const _ServerSwitch({
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
    this.warning = false,
  });

  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;
  final bool warning;

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
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: TextStyle(
                    fontSize: 11,
                    height: 1.35,
                    color: warning
                        ? PallSqlColors.warning
                        : PallSqlColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          Switch(
            value: value,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }
}
