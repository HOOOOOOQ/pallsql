import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants/app_info.dart';
import '../../core/theme/pallsql_colors.dart';
import '../../core/utils/formatters.dart';
import '../../models/app_settings.dart';
import '../../providers/app_providers.dart';
import '../../services/app_bootstrap.dart';
import '../../services/native_bridge.dart';
import '../../widgets/pallsql_app_bar.dart';
import '../../widgets/pallsql_card.dart';
import '../../widgets/pallsql_dialogs.dart';
import '../backups/backups_page.dart';
import '../php/php_page.dart';

/// Settings tab: editor, server, storage and about.
class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  Future<void> _update(AppSettings next, {String? success}) async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final String? error =
        await ref.read(settingsProvider.notifier).update(next);
    if (!mounted) {
      return;
    }
    if (error != null) {
      showPallSqlSnack(messenger, error, error: true);
    } else if (success != null) {
      showPallSqlSnack(messenger, success);
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppSettings settings = ref.watch(settingsProvider);
    final AsyncValue<StorageReport> storage = ref.watch(storageReportProvider);
    final NativeDeviceInfo? device = ref.watch(deviceInfoProvider);
    final DatabaseOverview? database = ref.watch(databaseProvider).valueOrNull;

    return Scaffold(
      appBar: PallSQLAppBar(
        title: 'Settings',
        subtitle: '${AppInfo.appName} ${AppInfo.version}',
        actions: <Widget>[
          IconButton(
            tooltip: 'Refresh storage',
            icon: const Icon(Icons.refresh_rounded, size: 19),
            onPressed: () => ref.invalidate(storageReportProvider),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(14, 6, 14, 24),
        children: <Widget>[
          const PallSqlSectionHeader(title: 'Editor'),
          PallSqlCard(
            child: Column(
              children: <Widget>[
                Row(
                  children: <Widget>[
                    const Expanded(
                      child: Text(
                        'Font size',
                        style: TextStyle(
                          fontSize: 13,
                          color: PallSqlColors.textPrimary,
                        ),
                      ),
                    ),
                    Text(
                      '${settings.editorFontSize.toStringAsFixed(0)} pt',
                      style: const TextStyle(
                        fontSize: 12,
                        color: PallSqlColors.accent,
                        fontFamily: PallSqlColors.monoFontFamily,
                      ),
                    ),
                  ],
                ),
                Slider(
                  value: settings.editorFontSize,
                  min: 10,
                  max: 24,
                  divisions: 14,
                  activeColor: PallSqlColors.accent,
                  inactiveColor: PallSqlColors.surfaceMuted,
                  onChanged: (double value) {
                    ref.read(settingsProvider.notifier).update(
                          settings.copyWith(editorFontSize: value.roundToDouble()),
                        );
                  },
                ),
                _SettingSwitch(
                  title: 'Line numbers',
                  value: settings.showLineNumbers,
                  onChanged: (bool value) => _update(
                    settings.copyWith(showLineNumbers: value),
                  ),
                ),
                _SettingSwitch(
                  title: 'Word wrap',
                  value: settings.editorWordWrap,
                  onChanged: (bool value) => _update(
                    settings.copyWith(editorWordWrap: value),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          const PallSqlSectionHeader(title: 'Server'),
          PallSqlCard(
            child: Column(
              children: <Widget>[
                PallSqlKeyValue(
                  label: 'HTTP port',
                  value: '${settings.httpPort}',
                  monospace: true,
                ),
                PallSqlKeyValue(
                  label: 'Bind address',
                  value: settings.lanAccess ? '0.0.0.0 (LAN)' : '127.0.0.1',
                  monospace: true,
                  valueColor: settings.lanAccess
                      ? PallSqlColors.warning
                      : PallSqlColors.textPrimary,
                ),
                _SettingSwitch(
                  title: 'Autostart server',
                  subtitle: 'Start the web server when PALLSQL launches',
                  value: settings.autoStartServer,
                  onChanged: (bool value) => _update(
                    settings.copyWith(autoStartServer: value),
                  ),
                ),
                _SettingSwitch(
                  title: 'LAN access',
                  subtitle: 'Expose the server to your local network',
                  value: settings.lanAccess,
                  onChanged: (bool value) async {
                    final ScaffoldMessengerState messenger =
                        ScaffoldMessenger.of(context);
                    await _update(settings.copyWith(lanAccess: value));
                    if (!mounted) {
                      return;
                    }
                    if (ref.read(webServerProvider).isRunning) {
                      final String? error =
                          await ref.read(webServerProvider.notifier).restart();
                      if (!mounted) {
                        return;
                      }
                      if (error != null) {
                        showPallSqlSnack(messenger, error, error: true);
                      }
                    }
                  },
                ),
                _SettingSwitch(
                  title: 'Server notification',
                  value: settings.notificationsEnabled,
                  onChanged: (bool value) => _update(
                    settings.copyWith(notificationsEnabled: value),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          const PallSqlSectionHeader(title: 'Logs and storage'),
          PallSqlCard(
            child: Column(
              children: <Widget>[
                PallSqlKeyValue(
                  label: 'Log buffer',
                  value: '${settings.maxLogEntries} entries',
                  monospace: true,
                ),
                Slider(
                  value: settings.maxLogEntries.toDouble().clamp(50.0, 2000.0).toDouble(),
                  min: 50,
                  max: 2000,
                  divisions: 39,
                  activeColor: PallSqlColors.accent,
                  inactiveColor: PallSqlColors.surfaceMuted,
                  onChanged: (double value) {
                    ref.read(settingsProvider.notifier).update(
                          settings.copyWith(maxLogEntries: value.round()),
                        );
                  },
                ),
                PallSqlKeyValue(
                  label: 'Workspace size',
                  value: storage.when(
                    data: (StorageReport report) =>
                        '${Formatters.bytes(report.workspaceBytes)} / '
                        '${report.workspaceFiles} files',
                    loading: () => 'measuring...',
                    error: (Object error, StackTrace stack) => 'unavailable',
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
                  label: 'App data',
                  value: storage.valueOrNull?.appBytes == null
                      ? 'n/a'
                      : Formatters.bytes(storage.valueOrNull!.appBytes!),
                  monospace: true,
                ),
                const SizedBox(height: 8),
                _SettingAction(
                  icon: Icons.cleaning_services_rounded,
                  label: 'Clear temporary files',
                  onTap: () async {
                    final ScaffoldMessengerState messenger =
                        ScaffoldMessenger.of(context);
                    final int removed = await ref
                        .read(bootstrapProvider)
                        .workspace
                        .clearTemp();
                    if (!mounted) {
                      return;
                    }
                    showPallSqlSnack(messenger, '$removed item(s) removed');
                  },
                ),
                _SettingAction(
                  icon: Icons.archive_rounded,
                  label: 'Backups and restore',
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (BuildContext context) => const BackupsPage(),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          const PallSqlSectionHeader(title: 'Runtime'),
          PallSqlCard(
            child: Column(
              children: <Widget>[
                PallSqlKeyValue(
                  label: 'Database engine',
                  value: '${database?.sqlite.engine.label ?? 'SQLite'} '
                      '${database?.sqlite.version ?? ''}'.trim(),
                  monospace: true,
                ),
                PallSqlKeyValue(
                  label: 'MariaDB',
                  value: database?.mariadb.available == true
                      ? 'available'
                      : 'not available in this build',
                  monospace: true,
                  valueColor: PallSqlColors.warning,
                ),
                PallSqlKeyValue(
                  label: 'PHP',
                  value: ref.watch(phpStatusProvider).label,
                  monospace: true,
                ),
                const SizedBox(height: 8),
                _SettingAction(
                  icon: Icons.code_rounded,
                  label: 'PHP configuration and runtime install',
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (BuildContext context) => const PhpPage(),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          const PallSqlSectionHeader(title: 'About'),
          PallSqlCard(
            child: Column(
              children: <Widget>[
                const PallSqlKeyValue(
                  label: 'Application',
                  value: '${AppInfo.appName} ${AppInfo.version}',
                  monospace: true,
                ),
                const PallSqlKeyValue(
                  label: 'Package',
                  value: AppInfo.packageName,
                  monospace: true,
                ),
                PallSqlKeyValue(
                  label: 'Android',
                  value: device == null
                      ? 'unknown'
                      : '${device.androidVersion} (API ${device.sdkInt})',
                  monospace: true,
                ),
                PallSqlKeyValue(
                  label: 'ABIs',
                  value: device == null || device.abis.isEmpty
                      ? 'unknown'
                      : device.abis.join(', '),
                  monospace: true,
                  maxLines: 2,
                ),
                PallSqlKeyValue(
                  label: 'Workspace',
                  value: ref.watch(bootstrapProvider).workspace.rootPath,
                  monospace: true,
                  maxLines: 2,
                ),
                const SizedBox(height: 8),
                const Text(
                  'PALLSQL is an offline development environment for Android. '
                  'It runs a real HTTP server and a real SQLite engine inside the '
                  'app sandbox. PHP requires a runtime you install; MariaDB is '
                  'not bundled.',
                  style: TextStyle(
                    fontSize: 11,
                    height: 1.45,
                    color: PallSqlColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SettingSwitch extends StatelessWidget {
  const _SettingSwitch({
    required this.title,
    required this.value,
    required this.onChanged,
    this.subtitle,
  });

  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

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
                if (subtitle != null)
                  Text(
                    subtitle!,
                    style: const TextStyle(
                      fontSize: 11,
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

class _SettingAction extends StatelessWidget {
  const _SettingAction({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 2),
        child: Row(
          children: <Widget>[
            Icon(icon, size: 16, color: PallSqlColors.accent),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                label,
                style: const TextStyle(
                  fontSize: 12.5,
                  color: PallSqlColors.textPrimary,
                ),
              ),
            ),
            const Icon(
              Icons.chevron_right_rounded,
              size: 16,
              color: PallSqlColors.textDisabled,
            ),
          ],
        ),
      ),
    );
  }
}
