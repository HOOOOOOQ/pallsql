import 'package:path/path.dart' as p;

import '../errors/app_failure.dart';

/// Confines every filesystem operation to the PALLSQL workspace.
///
/// All user supplied paths are relative to [root]; absolute paths, `..`
/// segments, NUL bytes and Windows drive prefixes are rejected before they ever
/// reach the filesystem.
class PathGuard {
  PathGuard(this.root) : _normalizedRoot = p.normalize(p.absolute(root));

  final String root;
  final String _normalizedRoot;

  String get normalizedRoot => _normalizedRoot;

  /// Validates [relative] and returns the absolute path it maps to.
  ///
  /// Throws [PathSecurityFailure] when the input tries to leave the workspace.
  String resolveRelative(String relative) {
    final String cleaned = relative.trim();
    if (cleaned.contains('\u0000')) {
      throw const PathSecurityFailure('Path contains an invalid character');
    }
    if (p.isAbsolute(cleaned) || RegExp(r'^[A-Za-z]:').hasMatch(cleaned)) {
      throw const PathSecurityFailure('Absolute paths are not allowed');
    }
    final String unixStyle = cleaned.replaceAll('\\', '/');
    final List<String> segments = unixStyle.split('/');
    for (final String segment in segments) {
      if (segment == '..') {
        throw const PathSecurityFailure(
            'Parent directory traversal is blocked');
      }
    }
    final String candidate = p.normalize(p.join(_normalizedRoot, unixStyle));
    return _ensureInside(candidate);
  }

  /// Verifies that [absolutePath] is inside the workspace.
  String ensureInside(String absolutePath) =>
      _ensureInside(p.normalize(p.absolute(absolutePath)));

  String _ensureInside(String absolutePath) {
    if (absolutePath == _normalizedRoot) {
      return absolutePath;
    }
    if (!p.isWithin(_normalizedRoot, absolutePath)) {
      throw PathSecurityFailure(
        'Path escapes the PALLSQL workspace',
        details: p.basename(absolutePath),
      );
    }
    return absolutePath;
  }

  /// Returns [absolutePath] relative to the workspace root using `/`.
  String toRelative(String absolutePath) {
    final String normalized = ensureInside(absolutePath);
    if (normalized == _normalizedRoot) {
      return '';
    }
    return p.relative(normalized, from: _normalizedRoot).replaceAll('\\', '/');
  }

  bool contains(String absolutePath) {
    try {
      _ensureInside(p.normalize(p.absolute(absolutePath)));
      return true;
    } on PathSecurityFailure {
      return false;
    }
  }

  /// Joins a user supplied single segment (file/folder name) safely.
  String resolveSegment(String parentRelative, String name) {
    final String trimmed = name.trim();
    if (trimmed.isEmpty) {
      throw const ValidationFailure('Name cannot be empty');
    }
    if (trimmed == '.' || trimmed == '..') {
      throw const PathSecurityFailure('Invalid name');
    }
    if (trimmed.contains('/') || trimmed.contains('\\')) {
      throw const PathSecurityFailure('Name cannot contain path separators');
    }
    if (trimmed.contains('\u0000')) {
      throw const PathSecurityFailure('Name contains an invalid character');
    }
    final String parent = resolveRelative(parentRelative);
    return ensureInside(p.join(parent, trimmed));
  }
}
