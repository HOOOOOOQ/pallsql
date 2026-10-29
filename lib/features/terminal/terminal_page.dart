import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/pallsql_colors.dart';
import '../../models/log_entry.dart';
import '../../providers/app_providers.dart';
import '../../services/terminal_service.dart';
import '../../widgets/pallsql_app_bar.dart';
import '../../widgets/pallsql_components.dart';

/// Allow-listed command terminal (never a Linux shell).
class TerminalPage extends ConsumerStatefulWidget {
  const TerminalPage({super.key, this.openSqlConsole = false});

  /// Opens the SQL console immediately (used by the Database tab).
  final bool openSqlConsole;

  @override
  ConsumerState<TerminalPage> createState() => _TerminalPageState();
}

class _TerminalPageState extends ConsumerState<TerminalPage> {
  final TextEditingController _input = TextEditingController();
  final FocusNode _focus = FocusNode();
  final List<LogEntry> _lines = <LogEntry>[];
  final List<String> _history = <String>[];
  int _historyIndex = -1;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _lines.add(
      LogEntry(
        timestamp: DateTime.now(),
        level: LogLevel.debug,
        source: LogSource.terminal,
        message: 'PALLSQL terminal - allow-listed commands only, no shell, '
            'no root.\n'
            'Type "help" for the command list, or "sql" to open the SQL '
            'console against a real SQLite database.',
      ),
    );
    if (widget.openSqlConsole) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _submit('sql');
        }
      });
    }
  }

  @override
  void dispose() {
    _input.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _append(String text, {LogLevel level = LogLevel.info}) {
    setState(() {
      _lines.add(
        LogEntry(
          timestamp: DateTime.now(),
          level: level,
          source: LogSource.terminal,
          message: text,
        ),
      );
    });
  }

  Future<void> _submit(String raw) async {
    final String command = raw.trim();
    if (command.isEmpty) {
      return;
    }
    final TerminalService service = ref.read(terminalServiceProvider);
    final String prompt = service.prompt;
    _input.clear();
    _history.insert(0, command);
    _historyIndex = -1;
    _append('$prompt $command', level: LogLevel.debug);
    setState(() => _busy = true);
    final TerminalResult result = await service.execute(command);
    if (!mounted) {
      return;
    }
    setState(() => _busy = false);
    if (result.clearScreen) {
      setState(_lines.clear);
      return;
    }
    for (final TerminalLine line in result.lines) {
      _append(line.text, level: line.level);
    }
  }

  void _insertHistory() {
    if (_history.isEmpty) {
      return;
    }
    final int next = _historyIndex + 1;
    _historyIndex = next >= _history.length ? _history.length - 1 : next;
    _input.text = _history[_historyIndex];
    _input.selection = TextSelection.collapsed(offset: _input.text.length);
  }

  @override
  Widget build(BuildContext context) {
    final TerminalService service = ref.watch(terminalServiceProvider);
    final bool sqlMode = service.sqlMode;
    return Scaffold(
      appBar: PallSQLAppBar(
        title: sqlMode ? 'SQL console' : 'Terminal',
        subtitle: sqlMode
            ? 'SQLite dialect - ${service.currentDatabase ?? 'no database'}'
            : '${service.commands.length} registered commands, no shell',
        showBack: true,
        actions: <Widget>[
          if (sqlMode)
            TextButton.icon(
              onPressed: () => setState(service.exitSqlMode),
              icon: const Icon(Icons.logout_rounded, size: 15),
              label: const Text('Exit SQL', style: TextStyle(fontSize: 11)),
            ),
          IconButton(
            tooltip: 'Clear output',
            icon: const Icon(Icons.cleaning_services_rounded, size: 18),
            onPressed: () => setState(_lines.clear),
          ),
        ],
      ),
      body: Column(
        children: <Widget>[
          Expanded(
            child: Container(
              width: double.infinity,
              color: PallSqlColors.background,
              child: PallSQLTerminal(lines: _lines),
            ),
          ),
          if (_busy) const LinearProgressIndicator(minHeight: 2),
          Container(
            decoration: const BoxDecoration(
              color: PallSqlColors.surface,
              border: Border(top: BorderSide(color: PallSqlColors.border)),
            ),
            padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
            child: SafeArea(
              top: false,
              child: Column(
                children: <Widget>[
                  if (sqlMode)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Row(
                        children: <Widget>[
                          const Icon(
                            Icons.storage_rounded,
                            size: 13,
                            color: PallSqlColors.accent,
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              'SQL console - statements run for real. '
                              '.help for console commands, \\q to exit.',
                              style: const TextStyle(
                                fontSize: 10.5,
                                color: PallSqlColors.textSecondary,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  Row(
                    children: <Widget>[
                      Text(
                        service.prompt,
                        style: const TextStyle(
                          color: PallSqlColors.accent,
                          fontFamily: PallSqlColors.monoFontFamily,
                          fontSize: 13,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: TextField(
                          controller: _input,
                          focusNode: _focus,
                          autocorrect: false,
                          enableSuggestions: false,
                          textInputAction: TextInputAction.send,
                          style: const TextStyle(
                            color: PallSqlColors.textPrimary,
                            fontFamily: PallSqlColors.monoFontFamily,
                            fontSize: 12.5,
                          ),
                          keyboardType: TextInputType.text,
                          decoration: InputDecoration(
                            isDense: true,
                            border: InputBorder.none,
                            filled: false,
                            hintText: sqlMode
                                ? 'SELECT * FROM sqlite_master;'
                                : 'server status',
                            hintStyle: const TextStyle(
                              color: PallSqlColors.textDisabled,
                              fontFamily: PallSqlColors.monoFontFamily,
                              fontSize: 12.5,
                            ),
                          ),
                          onSubmitted: _submit,
                        ),
                      ),
                      IconButton(
                        tooltip: 'History',
                        icon: const Icon(Icons.history_rounded, size: 18),
                        onPressed: _insertHistory,
                      ),
                      IconButton(
                        tooltip: 'Run',
                        icon:
                            const Icon(Icons.keyboard_return_rounded, size: 18),
                        color: PallSqlColors.accent,
                        onPressed: () => _submit(_input.text),
                      ),
                    ],
                  ),
                  SizedBox(
                    height: 34,
                    child: ListView(
                      scrollDirection: Axis.horizontal,
                      children: <Widget>[
                        for (final TerminalCommand command
                            in service.commands.take(sqlMode ? 4 : 8))
                          Padding(
                            padding: const EdgeInsets.only(right: 6, top: 4),
                            child: GestureDetector(
                              onTap: () {
                                _input.text = command.name;
                                _input.selection = TextSelection.collapsed(
                                  offset: _input.text.length,
                                );
                                _focus.requestFocus();
                              },
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 9,
                                  vertical: 4,
                                ),
                                decoration: BoxDecoration(
                                  color: PallSqlColors.surfaceMuted,
                                  borderRadius: BorderRadius.circular(999),
                                ),
                                child: Text(
                                  command.name,
                                  style: const TextStyle(
                                    fontSize: 10.5,
                                    color: PallSqlColors.textSecondary,
                                    fontFamily: PallSqlColors.monoFontFamily,
                                  ),
                                ),
                              ),
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
    );
  }
}
