/// Severity of a log entry.
enum LogLevel {
  debug,
  info,
  warning,
  error;

  String get label => name.toUpperCase();

  static LogLevel fromName(String value) {
    final String normalized = value.trim().toLowerCase();
    for (final LogLevel level in LogLevel.values) {
      if (level.name == normalized) {
        return level;
      }
    }
    return LogLevel.info;
  }
}

/// Subsystem that produced a log entry.
enum LogSource {
  app('APP'),
  webServer('WEB'),
  php('PHP'),
  database('DATABASE'),
  files('FILES'),
  terminal('TERMINAL'),
  backup('BACKUP'),
  network('NETWORK');

  const LogSource(this.label);

  final String label;

  String get description {
    switch (this) {
      case LogSource.app:
        return 'Application';
      case LogSource.webServer:
        return 'Web server';
      case LogSource.php:
        return 'PHP runtime';
      case LogSource.database:
        return 'Database';
      case LogSource.files:
        return 'File manager';
      case LogSource.terminal:
        return 'Terminal';
      case LogSource.backup:
        return 'Backup';
      case LogSource.network:
        return 'Network';
    }
  }

  static LogSource fromLabel(String value) {
    final String normalized = value.trim().toUpperCase();
    for (final LogSource source in LogSource.values) {
      if (source.label == normalized || source.name.toUpperCase() == normalized) {
        return source;
      }
    }
    return LogSource.app;
  }
}

/// A single, immutable log record.
class LogEntry {
  LogEntry({
    required this.timestamp,
    required this.level,
    required this.source,
    required this.message,
  }) : message = _sanitize(message);

  final DateTime timestamp;
  final LogLevel level;
  final LogSource source;
  final String message;

  static String _sanitize(String value) =>
      value.replaceAll('\r', ' ').replaceAll('\n', ' ').trim();

  /// Persisted form: `<iso8601>\t<LEVEL>\t<SOURCE>\t<message>`.
  String toLine() =>
      '${timestamp.toUtc().toIso8601String()}\t${level.label}\t${source.label}\t$message';

  /// Parses a persisted line, returning `null` for malformed input.
  static LogEntry? tryParse(String line) {
    final List<String> parts = line.split('\t');
    if (parts.length < 4) {
      return null;
    }
    final DateTime? timestamp = DateTime.tryParse(parts[0].trim());
    if (timestamp == null) {
      return null;
    }
    final String message = parts.sublist(3).join(' ').trim();
    if (message.isEmpty) {
      return null;
    }
    return LogEntry(
      timestamp: timestamp.toLocal(),
      level: LogLevel.fromName(parts[1]),
      source: LogSource.fromLabel(parts[2]),
      message: message,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'timestamp': timestamp.toIso8601String(),
        'level': level.name,
        'source': source.name,
        'message': message,
      };

  static LogEntry fromJson(Map<String, Object?> json) {
    return LogEntry(
      timestamp:
          DateTime.tryParse(json['timestamp']?.toString() ?? '') ?? DateTime.now(),
      level: LogLevel.fromName(json['level']?.toString() ?? 'info'),
      source: LogSource.fromLabel(json['source']?.toString() ?? 'app'),
      message: json['message']?.toString() ?? '',
    );
  }

  bool matches({String? query, LogLevel? level, LogSource? source}) {
    if (level != null && level != this.level) {
      return false;
    }
    if (source != null && source != this.source) {
      return false;
    }
    final String trimmed = (query ?? '').trim().toLowerCase();
    if (trimmed.isEmpty) {
      return true;
    }
    return message.toLowerCase().contains(trimmed) ||
        source.label.toLowerCase().contains(trimmed) ||
        level.label.toLowerCase().contains(trimmed);
  }

  @override
  String toString() => toLine();
}
