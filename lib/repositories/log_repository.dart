import 'dart:async';
import 'dart:io';

import '../core/contracts/controllers.dart';
import '../models/log_entry.dart';
import '../services/log_sink.dart';

/// In-memory log ring buffer with optional persistence to a log file.
class LogRepository implements LogSink, LogController {
  LogRepository({
    File? file,
    int maxEntries = 500,
    DateTime Function()? clock,
  })  : _file = file,
        _maxEntries = maxEntries,
        _clock = clock ?? DateTime.now;

  final File? _file;
  final DateTime Function() _clock;
  final List<LogEntry> _entries = <LogEntry>[];
  final List<String> _pendingWrites = <String>[];
  final StreamController<List<LogEntry>> _controller =
      StreamController<List<LogEntry>>.broadcast();
  int _maxEntries;
  bool _flushScheduled = false;
  bool _disposed = false;

  /// Newest first.
  List<LogEntry> get entries => List<LogEntry>.unmodifiable(_entries);

  Stream<List<LogEntry>> get changes => _controller.stream;

  int get maxEntries => _maxEntries;

  void setMaxEntries(int value) {
    if (value < 10) {
      return;
    }
    _maxEntries = value;
    _trim();
    _emit();
  }

  /// Loads persisted lines (newest last on disk); corrupted lines are skipped.
  Future<void> load() async {
    final File? file = _file;
    if (file == null || !await file.exists()) {
      return;
    }
    try {
      final String content = await file.readAsString();
      final List<String> lines = content.split('\n');
      for (final String line in lines.reversed) {
        if (line.trim().isEmpty) {
          continue;
        }
        final LogEntry? entry = LogEntry.tryParse(line);
        if (entry != null) {
          _entries.add(entry);
        }
        if (_entries.length >= _maxEntries) {
          break;
        }
      }
      _emit();
    } on FileSystemException {
      // A missing or unreadable log file must never block startup.
    }
  }

  @override
  void log(LogLevel level, LogSource source, String message) {
    if (_disposed) {
      return;
    }
    final String trimmed = message.trim();
    if (trimmed.isEmpty) {
      return;
    }
    final LogEntry entry = LogEntry(
      timestamp: _clock(),
      level: level,
      source: source,
      message: trimmed,
    );
    _entries.insert(0, entry);
    _trim();
    _emit();
    _pendingWrites.add(entry.toLine());
    _scheduleFlush();
  }

  /// Keeps only entries of the given source (used by the export dialog).
  List<LogEntry> filtered({LogLevel? level, LogSource? source, String query = ''}) {
    return _entries
        .where((LogEntry entry) =>
            entry.matches(query: query, level: level, source: source))
        .toList(growable: false);
  }

  Future<void> clear() async {
    _entries.clear();
    _pendingWrites.clear();
    _emit();
    final File? file = _file;
    if (file != null) {
      try {
        await file.writeAsString('', flush: true);
      } on FileSystemException {
        // Clearing an already deleted file is fine.
      }
    }
  }

  /// Writes the current buffer to [destination] and returns the line count.
  Future<int> exportTo(File destination) async {
    final List<LogEntry> snapshot = _entries.reversed.toList(growable: false);
    final StringBuffer buffer = StringBuffer();
    for (final LogEntry entry in snapshot) {
      buffer.writeln(entry.toLine());
    }
    await destination.parent.create(recursive: true);
    await destination.writeAsString(buffer.toString(), flush: true);
    return snapshot.length;
  }

  Future<void> dispose() async {
    _disposed = true;
    await _flush();
    await _controller.close();
  }

  void _trim() {
    if (_entries.length > _maxEntries) {
      _entries.removeRange(_maxEntries, _entries.length);
    }
  }

  void _emit() {
    if (!_controller.isClosed) {
      _controller.add(entries);
    }
  }

  void _scheduleFlush() {
    if (_flushScheduled || _file == null) {
      return;
    }
    _flushScheduled = true;
    scheduleMicrotask(() async {
      _flushScheduled = false;
      await _flush();
    });
  }

  Future<void> _flush() async {
    final File? file = _file;
    if (file == null || _pendingWrites.isEmpty) {
      return;
    }
    final String payload = '${_pendingWrites.join('\n')}\n';
    _pendingWrites.clear();
    try {
      await file.parent.create(recursive: true);
      await file.writeAsString(payload, mode: FileMode.append, flush: false);
    } on FileSystemException {
      // Logging must never throw into the caller.
    }
  }
}
