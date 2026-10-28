import 'package:flutter/material.dart';

import '../core/theme/pallsql_colors.dart';
import '../core/utils/formatters.dart';
import '../models/database_models.dart';

/// Renders a [QueryResult] as a horizontally scrollable table.
class QueryResultView extends StatelessWidget {
  const QueryResultView({
    super.key,
    required this.result,
    this.maxHeight = 320,
    this.columnWidth = 140,
  });

  final QueryResult result;
  final double maxHeight;
  final double columnWidth;

  @override
  Widget build(BuildContext context) {
    if (result.isError) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: PallSqlColors.error.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(10),
          border:
              Border.all(color: PallSqlColors.error.withValues(alpha: 0.35)),
        ),
        child: SelectableText(
          result.error!,
          style: const TextStyle(
            fontFamily: PallSqlColors.monoFontFamily,
            fontSize: 11.5,
            height: 1.4,
            color: PallSqlColors.error,
          ),
        ),
      );
    }
    if (!result.hasResultSet) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: PallSqlColors.surface,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: PallSqlColors.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              '${result.statements} statement(s) in '
              '${Formatters.duration(result.duration)}',
              style: const TextStyle(
                fontSize: 11.5,
                color: PallSqlColors.textPrimary,
                fontFamily: PallSqlColors.monoFontFamily,
              ),
            ),
            if (result.rowsAffected > 0)
              Text(
                '${result.rowsAffected} row(s) affected',
                style: const TextStyle(
                  fontSize: 11,
                  color: PallSqlColors.textSecondary,
                ),
              ),
            if (result.lastInsertRowId != null)
              Text(
                'last insert rowid: ${result.lastInsertRowId}',
                style: const TextStyle(
                  fontSize: 11,
                  color: PallSqlColors.textSecondary,
                ),
              ),
            for (final String notice in result.notices.take(6))
              Padding(
                padding: const EdgeInsets.only(top: 3),
                child: Text(
                  notice,
                  style: const TextStyle(
                    fontSize: 10.5,
                    color: PallSqlColors.textDisabled,
                  ),
                ),
              ),
          ],
        ),
      );
    }
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: PallSqlColors.border),
        borderRadius: BorderRadius.circular(10),
        color: PallSqlColors.background,
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SizedBox(
              width: result.columns.length * columnWidth,
              child: Container(
                color: PallSqlColors.surfaceElevated,
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Row(
                  children: <Widget>[
                    for (final String column in result.columns)
                      SizedBox(
                        width: columnWidth,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          child: Text(
                            column,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 10.5,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.4,
                              color: PallSqlColors.accent,
                              fontFamily: PallSqlColors.monoFontFamily,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
          SizedBox(
            height: maxHeight,
            child: result.rows.isEmpty
                ? const Center(
                    child: Text(
                      '0 rows',
                      style: TextStyle(
                        color: PallSqlColors.textDisabled,
                        fontSize: 12,
                      ),
                    ),
                  )
                : SingleChildScrollView(
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          for (final List<String?> row in result.rows)
                            Container(
                              decoration: const BoxDecoration(
                                border: Border(
                                  bottom:
                                      BorderSide(color: PallSqlColors.border),
                                ),
                              ),
                              child: Row(
                                children: <Widget>[
                                  for (final String? cell in row)
                                    SizedBox(
                                      width: columnWidth,
                                      child: Padding(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 8,
                                          vertical: 7,
                                        ),
                                        child: Text(
                                          cell ?? 'NULL',
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            fontSize: 11,
                                            fontFamily:
                                                PallSqlColors.monoFontFamily,
                                            color: cell == null
                                                ? PallSqlColors.textDisabled
                                                : PallSqlColors.textPrimary,
                                            fontStyle: cell == null
                                                ? FontStyle.italic
                                                : FontStyle.normal,
                                          ),
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
          ),
          Container(
            width: double.infinity,
            color: PallSqlColors.surface,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            child: Text(
              '${Formatters.count(result.rowCount, 'row')} - '
              '${Formatters.duration(result.duration)}',
              style: const TextStyle(
                fontSize: 10.5,
                color: PallSqlColors.textSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
