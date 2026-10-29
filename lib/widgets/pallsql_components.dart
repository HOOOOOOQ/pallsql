import 'package:flutter/material.dart';

import '../core/theme/pallsql_colors.dart';
import '../features/editor/syntax_highlighter.dart';
import '../models/log_entry.dart';
import 'code_editor_panel.dart';
import 'pallsql_card.dart';
import 'pallsql_dialogs.dart';
import 'terminal_output.dart';

/// Visual weight of a [PallSQLButton].
enum PallSQLButtonVariant {
  /// Accent filled: one per screen, for the primary action.
  primary,

  /// Neutral surface with a hairline border.
  secondary,

  /// Destructive action (delete, drop, stop).
  danger,
}

/// The standard PALLSQL button.
///
/// Only [PallSQLButtonVariant.primary] uses the accent colour; everything else
/// stays neutral so the UI does not glow.
class PallSQLButton extends StatelessWidget {
  const PallSQLButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.variant = PallSQLButtonVariant.secondary,
    this.busy = false,
    this.expand = true,
    this.compact = false,
    this.tooltip,
  });

  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;
  final PallSQLButtonVariant variant;
  final bool busy;
  final bool expand;
  final bool compact;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final bool primary = variant == PallSQLButtonVariant.primary;
    final bool danger = variant == PallSQLButtonVariant.danger;
    final Color accent = danger ? PallSqlColors.error : PallSqlColors.accent;
    final Color foreground = primary
        ? PallSqlColors.onAccent
        : (danger ? PallSqlColors.error : PallSqlColors.textPrimary);
    final Color background = primary
        ? accent
        : (danger
            ? PallSqlColors.error.withValues(alpha: 0.10)
            : PallSqlColors.surfaceMuted);
    final Color borderColor = primary
        ? Colors.transparent
        : (danger
            ? PallSqlColors.error.withValues(alpha: 0.40)
            : PallSqlColors.border);
    final double iconSize = compact ? 14 : 16;
    final double fontSize = compact ? 12 : 13;

    final Widget content = busy
        ? SizedBox(
            height: iconSize,
            width: iconSize,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: primary ? PallSqlColors.onAccent : accent,
            ),
          )
        : Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (icon != null) ...<Widget>[
                Icon(icon, size: iconSize, color: foreground),
                const SizedBox(width: 6),
              ],
              Flexible(
                child: Text(
                  label,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: foreground,
                    fontWeight: FontWeight.w600,
                    fontSize: fontSize,
                  ),
                ),
              ),
            ],
          );

    final Widget button = TextButton(
      onPressed: busy ? null : onPressed,
      style: ButtonStyle(
        backgroundColor: WidgetStatePropertyAll<Color>(background),
        foregroundColor: WidgetStatePropertyAll<Color>(foreground),
        overlayColor: WidgetStatePropertyAll<Color>(
          accent.withValues(alpha: 0.12),
        ),
        padding: WidgetStatePropertyAll<EdgeInsetsGeometry>(
          EdgeInsets.symmetric(
            horizontal: compact ? 12 : 16,
            vertical: compact ? 8 : 12,
          ),
        ),
        minimumSize: const WidgetStatePropertyAll<Size>(Size(0, 0)),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        shape: WidgetStatePropertyAll<OutlinedBorder>(
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
        side: WidgetStatePropertyAll<BorderSide>(
          BorderSide(color: borderColor),
        ),
        elevation: const WidgetStatePropertyAll<double>(0),
      ),
      child: Center(child: content),
    );

    final Widget sized =
        expand ? SizedBox(width: double.infinity, child: button) : button;
    if (tooltip == null) {
      return sized;
    }
    return Tooltip(message: tooltip!, child: sized);
  }
}

/// The standard PALLSQL text input.
class PallSQLTextField extends StatelessWidget {
  const PallSQLTextField({
    super.key,
    this.controller,
    this.label,
    this.hint,
    this.helper,
    this.maxLines = 1,
    this.monospace = false,
    this.obscure = false,
    this.enabled = true,
    this.autofocus = false,
    this.onSubmitted,
    this.onChanged,
    this.keyboardType,
    this.validator,
    this.fontSize = 13.5,
  });

  final TextEditingController? controller;
  final String? label;
  final String? hint;
  final String? helper;
  final int maxLines;
  final bool monospace;
  final bool obscure;
  final bool enabled;
  final bool autofocus;
  final ValueChanged<String>? onSubmitted;
  final ValueChanged<String>? onChanged;
  final TextInputType? keyboardType;
  final String? Function(String value)? validator;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: controller,
      obscureText: obscure,
      enabled: enabled,
      autofocus: autofocus,
      keyboardType: keyboardType,
      maxLines: obscure ? 1 : maxLines,
      onChanged: onChanged,
      onFieldSubmitted: onSubmitted,
      validator:
          validator == null ? null : (String? value) => validator!(value ?? ''),
      style: TextStyle(
        color: PallSqlColors.textPrimary,
        fontSize: fontSize,
        fontFamily: monospace ? PallSqlColors.monoFontFamily : null,
      ),
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        helperText: helper,
        helperMaxLines: 2,
        helperStyle: const TextStyle(
          color: PallSqlColors.textDisabled,
          fontSize: 10.5,
        ),
        labelStyle: const TextStyle(
          color: PallSqlColors.textSecondary,
          fontSize: 12.5,
        ),
        filled: true,
        fillColor: PallSqlColors.background,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(9),
          borderSide: const BorderSide(color: PallSqlColors.border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(9),
          borderSide: const BorderSide(color: PallSqlColors.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(9),
          borderSide: const BorderSide(color: PallSqlColors.accent),
        ),
      ),
    );
  }
}

/// Small status pill used for runtime states and engine badges.
class PallSQLStatusBadge extends StatelessWidget {
  const PallSQLStatusBadge({
    super.key,
    required this.label,
    this.color = PallSqlColors.accent,
    this.icon,
  });

  final String label;
  final Color color;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return PallSqlPill(label: label, color: color, icon: icon);
  }
}

/// Branded, bounded loading indicator with a caption.
class PallSQLLoading extends StatelessWidget {
  const PallSQLLoading({
    super.key,
    this.message,
    this.progress,
    this.compact = false,
  });

  final String? message;

  /// 0..1 for a determinate bar; `null` shows an indeterminate spinner.
  final double? progress;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final double size = compact ? 16 : 22;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (progress == null)
          SizedBox(
            height: size,
            width: size,
            child: const CircularProgressIndicator(
              strokeWidth: 2,
              color: PallSqlColors.accent,
            ),
          )
        else
          SizedBox(
            width: compact ? 120 : 180,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(999),
              child: LinearProgressIndicator(
                value: progress!.clamp(0.0, 1.0),
                minHeight: compact ? 3 : 4,
                backgroundColor: PallSqlColors.surfaceMuted,
                valueColor:
                    const AlwaysStoppedAnimation<Color>(PallSqlColors.accent),
              ),
            ),
          ),
        if (message != null) ...<Widget>[
          SizedBox(height: compact ? 6 : 10),
          Text(
            message!,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: compact ? 11 : 12,
              color: PallSqlColors.textSecondary,
            ),
          ),
        ],
      ],
    );
  }
}

/// Read-only monospace output panel (terminal, console, query log).
class PallSQLTerminal extends StatelessWidget {
  const PallSQLTerminal({
    super.key,
    required this.lines,
    this.emptyMessage = 'No output yet',
    this.autoScroll = true,
  });

  final List<LogEntry> lines;
  final String emptyMessage;
  final bool autoScroll;

  @override
  Widget build(BuildContext context) {
    return TerminalOutput(
      lines: lines,
      emptyMessage: emptyMessage,
      autoScroll: autoScroll,
    );
  }
}

/// Thin, documented wrapper around [CodeEditorPanel] so callers use one name.
class PallSQLCodeEditor extends StatelessWidget {
  const PallSQLCodeEditor({
    super.key,
    required this.controller,
    required this.language,
    this.fontSize = 13,
    this.showLineNumbers = true,
    this.wordWrap = false,
    this.readOnly = false,
    this.focusNode,
    this.onChanged,
    this.hintText = 'Start typing...',
  });

  final HighlightingTextController controller;
  final CodeLanguage language;
  final double fontSize;
  final bool showLineNumbers;
  final bool wordWrap;
  final bool readOnly;
  final FocusNode? focusNode;
  final ValueChanged<String>? onChanged;
  final String hintText;

  @override
  Widget build(BuildContext context) {
    return CodeEditorPanel(
      controller: controller,
      language: language,
      fontSize: fontSize,
      showLineNumbers: showLineNumbers,
      wordWrap: wordWrap,
      readOnly: readOnly,
      focusNode: focusNode,
      onChanged: onChanged,
      hintText: hintText,
    );
  }
}

/// Shared dialog entry points.
///
/// Every PALLSQL dialog goes through these so colours, radius and the busy
/// state stay consistent.
class PallSQLDialog {
  const PallSQLDialog._();

  /// Single line text prompt with validation.
  static Future<String?> prompt({
    required BuildContext context,
    required String title,
    required String label,
    String? message,
    String initialValue = '',
    String confirmLabel = 'Save',
    String? Function(String value)? validator,
    int maxLines = 1,
    TextInputType? keyboardType,
  }) {
    return showPromptDialog(
      context: context,
      title: title,
      label: label,
      message: message,
      initialValue: initialValue,
      confirmLabel: confirmLabel,
      validator: validator,
      maxLines: maxLines,
      keyboardType: keyboardType,
    );
  }

  /// Destructive / irreversible confirmation.
  static Future<bool> confirm({
    required BuildContext context,
    required String title,
    required String message,
    String confirmLabel = 'Confirm',
    bool destructive = false,
  }) {
    return showConfirmDialog(
      context: context,
      title: title,
      message: message,
      confirmLabel: confirmLabel,
      destructive: destructive,
    );
  }

  /// Informational sheet with a single close action.
  static Future<void> info({
    required BuildContext context,
    required String title,
    required String message,
  }) async {
    await showDialog<void>(
      context: context,
      builder: (BuildContext dialogContext) {
        return AlertDialog(
          backgroundColor: PallSqlColors.surfaceElevated,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
            side: const BorderSide(color: PallSqlColors.border),
          ),
          title: Text(
            title,
            style: const TextStyle(
              color: PallSqlColors.textPrimary,
              fontSize: 15,
              fontWeight: FontWeight.w700,
            ),
          ),
          content: SingleChildScrollView(
            child: Text(
              message,
              style: const TextStyle(
                color: PallSqlColors.textSecondary,
                fontSize: 12.5,
                height: 1.5,
              ),
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Close'),
            ),
          ],
        );
      },
    );
  }
}
