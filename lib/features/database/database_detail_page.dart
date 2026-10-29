import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/errors/app_failure.dart';
import '../../core/theme/pallsql_colors.dart';
import '../../core/utils/sql_utils.dart';
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
import 'sql_editor_page.dart';

/// Table browser and SQL editor for a single SQLite database.
class DatabaseDetailPage extends ConsumerStatefulWidget {
  const DatabaseDetailPage({super.key, required this.databaseName});

  final String databaseName;

  @override
  ConsumerState<DatabaseDetailPage> createState() => _DatabaseDetailPageState();
}

class _DatabaseDetailPageState extends ConsumerState<DatabaseDetailPage> {
  late final HighlightingTextController _sqlController =
      HighlightingTextController(
    language: CodeLanguage.sql,
    text: 'SELECT * FROM sqlite_master;',
  );
  List<TableInfo> _tables = const <TableInfo>[];
  List<ColumnInfo> _columns = const <ColumnInfo>[];
  TableInfo? _selected;
  QueryResult? _rows;
  QueryResult? _result;
  bool _loading = true;

  SqliteDatabaseRepository get _repository =>
      ref.read(databaseRepositoryProvider);

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _sqlController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final List<TableInfo> tables =
          await _repository.listTables(widget.databaseName);
      if (!mounted) {
        return;
      }
      setState(() {
        _tables = tables;
        _loading = false;
      });
      if (tables.isNotEmpty) {
        await _selectTable(tables.first.name);
      }
    } on AppFailure catch (failure) {
      if (!mounted) {
        return;
      }
      setState(() => _loading = false);
      _showError(failure.combined);
    }
  }

  Future<void> _selectTable(String name) async {
    try {
      final List<ColumnInfo> columns =
          await _repository.describeTable(widget.databaseName, name);
      final QueryResult rows =
          await _repository.selectRows(widget.databaseName, name, limit: 50);
      if (!mounted) {
        return;
      }
      setState(() {
        _selected = _tables.firstWhere(
          (TableInfo table) => table.name == name,
          orElse: () => TableInfo(name: name, type: 'table'),
        );
        _columns = columns;
        _rows = rows;
      });
    } on AppFailure catch (failure) {
      if (!mounted) {
        return;
      }
      _showError(failure.combined);
    }
  }

  void _showError(String message) {
    showPallSqlSnack(ScaffoldMessenger.of(context), message, error: true);
  }

  Future<void> _runSql() async {
    final String sql = _sqlController.text.trim();
    if (sql.isEmpty) {
      _showError('Enter a SQL statement');
      return;
    }
    final bool destructive = SqlUtils.splitStatements(sql)
        .any((SqlStatement s) => SqlUtils.isDestructive(s.sql));
    if (destructive) {
      final bool confirmed = await showConfirmDialog(
        context: context,
        title: 'Destructive statement',
        message: 'This script drops data or modifies rows without a WHERE '
            'clause. Run it against ${widget.databaseName}?',
        confirmLabel: 'Run anyway',
        destructive: true,
      );
      if (!confirmed || !mounted) {
        return;
      }
    }
    setState(() => _loading = true);
    try {
      final QueryResult result =
          await _repository.execute(widget.databaseName, sql);
      if (!mounted) {
        return;
      }
      setState(() {
        _result = result;
        _loading = false;
      });
      ref.read(queryHistoryProvider.notifier).refresh();
      if (result.error != null) {
        _showError(result.error!);
      } else {
        await _refreshStructure();
      }
    } on AppFailure catch (failure) {
      if (!mounted) {
        return;
      }
      setState(() {
        _loading = false;
        _result = QueryResult.failure(failure.combined);
      });
      ref.read(queryHistoryProvider.notifier).refresh();
      _showError(failure.combined);
    }
  }

  Future<void> _refreshStructure() async {
    final List<TableInfo> tables =
        await _repository.listTables(widget.databaseName);
    if (!mounted) {
      return;
    }
    setState(() => _tables = tables);
    final TableInfo? selected = _selected;
    if (selected != null &&
        tables.any((TableInfo table) => table.name == selected.name)) {
      await _selectTable(selected.name);
    }
  }

  Future<void> _createTable() async {
    final String? sql = await showPromptDialog(
      context: context,
      title: 'Create table',
      label: 'CREATE TABLE statement',
      message: 'Example: CREATE TABLE notes (id INTEGER PRIMARY KEY '
          'AUTOINCREMENT, body TEXT NOT NULL)',
      initialValue:
          'CREATE TABLE notes (\n  id INTEGER PRIMARY KEY AUTOINCREMENT,\n'
          '  body TEXT NOT NULL,\n  created_at TEXT NOT NULL\n);',
      maxLines: 8,
      confirmLabel: 'Run',
      keyboardType: TextInputType.multiline,
      validator: (String value) =>
          value.trim().isEmpty ? 'A CREATE TABLE statement is required' : null,
    );
    if (sql == null || !mounted) {
      return;
    }
    final QueryResult result =
        await _repository.execute(widget.databaseName, sql);
    if (!mounted) {
      return;
    }
    if (result.error != null) {
      _showError(result.error!);
      return;
    }
    await _refreshStructure();
  }

  Future<void> _insertRow() async {
    final TableInfo? table = _selected;
    if (table == null || _columns.isEmpty) {
      return;
    }
    final Map<String, String> values = await _askForValues(table);
    if (values.isEmpty || !mounted) {
      return;
    }
    final QueryResult result = await _repository.insertRow(
      widget.databaseName,
      table.name,
      values.map<String, Object?>(
        (String key, String value) =>
            MapEntry<String, Object?>(key, _parseValue(value)),
      ),
    );
    if (!mounted) {
      return;
    }
    if (result.error != null) {
      _showError(result.error!);
      return;
    }
    await _selectTable(table.name);
    if (!mounted) {
      return;
    }
    showPallSqlSnack(ScaffoldMessenger.of(context), 'Row inserted');
  }

  Future<void> _deleteRow(int rowId) async {
    final TableInfo? table = _selected;
    if (table == null) {
      return;
    }
    final bool confirmed = await showConfirmDialog(
      context: context,
      title: 'Delete row',
      message: 'Delete rowid $rowId from ${table.name}?',
      confirmLabel: 'Delete',
      destructive: true,
    );
    if (!confirmed || !mounted) {
      return;
    }
    final QueryResult result = await _repository.deleteRow(
      widget.databaseName,
      table.name,
      keyColumn: 'rowid',
      keyValue: rowId,
    );
    if (!mounted) {
      return;
    }
    if (result.error != null) {
      _showError(result.error!);
      return;
    }
    await _selectTable(table.name);
  }

  Future<Map<String, String>> _askForValues(TableInfo table) async {
    final Map<String, TextEditingController> controllers =
        <String, TextEditingController>{};
    final List<ColumnInfo> editable = _columns
        .where((ColumnInfo column) =>
            !(column.primaryKey && column.type.toUpperCase().contains('INT')))
        .toList(growable: false);
    for (final ColumnInfo column in editable) {
      controllers[column.name] = TextEditingController();
    }
    final Map<String, String>? values = await showDialog<Map<String, String>>(
      context: context,
      builder: (BuildContext dialogContext) {
        return AlertDialog(
          backgroundColor: PallSqlColors.surfaceElevated,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          title: Text(
            'Insert into ${table.name}',
            style: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: PallSqlColors.textPrimary,
            ),
          ),
          content: SizedBox(
            width: 380,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  for (final ColumnInfo column in editable)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: TextField(
                        controller: controllers[column.name],
                        style: const TextStyle(
                          color: PallSqlColors.textPrimary,
                          fontSize: 12.5,
                          fontFamily: PallSqlColors.monoFontFamily,
                        ),
                        decoration: InputDecoration(
                          isDense: true,
                          labelText: '${column.name} (${column.summary})',
                          labelStyle: const TextStyle(
                            color: PallSqlColors.textSecondary,
                            fontSize: 11.5,
                          ),
                          filled: true,
                          fillColor: PallSqlColors.background,
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
                        ),
                      ),
                    ),
                  const Text(
                    'Leave a field empty to insert NULL.',
                    style: TextStyle(
                      fontSize: 10.5,
                      color: PallSqlColors.textDisabled,
                    ),
                  ),
                ],
              ),
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: PallSqlColors.accent,
                foregroundColor: const Color(0xFF07130A),
              ),
              onPressed: () {
                final Map<String, String> collected = <String, String>{};
                controllers.forEach((String name, TextEditingController c) {
                  if (c.text.trim().isNotEmpty) {
                    collected[name] = c.text.trim();
                  }
                });
                Navigator.of(dialogContext).pop(collected);
              },
              child: const Text('Insert'),
            ),
          ],
        );
      },
    );
    for (final TextEditingController controller in controllers.values) {
      controller.dispose();
    }
    return values ?? const <String, String>{};
  }

  Object? _parseValue(String raw) {
    if (raw.isEmpty || raw.toUpperCase() == 'NULL') {
      return null;
    }
    final int? asInt = int.tryParse(raw);
    if (asInt != null) {
      return asInt;
    }
    final double? asDouble = double.tryParse(raw);
    if (asDouble != null) {
      return asDouble;
    }
    return raw;
  }

  Future<void> _exportSql() async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final File target = File(
      '${ref.read(bootstrapProvider).workspace.backups.path}/'
      '${widget.databaseName}_export.sql',
    );
    try {
      final String sql = await _repository.exportSql(widget.databaseName);
      await target.parent.create(recursive: true);
      await target.writeAsString(sql, flush: true);
      final bool shared =
          await ref.read(nativeBridgeProvider).shareFile(target.path);
      if (!mounted) {
        return;
      }
      showPallSqlSnack(
        messenger,
        shared
            ? 'Exported ${target.path}'
            : 'Exported to ${target.path} (sharing unavailable)',
      );
    } on Object catch (error) {
      if (!mounted) {
        return;
      }
      showPallSqlSnack(messenger, 'Export failed: $error', error: true);
    }
  }

  Future<void> _importSql() async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final String? sql = await showPromptDialog(
      context: context,
      title: 'Import SQL',
      label: 'SQL script',
      message: 'Runs inside a single transaction. ATTACH/DETACH is refused. '
          '${widget.databaseName}',
      maxLines: 10,
      confirmLabel: 'Import',
      keyboardType: TextInputType.multiline,
    );
    if (sql == null || sql.trim().isEmpty || !mounted) {
      return;
    }
    setState(() => _loading = true);
    final QueryResult result =
        await _repository.runScript(widget.databaseName, sql);
    if (!mounted) {
      return;
    }
    setState(() {
      _result = result;
      _loading = false;
    });
    ref.read(queryHistoryProvider.notifier).refresh();
    await _refreshStructure();
    if (!mounted) {
      return;
    }
    showPallSqlSnack(
      messenger,
      result.error ?? 'Imported ${result.statements} statement(s)',
      error: result.error != null,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: PallSQLAppBar(
        title: widget.databaseName,
        subtitle: 'SQLite database',
        showBack: true,
        actions: <Widget>[
          IconButton(
            tooltip: 'Open SQL editor',
            icon: const Icon(Icons.terminal_rounded, size: 19),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (BuildContext context) =>
                    SqlEditorPage(initialDatabase: widget.databaseName),
              ),
            ),
          ),
          IconButton(
            tooltip: 'Export SQL',
            icon: const Icon(Icons.ios_share_rounded, size: 19),
            onPressed: _exportSql,
          ),
          IconButton(
            tooltip: 'Import SQL',
            icon: const Icon(Icons.file_download_outlined, size: 19),
            onPressed: _importSql,
          ),
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh_rounded, size: 19),
            onPressed: _load,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(14, 6, 14, 24),
        children: <Widget>[
          if (_loading) const LinearProgressIndicator(minHeight: 2),
          PallSqlSectionHeader(
            title: 'Tables',
            subtitle: '${_tables.length} object(s)',
            trailing: TextButton.icon(
              onPressed: _createTable,
              icon: const Icon(Icons.add_rounded, size: 15),
              label: const Text('New', style: TextStyle(fontSize: 11.5)),
              style: TextButton.styleFrom(
                foregroundColor: PallSqlColors.accent,
                minimumSize: Size.zero,
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
          ),
          if (_tables.isEmpty)
            const PallSqlCard(
              child: PallSqlEmptyState(
                icon: Icons.table_rows_rounded,
                title: 'No tables yet',
                message: 'Create a table here or run a CREATE TABLE statement '
                    'in the editor below.',
              ),
            )
          else
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: <Widget>[
                  for (final TableInfo table in _tables)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: GestureDetector(
                        onTap: () => _selectTable(table.name),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 11,
                            vertical: 6,
                          ),
                          decoration: BoxDecoration(
                            color: _selected?.name == table.name
                                ? PallSqlColors.accent.withValues(alpha: 0.14)
                                : PallSqlColors.surface,
                            borderRadius: BorderRadius.circular(999),
                            border: Border.all(
                              color: _selected?.name == table.name
                                  ? PallSqlColors.accent.withValues(alpha: 0.5)
                                  : PallSqlColors.border,
                            ),
                          ),
                          child: Row(
                            children: <Widget>[
                              Icon(
                                table.isView
                                    ? Icons.remove_red_eye_outlined
                                    : Icons.table_chart_outlined,
                                size: 12,
                                color: _selected?.name == table.name
                                    ? PallSqlColors.accent
                                    : PallSqlColors.textSecondary,
                              ),
                              const SizedBox(width: 5),
                              Text(
                                table.name,
                                style: TextStyle(
                                  fontSize: 11.5,
                                  fontFamily: PallSqlColors.monoFontFamily,
                                  color: _selected?.name == table.name
                                      ? PallSqlColors.accent
                                      : PallSqlColors.textSecondary,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          if (_selected != null) ...<Widget>[
            const SizedBox(height: 14),
            PallSqlSectionHeader(
              title: '${_selected!.name} - columns',
              subtitle: '${_columns.length} column(s)',
            ),
            PallSqlCard(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Column(
                children: <Widget>[
                  for (final ColumnInfo column in _columns)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Row(
                        children: <Widget>[
                          Icon(
                            column.primaryKey
                                ? Icons.vpn_key_rounded
                                : Icons.view_column_outlined,
                            size: 12,
                            color: column.primaryKey
                                ? PallSqlColors.accent
                                : PallSqlColors.textSecondary,
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              column.name,
                              style: const TextStyle(
                                fontSize: 12,
                                fontFamily: PallSqlColors.monoFontFamily,
                                color: PallSqlColors.textPrimary,
                              ),
                            ),
                          ),
                          Text(
                            column.summary,
                            style: const TextStyle(
                              fontSize: 10.5,
                              fontFamily: PallSqlColors.monoFontFamily,
                              color: PallSqlColors.textDisabled,
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            PallSqlSectionHeader(
              title: 'Rows',
              subtitle: 'First 50 rows',
              trailing: TextButton.icon(
                onPressed: _insertRow,
                icon: const Icon(Icons.add_rounded, size: 15),
                label: const Text('Row', style: TextStyle(fontSize: 11.5)),
                style: TextButton.styleFrom(
                  foregroundColor: PallSqlColors.accent,
                  minimumSize: Size.zero,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
            ),
            if (_rows != null)
              QueryResultView(result: _rows!, maxHeight: 220, columnWidth: 120),
            if (_rows != null && _rows!.rowCount > 0 && !_selected!.isView)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: ServiceControlButton(
                  label: 'Delete row by rowid',
                  icon: Icons.delete_outline_rounded,
                  compact: true,
                  destructive: true,
                  onPressed: _askDeleteRow,
                ),
              ),
          ],
          const SizedBox(height: 18),
          const PallSqlSectionHeader(
            title: 'SQL editor',
            subtitle: 'Statements run against this database only',
          ),
          SizedBox(
            height: 190,
            child: CodeEditorPanel(
              controller: _sqlController,
              language: CodeLanguage.sql,
              fontSize: 12,
              showLineNumbers: true,
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: <Widget>[
              Expanded(
                child: ServiceControlButton(
                  label: 'Run statement',
                  icon: Icons.play_arrow_rounded,
                  filled: true,
                  busy: _loading,
                  onPressed: _runSql,
                ),
              ),
              const SizedBox(width: 8),
              ServiceControlButton(
                label: 'Clear',
                icon: Icons.backspace_outlined,
                expand: false,
                compact: true,
                onPressed: () => _sqlController.text = '',
              ),
            ],
          ),
          if (_result != null) ...<Widget>[
            const SizedBox(height: 12),
            QueryResultView(result: _result!, maxHeight: 260),
          ],
          const SizedBox(height: 18),
          const PallSqlCard(
            child: Text(
              'INSERT/UPDATE/DELETE statements report their affected row count. '
              'DROP, TRUNCATE and unqualified DELETE/UPDATE ask for confirmation '
              'first. ATTACH and DETACH are always refused so a script cannot '
              'reach files outside the workspace.',
              style: TextStyle(
                fontSize: 11,
                height: 1.45,
                color: PallSqlColors.textSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _askDeleteRow() async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final String? raw = await showPromptDialog(
      context: context,
      title: 'Delete row',
      label: 'rowid',
      message: 'rowid is the hidden primary key of the table.',
      keyboardType: TextInputType.number,
      confirmLabel: 'Delete',
      validator: (String value) =>
          int.tryParse(value.trim()) == null ? 'Enter a numeric rowid' : null,
    );
    if (raw == null || !mounted) {
      return;
    }
    final int? rowId = int.tryParse(raw.trim());
    if (rowId == null) {
      return;
    }
    await _deleteRow(rowId);
    if (!mounted) {
      return;
    }
    showPallSqlSnack(messenger, 'Delete statement executed');
  }
}
