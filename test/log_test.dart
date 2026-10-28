import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pallsql/models/log_entry.dart';
import 'package:pallsql/repositories/log_repository.dart';

void main() {
  group('LogEntry parsing', () {
    test('round trips through the persisted line format', () {
      final LogEntry entry = LogEntry(
        timestamp: DateTime.utc(2026, 10, 28, 9, 30, 15),
        level: LogLevel.warning,
        source: LogSource.webServer,
        message: 'Port 8080 busy',
      );
      final LogEntry? parsed = LogEntry.tryParse(entry.toLine());
      expect(parsed, isNotNull);
      expect(parsed!.level, LogLevel.warning);
      expect(parsed.source, LogSource.webServer);
      expect(parsed.message, 'Port 8080 busy');
      expect(parsed.timestamp.toUtc(), entry.timestamp);
    });

    test('multi line messages are flattened', () {
      final LogEntry entry = LogEntry(
        timestamp: DateTime.now(),
        level: LogLevel.error,
        source: LogSource.database,
        message: 'line one\nline two\r\n',
      );
      expect(entry.message.contains('\n'), isFalse);
    });

    test('rejects malformed lines', () {
      expect(LogEntry.tryParse(''), isNull);
      expect(LogEntry.tryParse('nonsense'), isNull);
      expect(LogEntry.tryParse('2026-10-28T09:30:15Z\tINFO\tWEB'), isNull);
      expect(LogEntry.tryParse('not-a-date\tINFO\tWEB\tmessage'), isNull);
    });

    test('unknown level and source fall back safely', () {
      final LogEntry? parsed =
          LogEntry.tryParse('2026-10-28T09:30:15Z\tTRACE\tMYSTERY\tmessage');
      expect(parsed, isNotNull);
      expect(parsed!.level, LogLevel.info);
      expect(parsed.source, LogSource.app);
    });

    test('filtering matches message, level and source', () {
      final LogEntry entry = LogEntry(
        timestamp: DateTime.now(),
        level: LogLevel.error,
        source: LogSource.php,
        message: 'Runtime missing',
      );
      expect(entry.matches(query: 'runtime'), isTrue);
      expect(entry.matches(query: 'php'), isTrue);
      expect(entry.matches(query: 'zzz'), isFalse);
      expect(entry.matches(level: LogLevel.error), isTrue);
      expect(entry.matches(level: LogLevel.info), isFalse);
      expect(entry.matches(source: LogSource.php), isTrue);
      expect(entry.matches(source: LogSource.database), isFalse);
    });
  });

  group('LogRepository', () {
    test('keeps newest first and honours the buffer limit', () {
      final LogRepository repository = LogRepository(maxEntries: 3);
      for (int i = 0; i < 5; i++) {
        repository.log(LogLevel.info, LogSource.app, 'entry $i');
      }
      expect(repository.entries, hasLength(3));
      expect(repository.entries.first.message, 'entry 4');
      repository.dispose();
    });

    test('persists and reloads entries', () async {
      final Directory directory =
          await Directory.systemTemp.createTemp('pallsql_logs_');
      final File file = File('${directory.path}/app.log');
      final LogRepository writer = LogRepository(file: file);
      writer.log(LogLevel.info, LogSource.app, 'first');
      writer.log(LogLevel.error, LogSource.webServer, 'second');
      // Let the scheduled flush run.
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await writer.dispose();

      expect(await file.exists(), isTrue);
      final LogRepository reader = LogRepository(file: file);
      await reader.load();
      expect(reader.entries, hasLength(2));
      expect(reader.entries.first.level, LogLevel.error);
      await reader.dispose();
      await directory.delete(recursive: true);
    });

    test('clears entries and the backing file', () async {
      final Directory directory =
          await Directory.systemTemp.createTemp('pallsql_logs_');
      final File file = File('${directory.path}/app.log');
      final LogRepository repository = LogRepository(file: file);
      repository.log(LogLevel.info, LogSource.app, 'hello');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await repository.clear();
      expect(repository.entries, isEmpty);
      expect((await file.readAsString()).trim(), isEmpty);
      await repository.dispose();
      await directory.delete(recursive: true);
    });

    test('exports to a file', () async {
      final Directory directory =
          await Directory.systemTemp.createTemp('pallsql_logs_');
      final LogRepository repository = LogRepository();
      repository.log(LogLevel.info, LogSource.app, 'export me');
      final File target = File('${directory.path}/export.log');
      final int count = await repository.exportTo(target);
      expect(count, 1);
      expect(await target.readAsString(), contains('export me'));
      await repository.dispose();
      await directory.delete(recursive: true);
    });
  });
}
