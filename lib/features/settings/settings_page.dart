import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants/app_info.dart';
import '../../core/theme/pallsql_colors.dart';
import '../../core/utils/formatters.dart';
import '../../models/app_settings.dart';
import '../../models/backup_info.dart';
import '../../providers/app_providers.dart';
import '../../services/app_bootstrap.dart';
import '../../services/native_bridge.dart';
import '../../widgets/pallsql_app_bar.dart';
import '../../widgets/pallsql_card.dart';
import '../../widgets/pallsql_components.dart';
import '../../widgets/pallsql_dialogs.dart';
import '../about/about_page.dart';
import '../backups/backups_page.dart';
import '../files/files_page.dart';
import '../php/php_page.dart';

/// Settings tab: appearance, editor, server, storage, workspace and about.
class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  bool _exporting = false;

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

  void _openFolder(String path, String title) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (BuildContext context) =>
            FilesPage(initialPath: path, titleOverride: title),
      ),
    );
  }

  /// Writes a full workspace ZIP into `backups` and offers it through Android's
  /// share sheet. Nothing leaves the device unless the user picks a target.
  Future<void> _exportWorkspace() async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    setState(() => _exporting = true);
    final AppBootstrap bootstrap = ref.read(bootstrapProvider);
    try {
      final BackupInfo backup = await bootstrap.backups.create(
        includeProjects: true,
        includeWebRoot: true,
        includeDatabases: true,
        includeConfig: true,
        includeLogs: true,
      );
      final bool shared = await bootstrap.native.shareFile(
        backup.path,
        mimeType: 'application/zip',
      );
      if (!mounted) {
        return;
      }
      setState(() => _exporting = false);
      showPallSqlSnack(
        messenger,
        shared
            ? 'Workspace exported: ${backup.fileName}'
            : 'Workspace ZIP written to ${backup.path}',
      );
    } on Object catch (error) {
      if (!mounted) {
        return;
      }
      setState(() => _exporting = false);
      showPallSqlSnack(messenger, 'Export failed: $error', error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppSettings settings = ref.watch(settingsProvider);
    final AsyncValue<StorageReport> storage = ref.watch(storageReportProvider);
    final NativeDeviceInfo? device = ref.watch(deviceInfoProvider);
    final DatabaseOverview? database = ref.watch(databaseProvider).valueOrNull;
    final String workspacePath =
        ref.watch(bootstrapProvider).workspace.rootPath;

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
          const PallSqlSectionHeader(
            title: 'Appearance',
            subtitle: 'PALLSQL keeps dark surfaces with a soft green accent',
          ),
          PallSqlCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    const Expanded(
                      child: Text(
                        'Theme',
                        style: TextStyle(
                          fontSize: 13,
                          color: PallSqlColors.textPrimary,
                        ),
                      ),
                    ),
                    for (final AppThemeMode mode in AppThemeMode.values)
                      Padding(
                        padding: const EdgeInsets.only(left: 6),
                        child: _Choice(
                          label: mode.label,
                          selected: settings.themeMode == mode,
                          onTap: () => _update(
                            settings.copyWith(themeMode: mode),
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: <Widget>[
                    const Expanded(
                      child: Text(
                        'Text size',
                        style: TextStyle(
                          fontSize: 13,
                          color: PallSqlColors.textPrimary,
                        ),
                      ),
                    ),
                    Text(
                      '${(settings.uiTextScale * 100).round()}%',
                      style: const TextStyle(
                        fontSize: 12,
                        color: PallSqlColors.accent,
                        fontFamily: PallSqlColors.monoFontFamily,
                      ),
                    ),
                  ],
                ),
                Slider(
                  value: settings.uiTextScale,
                  min: 0.85,
                  max: 1.3,
                  divisions: 9,
                  activeColor: PallSqlColors.accent,
                  inactiveColor: PallSqlColors.surfaceMuted,
                  onChanged: (double value) {
                    ref.read(settingsProvider.notifier).update(
                          settings.copyWith(
                            uiTextScale:
                                (value * 20).roundToDouble() / 20,
                          ),
                        );
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
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
                          settings.copyWith(
                              editorFontSize: value.roundToDouble()),
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
          const PallSqlSectionHeader(
            title: 'Workspace',
            subtitle: 'One folder shared by files, server, database and terminal',
          ),
          PallSqlCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                const Text(
                  'Location',
                  style: TextStyle(
                    fontSize: 11,
                    color: PallSqlColors.textSecondary,
                  ),
                ),
                const SizedBox(height: 3),
                SelectableText(
                  workspacePath,
                  style: const TextStyle(
                    fontSize: 10.5,
                    height: 1.4,
                    color: PallSqlColors.textPrimary,
                    fontFamily: PallSqlColors.monoFontFamily,
                  ),
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: <Widget>[
                    PallSQLButton(
                      label: 'Open workspace',
                      icon: Icons.folder_open_rounded,
                      compact: true,
                      expand: false,
                      onPressed: () => _openFolder('', 'Workspace'),
                    ),
                    PallSQLButton(
                      label: 'Open htdocs',
                      icon: Icons.public_rounded,
                      compact: true,
                      expand: false,
                      onPressed: () => _openFolder('htdocs', 'htdocs'),
                    ),
                    PallSQLButton(
                      label: 'Open projects',
                      icon: Icons.workspaces_outline,
                      compact: true,
                      expand: false,
                      onPressed: () => _openFolder('projects', 'Projects'),
                    ),
                    PallSQLButton(
                      label: 'Open database folder',
                      icon: Icons.storage_rounded,
                      compact: true,
                      expand: false,
                      onPressed: () => _openFolder('database', 'Database'),
                    ),
                    PallSQLButton(
                      label: 'Open logs',
                      icon: Icons.receipt_long_rounded,
                      compact: true,
                      expand: false,
                      onPressed: () => _openFolder('logs', 'Logs'),
                    ),
                    PallSQLButton(
                      label: 'Export workspace',
                      icon: Icons.archive_rounded,
                      compact: true,
                      expand: false,
                      busy: _exporting,
                      onPressed: _exporting ? null : _exportWorkspace,
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                const Text(
                  'The workspace is private app storage, so other apps cannot '
                  'read it. Use Export workspace (ZIP) to move files out, or '
                  'share a single file from the File Manager.',
                  style: TextStyle(
                    fontSize: 10.5,
                    height: 1.45,
                    color: PallSqlColors.textDisabled,
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
                  value: settings.maxLogEntries
                      .toDouble()
                      .clamp(50.0, 2000.0)
                      .toDouble(),
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
                    final int removed =
                        await ref.read(bootstrapProvider).workspace.clearTemp();
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
                          '${database?.sqlite.version ?? ''}'
                      .trim(),
                  monospace: true,
                ),
                PallSqlKeyValue(
                  label: 'Dialect',
                  value: 'SQLite dialect (not MySQL/MariaDB)',
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
                  label: 'Developer',
                  value: AppInfo.developer,
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
                const SizedBox(height: 8),
                _SettingAction(
                  icon: Icons.info_outline_rounded,
                  label: 'About PALLSQL, developer and licenses',
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (BuildContext context) => const AboutPage(),
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                const Text(
                  AppInfo.copyright,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 10.5,
                    color: PallSqlColors.textDisabled,
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

class _Choice extends StatelessWidget {
  const _Choice({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
        decoration: BoxDecoration(
          color: selected
              ? PallSqlColors.accentMuted
              : PallSqlColors.surfaceMuted,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: selected ? PallSqlColors.accentDeep : PallSqlColors.border,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: selected
                ? PallSqlColors.accentSoft
                : PallSqlColors.textSecondary,
          ),
        ),
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
