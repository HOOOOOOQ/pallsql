import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/errors/app_failure.dart';
import '../../core/theme/pallsql_colors.dart';
import '../../core/utils/formatters.dart';
import '../../core/utils/sql_utils.dart';
import '../../core/utils/validators.dart';
import '../../models/app_settings.dart';
import '../../models/database_models.dart';
import '../../providers/app_providers.dart';
import '../../repositories/database_repository.dart';
import '../../services/app_bootstrap.dart';
import '../../services/query_store.dart';
import '../../services/sql_compatibility.dart';
import '../../widgets/pallsql_app_bar.dart';
import '../../widgets/pallsql_card.dart';
import '../../widgets/pallsql_components.dart';
import '../../widgets/pallsql_dialogs.dart';
import '../../widgets/query_result_view.dart';
import '../editor/syntax_highlighter.dart';

/// Standalone SQL editor: pick a database, write SQL, run it, read the result.
///
/// The page is the single entry point for ad-hoc SQL. It uses the shared
/// [SqliteDatabaseRepository] from the bootstrap, so it reuses the very same
/// MariaDB connection as the table browser; no second driver is created.
///
/// `SHOW TABLES`, `DESCRIBE`, `SHOW CREATE TABLE`, ... are answered by the
/// MariaDB server itself, because PALLSQL now speaks the real MariaDB dialect.
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
  SqlCancelToken? _cancelToken;
  bool _running = false;
  bool _cancellable = false;
  bool _creating = false;
  bool _fullscreen = false;
  int _tab = 0;

  SqliteDatabaseRepository get _repository =>
      ref.read(databaseRepositoryProvider);

  @override
  void initState() {
    super.initState();
    _database = widget.initialDatabase;
  }

  @override
  void dispose() {
    _cancelToken?.cancel();
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
      _tab = 0;
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
    final String? name = await PallSQLDialog.prompt(
      context: context,
      title: 'New MariaDB database',
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
    if (_running) {
      return;
    }
    final String? name = _database;
    if (name == null || name.isEmpty) {
      _snack('Select a database first', error: true);
      return;
    }
    // The list can still be loading (or stale) while the file already exists,
    // so the truth comes from the repository: it reports a missing database
    // with a real error instead of this page guessing.
    final String database = name;
    final String sql = _sqlController.text.trim();
    if (sql.isEmpty) {
      _snack('Enter a SQL statement', error: true);
      return;
    }
    final List<SqlStatement> parsed = SqlUtils.splitStatements(sql);
    final bool destructive = parsed
        .any((SqlStatement statement) => SqlUtils.isDestructive(statement.sql));
    if (destructive) {
      final bool confirmed = await PallSQLDialog.confirm(
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
    final SqlCancelToken token = SqlCancelToken();
    _cancelToken = token;
    setState(() {
      _running = true;
      _cancellable = parsed.length > 1;
      _tab = 0;
    });
    try {
      final QueryResult result = await _repository.execute(
        database,
        sql,
        allowDestructive: true,
        cancel: token,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _result = result;
        _running = false;
        _cancellable = false;
      });
      ref.read(queryHistoryProvider.notifier).refresh();
      if (result.error != null) {
        _snack(result.error!, error: true);
      } else if (result.cancelled) {
        _snack(
          'Stopped after ${result.statementsExecuted} statement(s)',
        );
      }
    } on AppFailure catch (failure) {
      if (!mounted) {
        return;
      }
      setState(() {
        _running = false;
        _cancellable = false;
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
        _cancellable = false;
        _result = QueryResult.failure('$error');
      });
      _snack('$error', error: true);
    }
  }

  /// Stop issues a real `KILL QUERY` on a second connection (see
  /// `MariaDbRepository.execute`), so a long statement is interrupted on the
  /// server instead of only between statements.
  void _stop() {
    _cancelToken?.cancel();
    _snack('Stopping after the current statement...');
  }

  void _clear() {
    _sqlController.clear();
    setState(() => _result = null);
  }

  void _format() {
    final String text = _sqlController.text;
    if (text.trim().isEmpty) {
      _snack('Nothing to format', error: true);
      return;
    }
    final String formatted = SqlUtils.format(text);
    _sqlController.text = formatted;
    _sqlController.selection = TextSelection.collapsed(
      offset: _sqlController.text.length,
    );
    setState(() {});
    _snack('SQL formatted');
  }

  void _useHistoryEntry(QueryHistoryEntry entry) {
    setState(() {
      _database = entry.database;
      _result = null;
    });
    _sqlController.text = entry.sql;
  }

  // ---------------------------------------------------------------------
  // Save / load snippets
  // ---------------------------------------------------------------------

  Future<void> _saveQuery() async {
    final String sql = _sqlController.text.trim();
    if (sql.isEmpty) {
      _snack('Write a statement before saving', error: true);
      return;
    }
    final String? name = await PallSQLDialog.prompt(
      context: context,
      title: 'Save query',
      label: 'Query name',
      message: 'Saved as a .sql file in PALLSQL/config/queries.',
      confirmLabel: 'Save',
      validator: Validators.entryNameError,
    );
    if (name == null || !mounted) {
      return;
    }
    try {
      final QueryStore store = ref.read(queryStoreProvider);
      await store.save(name, sql);
      if (!mounted) {
        return;
      }
      _snack('Saved ${name.replaceAll('.sql', '')}.sql');
    } on AppFailure catch (failure) {
      if (!mounted) {
        return;
      }
      _snack(failure.combined, error: true);
    }
  }

  Future<void> _loadQuery() async {
    final QueryStore store = ref.read(queryStoreProvider);
    List<SavedQuery> queries;
    try {
      queries = await store.list();
    } on AppFailure catch (failure) {
      if (!mounted) {
        return;
      }
      _snack(failure.combined, error: true);
      return;
    }
    if (!mounted) {
      return;
    }
    if (queries.isEmpty) {
      _snack('No saved queries yet - use Save query first');
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: PallSqlColors.surfaceElevated,
      showDragHandle: true,
      builder: (BuildContext sheetContext) {
        return SafeArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            children: <Widget>[
              const Text(
                'Saved queries',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: PallSqlColors.textPrimary,
                ),
              ),
              const SizedBox(height: 8),
              for (final SavedQuery query in queries)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  leading: const Icon(
                    Icons.description_outlined,
                    size: 18,
                    color: PallSqlColors.accent,
                  ),
                  title: Text(
                    query.fileName,
                    style: const TextStyle(
                      fontSize: 12.5,
                      fontFamily: PallSqlColors.monoFontFamily,
                      color: PallSqlColors.textPrimary,
                    ),
                  ),
                  subtitle: Text(
                    Formatters.truncate(
                      query.sql.replaceAll(RegExp(r'\s+'), ' '),
                      70,
                    ),
                    style: const TextStyle(
                      fontSize: 10.5,
                      color: PallSqlColors.textDisabled,
                    ),
                  ),
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    _sqlController.text = query.sql;
                    setState(() => _result = null);
                  },
                ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _changeFontSize() async {
    final AppSettings settings = ref.read(settingsProvider);
    double value = settings.editorFontSize;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: PallSqlColors.surfaceElevated,
      showDragHandle: true,
      builder: (BuildContext sheetContext) {
        return StatefulBuilder(
          builder: (BuildContext context, StateSetter setSheetState) {
            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      'Editor font size - ${value.toStringAsFixed(0)} pt',
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: PallSqlColors.textPrimary,
                      ),
                    ),
                    Slider(
                      value: value,
                      min: 10,
                      max: 24,
                      divisions: 14,
                      activeColor: PallSqlColors.accent,
                      inactiveColor: PallSqlColors.surfaceMuted,
                      onChanged: (double next) {
                        setSheetState(() => value = next);
                      },
                      onChangeEnd: (double next) {
                        ref.read(settingsProvider.notifier).update(
                              settings.copyWith(
                                editorFontSize: next.roundToDouble(),
                              ),
                            );
                      },
                    ),
                    const Text(
                      'Stored in PALLSQL/config/settings.json and shared with '
                      'the code editor.',
                      style: TextStyle(
                        fontSize: 10.5,
                        color: PallSqlColors.textDisabled,
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  // ---------------------------------------------------------------------
  // Result helpers
  // ---------------------------------------------------------------------

  String _asDelimited(QueryResult result, String separator) {
    final StringBuffer buffer = StringBuffer()
      ..writeln(result.columns.join(separator));
    for (final List<String?> row in result.rows) {
      buffer.writeln(
        row.map((String? cell) => cell ?? '').join(separator),
      );
    }
    return buffer.toString();
  }

  String _asCsv(QueryResult result) {
    String escape(String? value) {
      final String text = value ?? '';
      if (text.contains(',') || text.contains('"') || text.contains('\n')) {
        return '"${text.replaceAll('"', '""')}"';
      }
      return text;
    }

    final StringBuffer buffer = StringBuffer()
      ..writeln(result.columns.map(escape).join(','));
    for (final List<String?> row in result.rows) {
      buffer.writeln(row.map(escape).join(','));
    }
    return buffer.toString();
  }

  Future<void> _copyResult() async {
    final QueryResult? result = _result;
    if (result == null || !result.hasResultSet) {
      return;
    }
    await Clipboard.setData(ClipboardData(text: _asDelimited(result, '\t')));
    _snack('${Formatters.count(result.rowCount, 'row')} copied');
  }

  Future<void> _exportResult() async {
    final QueryResult? result = _result;
    if (result == null || !result.hasResultSet) {
      return;
    }
    try {
      final AppBootstrap bootstrap = ref.read(bootstrapProvider);
      final File file =
          await bootstrap.workspace.createTempFile('result', '.csv');
      await file.writeAsString(_asCsv(result), flush: true);
      final bool shared =
          await bootstrap.native.shareFile(file.path, mimeType: 'text/csv');
      if (!mounted) {
        return;
      }
      _snack(
        shared ? 'Exported as CSV' : 'CSV written to ${file.path}',
      );
    } on Object catch (error) {
      if (!mounted) {
        return;
      }
      _snack('Export failed: $error', error: true);
    }
  }

  // ---------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final AsyncValue<DatabaseOverview> async = ref.watch(databaseProvider);
    final DatabaseOverview? overview = async.valueOrNull;
    final List<DatabaseInfo> databases =
        overview?.databases ?? const <DatabaseInfo>[];
    // A database can disappear between builds (deleted on the Database tab),
    // so the selection is resolved against the list that is on screen.
    String? selected;
    for (final DatabaseInfo info in databases) {
      if (info.name == _database) {
        selected = info.name;
        break;
      }
    }
    final String engine = SqlDialect.engineLabel(
      overview?.mariadb.version ?? '',
    );
    final double fontSize = ref.watch(settingsProvider).editorFontSize;

    if (_fullscreen) {
      return _buildFullscreen(selected, engine, fontSize);
    }

    return Scaffold(
      appBar: PallSQLAppBar(
        title: 'SQL editor',
        subtitle: selected ?? 'No database selected',
        showBack: true,
        actions: <Widget>[
          IconButton(
            tooltip: 'Query history',
            icon: const Icon(Icons.history_rounded, size: 19),
            onPressed: ref.watch(queryHistoryProvider).isEmpty
                ? null
                : () => _showHistory(ref.read(queryHistoryProvider)),
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
          PallSqlSectionHeader(
            title: 'Database',
            subtitle: engine,
            trailing: PallSQLStatusBadge(
              label: 'MariaDB dialect',
              icon: Icons.memory_rounded,
            ),
          ),
          _DatabasePicker(
            databases: databases,
            selected: selected,
            busy: _creating,
            onSelect: _select,
            onCreate: _createDatabase,
          ),
          const SizedBox(height: 16),
          PallSqlSectionHeader(
            title: 'SQL',
            subtitle: 'Separate statements with a semicolon',
            trailing: TextButton.icon(
              onPressed: _format,
              icon: const Icon(Icons.format_align_left_rounded, size: 14),
              label: const Text('Format', style: TextStyle(fontSize: 11)),
              style: TextButton.styleFrom(
                minimumSize: Size.zero,
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
          ),
          SizedBox(
            height: 200,
            child: PallSQLCodeEditor(
              controller: _sqlController,
              language: CodeLanguage.sql,
              fontSize: fontSize,
              showLineNumbers: ref.watch(settingsProvider).showLineNumbers,
              hintText: 'SELECT * FROM sqlite_master;',
            ),
          ),
          const SizedBox(height: 8),
          _EditorToolbar(
            onSave: _saveQuery,
            onLoad: _loadQuery,
            onFontSize: _changeFontSize,
            onFullscreen: () => setState(() => _fullscreen = true),
            fontSize: fontSize,
          ),
          const SizedBox(height: 10),
          Row(
            children: <Widget>[
              Expanded(
                child: PallSQLButton(
                  label: 'Execute',
                  icon: Icons.play_arrow_rounded,
                  variant: PallSQLButtonVariant.primary,
                  busy: _running && !_cancellable,
                  onPressed: _running ? null : _execute,
                ),
              ),
              if (_running && _cancellable) ...<Widget>[
                const SizedBox(width: 8),
                PallSQLButton(
                  label: 'Stop',
                  icon: Icons.stop_rounded,
                  variant: PallSQLButtonVariant.danger,
                  expand: false,
                  onPressed: _stop,
                ),
              ],
              const SizedBox(width: 8),
              PallSQLButton(
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
            LinearProgressIndicator(
              minHeight: 2,
              backgroundColor: PallSqlColors.surfaceMuted,
              valueColor:
                  const AlwaysStoppedAnimation<Color>(PallSqlColors.accent),
            ),
          ],
          const SizedBox(height: 14),
          PallSqlSectionHeader(
            title: 'Result',
            subtitle: _resultSummary(),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                IconButton(
                  tooltip: 'Copy result',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.copy_all_rounded, size: 17),
                  onPressed:
                      (_result?.hasResultSet ?? false) ? _copyResult : null,
                ),
                IconButton(
                  tooltip: 'Export CSV',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.ios_share_rounded, size: 17),
                  onPressed:
                      (_result?.hasResultSet ?? false) ? _exportResult : null,
                ),
              ],
            ),
          ),
          _buildResult(),
          const SizedBox(height: 18),
          PallSqlSectionHeader(
            title: 'History',
            subtitle: ref.watch(queryHistoryProvider).isEmpty
                ? 'Nothing executed yet'
                : 'Last ${ref.watch(queryHistoryProvider).length} statement(s)',
            trailing: ref.watch(queryHistoryProvider).isEmpty
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
          if (ref.watch(queryHistoryProvider).isEmpty)
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
                  for (final QueryHistoryEntry entry
                      in ref.watch(queryHistoryProvider).take(10))
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

  Widget _buildFullscreen(String? selected, String engine, double fontSize) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (bool didPop, Object? result) {
        if (!didPop) {
          setState(() => _fullscreen = false);
        }
      },
      child: Scaffold(
        body: SafeArea(
          child: Column(
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 6, 6, 4),
                child: Row(
                  children: <Widget>[
                    PallSQLStatusBadge(
                      label: selected ?? 'no database',
                      color: selected == null
                          ? PallSqlColors.warning
                          : PallSqlColors.accent,
                      icon: Icons.storage_rounded,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        engine,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 10.5,
                          color: PallSqlColors.textSecondary,
                          fontFamily: PallSqlColors.monoFontFamily,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Exit fullscreen',
                      icon: const Icon(Icons.fullscreen_exit_rounded, size: 19),
                      onPressed: () => setState(() => _fullscreen = false),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  child: PallSQLCodeEditor(
                    controller: _sqlController,
                    language: CodeLanguage.sql,
                    fontSize: fontSize,
                    showLineNumbers: true,
                    hintText: 'SELECT * FROM sqlite_master;',
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
                child: Row(
                  children: <Widget>[
                    Expanded(
                      child: PallSQLButton(
                        label: 'Execute',
                        icon: Icons.play_arrow_rounded,
                        variant: PallSQLButtonVariant.primary,
                        busy: _running && !_cancellable,
                        onPressed: _running ? null : _execute,
                      ),
                    ),
                    const SizedBox(width: 8),
                    if (_running && _cancellable)
                      PallSQLButton(
                        label: 'Stop',
                        icon: Icons.stop_rounded,
                        variant: PallSQLButtonVariant.danger,
                        expand: false,
                        onPressed: _stop,
                      )
                    else
                      PallSQLButton(
                        label: 'Clear',
                        icon: Icons.backspace_outlined,
                        compact: true,
                        expand: false,
                        onPressed: _running ? null : _clear,
                      ),
                  ],
                ),
              ),
              if (_running)
                const LinearProgressIndicator(
                  minHeight: 2,
                  backgroundColor: PallSqlColors.surfaceMuted,
                  valueColor:
                      AlwaysStoppedAnimation<Color>(PallSqlColors.accent),
                ),
              if (_result != null)
                SizedBox(
                  height: 180,
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    child: _buildResult(),
                  ),
                ),
            ],
          ),
        ),
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
    if (result.cancelled) {
      return 'Stopped after ${result.statementsExecuted} statement(s)';
    }
    if (result.hasResultSet) {
      return '${Formatters.count(result.rowCount, 'row')} in '
          '${Formatters.duration(result.duration)}';
    }
    return '${result.statementsExecuted} statement(s), '
        '${Formatters.count(result.rowsAffected, 'row')} affected, '
        '${Formatters.duration(result.duration)}';
  }

  Widget _buildResult() {
    if (_running) {
      return const PallSqlCard(
        child: PallSQLLoading(
          message: 'Executing...',
          compact: true,
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
              ? 'Create or select a MariaDB database to start writing SQL.'
              : 'Write a statement above and press Execute.',
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _ResultTabs(
          index: _tab,
          onChanged: (int index) => setState(() => _tab = index),
          messages: result.notices.length,
          hasError: result.isError,
        ),
        const SizedBox(height: 8),
        if (_tab == 0)
          QueryResultView(result: result, maxHeight: 280)
        else
          _ResultMessages(result: result),
      ],
    );
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

/// Secondary editor actions (save, load, font, fullscreen).
class _EditorToolbar extends StatelessWidget {
  const _EditorToolbar({
    required this.onSave,
    required this.onLoad,
    required this.onFontSize,
    required this.onFullscreen,
    required this.fontSize,
  });

  final VoidCallback onSave;
  final VoidCallback onLoad;
  final VoidCallback onFontSize;
  final VoidCallback onFullscreen;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 4,
      runSpacing: 4,
      children: <Widget>[
        _ToolChip(
          icon: Icons.save_outlined,
          label: 'Save query',
          onTap: onSave,
        ),
        _ToolChip(
          icon: Icons.folder_open_rounded,
          label: 'Load query',
          onTap: onLoad,
        ),
        _ToolChip(
          icon: Icons.format_size_rounded,
          label: '${fontSize.toStringAsFixed(0)} pt',
          onTap: onFontSize,
        ),
        _ToolChip(
          icon: Icons.fullscreen_rounded,
          label: 'Fullscreen',
          onTap: onFullscreen,
        ),
      ],
    );
  }
}

class _ToolChip extends StatelessWidget {
  const _ToolChip({
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
      borderRadius: BorderRadius.circular(999),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: PallSqlColors.surfaceMuted,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: PallSqlColors.border),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(icon, size: 13, color: PallSqlColors.textSecondary),
            const SizedBox(width: 5),
            Text(
              label,
              style: const TextStyle(
                fontSize: 10.5,
                color: PallSqlColors.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Result / Messages switch under the result header.
class _ResultTabs extends StatelessWidget {
  const _ResultTabs({
    required this.index,
    required this.onChanged,
    required this.messages,
    required this.hasError,
  });

  final int index;
  final ValueChanged<int> onChanged;
  final int messages;
  final bool hasError;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        _tab('Result', 0, index == 0),
        const SizedBox(width: 6),
        _tab(
          hasError ? 'Error' : 'Messages ($messages)',
          hasError ? 0 : 1,
          index == 1,
        ),
      ],
    );
  }

  Widget _tab(String label, int value, bool active) {
    return InkWell(
      onTap: () => onChanged(value),
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: active ? PallSqlColors.accentMuted : PallSqlColors.surface,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: active ? PallSqlColors.accentDeep : PallSqlColors.border,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 10.5,
            fontWeight: FontWeight.w600,
            color:
                active ? PallSqlColors.accentSoft : PallSqlColors.textSecondary,
          ),
        ),
      ),
    );
  }
}

/// Execution metadata, notices and the executed statement count.
class _ResultMessages extends StatelessWidget {
  const _ResultMessages({required this.result});

  final QueryResult result;

  @override
  Widget build(BuildContext context) {
    final List<String> rows = <String>[
      'statements    ${result.statementsExecuted}/${result.statements}',
      'duration      ${Formatters.duration(result.duration)}',
      'rows affected ${result.rowsAffected}',
      if (result.lastInsertRowId != null)
        'last insert   ${result.lastInsertRowId}',
      'result set    ${result.hasResultSet ? '${result.rowCount} row(s)' : 'none'}',
    ];
    return PallSqlCard(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          for (final String row in rows)
            Padding(
              padding: const EdgeInsets.only(bottom: 3),
              child: Text(
                row,
                style: const TextStyle(
                  fontSize: 11,
                  fontFamily: PallSqlColors.monoFontFamily,
                  color: PallSqlColors.textSecondary,
                ),
              ),
            ),
          if (result.notices.isNotEmpty) ...<Widget>[
            const SizedBox(height: 8),
            const Text(
              'NOTICES',
              style: TextStyle(
                fontSize: 9.5,
                letterSpacing: 1.4,
                fontWeight: FontWeight.w700,
                color: PallSqlColors.textDisabled,
              ),
            ),
            const SizedBox(height: 4),
            for (final String notice in result.notices)
              Padding(
                padding: const EdgeInsets.only(bottom: 3),
                child: Text(
                  notice,
                  style: const TextStyle(
                    fontSize: 11,
                    color: PallSqlColors.textPrimary,
                  ),
                ),
              ),
          ],
        ],
      ),
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
              message: 'Create a MariaDB database to run SQL. The schema '
                  'lives in PALLSQL/database and survives restarts.',
            ),
            PallSQLButton(
              label: 'New database',
              icon: Icons.add_rounded,
              variant: PallSQLButtonVariant.primary,
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
