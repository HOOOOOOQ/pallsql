import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/theme/pallsql_colors.dart';
import '../features/editor/syntax_highlighter.dart';

/// Code editing surface with an optional line-number gutter.
///
/// The gutter and the text field share one scroll view so line numbers always
/// stay aligned. Highlighting is provided by [HighlightingTextController].
class CodeEditorPanel extends StatefulWidget {
  const CodeEditorPanel({
    super.key,
    required this.controller,
    required this.language,
    this.fontSize = 13,
    this.showLineNumbers = true,
    this.wordWrap = false,
    this.readOnly = false,
    this.onChanged,
    this.focusNode,
    this.hintText = 'Start typing...',
  });

  final HighlightingTextController controller;
  final CodeLanguage language;
  final double fontSize;
  final bool showLineNumbers;
  final bool wordWrap;
  final bool readOnly;
  final ValueChanged<String>? onChanged;
  final FocusNode? focusNode;
  final String hintText;

  @override
  State<CodeEditorPanel> createState() => _CodeEditorPanelState();
}

class _CodeEditorPanelState extends State<CodeEditorPanel> {
  @override
  void initState() {
    super.initState();
    widget.controller.language = widget.language;
    widget.controller.addListener(_handleTextChanged);
  }

  @override
  void didUpdateWidget(covariant CodeEditorPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_handleTextChanged);
      widget.controller.addListener(_handleTextChanged);
    }
    widget.controller.language = widget.language;
  }

  @override
  void dispose() {
    widget.controller.removeListener(_handleTextChanged);
    super.dispose();
  }

  void _handleTextChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  double get _lineHeight => widget.fontSize * 1.45;

  int _lineCount(String text) {
    if (text.isEmpty) {
      return 1;
    }
    int lines = 1;
    for (int i = 0; i < text.length; i++) {
      if (text.codeUnitAt(i) == 10) {
        lines++;
      }
    }
    return lines;
  }

  int _longestLine(String text) {
    int longest = 0;
    int current = 0;
    for (int i = 0; i < text.length; i++) {
      if (text.codeUnitAt(i) == 10) {
        longest = math.max(longest, current);
        current = 0;
      } else {
        current++;
      }
    }
    return math.max(longest, current);
  }

  @override
  Widget build(BuildContext context) {
    final TextStyle textStyle = TextStyle(
      fontFamily: PallSqlColors.monoFontFamily,
      fontSize: widget.fontSize,
      height: 1.45,
      color: PallSqlColors.textPrimary,
      letterSpacing: 0,
    );
    widget.controller.baseStyle = textStyle;
    final String text = widget.controller.text;
    final int lineCount = _lineCount(text);
    final Widget gutter = Padding(
      padding: const EdgeInsets.only(left: 8, right: 8, top: 10, bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: <Widget>[
          for (int line = 1; line <= lineCount; line++)
            SizedBox(
              height: _lineHeight,
              child: Text(
                '$line',
                textAlign: TextAlign.right,
                style: TextStyle(
                  fontFamily: PallSqlColors.monoFontFamily,
                  fontSize: widget.fontSize,
                  height: 1.45,
                  color: PallSqlColors.textDisabled,
                ),
              ),
            ),
        ],
      ),
    );
    final Widget field = TextField(
      controller: widget.controller,
      focusNode: widget.focusNode,
      readOnly: widget.readOnly,
      maxLines: null,
      keyboardType: TextInputType.multiline,
      textAlignVertical: TextAlignVertical.top,
      style: textStyle,
      onChanged: widget.onChanged,
      cursorColor: PallSqlColors.accent,
      decoration: InputDecoration(
        isDense: true,
        border: InputBorder.none,
        hintText: widget.hintText,
        hintStyle: const TextStyle(color: PallSqlColors.textDisabled),
        contentPadding: const EdgeInsets.only(top: 10, bottom: 10, right: 12),
      ),
    );

    return Container(
      decoration: BoxDecoration(
        color: PallSqlColors.background,
        border: Border.all(color: PallSqlColors.border),
        borderRadius: BorderRadius.circular(10),
      ),
      clipBehavior: Clip.antiAlias,
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final double gutterWidth = widget.showLineNumbers
              ? (18 + widget.fontSize * 0.62 * lineCount.toString().length)
              : 0;
          final double available = math.max(
            120,
            constraints.maxWidth - gutterWidth - 12,
          );
          final double contentWidth = widget.wordWrap
              ? available
              : math.max(
                  available,
                  _longestLine(text) * widget.fontSize * 0.62 + 24,
                );
          final Widget row = Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              if (widget.showLineNumbers)
                SizedBox(
                  width: gutterWidth,
                  child: ColoredBox(
                    color: PallSqlColors.surface,
                    child: gutter,
                  ),
                ),
              SizedBox(
                width: contentWidth,
                child: field,
              ),
            ],
          );
          return SingleChildScrollView(
            child: widget.wordWrap
                ? row
                : SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: row,
                  ),
          );
        },
      ),
    );
  }
}
