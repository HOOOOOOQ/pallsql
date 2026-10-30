import '../core/utils/sql_utils.dart';

/// Dialect helpers for the SQL editor header and the terminal.
///
/// MariaDB 0.3 history: PALLSQL used to *translate* MySQL metadata statements
/// into SQLite ones. That layer is gone, because the app now runs a real
/// MariaDB server which answers `SHOW DATABASES`, `DESCRIBE`,
/// `SHOW CREATE TABLE`, `SHOW INDEX`, `SELECT VERSION()` and friends itself.
///
/// What remains here is the honest labelling: the editor must say which engine
/// and dialect it is talking to, and the terminal must never call MariaDB
/// "MySQL".
class SqlDialect {
  const SqlDialect._();

  static const String engine = 'MariaDB';

  /// `MariaDB 10.11.6 — MariaDB dialect`.
  static String engineLabel(String version) {
    final String trimmed = version.trim();
    if (trimmed.isEmpty) {
      return '$engine — $engine dialect';
    }
    return '$engine $trimmed — $engine dialect';
  }

  static String databaseLabel(String name) => name;

  /// Statements that PALLSQL itself does not send to the server because they
  /// touch files outside the workspace, regardless of the engine.
  static bool isBlockedForSafety(String sql) =>
      SqlUtils.leadingKeyword(sql) == 'ATTACH' ||
      SqlUtils.leadingKeyword(sql) == 'DETACH';
}

/// Kept for the tests that assert the old behaviour is gone: any attempt to
/// route a statement through a translation layer must return `null`.
@Deprecated('The compatibility layer was removed with the MariaDB migration')
class SqlCompatibility {
  const SqlCompatibility._();

  static Object? parse(String sql) => null;
}
