import 'package:flutter/material.dart';

import '../core/theme/pallsql_colors.dart';
import '../core/theme/pallsql_theme.dart';
import '../models/service_status.dart';
import 'pallsql_card.dart';
import 'status_dot.dart';

/// A service row: icon, name, live status, details and actions.
class ServerStatusCard extends StatelessWidget {
  const ServerStatusCard({
    super.key,
    required this.title,
    required this.status,
    this.icon = Icons.dns_rounded,
    this.subtitle,
    this.details = const <String>[],
    this.actions = const <Widget>[],
    this.onTap,
    this.trailing,
  });

  final String title;
  final ServiceStatus status;
  final IconData icon;
  final String? subtitle;
  final List<String> details;
  final List<Widget> actions;
  final VoidCallback? onTap;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final Color stateColor = PallSqlTheme.stateColor(status.state);
    return PallSqlCard(
      onTap: onTap,
      accentColor: stateColor,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: stateColor.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Icon(icon, size: 18, color: stateColor),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      title,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: PallSqlColors.textPrimary,
                      ),
                    ),
                    if (subtitle != null)
                      Text(
                        subtitle!,
                        style: const TextStyle(
                          fontSize: 11.5,
                          color: PallSqlColors.textSecondary,
                        ),
                      ),
                  ],
                ),
              ),
              if (trailing != null) trailing!,
              const SizedBox(width: 8),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  StatusDot(
                    state: status.state,
                    pulse: status.isRunning || status.isBusy,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    status.label,
                    style: TextStyle(
                      color: stateColor,
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.3,
                    ),
                  ),
                ],
              ),
            ],
          ),
          if (status.message != null && status.message!.isNotEmpty) ...<Widget>[
            const SizedBox(height: 10),
            Text(
              status.message!,
              style: const TextStyle(
                fontSize: 11.5,
                color: PallSqlColors.textSecondary,
                height: 1.35,
              ),
            ),
          ],
          if (details.isNotEmpty) ...<Widget>[
            const SizedBox(height: 10),
            for (final String line in details)
              Padding(
                padding: const EdgeInsets.only(bottom: 3),
                child: Text(
                  line,
                  style: const TextStyle(
                    fontSize: 11.5,
                    fontFamily: PallSqlColors.monoFontFamily,
                    color: PallSqlColors.textSecondary,
                  ),
                ),
              ),
          ],
          if (actions.isNotEmpty) ...<Widget>[
            const SizedBox(height: 14),
            Row(
              children: <Widget>[
                for (int i = 0; i < actions.length; i++) ...<Widget>[
                  if (i > 0) const SizedBox(width: 8),
                  Expanded(child: actions[i]),
                ],
              ],
            ),
          ],
        ],
      ),
    );
  }
}
