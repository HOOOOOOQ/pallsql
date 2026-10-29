import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/errors/app_failure.dart';
import '../../core/theme/pallsql_colors.dart';
import '../../core/utils/formatters.dart';
import '../../core/utils/sql_utils.dart';
import '../../core/utils/validators.dart';
import '../../models/database_models.dart';
import '../../providers/app_providers.dart';
import '../../repositories/database_repository.dart';
import '../../widgets/code_editor_panel.dart';
import '../../widgets/pallsql_app_bar.dart';
import '../../widgets/pallsql_card.dart';
import '../../widgets/pallsql_dialogs.dart';
import '../../widgets/query_result_view.dart';
import '../../widgets/service_control_button.dart';
import '../editor/syntax_highlighter.dart';

/// Standalone SQL editor: pick a database, write SQL, run it, read the result.
///
/// The page is the single entry point for ad-hoc SQL. It uses the shared
/// [SqliteDatabaseRepository] from the bootstrap, so it reuses the very same
/// SQLite connections as the table browser; no second driver is created.
class SqlEditorPage extends ConsumerStatefulWidget {
  const SqlEditorPage({super.key, this.initialDatabase});

  /// Database preselected when the page opens (for example the one the user
  /// just tapped on the Database tab).
  final String? initialDatabase;

  @override
  ConsumerState<SqlEditorPage> createState() => _SqlEditorPageState();
}

class _SqlEditorPageState extends ConsumerState<SqlEditorPage> {
  final HighlightingTextController _sqlController =
      HighlightingTextController(language: CodeLanguage.sql);
  String? _database;
  QueryResult? _result;
  bool _running = false;
  bool _creating = false;

  SqliteDatabaseRepository get _repository =>
      ref.read(databaseRepositoryProvider);

  @override
  void initState() {
    super.initState();
    _database = widget.initialDatabase;
  }

  @override
  void dispose() {
    _sqlController.dispose();
    super.dispose();
  }

  void _snack(String message, {bool error = false}) {
    if (!mounted) {
      return;
    }
    showPallSqlSnack(ScaffoldMessenger.of(context), message, error: error);
  }

  void _select(String? name) {
    setState(() {
      _database = name;
      _result = null;
    });
    if (name != null) {
      _previewSchema(name);
    }
  }

  /// Loads the table list of the selected database so an empty query result is
  /// easy to diagnose.
  Future<void> _previewSchema(String name) async {
    try {
      final List<TableInfo> tables = await _repository.listTables(name);
      if (!mounted || _database != name) {
        return;
      }
      if (tables.isEmpty && _result == null) {
        _snack('$name has no tables yet - run a CREATE TABLE statement');
      }
    } on AppFailure catch (failure) {
      if (!mounted) {
        return;
      }
      _snack(failure.combined, error: true);
    }
  }

  Future<void> _createDatabase() async {
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
    setState(() => _creating = true);
    final String? error =
        await ref.read(databaseProvider.notifier).createDatabase(name);
    if (!mounted) {
      return;
    }
    setState(() => _creating = false);
    if (error != null) {
      _snack(error, error: true);
      return;
    }
    _snack('Database $name created');
    _select(name);
  }

  /// Runs the statements in the editor against the selected database.
  Future<void> _execute() async {
    final List<DatabaseInfo> databases =
        ref.read(databaseProvider).valueOrNull?.databases ??
            const <DatabaseInfo>[];
    final String? name = _database;
    if (name == null || name.isEmpty) {
      _snack('Select a database first', error: true);
      return;
    }
    if (!databases.any((DatabaseInfo info) => info.name == name)) {
      _snack('Database $name is no longer available', error: true);
      return;
    }
    final String database = name;
    final String sql = _sqlController.text.trim();
    if (sql.isEmpty) {
      _snack('Enter a SQL statement', error: true);
      return;
    }
    final bool destructive = SqlUtils.splitStatements(sql)
        .any((SqlStatement statement) => SqlUtils.isDestructive(statement.sql));
    if (destructive) {
      final bool confirmed = await showConfirmDialog(
        context: context,
        title: 'Destructive statement',
        message: 'This script drops data or modifies rows without a WHERE '
            'clause. Run it against $database?',
        confirmLabel: 'Run anyway',
        destructive: true,
      );
      if (!confirmed || !mounted) {
        return;
      }
    }
    setState(() => _running = true);
    try {
      final QueryResult result =
          await _repository.execute(database, sql, allowDestructive: true);
      if (!mounted) {
        return;
      }
      setState(() {
        _result = result;
        _running = false;
      });
      ref.read(queryHistoryProvider.notifier).refresh();
      if (result.error != null) {
        _snack(result.error!, error: true);
      }
    } on AppFailure catch (failure) {
      if (!mounted) {
        return;
      }
      setState(() {
        _running = false;
        _result = QueryResult.failure(failure.combined);
      });
      ref.read(queryHistoryProvider.notifier).refresh();
      _snack(failure.combined, error: true);
    } on Object catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _running = false;
        _result = QueryResult.failure('$error');
      });
      _snack('$error', error: true);
    }
  }

  void _clear() {
    _sqlController.clear();
    setState(() => _result = null);
  }

  void _useHistoryEntry(QueryHistoryEntry entry) {
    _database = entry.database;
    _sqlController.text = entry.sql;
    setState(() => _result = null);
  }

  @override
  Widget build(BuildContext context) {
    final AsyncValue<DatabaseOverview> async = ref.watch(databaseProvider);
    final DatabaseOverview? overview = async.valueOrNull;
    final List<DatabaseInfo> databases =
        overview?.databases ?? const <DatabaseInfo>[];
    final List<QueryHistoryEntry> history = ref.watch(queryHistoryProvider);
    // A database can disappear between builds (deleted on the Database tab),
    // so the selection is resolved against the list that is on screen.
    String? selected;
    for (final DatabaseInfo info in databases) {
      if (info.name == _database) {
        selected = info.name;
        break;
      }
    }

    return Scaffold(
      appBar: PallSQLAppBar(
        title: 'SQL editor',
        subtitle: selected == null ? 'No database selected' : selected,
        showBack: true,
        actions: <Widget>[
          IconButton(
            tooltip: 'Query history',
            icon: const Icon(Icons.history_rounded, size: 19),
            onPressed: history.isEmpty ? null : () => _showHistory(history),
          ),
          IconButton(
            tooltip: 'Refresh databases',
            icon: const Icon(Icons.refresh_rounded, size: 19),
            onPressed: () => ref.read(databaseProvider.notifier).refresh(),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(14, 6, 14, 28),
        children: <Widget>[
          const PallSqlSectionHeader(
            title: 'Database',
            subtitle: 'Statements run against the selected SQLite file',
          ),
          _DatabasePicker(
            databases: databases,
            selected: selected,
            busy: _creating,
            onSelect: _select,
            onCreate: _createDatabase,
          ),
          const SizedBox(height: 16),
          const PallSqlSectionHeader(
            title: 'SQL',
            subtitle: 'Separate statements with a semicolon',
          ),
          SizedBox(
            height: 200,
            child: CodeEditorPanel(
              controller: _sqlController,
              language: CodeLanguage.sql,
              fontSize: 12.5,
              showLineNumbers: true,
              hintText: 'SELECT * FROM sqlite_master;',
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: <Widget>[
              Expanded(
                child: ServiceControlButton(
                  label: 'Execute',
                  icon: Icons.play_arrow_rounded,
                  filled: true,
                  busy: _running,
                  onPressed: _running ? null : _execute,
                ),
              ),
              const SizedBox(width: 8),
              ServiceControlButton(
                label: 'Clear',
                icon: Icons.backspace_outlined,
                compact: true,
                expand: false,
                onPressed: _running ? null : _clear,
              ),
            ],
          ),
          if (_running) ...<Widget>[
            const SizedBox(height: 10),
            const LinearProgressIndicator(minHeight: 2),
          ],
          const SizedBox(height: 14),
          PallSqlSectionHeader(
            title: 'Result',
            subtitle: _resultSummary(),
          ),
          _buildResult(),
          const SizedBox(height: 18),
          PallSqlSectionHeader(
            title: 'History',
            subtitle: history.isEmpty
                ? 'Nothing executed yet'
                : 'Last ${history.length} statement(s)',
            trailing: history.isEmpty
                ? null
                : TextButton(
                    onPressed: () async {
                      await ref.read(queryHistoryProvider.notifier).clear();
                      if (!mounted) {
                        return;
                      }
                      _snack('History cleared');
                    },
                    style: TextButton.styleFrom(
                      minimumSize: Size.zero,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: const Text('Clear', style: TextStyle(fontSize: 11)),
                  ),
          ),
          if (history.isEmpty)
            const PallSqlCard(
              child: Text(
                'Every statement you execute is recorded here with its '
                'database, duration and whether it succeeded. Results and '
                'credentials are never stored.',
                style: TextStyle(
                  fontSize: 11.5,
                  color: PallSqlColors.textSecondary,
                  height: 1.4,
                ),
              ),
            )
          else
            PallSqlCard(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  for (final QueryHistoryEntry entry in history.take(10))
                    InkWell(
                      onTap: () => _useHistoryEntry(entry),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6),
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
                                      100,
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
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  String _resultSummary() {
    if (_running) {
      return 'Running...';
    }
    final QueryResult? result = _result;
    if (result == null) {
      return 'Nothing executed yet';
    }
    if (result.isError) {
      return 'Failed';
    }
    if (result.hasResultSet) {
      return '${Formatters.count(result.rowCount, 'row')} in '
          '${Formatters.duration(result.duration)}';
    }
    return '${result.statements} statement(s), '
        '${Formatters.count(result.rowsAffected, 'row')} affected';
  }

  Widget _buildResult() {
    if (_running) {
      return const PallSqlCard(
        child: Text(
          'Executing...',
          style: TextStyle(fontSize: 11.5, color: PallSqlColors.textSecondary),
        ),
      );
    }
    final QueryResult? result = _result;
    if (result == null) {
      return PallSqlCard(
        child: PallSqlEmptyState(
          icon: Icons.play_circle_outline_rounded,
          title: _database == null ? 'Pick a database' : 'Ready to run',
          message: _database == null
              ? 'Create or select a SQLite database to start writing SQL.'
              : 'Write a statement above and press Execute.',
        ),
      );
    }
    return QueryResultView(result: result, maxHeight: 280);
  }

  void _showHistory(List<QueryHistoryEntry> history) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: PallSqlColors.surfaceElevated,
      showDragHandle: true,
      builder: (BuildContext sheetContext) {
        return SafeArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            children: <Widget>[
              const Text(
                'Query history',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: PallSqlColors.textPrimary,
                ),
              ),
              const SizedBox(height: 8),
              for (final QueryHistoryEntry entry in history)
                InkWell(
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    _useHistoryEntry(entry);
                  },
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Row(
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
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            entry.sql.replaceAll(RegExp(r'\s+'), ' '),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 11.5,
                              fontFamily: PallSqlColors.monoFontFamily,
                              color: PallSqlColors.textPrimary,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

/// Database chooser plus the "New database" shortcut.
class _DatabasePicker extends StatelessWidget {
  const _DatabasePicker({
    required this.databases,
    required this.selected,
    required this.busy,
    required this.onSelect,
    required this.onCreate,
  });

  final List<DatabaseInfo> databases;
  final String? selected;
  final bool busy;
  final ValueChanged<String?> onSelect;
  final VoidCallback onCreate;

  @override
  Widget build(BuildContext context) {
    if (databases.isEmpty) {
      return PallSqlCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const PallSqlEmptyState(
              icon: Icons.storage_rounded,
              title: 'No databases yet',
              message: 'Create a SQLite database to run SQL offline. The file '
                  'lives in PALLSQL/database and survives restarts.',
            ),
            ServiceControlButton(
              label: 'New database',
              icon: Icons.add_rounded,
              filled: true,
              busy: busy,
              onPressed: onCreate,
            ),
          ],
        ),
      );
    }
    return PallSqlCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: PallSqlColors.background,
              border: Border.all(color: PallSqlColors.border),
              borderRadius: BorderRadius.circular(9),
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                value: selected,
                isExpanded: true,
                dropdownColor: PallSqlColors.surfaceElevated,
                icon: const Icon(
                  Icons.expand_more_rounded,
                  size: 18,
                  color: PallSqlColors.textSecondary,
                ),
                style: const TextStyle(
                  fontSize: 12.5,
                  color: PallSqlColors.textPrimary,
                  fontFamily: PallSqlColors.monoFontFamily,
                ),
                hint: const Text(
                  'Select a database',
                  style: TextStyle(
                    fontSize: 12,
                    color: PallSqlColors.textDisabled,
                  ),
                ),
                items: <DropdownMenuItem<String>>[
                  for (final DatabaseInfo database in databases)
                    DropdownMenuItem<String>(
                      value: database.name,
                      child: Text(
                        database.name,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 12.5,
                          fontFamily: PallSqlColors.monoFontFamily,
                          color: PallSqlColors.textPrimary,
                        ),
                      ),
                    ),
                ],
                onChanged: onSelect,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  selected == null
                      ? 'No database selected'
                      : 'Running against $selected.db',
                  style: const TextStyle(
                    fontSize: 11,
                    color: PallSqlColors.textSecondary,
                  ),
                ),
              ),
              TextButton.icon(
                onPressed: busy ? null : onCreate,
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
            ],
          ),
        ],
      ),
    );
  }
}
