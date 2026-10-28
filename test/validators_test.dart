import 'package:flutter_test/flutter_test.dart';
import 'package:pallsql/core/utils/validators.dart';

void main() {
  group('port validation', () {
    test('rejects privileged and out of range ports', () {
      expect(Validators.portError(80), isNotNull);
      expect(Validators.portError(0), isNotNull);
      expect(Validators.portError(70000), isNotNull);
    });

    test('accepts user range ports', () {
      expect(Validators.portError(8080), isNull);
      expect(Validators.portError(1024), isNull);
      expect(Validators.portError(65535), isNull);
    });

    test('privileged ports can be allowed explicitly', () {
      expect(Validators.portError(80, allowPrivileged: true), isNull);
    });
  });

  group('project names', () {
    test('accepts sane names', () {
      expect(Validators.projectNameError('My Site'), isNull);
      expect(Validators.projectNameError('shop-v2'), isNull);
    });

    test('rejects empty, long, path like and reserved names', () {
      expect(Validators.projectNameError('   '), isNotNull);
      expect(Validators.projectNameError('a' * 65), isNotNull);
      expect(Validators.projectNameError('../etc'), isNotNull);
      expect(Validators.projectNameError('/absolute'), isNotNull);
      expect(Validators.projectNameError('settings.json'), isNotNull);
    });

    test('slugify produces a safe folder name', () {
      expect(Validators.slugify('My First Site'), 'my-first-site');
      expect(Validators.slugify('///'), 'project');
      expect(Validators.slugify('a' * 80).length, lessThanOrEqualTo(48));
    });
  });

  group('database names', () {
    test('accepts identifiers', () {
      expect(Validators.databaseNameError('app'), isNull);
      expect(Validators.databaseNameError('notes_2026'), isNull);
    });

    test('rejects injection style names', () {
      expect(Validators.databaseNameError('app; DROP TABLE x'), isNotNull);
      expect(Validators.databaseNameError('1app'), isNotNull);
      expect(Validators.databaseNameError('app.db'), isNotNull);
      expect(Validators.databaseNameError('sqlite_sequence'), isNotNull);
    });
  });

  group('file names and paths', () {
    test('entry names reject separators and traversal', () {
      expect(Validators.entryNameError('index.html'), isNull);
      expect(Validators.entryNameError('..'), isNotNull);
      expect(Validators.entryNameError('a/b'), isNotNull);
      expect(Validators.entryNameError('a\\b'), isNotNull);
      expect(Validators.entryNameError(''), isNotNull);
    });

    test('relative paths reject absolute and traversal', () {
      expect(Validators.isSafeRelativePath('htdocs/index.html'), isTrue);
      expect(Validators.isSafeRelativePath('/etc/passwd'), isFalse);
      expect(Validators.isSafeRelativePath('../outside'), isFalse);
      expect(Validators.isSafeRelativePath('C:/windows'), isFalse);
    });

    test('directory names are single safe segments', () {
      expect(Validators.isSafeDirectoryName('my-site'), isTrue);
      expect(Validators.isSafeDirectoryName('..'), isFalse);
      expect(Validators.isSafeDirectoryName('a/b'), isFalse);
    });
  });

  group('SQL quoting', () {
    test('identifiers are double quoted and escaped', () {
      expect(Validators.quoteSqlIdentifier('notes'), '"notes"');
      expect(Validators.quoteSqlIdentifier('we"ird'), '"we""ird"');
    });

    test('literals are single quoted and escaped', () {
      expect(Validators.quoteSqlLiteral("O'Brien"), "'O''Brien'");
      expect(Validators.quoteSqlLiteral(null), 'NULL');
    });
  });
}
