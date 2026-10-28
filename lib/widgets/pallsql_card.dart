import 'package:flutter/material.dart';

import '../core/theme/pallsql_colors.dart';

/// The standard PALLSQL surface: near-black card with a hairline border.
class PallSqlCard extends StatelessWidget {
  const PallSqlCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.onTap,
    this.accentColor,
    this.margin = EdgeInsets.zero,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final VoidCallback? onTap;
  final Color? accentColor;
  final EdgeInsetsGeometry margin;

  @override
  Widget build(BuildContext context) {
    final BorderRadius radius = BorderRadius.circular(14);
    return Padding(
      padding: margin,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: PallSqlColors.surface,
          borderRadius: radius,
          border: Border.all(
            color: accentColor?.withValues(alpha: 0.45) ?? PallSqlColors.border,
          ),
        ),
        child: Material(
          color: Colors.transparent,
          borderRadius: radius,
          child: InkWell(
            onTap: onTap,
            borderRadius: radius,
            splashColor: PallSqlColors.accent.withValues(alpha: 0.06),
            highlightColor: PallSqlColors.accent.withValues(alpha: 0.04),
            child: Padding(padding: padding, child: child),
          ),
        ),
      ),
    );
  }
}

/// Section label used above lists and cards.
class PallSqlSectionHeader extends StatelessWidget {
  const PallSqlSectionHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.trailing,
  });

  final String title;
  final String? subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10, top: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  title.toUpperCase(),
                  style: const TextStyle(
                    color: PallSqlColors.textSecondary,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.6,
                  ),
                ),
                if (subtitle != null) ...<Widget>[
                  const SizedBox(height: 2),
                  Text(
                    subtitle!,
                    style: const TextStyle(
                      color: PallSqlColors.textDisabled,
                      fontSize: 12,
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}

/// Compact label/value pair used across detail screens.
class PallSqlKeyValue extends StatelessWidget {
  const PallSqlKeyValue({
    super.key,
    required this.label,
    required this.value,
    this.monospace = false,
    this.valueColor,
    this.maxLines = 3,
  });

  final String label;
  final String value;
  final bool monospace;
  final Color? valueColor;
  final int maxLines;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 118,
            child: Text(
              label,
              style: const TextStyle(
                color: PallSqlColors.textSecondary,
                fontSize: 12.5,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              maxLines: maxLines,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: valueColor ?? PallSqlColors.textPrimary,
                fontSize: 12.5,
                fontFamily: monospace ? PallSqlColors.monoFontFamily : null,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Empty placeholder with an optional call to action.
class PallSqlEmptyState extends StatelessWidget {
  const PallSqlEmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.message,
    this.action,
  });

  final IconData icon;
  final String title;
  final String? message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 32, horizontal: 16),
      child: Column(
        children: <Widget>[
          Icon(icon, size: 34, color: PallSqlColors.textDisabled),
          const SizedBox(height: 12),
          Text(
            title,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: PallSqlColors.textPrimary,
              fontWeight: FontWeight.w600,
              fontSize: 14,
            ),
          ),
          if (message != null) ...<Widget>[
            const SizedBox(height: 6),
            Text(
              message!,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: PallSqlColors.textSecondary,
                fontSize: 12.5,
                height: 1.4,
              ),
            ),
          ],
          if (action != null) ...<Widget>[
            const SizedBox(height: 16),
            action!,
          ],
        ],
      ),
    );
  }
}

/// Small pill used for engine badges and tags.
class PallSqlPill extends StatelessWidget {
  const PallSqlPill({
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
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (icon != null) ...<Widget>[
            Icon(icon, size: 11, color: color),
            const SizedBox(width: 4),
          ],
          Flexible(
            child: Text(
              label.toUpperCase(),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: color,
                fontSize: 9.5,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.1,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
