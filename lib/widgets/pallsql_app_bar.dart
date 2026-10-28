import 'package:flutter/material.dart';

import '../core/constants/app_info.dart';
import '../core/theme/pallsql_colors.dart';

/// Branded app bar with the PALLSQL wordmark.
class PallSQLAppBar extends StatelessWidget implements PreferredSizeWidget {
  const PallSQLAppBar({
    super.key,
    required this.title,
    this.subtitle,
    this.actions,
    this.showBack = false,
    this.showLogo = false,
    this.bottom,
  });

  final String title;
  final String? subtitle;
  final List<Widget>? actions;
  final bool showBack;
  final bool showLogo;
  final PreferredSizeWidget? bottom;

  @override
  Size get preferredSize => Size.fromHeight(
        64 + (bottom?.preferredSize.height ?? 0),
      );

  @override
  Widget build(BuildContext context) {
    return AppBar(
      automaticallyImplyLeading: false,
      leadingWidth: showBack ? 52 : (showLogo ? 52 : 0),
      leading: showBack
          ? IconButton(
              tooltip: 'Back',
              icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 18),
              onPressed: () => Navigator.of(context).maybePop(),
            )
          : (showLogo
              ? const Padding(
                  padding: EdgeInsets.only(left: 14),
                  child: Center(child: PallSqlLogoMark(size: 26)),
                )
              : null),
      titleSpacing: showBack || showLogo ? 4 : 16,
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          Text(
            title,
            style: const TextStyle(
              fontSize: 16.5,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.2,
              color: PallSqlColors.textPrimary,
            ),
          ),
          if (subtitle != null)
            Padding(
              padding: const EdgeInsets.only(top: 1),
              child: Text(
                subtitle!,
                style: const TextStyle(
                  fontSize: 11,
                  color: PallSqlColors.textSecondary,
                  fontWeight: FontWeight.w400,
                ),
              ),
            ),
        ],
      ),
      actions: actions,
      bottom: bottom,
    );
  }
}

/// The PALLSQL logo mark: a neon database glyph inside a rounded square.
class PallSqlLogoMark extends StatelessWidget {
  const PallSqlLogoMark({super.key, this.size = 32});

  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: PallSqlColors.accentMuted,
        borderRadius: BorderRadius.circular(size * 0.28),
        border: Border.all(color: PallSqlColors.accent.withValues(alpha: 0.5)),
      ),
      child: Icon(
        Icons.storage_rounded,
        size: size * 0.55,
        color: PallSqlColors.accent,
      ),
    );
  }
}

/// Branded wordmark block used on the dashboard.
class PallSqlWordmark extends StatelessWidget {
  const PallSqlWordmark({super.key, this.compact = false});

  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        PallSqlLogoMark(size: compact ? 34 : 44),
        const SizedBox(width: 12),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              AppInfo.appName,
              style: TextStyle(
                fontSize: compact ? 18 : 22,
                fontWeight: FontWeight.w800,
                letterSpacing: 2,
                color: PallSqlColors.textPrimary,
              ),
            ),
            Text(
              'v${AppInfo.version} - local environment',
              style: const TextStyle(
                fontSize: 11,
                color: PallSqlColors.textSecondary,
                letterSpacing: 0.3,
              ),
            ),
          ],
        ),
      ],
    );
  }
}
