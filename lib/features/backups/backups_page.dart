import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/pallsql_colors.dart';
import '../../core/utils/formatters.dart';
import '../../models/backup_info.dart';
import '../../providers/app_providers.dart';
import '../../services/backup_service.dart';
import '../../widgets/pallsql_app_bar.dart';
import '../../widgets/pallsql_card.dart';
import '../../widgets/pallsql_dialogs.dart';
import '../../widgets/service_control_button.dart';

/// Backup and restore of projects, web root, databases and configuration.
class BackupsPage extends ConsumerStatefulWidget {
  const BackupsPage({super.key});

  @override
  ConsumerState<BackupsPage> createState() => _BackupsPageState();
}

class _BackupsPageState extends ConsumerState<BackupsPage> {
  bool _busy = false;

  Future<void> _create() async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    final String? error = await ref.read(backupsProvider.notifier).create();
    if (!mounted) {
      return;
    }
    setState(() => _busy = false);
    showPallSqlSnack(
      messenger,
      error ?? 'Backup created',
      error: error != null,
    );
  }

  Future<void> _restore(BackupInfo backup) async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final BackupValidation validation =
        await ref.read(backupServiceProvider).validate(backup);
    if (!mounted) {
      return;
    }
    if (!validation.valid) {
      showPallSqlSnack(
        messenger,
        validation.issues.isEmpty
            ? 'Backup is not valid'
            : validation.issues.first,
        error: true,
      );
      return;
    }
    final bool confirmed = await showConfirmDialog(
      context: context,
      title: 'Restore ${backup.fileName}?',
      message: '${validation.entryCount} files will be written over the current '
          'workspace. A safety backup of the current state is created first.',
      confirmLabel: 'Restore',
      destructive: true,
    );
    if (!confirmed || !mounted) {
      return;
    }
    setState(() => _busy = true);
    final String? error =
        await ref.read(backupsProvider.notifier).restore(backup);
    if (!mounted) {
      return;
    }
    setState(() => _busy = false);
    showPallSqlSnack(
      messenger,
      error ?? 'Restored ${backup.fileName}',
      error: error != null,
    );
  }

  Future<void> _delete(BackupInfo backup) async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final bool confirmed = await showConfirmDialog(
      context: context,
      title: 'Delete backup?',
      message: '${backup.fileName} is removed from PALLSQL/backups.',
      confirmLabel: 'Delete',
      destructive: true,
    );
    if (!confirmed || !mounted) {
      return;
    }
    final String? error =
        await ref.read(backupsProvider.notifier).delete(backup);
    if (!mounted) {
      return;
    }
    showPallSqlSnack(
      messenger,
      error ?? 'Backup deleted',
      error: error != null,
    );
  }

  Future<void> _export(BackupInfo backup) async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final bool shared =
        await ref.read(nativeBridgeProvider).shareFile(backup.path);
    if (!mounted) {
      return;
    }
    showPallSqlSnack(
      messenger,
      shared
          ? 'Shared ${backup.fileName}'
          : 'Backup is stored at ${backup.path}',
    );
  }

  @override
  Widget build(BuildContext context) {
    final AsyncValue<List<BackupInfo>> async = ref.watch(backupsProvider);
    final List<BackupInfo> backups = async.valueOrNull ?? const <BackupInfo>[];
    return Scaffold(
      appBar: PallSQLAppBar(
        title: 'Backups',
        subtitle: 'ZIP archives in PALLSQL/backups',
        showBack: true,
        actions: <Widget>[
          IconButton(
            tooltip: 'Create backup',
            icon: const Icon(Icons.add_rounded, size: 20),
            onPressed: _busy ? null : _create,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(14, 8, 14, 24),
        children: <Widget>[
          if (_busy) const LinearProgressIndicator(minHeight: 2),
          ServiceControlButton(
            label: 'Create backup now',
            icon: Icons.archive_rounded,
            filled: true,
            busy: _busy,
            onPressed: _create,
          ),
          const SizedBox(height: 14),
          PallSqlSectionHeader(
            title: 'Archives',
            subtitle: '${backups.length} available',
          ),
          if (backups.isEmpty)
            const PallSqlCard(
              child: PallSqlEmptyState(
                icon: Icons.archive_outlined,
                title: 'No backups yet',
                message: 'A backup contains projects, htdocs, databases and '
                    'configuration. Credentials are never included.',
              ),
            )
          else
            for (final BackupInfo backup in backups)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: PallSqlCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Row(
                        children: <Widget>[
                          const Icon(
                            Icons.folder_zip_rounded,
                            size: 17,
                            color: PallSqlColors.accent,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              backup.fileName,
                              style: const TextStyle(
                                fontSize: 12.5,
                                fontFamily: PallSqlColors.monoFontFamily,
                                color: PallSqlColors.textPrimary,
                              ),
                            ),
                          ),
                          Text(
                            backup.sizeLabel,
                            style: const TextStyle(
                              fontSize: 10.5,
                              color: PallSqlColors.textSecondary,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${Formatters.dateTime(backup.createdAt)}'
                        '${backup.entryCount == null ? '' : ' - ${backup.entryCount} entries'}',
                        style: const TextStyle(
                          fontSize: 10.5,
                          color: PallSqlColors.textDisabled,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: <Widget>[
                          ServiceControlButton(
                            label: 'Restore',
                            icon: Icons.restore_rounded,
                            compact: true,
                            expand: false,
                            onPressed: () => _restore(backup),
                          ),
                          ServiceControlButton(
                            label: 'Export',
                            icon: Icons.ios_share_rounded,
                            compact: true,
                            expand: false,
                            onPressed: () => _export(backup),
                          ),
                          ServiceControlButton(
                            label: 'Delete',
                            icon: Icons.delete_outline_rounded,
                            compact: true,
                            expand: false,
                            destructive: true,
                            onPressed: () => _delete(backup),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
          const SizedBox(height: 8),
          const PallSqlCard(
            child: Text(
              'Restores are validated entry by entry: absolute paths, parent '
              'traversal and files outside htdocs/projects/database/config/logs '
              'are rejected, so a crafted archive cannot write outside the app '
              'sandbox. A safety backup is created before every restore.',
              style: TextStyle(
                fontSize: 11.5,
                height: 1.45,
                color: PallSqlColors.textSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
