import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/pallsql_colors.dart';
import '../../models/log_entry.dart';
import '../../providers/app_providers.dart';
import '../../services/terminal_service.dart';
import '../../widgets/pallsql_app_bar.dart';
import '../../widgets/terminal_output.dart';

/// Allow-listed command terminal (never a Linux shell).
class TerminalPage extends ConsumerStatefulWidget {
  const TerminalPage({super.key});

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
        message: 'PALLSQL terminal - allow-listed commands only.\n'
            'Type "help" for the registry. No shell, no root.',
      ),
    );
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
    _input.clear();
    _history.insert(0, command);
    _historyIndex = -1;
    _append('> $command', level: LogLevel.debug);
    setState(() => _busy = true);
    final TerminalResult result =
        await ref.read(terminalServiceProvider).execute(command);
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
    return Scaffold(
      appBar: PallSQLAppBar(
        title: 'Terminal',
        subtitle: '${service.commands.length} registered commands',
        showBack: true,
        actions: <Widget>[
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
              child: TerminalOutput(lines: _lines),
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
                  Row(
                    children: <Widget>[
                      const Text(
                        '>',
                        style: TextStyle(
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
                          decoration: const InputDecoration(
                            isDense: true,
                            border: InputBorder.none,
                            hintText: 'server status',
                            hintStyle: TextStyle(
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
                        icon: const Icon(Icons.keyboard_return_rounded, size: 18),
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
                            in service.commands.take(8))
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
