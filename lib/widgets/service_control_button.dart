import 'package:flutter/material.dart';

import 'pallsql_components.dart';

/// Primary or secondary action button with a built-in busy state.
///
/// Kept as a thin alias of [PallSQLButton] so existing screens (and tests) keep
/// working while every button in the app shares one implementation.
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
    return PallSQLButton(
      label: label,
      icon: icon,
      busy: busy,
      expand: expand,
      compact: compact,
      onPressed: onPressed,
      variant: destructive
          ? PallSQLButtonVariant.danger
          : (filled ? PallSQLButtonVariant.primary : PallSQLButtonVariant.secondary),
    );
  }
}
