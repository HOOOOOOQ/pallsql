import 'package:flutter/material.dart';

import '../core/theme/pallsql_colors.dart';
import '../core/utils/formatters.dart';
import '../models/log_entry.dart';
import 'pallsql_card.dart';
import 'terminal_output.dart';

/// Filterable log list with per-source and per-level controls.
class LogViewer extends StatefulWidget {
  const LogViewer({
    super.key,
    required this.entries,
    this.onClear,
    this.onExport,
    this.showSourceFilter = true,
    this.compact = false,
    this.emptyMessage = 'No log entries yet',
    this.initialSource,
  });

  final List<LogEntry> entries;
  final VoidCallback? onClear;
  final VoidCallback? onExport;
  final bool showSourceFilter;
  final bool compact;
  final String emptyMessage;
  final LogSource? initialSource;

  @override
  State<LogViewer> createState() => _LogViewerState();
}

class _LogViewerState extends State<LogViewer> {
  LogLevel? _level;
  LogSource? _source;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _source = widget.initialSource;
  }

  List<LogEntry> get _filtered => widget.entries
      .where((LogEntry entry) =>
          entry.matches(query: _query, level: _level, source: _source))
      .toList(growable: false);

  @override
  Widget build(BuildContext context) {
    final List<LogEntry> filtered = _filtered;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Column(
            children: <Widget>[
              TextField(
                onChanged: (String value) => setState(() => _query = value),
                style: const TextStyle(
                  fontSize: 12.5,
                  color: PallSqlColors.textPrimary,
                ),
                decoration: InputDecoration(
                  isDense: true,
                  hintText: 'Search logs',
                  hintStyle: const TextStyle(
                    color: PallSqlColors.textDisabled,
                    fontSize: 12.5,
                  ),
                  prefixIcon: const Icon(Icons.search_rounded, size: 17),
                  filled: true,
                  fillColor: PallSqlColors.surface,
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(9),
                    borderSide: const BorderSide(color: PallSqlColors.border),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(9),
                    borderSide: const BorderSide(color: PallSqlColors.border),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(9),
                    borderSide: const BorderSide(color: PallSqlColors.accent),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: <Widget>[
                    _FilterChip(
                      label: 'All levels',
                      selected: _level == null,
                      onTap: () => setState(() => _level = null),
                    ),
                    for (final LogLevel level in LogLevel.values)
                      _FilterChip(
                        label: level.label,
                        color: logLevelColor(level),
                        selected: _level == level,
                        onTap: () => setState(
                          () => _level = _level == level ? null : level,
                        ),
                      ),
                    if (widget.showSourceFilter) ...<Widget>[
                      const SizedBox(width: 6),
                      Container(
                        width: 1,
                        height: 18,
                        color: PallSqlColors.border,
                      ),
                      for (final LogSource source in LogSource.values)
                        _FilterChip(
                          label: source.label,
                          selected: _source == source,
                          onTap: () => setState(
                            () => _source = _source == source ? null : source,
                          ),
                        ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
        Row(
          children: <Widget>[
            Text(
              '${filtered.length} of ${widget.entries.length} entries',
              style: const TextStyle(
                fontSize: 11,
                color: PallSqlColors.textSecondary,
              ),
            ),
            const Spacer(),
            if (widget.onExport != null)
              TextButton.icon(
                onPressed: widget.onExport,
                icon: const Icon(Icons.ios_share_rounded, size: 14),
                label: const Text('Export', style: TextStyle(fontSize: 11.5)),
                style: TextButton.styleFrom(
                  foregroundColor: PallSqlColors.textSecondary,
                  minimumSize: Size.zero,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
            if (widget.onClear != null)
              TextButton.icon(
                onPressed: widget.onClear,
                icon: const Icon(Icons.delete_sweep_rounded, size: 14),
                label: const Text('Clear', style: TextStyle(fontSize: 11.5)),
                style: TextButton.styleFrom(
                  foregroundColor: PallSqlColors.error,
                  minimumSize: Size.zero,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
          ],
        ),
        const SizedBox(height: 6),
        Expanded(
          child: PallSqlCard(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: filtered.isEmpty
                ? Center(
                    child: Text(
                      widget.emptyMessage,
                      style: const TextStyle(
                        color: PallSqlColors.textDisabled,
                        fontSize: 12,
                      ),
                    ),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    itemCount: filtered.length,
                    separatorBuilder: (BuildContext context, int index) =>
                        const Divider(height: 1),
                    itemBuilder: (BuildContext context, int index) {
                      final LogEntry entry = filtered[index];
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 7),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Text(
                              Formatters.clock(entry.timestamp),
                              style: const TextStyle(
                                fontFamily: PallSqlColors.monoFontFamily,
                                fontSize: 10.5,
                                color: PallSqlColors.textDisabled,
                              ),
                            ),
                            const SizedBox(width: 8),
                            LogLevelBadge(level: entry.level, width: 50),
                            SizedBox(
                              width: 70,
                              child: Text(
                                entry.source.label,
                                style: const TextStyle(
                                  fontFamily: PallSqlColors.monoFontFamily,
                                  fontSize: 10,
                                  color: PallSqlColors.textSecondary,
                                ),
                              ),
                            ),
                            Expanded(
                              child: SelectableText(
                                entry.message,
                                style: TextStyle(
                                  fontFamily: PallSqlColors.monoFontFamily,
                                  fontSize: 11,
                                  height: 1.35,
                                  color: logLevelColor(entry.level),
                                ),
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ),
      ],
    );
  }
}

class _FilterChip extends StatelessWidget {
  const _FilterChip({
    required this.label,
    required this.selected,
    required this.onTap,
    this.color,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final Color accent = color ?? PallSqlColors.accent;
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
          decoration: BoxDecoration(
            color: selected
                ? accent.withValues(alpha: 0.14)
                : PallSqlColors.surface,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: selected
                  ? accent.withValues(alpha: 0.5)
                  : PallSqlColors.border,
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.4,
              color: selected ? accent : PallSqlColors.textSecondary,
            ),
          ),
        ),
      ),
    );
  }
}
