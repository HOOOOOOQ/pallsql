import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/pallsql_colors.dart';
import '../../core/utils/formatters.dart';
import '../../providers/app_providers.dart';
import '../../services/legacy_sqlite_migration.dart';
import '../../widgets/pallsql_card.dart';
import '../../widgets/pallsql_dialogs.dart';

/// Shows the SQLite files left over from PALLSQL 0.1/0.2 and copies their data
/// into MariaDB only when the user asks for it.
///
/// The scan is a real scan of `PALLSQL/database`, the import is a real import
/// through [LegacySqliteMigration], and the source file is never deleted - the
/// card says so explicitly after a successful migration.
class LegacyDataCard extends ConsumerStatefulWidget {
  const LegacyDataCard({super.key});

  @override
  ConsumerState<LegacyDataCard> createState() => _LegacyDataCardState();
}

class _LegacyDataCardState extends ConsumerState<LegacyDataCard> {
  bool _scanning = false;
  bool _scanned = false;
  bool _migrating = false;
  String? _error;
  List<LegacyDatabase> _found = const <LegacyDatabase>[];
  String? _summary;

  Future<void> _scan() async {
    setState(() {
      _scanning = true;
      _error = null;
      _summary = null;
    });
    try {
      final List<LegacyDatabase> found =
          await ref.read(legacyMigrationProvider).scan();
      if (!mounted) {
        return;
      }
      setState(() {
        _found = found;
        _scanned = true;
      });
    } on Object catch (error) {
      if (mounted) {
        setState(() => _error = 'Scan failed: $error');
      }
    } finally {
      if (mounted) {
        setState(() => _scanning = false);
      }
    }
  }

  Future<void> _migrate(LegacyDatabase legacy) async {
    if (!ref.read(mariadbServiceProvider).isRunning) {
      showPallSqlSnack(
        ScaffoldMessenger.of(context),
        'Start MariaDB first: the legacy data is copied into a real schema.',
        error: true,
      );
      return;
    }
    final bool confirmed = await showConfirmDialog(
      context: context,
      title: 'Import ${legacy.name}?',
      message: 'PALLSQL reads ${legacy.path} (${legacy.tables.length} table(s)) '
          'and copies the rows into a new MariaDB schema named '
          '"${legacy.targetSchema}". The original file is kept untouched - no '
          'data is deleted.',
      confirmLabel: 'Import',
    );
    if (!confirmed || !mounted) {
      return;
    }
    setState(() {
      _migrating = true;
      _error = null;
      _summary = null;
    });
    try {
      final LegacyMigrationReport report =
          await ref.read(legacyMigrationProvider).migrate(legacy);
      if (!mounted) {
        return;
      }
      setState(() {
        _summary = report.summary;
        if (!report.ok) {
          _error = report.summary;
        }
      });
      await ref.read(databaseProvider.notifier).refresh();
      if (mounted) {
        showPallSqlSnack(
          ScaffoldMessenger.of(context),
          report.ok
              ? '${report.rowsMigrated} row(s) copied into ${report.schema}'
              : 'Import failed: ${report.error}',
          error: !report.ok,
        );
      }
    } on Object catch (error) {
      if (mounted) {
        setState(() => _error = 'Import failed: $error');
      }
    } finally {
      if (mounted) {
        setState(() => _migrating = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: PallSqlCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                const Icon(
                  Icons.inventory_2_outlined,
                  size: 16,
                  color: PallSqlColors.textSecondary,
                ),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    'Legacy SQLite data',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: PallSqlColors.textPrimary,
                    ),
                  ),
                ),
                TextButton(
                  onPressed: _scanning || _migrating ? null : _scan,
                  child: Text(
                    _scanned ? 'Scan again' : 'Scan',
                    style: const TextStyle(fontSize: 11.5),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            const Text(
              'PALLSQL 0.3 no longer uses SQLite. Files from 0.1/0.2 can be '
              'read once and copied into MariaDB; nothing is deleted and no '
              'file is opened unless you press Scan.',
              style: TextStyle(
                fontSize: 11,
                height: 1.45,
                color: PallSqlColors.textSecondary,
              ),
            ),
            if (_scanning) ...<Widget>[
              const SizedBox(height: 10),
              const LinearProgressIndicator(minHeight: 2),
            ],
            if (_scanned && _found.isEmpty) ...<Widget>[
              const SizedBox(height: 10),
              const Text(
                'No legacy .db files found in PALLSQL/database.',
                style: TextStyle(
                  fontSize: 11.5,
                  color: PallSqlColors.textDisabled,
                ),
              ),
            ],
            for (final LegacyDatabase legacy in _found) ...<Widget>[
              const SizedBox(height: 10),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          '${legacy.name}.db',
                          style: const TextStyle(
                            fontSize: 12.5,
                            fontFamily: PallSqlColors.monoFontFamily,
                            color: PallSqlColors.textPrimary,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${Formatters.bytes(legacy.sizeBytes)} · '
                          '${legacy.readable ? '${legacy.tables.length} table(s)' : 'unreadable'}'
                          '${legacy.error == null ? '' : ' · ${legacy.error}'}',
                          style: TextStyle(
                            fontSize: 11,
                            height: 1.4,
                            color: legacy.readable
                                ? PallSqlColors.textSecondary
                                : PallSqlColors.error,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  TextButton(
                    onPressed: _migrating || !legacy.readable
                        ? null
                        : () => _migrate(legacy),
                    child: const Text(
                      'Import to MariaDB',
                      style: TextStyle(fontSize: 11.5),
                    ),
                  ),
                ],
              ),
            ],
            if (_summary != null) ...<Widget>[
              const SizedBox(height: 8),
              Text(
                _summary!,
                style: const TextStyle(
                  fontSize: 11,
                  height: 1.45,
                  color: PallSqlColors.textSecondary,
                ),
              ),
            ],
            if (_error != null) ...<Widget>[
              const SizedBox(height: 8),
              Text(
                _error!,
                style: const TextStyle(
                  fontSize: 11,
                  height: 1.45,
                  color: PallSqlColors.error,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
