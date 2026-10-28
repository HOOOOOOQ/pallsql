import 'package:flutter/material.dart';

import '../core/theme/pallsql_colors.dart';

/// Primary or secondary action button with a built-in busy state.
class ServiceControlButton extends StatelessWidget {
  const ServiceControlButton({
    super.key,
    required this.label,
    required this.icon,
    required this.onPressed,
    this.busy = false,
    this.filled = false,
    this.destructive = false,
    this.expand = true,
    this.compact = false,
  });

  final String label;
  final IconData icon;
  final VoidCallback? onPressed;
  final bool busy;
  final bool filled;
  final bool destructive;
  final bool expand;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final Color accent = destructive ? PallSqlColors.error : PallSqlColors.accent;
    final Color foreground =
        filled ? const Color(0xFF07130A) : (destructive ? accent : PallSqlColors.textPrimary);
    final EdgeInsetsGeometry padding = EdgeInsets.symmetric(
      horizontal: compact ? 12 : 16,
      vertical: compact ? 8 : 12,
    );
    final Widget content = busy
        ? SizedBox(
            height: compact ? 14 : 16,
            width: compact ? 14 : 16,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: filled ? const Color(0xFF07130A) : PallSqlColors.accent,
            ),
          )
        : Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(icon, size: compact ? 14 : 16, color: foreground),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  label,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: foreground,
                    fontWeight: FontWeight.w600,
                    fontSize: compact ? 12 : 13,
                  ),
                ),
              ),
            ],
          );
    final ButtonStyle style = ButtonStyle(
      backgroundColor: WidgetStatePropertyAll<Color>(
        filled
            ? accent
            : (destructive
                ? PallSqlColors.error.withValues(alpha: 0.08)
                : PallSqlColors.surfaceMuted),
      ),
      foregroundColor: WidgetStatePropertyAll<Color>(foreground),
      overlayColor: WidgetStatePropertyAll<Color>(
        accent.withValues(alpha: 0.12),
      ),
      padding: WidgetStatePropertyAll<EdgeInsetsGeometry>(padding),
      minimumSize: const WidgetStatePropertyAll<Size>(Size(0, 0)),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      shape: WidgetStatePropertyAll<OutlinedBorder>(
        RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
      ),
      side: WidgetStatePropertyAll<BorderSide>(
        BorderSide(
          color: filled
              ? Colors.transparent
              : (destructive
                  ? PallSqlColors.error.withValues(alpha: 0.35)
                  : PallSqlColors.border),
        ),
      ),
      elevation: const WidgetStatePropertyAll<double>(0),
    );
    final Widget button = TextButton(
      style: style,
      onPressed: busy ? null : onPressed,
      child: Center(child: content),
    );
    return expand ? SizedBox(width: double.infinity, child: button) : button;
  }
}
