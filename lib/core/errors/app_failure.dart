/// Typed failures used across PALLSQL services.
///
/// Every failure carries a message that is safe to show to the user: it never
/// contains credentials or file contents.
class AppFailure implements Exception {
  const AppFailure(this.message, {this.details});

  final String message;
  final String? details;

  String get combined =>
      details == null || details!.isEmpty ? message : '$message ($details)';

  @override
  String toString() => combined;
}

/// User input did not pass validation.
class ValidationFailure extends AppFailure {
  const ValidationFailure(super.message, {super.details});
}

/// A service could not bind to the requested TCP port.
class PortInUseFailure extends AppFailure {
  const PortInUseFailure(this.port, {String? details})
      : super('Port $port is already in use', details: details);

  final int port;
}

/// The requested resource does not exist.
class NotFoundFailure extends AppFailure {
  const NotFoundFailure(super.message, {super.details});
}

/// The action is not supported by the current runtime or engine.
class UnsupportedFailure extends AppFailure {
  const UnsupportedFailure(super.message, {super.details});
}

/// A path escaped (or tried to escape) the sandboxed workspace.
class PathSecurityFailure extends AppFailure {
  const PathSecurityFailure(super.message, {super.details});
}

/// The database server rejected the statement or object.
class SqlRejectedFailure extends AppFailure {
  const SqlRejectedFailure(super.message, {super.details});
}

/// A file could not be parsed, for example a corrupted ZIP archive.
class ArchiveFailure extends AppFailure {
  const ArchiveFailure(super.message, {super.details});
}

/// Wraps an unknown error into a user presentable failure.
AppFailure toFailure(Object error, {String fallback = 'Unexpected error'}) {
  if (error is AppFailure) {
    return error;
  }
  return AppFailure(fallback, details: error.toString());
}
