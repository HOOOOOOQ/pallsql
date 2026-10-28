import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/log_entry.dart';
import '../../providers/app_providers.dart';
import '../../widgets/log_viewer.dart';
import '../../widgets/pallsql_app_bar.dart';
import '../../widgets/pallsql_dialogs.dart';

/// Full log viewer with filters, search, export and clear.
class LogsPage extends ConsumerStatefulWidget {
  const LogsPage({super.key, this.initialSource});

  final LogSource? initialSource;

  @override
  ConsumerState<LogsPage> createState() => _LogsPageState();
}

class _LogsPageState extends ConsumerState<LogsPage> {
  Future<void> _export() async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final File target = await ref
        .read(bootstrapProvider)
        .workspace
        .createTempFile('logs', '.log');
    final int count = await ref.read(logRepositoryProvider).exportTo(target);
    if (!mounted) {
      return;
    }
    final bool shared =
        await ref.read(nativeBridgeProvider).shareFile(target.path);
    if (!mounted) {
      return;
    }
    showPallSqlSnack(
      messenger,
      shared
          ? 'Exported $count entries'
          : 'Saved $count entries to ${target.path}',
    );
  }

  Future<void> _clear() async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final bool confirmed = await showConfirmDialog(
      context: context,
      title: 'Clear logs?',
      message: 'All in-memory entries and the persisted log file are cleared. '
          'This cannot be undone.',
      confirmLabel: 'Clear',
      destructive: true,
    );
    if (!confirmed || !mounted) {
      return;
    }
    await ref.read(logRepositoryProvider).clear();
    if (!mounted) {
      return;
    }
    showPallSqlSnack(messenger, 'Logs cleared');
  }

  @override
  Widget build(BuildContext context) {
    final List<LogEntry> entries =
        ref.watch(logEntriesProvider).valueOrNull ?? const <LogEntry>[];
    return Scaffold(
      appBar: PallSQLAppBar(
        title: 'Logs',
        subtitle: '${entries.length} entries',
        showBack: true,
      ),
      body: Padding(
        padding: const EdgeInsets.fromLTRB(14, 8, 14, 14),
        child: LogViewer(
          entries: entries,
          initialSource: widget.initialSource,
          onClear: _clear,
          onExport: _export,
        ),
      ),
    );
  }
}
