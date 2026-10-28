import 'package:flutter/material.dart';

import '../core/theme/pallsql_colors.dart';
import '../core/theme/pallsql_theme.dart';
import '../models/service_status.dart';

/// Coloured status indicator with an optional pulse for running services.
class StatusDot extends StatelessWidget {
  const StatusDot({
    super.key,
    this.state,
    this.color,
    this.size = 8,
    this.pulse = false,
  });

  final ServiceState? state;
  final Color? color;
  final double size;
  final bool pulse;

  @override
  Widget build(BuildContext context) {
    final Color resolved = color ??
        (state == null ? PallSqlColors.stopped : PallSqlTheme.stateColor(state!));
    if (!pulse) {
      return _dot(resolved);
    }
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0.55, end: 1),
      duration: const Duration(milliseconds: 1400),
      builder: (BuildContext context, double value, Widget? child) {
        return Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: resolved.withValues(alpha: value),
            boxShadow: <BoxShadow>[
              BoxShadow(
                color: resolved.withValues(alpha: 0.35 * value),
                blurRadius: size * 1.6,
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _dot(Color resolved) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: resolved,
        boxShadow: <BoxShadow>[
          BoxShadow(color: resolved.withValues(alpha: 0.35), blurRadius: size),
        ],
      ),
    );
  }
}
