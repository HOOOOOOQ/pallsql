import 'package:flutter/material.dart';

import '../core/theme/pallsql_colors.dart';
import '../core/utils/formatters.dart';
import '../models/project.dart';
import 'pallsql_card.dart';

/// Project summary with the actions available from the projects list.
class ProjectCard extends StatelessWidget {
  const ProjectCard({
    super.key,
    required this.project,
    this.isActive = false,
    this.onOpen,
    this.onRun,
    this.onDuplicate,
    this.onExport,
    this.onDelete,
  });

  final Project project;
  final bool isActive;
  final VoidCallback? onOpen;
  final VoidCallback? onRun;
  final VoidCallback? onDuplicate;
  final VoidCallback? onExport;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    return PallSqlCard(
      onTap: onOpen,
      accentColor: isActive ? PallSqlColors.accent : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              const Icon(
                Icons.folder_special_rounded,
                size: 18,
                color: PallSqlColors.accent,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  project.name,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: PallSqlColors.textPrimary,
                  ),
                ),
              ),
              if (isActive)
                const PallSqlPill(
                    label: 'Serving', icon: Icons.play_arrow_rounded),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            project.description.isEmpty
                ? 'projects/${project.directory}'
                : project.description,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 11.5,
              color: PallSqlColors.textSecondary,
              height: 1.35,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'updated ${Formatters.relativeTime(project.updatedAt)} - '
            'projects/${project.directory}',
            style: const TextStyle(
              fontSize: 10.5,
              fontFamily: PallSqlColors.monoFontFamily,
              color: PallSqlColors.textDisabled,
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              if (onOpen != null)
                _ProjectAction(
                  icon: Icons.folder_open_rounded,
                  label: 'Files',
                  onPressed: onOpen!,
                ),
              if (onRun != null)
                _ProjectAction(
                  icon: Icons.play_circle_outline_rounded,
                  label: isActive ? 'Serving' : 'Serve',
                  onPressed: onRun!,
                ),
              if (onDuplicate != null)
                _ProjectAction(
                  icon: Icons.copy_rounded,
                  label: 'Copy',
                  onPressed: onDuplicate!,
                ),
              if (onExport != null)
                _ProjectAction(
                  icon: Icons.ios_share_rounded,
                  label: 'Export',
                  onPressed: onExport!,
                ),
              if (onDelete != null)
                _ProjectAction(
                  icon: Icons.delete_outline_rounded,
                  label: 'Delete',
                  onPressed: onDelete!,
                  destructive: true,
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ProjectAction extends StatelessWidget {
  const _ProjectAction({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.destructive = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final Color color =
        destructive ? PallSqlColors.error : PallSqlColors.textSecondary;
    return TextButton.icon(
      onPressed: onPressed,
      icon: Icon(icon, size: 14, color: color),
      label: Text(
        label,
        style: TextStyle(fontSize: 11.5, color: color),
      ),
      style: TextButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        minimumSize: Size.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        backgroundColor: PallSqlColors.surfaceMuted,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    );
  }
}
