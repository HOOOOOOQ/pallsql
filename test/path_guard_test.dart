import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pallsql/core/errors/app_failure.dart';
import 'package:pallsql/core/utils/path_guard.dart';

void main() {
  late Directory root;
  late PathGuard guard;

  setUp(() {
    root = Directory.systemTemp.createTempSync('pallsql_guard_');
    guard = PathGuard(root.path);
  });

  tearDown(() {
    if (root.existsSync()) {
      root.deleteSync(recursive: true);
    }
  });

  test('resolves relative paths inside the workspace', () {
    final String resolved = guard.resolveRelative('htdocs/index.html');
    expect(resolved, p.join(root.path, 'htdocs', 'index.html'));
    expect(guard.contains(resolved), isTrue);
  });

  test('allows the root itself', () {
    expect(guard.resolveRelative('.'), p.normalize(root.path));
  });

  test('blocks parent traversal', () {
    expect(
      () => guard.resolveRelative('../secret.txt'),
      throwsA(isA<PathSecurityFailure>()),
    );
    expect(
      () => guard.resolveRelative('htdocs/../../secret.txt'),
      throwsA(isA<PathSecurityFailure>()),
    );
    expect(
      () => guard.resolveRelative('htdocs\\..\\secret.txt'),
      throwsA(isA<PathSecurityFailure>()),
    );
  });

  test('blocks absolute paths and drive letters', () {
    expect(
      () => guard.resolveRelative('/etc/passwd'),
      throwsA(isA<PathSecurityFailure>()),
    );
    expect(
      () => guard.resolveRelative('C:/windows/system32'),
      throwsA(isA<PathSecurityFailure>()),
    );
  });

  test('blocks NUL bytes', () {
    expect(
      () => guard.resolveRelative('htdocs/\u0000evil'),
      throwsA(isA<PathSecurityFailure>()),
    );
  });

  test('computes relative paths and rejects escapes', () {
    final String inside = p.join(root.path, 'projects', 'demo', 'index.html');
    expect(guard.toRelative(inside), 'projects/demo/index.html');
    expect(
      () => guard.toRelative('/tmp/outside.txt'),
      throwsA(isA<PathSecurityFailure>()),
    );
    expect(guard.contains('/tmp/outside.txt'), isFalse);
  });

  test('resolves single segments and rejects separators', () {
    expect(
      guard.resolveSegment('htdocs', 'index.html'),
      p.join(root.path, 'htdocs', 'index.html'),
    );
    expect(
      () => guard.resolveSegment('htdocs', '../escape.txt'),
      throwsA(isA<AppFailure>()),
    );
    expect(
      () => guard.resolveSegment('htdocs', 'nested/file.txt'),
      throwsA(isA<PathSecurityFailure>()),
    );
    expect(
      () => guard.resolveSegment('htdocs', '   '),
      throwsA(isA<ValidationFailure>()),
    );
  });
}
