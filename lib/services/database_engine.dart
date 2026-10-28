import '../models/database_models.dart';

/// Contract every database backend must satisfy.
///
/// The UI talks to this interface only, so the SQLite MVP and a future MariaDB
/// adapter can coexist without leaking engine details into widgets.
abstract class DatabaseEngine {
  DatabaseEngineId get id;

  /// Real availability check; must never report `available` optimistically.
  Future<EngineAvailability> availability();

  Future<void> dispose();
}

/// MariaDB adapter status.
///
/// MariaDB cannot be shipped through pub.dev and requires a native Android
/// build (see `docs/database.md` for the evaluation that was performed).
/// This adapter therefore reports `unavailable` with an explicit reason instead
/// of pretending the engine exists.
class MariaDbEngine implements DatabaseEngine {
  MariaDbEngine({this.reason = _defaultReason});

  static const String _defaultReason =
      'MariaDB server is not bundled with this build. PALLSQL ships SQLite as '
      'the offline engine; a native MariaDB runtime (ndk build + data '
      'directory bootstrap) has not been verified on device yet.';

  final String reason;

  @override
  DatabaseEngineId get id => DatabaseEngineId.mariadb;

  @override
  Future<EngineAvailability> availability() async => EngineAvailability.unavailable(
        DatabaseEngineId.mariadb,
        reason,
      );

  @override
  Future<void> dispose() async {}
}
