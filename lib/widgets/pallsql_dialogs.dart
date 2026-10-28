import 'package:flutter/material.dart';

import '../core/theme/pallsql_colors.dart';

/// Modal text prompt used for names, ports and SQL snippets.
Future<String?> showPromptDialog({
  required BuildContext context,
  required String title,
  required String label,
  String? message,
  String initialValue = '',
  String confirmLabel = 'Save',
  String? Function(String value)? validator,
  int maxLines = 1,
  bool obscure = false,
  TextInputType? keyboardType,
}) async {
  final String? result = await showDialog<String>(
    context: context,
    builder: (BuildContext dialogContext) {
      return _PromptDialog(
        title: title,
        label: label,
        message: message,
        initialValue: initialValue,
        confirmLabel: confirmLabel,
        validator: validator,
        maxLines: maxLines,
        obscure: obscure,
        keyboardType: keyboardType,
      );
    },
  );
  return result;
}

/// Standard destructive confirmation dialog.
Future<bool> showConfirmDialog({
  required BuildContext context,
  required String title,
  required String message,
  String confirmLabel = 'Confirm',
  String cancelLabel = 'Cancel',
  bool destructive = false,
}) async {
  final bool? result = await showDialog<bool>(
    context: context,
    builder: (BuildContext dialogContext) {
      return AlertDialog(
        backgroundColor: PallSqlColors.surfaceElevated,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        title: Text(
          title,
          style: const TextStyle(
            color: PallSqlColors.textPrimary,
            fontSize: 16,
            fontWeight: FontWeight.w700,
          ),
        ),
        content: Text(
          message,
          style: const TextStyle(
            color: PallSqlColors.textSecondary,
            fontSize: 13,
            height: 1.45,
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            style: TextButton.styleFrom(
              foregroundColor: PallSqlColors.textSecondary,
            ),
            child: Text(cancelLabel),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor:
                  destructive ? PallSqlColors.error : PallSqlColors.accent,
              foregroundColor:
                  destructive ? Colors.white : const Color(0xFF07130A),
            ),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(confirmLabel),
          ),
        ],
      );
    },
  );
  return result ?? false;
}

/// Shows a short status message above the bottom navigation.
void showPallSqlSnack(
  ScaffoldMessengerState messenger,
  String message, {
  bool error = false,
}) {
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        duration: Duration(seconds: error ? 4 : 2),
        backgroundColor:
            error ? PallSqlColors.error.withValues(alpha: 0.95) : null,
        content: Text(
          message,
          style: TextStyle(
            fontSize: 12.5,
            color: error ? Colors.white : PallSqlColors.textPrimary,
          ),
        ),
      ),
    );
}

class _PromptDialog extends StatefulWidget {
  const _PromptDialog({
    required this.title,
    required this.label,
    required this.confirmLabel,
    required this.initialValue,
    required this.maxLines,
    required this.obscure,
    this.message,
    this.validator,
    this.keyboardType,
  });

  final String title;
  final String label;
  final String confirmLabel;
  final String initialValue;
  final int maxLines;
  final bool obscure;
  final String? message;
  final String? Function(String value)? validator;
  final TextInputType? keyboardType;

  @override
  State<_PromptDialog> createState() => _PromptDialogState();
}

class _PromptDialogState extends State<_PromptDialog> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initialValue);
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    if (_formKey.currentState?.validate() ?? false) {
      Navigator.of(context).pop(_controller.text.trim());
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: PallSqlColors.surfaceElevated,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      title: Text(
        widget.title,
        style: const TextStyle(
          color: PallSqlColors.textPrimary,
          fontSize: 16,
          fontWeight: FontWeight.w700,
        ),
      ),
      content: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            if (widget.message != null) ...<Widget>[
              Text(
                widget.message!,
                style: const TextStyle(
                  color: PallSqlColors.textSecondary,
                  fontSize: 12.5,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 12),
            ],
            TextFormField(
              controller: _controller,
              autofocus: true,
              obscureText: widget.obscure,
              keyboardType: widget.keyboardType,
              maxLines: widget.maxLines,
              style: const TextStyle(
                color: PallSqlColors.textPrimary,
                fontSize: 13.5,
              ),
              decoration: InputDecoration(
                labelText: widget.label,
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
              validator: (String? value) {
                final String? check = widget.validator?.call(value ?? '');
                return check;
              },
              onFieldSubmitted: widget.maxLines == 1 ? (_) => _submit() : null,
            ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          style: TextButton.styleFrom(
            foregroundColor: PallSqlColors.textSecondary,
          ),
          child: const Text('Cancel'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: PallSqlColors.accent,
            foregroundColor: const Color(0xFF07130A),
          ),
          onPressed: _submit,
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }
}
