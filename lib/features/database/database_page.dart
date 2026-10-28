import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/pallsql_colors.dart';
import '../../core/utils/formatters.dart';
import '../../core/utils/validators.dart';
import '../../models/database_models.dart';
import '../../models/log_entry.dart';
import '../../providers/app_providers.dart';
import '../../repositories/database_repository.dart';
import '../../widgets/database_card.dart';
import '../../widgets/pallsql_app_bar.dart';
import '../../widgets/pallsql_card.dart';
import '../../widgets/pallsql_dialogs.dart';
import '../../widgets/service_control_button.dart';
import '../logs/logs_page.dart';
import 'database_detail_page.dart';

/// Database tab: engine status, database files and query history.
class DatabasePage extends ConsumerStatefulWidget {
  const DatabasePage({super.key});

  @override
  ConsumerState<DatabasePage> createState() => _DatabasePageState();
}

class _DatabasePageState extends ConsumerState<DatabasePage> {
  bool _busy = false;

  Future<void> _createDatabase() async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final String? name = await showPromptDialog(
      context: context,
      title: 'New SQLite database',
      label: 'Database name',
      message: 'A file named <name>.db is created in PALLSQL/database.',
      confirmLabel: 'Create',
      validator: Validators.databaseNameError,
    );
    if (name == null || !mounted) {
      return;
    }
    setState(() => _busy = true);
    final String? error =
        await ref.read(databaseProvider.notifier).createDatabase(name);
    if (!mounted) {
      return;
    }
    setState(() => _busy = false);
    showPallSqlSnack(
      messenger,
      error ?? 'Database $name created',
      error: error != null,
    );
  }

  Future<void> _deleteDatabase(DatabaseInfo database) async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final bool confirmed = await showConfirmDialog(
      context: context,
      title: 'Delete ${database.name}?',
      message: 'The database file and its -wal/-shm sidecars are removed from '
          'the workspace. This cannot be undone unless you have a backup.',
      confirmLabel: 'Delete',
      destructive: true,
    );
    if (!confirmed || !mounted) {
      return;
    }
    final String? error =
        await ref.read(databaseProvider.notifier).deleteDatabase(database.name);
    if (!mounted) {
      return;
    }
    showPallSqlSnack(
      messenger,
      error ?? '${database.name} deleted',
      error: error != null,
    );
  }

  Future<void> _backupDatabase(DatabaseInfo database) async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final SqliteDatabaseRepository repository =
        ref.read(databaseRepositoryProvider);
    final AppBootstrapRef bootstrap = AppBootstrapRef(ref);
    try {
      final File file = await repository.backupDatabase(
        database.name,
        bootstrap.backupsDirectory,
      );
      await ref.read(databaseProvider.notifier).refresh();
      if (!mounted) {
        return;
      }
      showPallSqlSnack(messenger, 'Backup written to ${file.path}');
    } on Object catch (error) {
      if (!mounted) {
        return;
      }
      showPallSqlSnack(messenger, 'Backup failed: $error', error: true);
    }
  }

  void _openDatabase(DatabaseInfo database) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (BuildContext context) =>
            DatabaseDetailPage(databaseName: database.name),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final AsyncValue<DatabaseOverview> async = ref.watch(databaseProvider);
    final DatabaseOverview? overview = async.valueOrNull;
    final List<QueryHistoryEntry> history =
        ref.watch(databaseRepositoryProvider).history;

    return Scaffold(
      appBar: PallSQLAppBar(
        title: 'Database',
        subtitle: 'SQLite - offline engine',
        actions: <Widget>[
          IconButton(
            tooltip: 'Database logs',
            icon: const Icon(Icons.receipt_long_rounded, size: 19),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (BuildContext context) =>
                    const LogsPage(initialSource: LogSource.database),
              ),
            ),
          ),
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh_rounded, size: 19),
            onPressed: () => ref.read(databaseProvider.notifier).refresh(),
          ),
        ],
      ),
      body: RefreshIndicator(
        color: PallSqlColors.accent,
        backgroundColor: PallSqlColors.surfaceElevated,
        onRefresh: () => ref.read(databaseProvider.notifier).refresh(),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(14, 6, 14, 24),
          children: <Widget>[
            if (async.isLoading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: LinearProgressIndicator(minHeight: 2),
              ),
            if (async.hasError)
              PallSqlCard(
                accentColor: PallSqlColors.error,
                child: Text(
                  '${async.error}',
                  style: const TextStyle(
                    color: PallSqlColors.error,
                    fontSize: 11.5,
                  ),
                ),
              ),
            if (overview != null) ...<Widget>[
              EngineCard(availability: overview.sqlite),
              const SizedBox(height: 8),
              EngineCard(availability: overview.mariadb),
            ],
            const SizedBox(height: 16),
            PallSqlSectionHeader(
              title: 'Databases',
              subtitle:
                  '${overview?.databases.length ?? 0} file(s) in PALLSQL/database',
              trailing: TextButton.icon(
                onPressed: _busy ? null : _createDatabase,
                icon: const Icon(Icons.add_rounded, size: 15),
                label: const Text('New', style: TextStyle(fontSize: 11.5)),
                style: TextButton.styleFrom(
                  foregroundColor: PallSqlColors.accent,
                  minimumSize: Size.zero,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
            ),
            if (overview != null && overview.databases.isEmpty)
              const PallSqlCard(
                child: PallSqlEmptyState(
                  icon: Icons.storage_rounded,
                  title: 'No databases yet',
                  message: 'Create your first SQLite database to run SQL '
                      'entirely offline.',
                ),
              )
            else
              for (final DatabaseInfo database
                  in overview?.databases ?? const <DatabaseInfo>[])
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: DatabaseCard(
                    database: database,
                    onTap: () => _openDatabase(database),
                    onDelete: () => _deleteDatabase(database),
                    onBackup: () => _backupDatabase(database),
                  ),
                ),
            const SizedBox(height: 18),
            PallSqlSectionHeader(
              title: 'Query history',
              subtitle: 'Last ${history.length} statement(s)',
              trailing: history.isEmpty
                  ? null
                  : TextButton(
                      onPressed: () async {
                        final ScaffoldMessengerState messenger =
                            ScaffoldMessenger.of(context);
                        await ref
                            .read(databaseRepositoryProvider)
                            .clearHistory();
                        if (!mounted) {
                          return;
                        }
                        setState(() {});
                        showPallSqlSnack(messenger, 'History cleared');
                      },
                      style: TextButton.styleFrom(
                        minimumSize: Size.zero,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      child:
                          const Text('Clear', style: TextStyle(fontSize: 11)),
                    ),
            ),
            if (history.isEmpty)
              const PallSqlCard(
                child: Text(
                  'Statements you run in the SQL editor are recorded here '
                  '(never the results, never credentials).',
                  style: TextStyle(
                    fontSize: 11.5,
                    color: PallSqlColors.textSecondary,
                    height: 1.4,
                  ),
                ),
              )
            else
              PallSqlCard(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    for (final QueryHistoryEntry entry in history.take(8))
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 5),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Icon(
                              entry.succeeded
                                  ? Icons.check_circle_outline_rounded
                                  : Icons.error_outline_rounded,
                              size: 13,
                              color: entry.succeeded
                                  ? PallSqlColors.success
                                  : PallSqlColors.error,
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: <Widget>[
                                  Text(
                                    Formatters.truncate(
                                      entry.sql.replaceAll(RegExp(r'\s+'), ' '),
                                      120,
                                    ),
                                    style: const TextStyle(
                                      fontSize: 11,
                                      fontFamily: PallSqlColors.monoFontFamily,
                                      color: PallSqlColors.textPrimary,
                                    ),
                                  ),
                                  Text(
                                    '${entry.database} - '
                                    '${Formatters.relativeTime(entry.executedAt)}'
                                    ' - ${entry.durationMs} ms',
                                    style: const TextStyle(
                                      fontSize: 10,
                                      color: PallSqlColors.textDisabled,
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
            const SizedBox(height: 18),
            const PallSqlSectionHeader(title: 'Engine notes'),
            const PallSqlCard(
              child: Text(
                'SQLite is an embedded engine: every database is a single file, '
                'queries run inside the app and everything works offline. It is '
                'not MySQL or MariaDB, and PALLSQL never labels it as such. '
                'MariaDB needs a native server build plus a data directory '
                'bootstrap which has not been verified on device, so it stays '
                'marked unavailable. The SQL editor refuses ATTACH/DETACH so a '
                'script cannot touch files outside the workspace.',
                style: TextStyle(
                  fontSize: 11.5,
                  height: 1.5,
                  color: PallSqlColors.textSecondary,
                ),
              ),
            ),
            const SizedBox(height: 14),
            ServiceControlButton(
              label: 'Open SQL editor',
              icon: Icons.terminal_rounded,
              filled: true,
              onPressed: overview == null || overview.databases.isEmpty
                  ? null
                  : () => _openDatabase(overview.databases.first),
            ),
          ],
        ),
      ),
    );
  }
}

/// Tiny helper that exposes workspace folders without importing bootstrap in
/// every page.
class AppBootstrapRef {
  AppBootstrapRef(this.ref);

  final WidgetRef ref;

  Directory get backupsDirectory =>
      ref.read(bootstrapProvider).workspace.backups;
}
