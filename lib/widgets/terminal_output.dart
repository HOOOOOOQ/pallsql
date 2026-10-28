import 'package:flutter/material.dart';

import '../core/theme/pallsql_colors.dart';
import '../models/log_entry.dart';

/// Scrollable, monospace output panel shared by the terminal and log views.
class TerminalOutput extends StatelessWidget {
  const TerminalOutput({
    super.key,
    required this.lines,
    this.emptyMessage = 'No output yet',
    this.padding = const EdgeInsets.all(12),
    this.autoScroll = true,
  });

  final List<LogEntry> lines;
  final String emptyMessage;
  final EdgeInsetsGeometry padding;
  final bool autoScroll;

  @override
  Widget build(BuildContext context) {
    if (lines.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(20),
        child: Text(
          emptyMessage,
          style: const TextStyle(
            color: PallSqlColors.textDisabled,
            fontSize: 12,
            fontFamily: PallSqlColors.monoFontFamily,
          ),
        ),
      );
    }
    return ListView.builder(
      reverse: autoScroll,
      padding: padding,
      itemCount: lines.length,
      itemBuilder: (BuildContext context, int index) {
        final LogEntry line =
            lines[autoScroll ? lines.length - 1 - index : index];
        return Padding(
          padding: const EdgeInsets.only(bottom: 3),
          child: SelectableText(
            line.message,
            style: TextStyle(
              fontFamily: PallSqlColors.monoFontFamily,
              fontSize: 11.5,
              height: 1.45,
              color: logLevelColor(line.level),
            ),
          ),
        );
      },
    );
  }
}

/// Colour associated with a log level.
Color logLevelColor(LogLevel level) {
  switch (level) {
    case LogLevel.debug:
      return PallSqlColors.textDisabled;
    case LogLevel.info:
      return PallSqlColors.textPrimary;
    case LogLevel.warning:
      return PallSqlColors.warning;
    case LogLevel.error:
      return PallSqlColors.error;
  }
}

/// Small coloured badge for a log level.
class LogLevelBadge extends StatelessWidget {
  const LogLevelBadge({super.key, required this.level, this.width = 54});

  final LogLevel level;
  final double width;

  @override
  Widget build(BuildContext context) {
    final Color color = logLevelColor(level);
    return SizedBox(
      width: width,
      child: Text(
        level.label,
        style: TextStyle(
          color: color,
          fontSize: 9.5,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.8,
        ),
      ),
    );
  }
}
