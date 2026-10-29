import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pallsql/features/editor/syntax_highlighter.dart';

void main() {
  const TextStyle base = TextStyle();

  /// Every language defines a different set of named groups. Asking for a group
  /// that the pattern does not define used to throw ArgumentError inside
  /// `buildTextSpan`, which crashed the whole editor widget.
  const Map<CodeLanguage, String> samples = <CodeLanguage, String>{
    CodeLanguage.sql: 'SELECT * FROM users WHERE id = 1; -- one row',
    CodeLanguage.javascript:
        'const a = "b"; // note\nfunction f() { return 1; }',
    CodeLanguage.php: '<?php echo "hi"; // note\nfunction f() { return \$x; }',
    CodeLanguage.html: '<!doctype html>\n<div class="a">text</div>',
    CodeLanguage.css: '/* note */\na { color: #9bff3d; margin: 4px; }',
    CodeLanguage.json: '{"key": "value", "n": 12, "ok": true}',
    CodeLanguage.markdown: '# Title\n> quote\n`code`',
    CodeLanguage.plain: 'SELECT * FROM users;',
  };

  for (final MapEntry<CodeLanguage, String> sample in samples.entries) {
    test('highlights ${sample.key.name} without throwing', () {
      late TextSpan span;
      expect(
        () => span = SyntaxHighlighter.buildSpan(
          text: sample.value,
          language: sample.key,
          baseStyle: base,
        ),
        returnsNormally,
      );
      expect(span.toPlainText(), sample.value);
    });
  }

  test('still highlights SQL keywords', () {
    final TextSpan span = SyntaxHighlighter.buildSpan(
      text: 'SELECT name FROM users',
      language: CodeLanguage.sql,
      baseStyle: base,
    );
    final List<TextSpan> children = span.children!.cast<TextSpan>().toList();
    expect(children.map((TextSpan child) => child.text), contains('SELECT'));
    expect(children.first.style?.color, isNotNull);
  });

  test('returns the text unchanged when it is too long to highlight', () {
    final String huge = 'SELECT 1;' * 20000;
    final TextSpan span = SyntaxHighlighter.buildSpan(
      text: huge,
      language: CodeLanguage.sql,
      baseStyle: base,
    );
    expect(span.text, huge);
    expect(span.children, isNull);
  });
}
