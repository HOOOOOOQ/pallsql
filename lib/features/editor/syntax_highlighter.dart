import 'package:flutter/material.dart';

import '../../core/theme/pallsql_colors.dart';

/// Languages the built-in editor can highlight.
enum CodeLanguage {
  html,
  css,
  javascript,
  php,
  sql,
  json,
  markdown,
  plain,
}

/// Maps a file name to a highlight language.
CodeLanguage languageForFile(String fileName) {
  final int dot = fileName.lastIndexOf('.');
  final String extension =
      dot < 0 ? '' : fileName.substring(dot + 1).toLowerCase();
  switch (extension) {
    case 'html':
    case 'htm':
    case 'xml':
    case 'svg':
      return CodeLanguage.html;
    case 'css':
      return CodeLanguage.css;
    case 'js':
    case 'mjs':
      return CodeLanguage.javascript;
    case 'php':
      return CodeLanguage.php;
    case 'sql':
      return CodeLanguage.sql;
    case 'json':
      return CodeLanguage.json;
    case 'md':
    case 'markdown':
      return CodeLanguage.markdown;
    default:
      return CodeLanguage.plain;
  }
}

/// Regex based, dependency free syntax highlighting.
///
/// This is highlighting only: PALLSQL does not claim IntelliSense, linting or
/// semantic analysis for the edited files.
class SyntaxHighlighter {
  const SyntaxHighlighter._();

  /// Files larger than this are rendered without highlighting for performance.
  static const int maxHighlightLength = 120000;

  static final Map<CodeLanguage, RegExp> _patterns = <CodeLanguage, RegExp>{
    CodeLanguage.sql: RegExp(
      r"""(?<comment>--[^\n]*|/\*[\s\S]*?\*/)"""
      r"""|(?<string>'(?:[^']|'')*')"""
      r"""|(?<keyword>\b(?:SELECT|FROM|WHERE|INSERT|INTO|VALUES|UPDATE|SET|DELETE|CREATE|TABLE|INDEX|VIEW|DROP|ALTER|ADD|PRIMARY|KEY|FOREIGN|REFERENCES|NOT|NULL|DEFAULT|AUTOINCREMENT|JOIN|LEFT|RIGHT|INNER|OUTER|ON|GROUP|BY|ORDER|HAVING|LIMIT|OFFSET|AS|AND|OR|IN|IS|LIKE|BETWEEN|UNION|ALL|DISTINCT|BEGIN|COMMIT|ROLLBACK|TRANSACTION|PRAGMA|EXPLAIN|CASE|WHEN|THEN|ELSE|END|INTEGER|TEXT|REAL|BLOB|NUMERIC|UNIQUE|CHECK|CASCADE|IF|EXISTS|WITH|REPLACE|VACUUM)\b)"""
      r"""|(?<number>\b\d+(?:\.\d+)?\b)""",
      caseSensitive: false,
    ),
    CodeLanguage.javascript: RegExp(
      r"""(?<comment>//[^\n]*|/\*[\s\S]*?\*/)"""
      r"""|(?<string>'(?:[^'\\]|\\.)*'|"(?:[^"\\]|\\.)*"|`(?:[^`\\]|\\.)*`)"""
      r"""|(?<keyword>\b(?:const|let|var|function|return|if|else|for|while|do|switch|case|break|continue|new|class|extends|import|export|from|await|async|try|catch|finally|throw|typeof|instanceof|this|null|undefined|true|false|of|in)\b)"""
      r"""|(?<number>\b\d+(?:\.\d+)?\b)""",
    ),
    CodeLanguage.php: RegExp(
      r"""(?<comment>//[^\n]*|#[^\n]*|/\*[\s\S]*?\*/)"""
      r"""|(?<string>'(?:[^'\\]|\\.)*'|"(?:[^"\\]|\\.)*")"""
      r"""|(?<tag><\?php|<\?=|\?>)"""
      r"""|(?<variable>\$[A-Za-z_][A-Za-z0-9_]*)"""
      r"""|(?<keyword>\b(?:function|return|if|else|elseif|foreach|for|while|switch|case|break|continue|new|class|extends|implements|public|private|protected|static|echo|print|require|include|require_once|include_once|try|catch|finally|throw|null|true|false|array|use|namespace|isset|empty|unset|global|const|as|instanceof)\b)"""
      r"""|(?<number>\b\d+(?:\.\d+)?\b)""",
    ),
    CodeLanguage.html: RegExp(
      r"""(?<comment><!--[\s\S]*?-->)"""
      r"""|(?<tag></?[A-Za-z][A-Za-z0-9:-]*)"""
      r"""|(?<string>"[^"]*"|'[^']*')"""
      r"""|(?<keyword>\b(?:DOCTYPE|doctype)\b)""",
    ),
    CodeLanguage.css: RegExp(
      r"""(?<comment>/\*[\s\S]*?\*/)"""
      r"""|(?<atrule>\[A-Za-z-]+)"""
      r"""|(?<string>"[^"]*"|'[^']*')"""
      r"""|(?<keyword>[A-Za-z-]+(?=\s*:))"""
      r"""|(?<number>#(?:[0-9a-fA-F]{3,8})\b|\b\d+(?:\.\d+)?(?:px|em|rem|%|vh|vw|s|ms)?\b)""",
    ),
    CodeLanguage.json: RegExp(
      r"""(?<keyword>"[^"\\]*(?:\\.[^"\\]*)*"(?=\s*:))"""
      r"""|(?<string>"[^"\\]*(?:\\.[^"\\]*)*")"""
      r"""|(?<number>-?\b\d+(?:\.\d+)?(?:[eE][+-]?\d+)?\b)"""
      r"""|(?<tag>\b(?:true|false|null)\b)""",
    ),
    CodeLanguage.markdown: RegExp(
      r"""(?<keyword>^#{1,6} .*$)"""
      r"""|(?<comment>^>.*$)"""
      r"""|(?<string>`[^`]*`)"""
      r"""|(?<tag>\*\*[^*]+\*\*|__[^_]+__)"""
      r"""|(?<number>^\s*(?:[-*+]|\d+\.)\s)""",
      multiLine: true,
    ),
  };

  /// Builds the styled span for [text].
  static TextSpan buildSpan({
    required String text,
    required CodeLanguage language,
    required TextStyle baseStyle,
  }) {
    if (language == CodeLanguage.plain || text.length > maxHighlightLength) {
      return TextSpan(text: text, style: baseStyle);
    }
    final RegExp? pattern = _patterns[language];
    if (pattern == null) {
      return TextSpan(text: text, style: baseStyle);
    }
    final List<TextSpan> spans = <TextSpan>[];
    int cursor = 0;
    for (final RegExpMatch match in pattern.allMatches(text)) {
      if (match.start > cursor) {
        spans.add(TextSpan(text: text.substring(cursor, match.start)));
      }
      final String token = text.substring(match.start, match.end);
      String? group;
      for (final String candidate in <String>[
        'comment',
        'string',
        'tag',
        'variable',
        'keyword',
        'number',
        'atrule',
      ]) {
        if (match.namedGroup(candidate) != null) {
          group = candidate;
          break;
        }
      }
      final Color? color = group == null ? null : _colorFor(group);
      final FontWeight weight = group == 'keyword' || group == 'tag'
          ? FontWeight.w600
          : FontWeight.w400;
      final FontStyle fontStyle =
          group == 'comment' ? FontStyle.italic : FontStyle.normal;
      spans.add(
        TextSpan(
          text: token,
          style: TextStyle(
            color: color,
            fontWeight: weight,
            fontStyle: fontStyle,
            backgroundColor: color?.withValues(alpha: 0.06),
          ),
        ),
      );
      cursor = match.end;
    }
    if (cursor < text.length) {
      spans.add(TextSpan(text: text.substring(cursor)));
    }
    return TextSpan(style: baseStyle, children: spans);
  }

  static Color _colorFor(String group) {
    switch (group) {
      case 'comment':
        return PallSqlColors.textDisabled;
      case 'string':
        return const Color(0xFFB7E58A);
      case 'tag':
        return const Color(0xFF7FD8FF);
      case 'variable':
        return const Color(0xFFFFC46B);
      case 'keyword':
        return PallSqlColors.accent;
      case 'number':
        return const Color(0xFFE58AF0);
      case 'atrule':
        return const Color(0xFFFFC46B);
      default:
        return PallSqlColors.textPrimary;
    }
  }
}

/// [TextEditingController] that renders syntax highlighted text.
class HighlightingTextController extends TextEditingController {
  HighlightingTextController({
    required this.language,
    String? text,
    this.baseStyle = const TextStyle(),
  }) : super(text: text);

  CodeLanguage language;
  TextStyle baseStyle;

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final TextStyle effective = (style ?? baseStyle).copyWith(
      fontFamily: PallSqlColors.monoFontFamily,
    );
    return SyntaxHighlighter.buildSpan(
      text: text,
      language: language,
      baseStyle: effective,
    );
  }
}
