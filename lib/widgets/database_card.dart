import 'package:flutter/material.dart';

import '../core/theme/pallsql_colors.dart';
import '../core/utils/formatters.dart';
import '../models/database_models.dart';
import 'pallsql_card.dart';

/// Summary row for a SQLite database file.
class DatabaseCard extends StatelessWidget {
  const DatabaseCard({
    super.key,
    required this.database,
    this.onTap,
    this.onDelete,
    this.onBackup,
    this.isActive = false,
  });

  final DatabaseInfo database;
  final VoidCallback? onTap;
  final VoidCallback? onDelete;
  final VoidCallback? onBackup;
  final bool isActive;

  @override
  Widget build(BuildContext context) {
    return PallSqlCard(
      onTap: onTap,
      accentColor: isActive ? PallSqlColors.accent : null,
      padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
      child: Row(
        children: <Widget>[
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: PallSqlColors.accentMuted,
              borderRadius: BorderRadius.circular(9),
            ),
            child: const Icon(
              Icons.storage_rounded,
              size: 17,
              color: PallSqlColors.accent,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Flexible(
                      child: Text(
                        database.name,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w600,
                          color: PallSqlColors.textPrimary,
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    const PallSqlPill(
                        label: 'SQLite', icon: Icons.memory_rounded),
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  '${Formatters.bytes(database.sizeBytes)}'
                  '${database.tableCount == null ? '' : ' - ${Formatters.count(database.tableCount!, 'table')}'}'
                  ' - ${Formatters.dateTime(database.modifiedAt)}',
                  style: const TextStyle(
                    fontSize: 11,
                    color: PallSqlColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          if (onBackup != null)
            IconButton(
              tooltip: 'Back up',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.save_alt_rounded, size: 17),
              onPressed: onBackup,
            ),
          if (onDelete != null)
            IconButton(
              tooltip: 'Delete database',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.delete_outline_rounded, size: 17),
              color: PallSqlColors.error,
              onPressed: onDelete,
            ),
        ],
      ),
    );
  }
}

/// Card that explains the active database engine honestly.
class EngineCard extends StatelessWidget {
  const EngineCard({
    super.key,
    required this.availability,
    this.trailing,
  });

  final EngineAvailability availability;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final bool available = availability.available;
    final Color color =
        available ? PallSqlColors.success : PallSqlColors.warning;
    return PallSqlCard(
      accentColor: available ? null : PallSqlColors.warning,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              PallSqlPill(
                label: availability.engine.label,
                color: color,
                icon: Icons.storage_rounded,
              ),
              const SizedBox(width: 8),
              PallSqlPill(
                label: available ? 'Available' : 'Not available',
                color: color,
              ),
              const Spacer(),
              if (trailing != null) trailing!,
            ],
          ),
          const SizedBox(height: 10),
          Text(
            availability.engine.storageDescription,
            style: const TextStyle(
              fontSize: 12,
              color: PallSqlColors.textSecondary,
              height: 1.4,
            ),
          ),
          if (availability.version != null) ...<Widget>[
            const SizedBox(height: 6),
            Text(
              'Engine version ${availability.version}',
              style: const TextStyle(
                fontSize: 11.5,
                fontFamily: PallSqlColors.monoFontFamily,
                color: PallSqlColors.textPrimary,
              ),
            ),
          ],
          if (availability.reason != null) ...<Widget>[
            const SizedBox(height: 8),
            Text(
              availability.reason!,
              style: TextStyle(
                fontSize: 11.5,
                color: available
                    ? PallSqlColors.textSecondary
                    : PallSqlColors.warning,
                height: 1.4,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
