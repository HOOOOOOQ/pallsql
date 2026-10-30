import 'package:flutter_test/flutter_test.dart';
import 'package:pallsql/services/sql_compatibility.dart';

void main() {
  group('dialect labelling after the MariaDB migration', () {
    test('the engine label names MariaDB and never MySQL', () {
      final String label = SqlDialect.engineLabel('10.11.6-MariaDB');
      expect(label, contains('MariaDB'));
      expect(label, contains('10.11.6'));
      expect(label.toLowerCase(), contains('dialect'));
      expect(label.toLowerCase(), isNot(contains('mysql')));
    });

    test('an unknown version still names the real engine', () {
      expect(SqlDialect.engineLabel(''), 'MariaDB — MariaDB dialect');
      expect(SqlDialect.engineLabel('   '), 'MariaDB — MariaDB dialect');
    });

    test('ATTACH/DETACH stay blocked for workspace safety', () {
      expect(
          SqlDialect.isBlockedForSafety('ATTACH DATABASE "x" AS y;'), isTrue);
      expect(SqlDialect.isBlockedForSafety('detach database y'), isTrue);
      expect(SqlDialect.isBlockedForSafety('SELECT 1'), isFalse);
    });

    test('statements are no longer rewritten by a translation layer', () {
      // The compatibility layer is gone: MariaDB answers these itself, so
      // nothing may intercept them on the client.
      // ignore: deprecated_member_use_from_same_package
      expect(SqlCompatibility.parse('SHOW DATABASES;'), isNull);
      // ignore: deprecated_member_use_from_same_package
      expect(SqlCompatibility.parse('DESCRIBE users;'), isNull);
    });
  });
}
