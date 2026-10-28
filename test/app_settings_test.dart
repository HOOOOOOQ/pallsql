import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pallsql/models/app_settings.dart';

void main() {
  group('AppSettings', () {
    test('defaults are valid', () {
      const AppSettings settings = AppSettings();
      expect(settings.validate(), isEmpty);
      expect(settings.isValid, isTrue);
      expect(settings.httpPort, 8080);
      expect(settings.lanAccess, isFalse);
    });

    test('validation rejects bad values', () {
      expect(const AppSettings(httpPort: 80).validate(), isNotEmpty);
      expect(const AppSettings(editorFontSize: 4).validate(), isNotEmpty);
      expect(const AppSettings(maxLogEntries: 1).validate(), isNotEmpty);
      expect(
        const AppSettings(phpBinaryPath: '../../evil').validate(),
        isNotEmpty,
      );
    });

    test('round trips through JSON', () {
      const AppSettings settings = AppSettings(
        httpPort: 8888,
        lanAccess: true,
        editorFontSize: 15,
        maxLogEntries: 700,
        activeProjectId: 'demo',
        phpBinaryPath: 'config/php/php-cgi',
      );
      final String encoded = jsonEncode(settings.toJson());
      final AppSettings decoded =
          AppSettings.fromJson(jsonDecode(encoded) as Map<String, Object?>);
      expect(decoded.httpPort, 8888);
      expect(decoded.lanAccess, isTrue);
      expect(decoded.editorFontSize, 15);
      expect(decoded.maxLogEntries, 700);
      expect(decoded.activeProjectId, 'demo');
      expect(decoded.phpBinaryPath, 'config/php/php-cgi');
    });

    test('tolerates corrupted values', () {
      final AppSettings decoded = AppSettings.fromJson(<String, Object?>{
        'httpPort': 'nope',
        'editorFontSize': 99,
        'maxLogEntries': -5,
        'phpBinaryPath': '../escape',
        'activeProjectId': '../escape',
        'databaseEngine': 'oracle',
      });
      expect(decoded.httpPort, 8080);
      expect(decoded.editorFontSize, 13);
      expect(decoded.maxLogEntries, 500);
      expect(decoded.phpBinaryPath, '');
      expect(decoded.activeProjectId, '');
      expect(decoded.databaseEngine, 'sqlite');
    });

    test('copyWith replaces only the given fields', () {
      const AppSettings settings = AppSettings();
      final AppSettings updated = settings.copyWith(httpPort: 9090);
      expect(updated.httpPort, 9090);
      expect(updated.maxLogEntries, settings.maxLogEntries);
    });
  });
}
