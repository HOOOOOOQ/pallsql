import 'package:flutter/material.dart';

import '../core/theme/pallsql_colors.dart';

/// One destination of the PALLSQL bottom navigation.
class PallSQLNavItem {
  const PallSQLNavItem({required this.label, required this.icon});

  final String label;
  final IconData icon;
}

/// Custom Material 3 style bottom navigation bar.
class PallSQLBottomNavigation extends StatelessWidget {
  const PallSQLBottomNavigation({
    super.key,
    required this.items,
    required this.currentIndex,
    required this.onSelected,
  });

  final List<PallSQLNavItem> items;
  final int currentIndex;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: PallSqlColors.surface,
        border: Border(top: BorderSide(color: PallSqlColors.border)),
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 60,
          child: Row(
            children: <Widget>[
              for (int index = 0; index < items.length; index++)
                Expanded(
                  child: _NavButton(
                    item: items[index],
                    selected: index == currentIndex,
                    onTap: () => onSelected(index),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NavButton extends StatelessWidget {
  const _NavButton({
    required this.item,
    required this.selected,
    required this.onTap,
  });

  final PallSQLNavItem item;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final Color color =
        selected ? PallSqlColors.accent : PallSqlColors.textSecondary;
    return InkWell(
      onTap: onTap,
      splashColor: PallSqlColors.accent.withValues(alpha: 0.06),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 3),
            decoration: BoxDecoration(
              color: selected
                  ? PallSqlColors.accent.withValues(alpha: 0.12)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(999),
            ),
            child: Icon(item.icon, size: 19, color: color),
          ),
          const SizedBox(height: 3),
          Text(
            item.label,
            style: TextStyle(
              fontSize: 10,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
              color: color,
              letterSpacing: 0.2,
            ),
          ),
        ],
      ),
    );
  }
}
