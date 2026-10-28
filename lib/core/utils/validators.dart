/// Pure validation helpers shared by the UI, services and tests.
class Validators {
  const Validators._();

  static final RegExp _projectName = RegExp(r'^[A-Za-z0-9][A-Za-z0-9 _.\-]{0,63}$');
  static final RegExp _databaseName = RegExp(r'^[A-Za-z_][A-Za-z0-9_]{0,62}$');
  static final RegExp _safeDirectory = RegExp(r'^[A-Za-z0-9][A-Za-z0-9 _.\-]{0,63}$');
  static final RegExp _controlChars = RegExp(r'[\u0000-\u001f]');

  static const Set<String> _reservedNames = <String>{
    'con',
    'prn',
    'aux',
    'nul',
    'com1',
    'lpt1',
    'settings.json',
  };

  /// Returns an error message for an invalid port, or `null` when valid.
  static String? portError(int port, {bool allowPrivileged = false}) {
    final int min = allowPrivileged ? 1 : 1024;
    if (port < min || port > 65535) {
      return 'Port must be between $min and 65535';
    }
    return null;
  }

  static bool isValidPort(int port, {bool allowPrivileged = false}) {
    return portError(port, allowPrivileged: allowPrivileged) == null;
  }

  /// A project name is a human readable label, not a path.
  static String? projectNameError(String name) {
    final String trimmed = name.trim();
    if (trimmed.isEmpty) {
      return 'Project name is required';
    }
    if (trimmed.length > 64) {
      return 'Project name must be 64 characters or fewer';
    }
    if (!_projectName.hasMatch(trimmed)) {
      return 'Use letters, numbers, spaces, dot, dash or underscore and start '
          'with a letter or number';
    }
    if (_reservedNames.contains(trimmed.toLowerCase())) {
      return 'That name is reserved';
    }
    return null;
  }

  static bool isValidProjectName(String name) => projectNameError(name) == null;

  /// A directory name may only contain a single path segment.
  static bool isSafeDirectoryName(String value) {
    final String trimmed = value.trim();
    if (trimmed.isEmpty || trimmed == '.' || trimmed == '..') {
      return false;
    }
    if (trimmed.contains('/') || trimmed.contains('\\')) {
      return false;
    }
    if (_controlChars.hasMatch(trimmed)) {
      return false;
    }
    return _safeDirectory.hasMatch(trimmed);
  }

  /// A relative workspace path without traversal or absolute prefixes.
  static bool isSafeRelativePath(String value) {
    final String trimmed = value.trim();
    if (trimmed.isEmpty || trimmed.startsWith('/') || trimmed.startsWith('\\')) {
      return false;
    }
    if (RegExp(r'^[A-Za-z]:').hasMatch(trimmed)) {
      return false;
    }
    if (_controlChars.hasMatch(trimmed)) {
      return false;
    }
    final List<String> segments = trimmed.replaceAll('\\', '/').split('/');
    for (final String segment in segments) {
      if (segment == '..') {
        return false;
      }
    }
    return true;
  }

  /// File or folder name validation used by the file manager.
  static String? entryNameError(String name) {
    final String trimmed = name.trim();
    if (trimmed.isEmpty) {
      return 'Name is required';
    }
    if (trimmed.length > 128) {
      return 'Name must be 128 characters or fewer';
    }
    if (trimmed == '.' || trimmed == '..') {
      return 'Reserved name';
    }
    if (trimmed.contains('/') || trimmed.contains('\\')) {
      return 'Name cannot contain path separators';
    }
    if (_controlChars.hasMatch(trimmed)) {
      return 'Name contains control characters';
    }
    if (_reservedNames.contains(trimmed.toLowerCase())) {
      return 'That name is reserved';
    }
    return null;
  }

  static bool isValidEntryName(String name) => entryNameError(name) == null;

  /// SQLite database name (also used as the file name).
  static String? databaseNameError(String name) {
    final String trimmed = name.trim();
    if (trimmed.isEmpty) {
      return 'Database name is required';
    }
    if (!_databaseName.hasMatch(trimmed)) {
      return 'Use letters, numbers and underscore, starting with a letter or '
          'underscore (max 63 characters)';
    }
    final String lower = trimmed.toLowerCase();
    if (lower == 'sqlite_sequence' || lower == 'config') {
      return 'That database name is reserved';
    }
    return null;
  }

  static bool isValidDatabaseName(String name) => databaseNameError(name) == null;

  /// Converts a project name into a filesystem friendly folder name.
  static String slugify(String value) {
    final String lowered = value.trim().toLowerCase();
    final String replaced = lowered
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    final String collapsed = replaced.isEmpty ? 'project' : replaced;
    return collapsed.length <= 48 ? collapsed : collapsed.substring(0, 48);
  }

  /// SQLite identifiers are quoted with double quotes in generated SQL.
  static String quoteSqlIdentifier(String identifier) =>
      '"${identifier.replaceAll('"', '""')}"';

  /// Escapes a value for inclusion in a generated SQL script.
  static String quoteSqlLiteral(String? value) {
    if (value == null) {
      return 'NULL';
    }
    return "'${value.replaceAll("'", "''")}'";
  }
}
