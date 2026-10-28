import '../models/log_entry.dart';

/// Anything that can record a structured log line.
abstract class LogSink {
  const LogSink();

  void log(LogLevel level, LogSource source, String message);

  void debug(LogSource source, String message) => log(LogLevel.debug, source, message);

  void info(LogSource source, String message) => log(LogLevel.info, source, message);

  void warning(LogSource source, String message) =>
      log(LogLevel.warning, source, message);

  void error(LogSource source, String message) => log(LogLevel.error, source, message);
}

/// A sink that intentionally drops everything (used by isolated unit tests).
class NullLogSink extends LogSink {
  const NullLogSink();

  @override
  void log(LogLevel level, LogSource source, String message) {}
}
