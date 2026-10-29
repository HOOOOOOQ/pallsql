import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants/app_info.dart';
import '../../core/theme/pallsql_colors.dart';
import '../../providers/app_providers.dart';
import '../../widgets/pallsql_app_bar.dart';
import '../../widgets/pallsql_card.dart';
import '../../widgets/pallsql_components.dart';
import '../../widgets/pallsql_dialogs.dart';
import '../php/php_page.dart';

/// About PALLSQL: identity, developer, workspace location and credits.
class AboutPage extends ConsumerWidget {
  const AboutPage({super.key});

  Future<void> _openInstagram(BuildContext context, WidgetRef ref) async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final bool opened =
        await ref.read(linkOpenerProvider).open(AppInfo.developerInstagramUrl);
    if (opened) {
      return;
    }
    showPallSqlSnack(
      messenger,
      'No browser available. Open ${AppInfo.developerInstagramUrl} manually.',
      error: true,
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final String workspacePath =
        ref.watch(bootstrapProvider).workspace.rootPath;
    return Scaffold(
      appBar: const PallSQLAppBar(title: 'About', showBack: true),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(14, 8, 14, 26),
        children: <Widget>[
          PallSqlCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    const PallSqlLogoMark(size: 48),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          const Text(
                            AppInfo.appName,
                            style: TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 2.4,
                              color: PallSqlColors.textPrimary,
                            ),
                          ),
                          Text(
                            AppInfo.productTagline,
                            style: const TextStyle(
                              fontSize: 11.5,
                              color: PallSqlColors.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                const PallSqlKeyValue(
                  label: 'Application',
                  value: AppInfo.appName,
                  monospace: true,
                ),
                const PallSqlKeyValue(
                  label: 'Version',
                  value: 'v${AppInfo.version} (build ${AppInfo.buildNumber})',
                  monospace: true,
                ),
                const PallSqlKeyValue(
                  label: 'Package',
                  value: AppInfo.packageName,
                  monospace: true,
                ),
                const PallSqlKeyValue(
                  label: 'Platform',
                  value: 'Android - Flutter + Kotlin',
                  monospace: true,
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          const PallSqlSectionHeader(title: 'Developer'),
          PallSqlCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                const PallSqlKeyValue(
                  label: 'Developer',
                  value: AppInfo.developer,
                  monospace: true,
                ),
                const PallSqlKeyValue(
                  label: 'Instagram',
                  value: AppInfo.developerInstagramHandle,
                  monospace: true,
                  maxLines: 1,
                ),
                const SizedBox(height: 6),
                SelectableText(
                  AppInfo.developerInstagramUrl,
                  style: const TextStyle(
                    fontSize: 10.5,
                    color: PallSqlColors.textDisabled,
                    fontFamily: PallSqlColors.monoFontFamily,
                  ),
                ),
                const SizedBox(height: 12),
                PallSQLButton(
                  label: 'Visit Instagram',
                  icon: Icons.open_in_new_rounded,
                  variant: PallSQLButtonVariant.primary,
                  onPressed: () => _openInstagram(context, ref),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          const PallSqlSectionHeader(title: 'Workspace'),
          PallSqlCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                const Text(
                  'All PALLSQL data lives in one folder: htdocs, projects, '
                  'database, config, logs, backups, tmp, extensions and '
                  'terminal.',
                  style: TextStyle(
                    fontSize: 11.5,
                    height: 1.45,
                    color: PallSqlColors.textSecondary,
                  ),
                ),
                const SizedBox(height: 8),
                SelectableText(
                  workspacePath,
                  style: const TextStyle(
                    fontSize: 10.5,
                    height: 1.4,
                    color: PallSqlColors.textPrimary,
                    fontFamily: PallSqlColors.monoFontFamily,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          const PallSqlSectionHeader(title: 'Credits and licenses'),
          PallSqlCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                const Text(
                  'PALLSQL is built on open source software. PALLSQL claims no '
                  'ownership over third party components; each one keeps its '
                  'own license.',
                  style: TextStyle(
                    fontSize: 11.5,
                    height: 1.45,
                    color: PallSqlColors.textSecondary,
                  ),
                ),
                const SizedBox(height: 10),
                const _Credit(
                  name: 'Flutter and Dart',
                  note: 'UI framework and language runtime (BSD-3-Clause).',
                ),
                const _Credit(
                  name: 'MariaDB Server',
                  note: 'The database engine PALLSQL runs locally on the '
                      'device. GPLv2 licensed; built for Android from the '
                      'official source tarball, verified by checksum.',
                ),
                const _Credit(
                  name: 'MariaDB Connector (protocol implementation)',
                  note: 'PALLSQL speaks the MariaDB wire protocol directly '
                      'through its own client, without shipping Connector/C. '
                      'The protocol itself is documented by MariaDB and is not '
                      'a licensed library.',
                ),
                const _Credit(
                  name: 'sqflite / sqflite_common',
                  note: 'Retained only to read legacy SQLite files when the '
                      'user chooses to migrate them. BSD style license.',
                ),
                const _Credit(
                  name: 'flutter_riverpod',
                  note: 'State management (MIT).',
                ),
                const _Credit(
                  name: 'path, path_provider, archive, url_launcher',
                  note: 'Path handling, storage locations, ZIP archives and '
                      'URL launching; each ships its own BSD/MIT license.',
                ),
                const _Credit(
                  name: 'PHP',
                  note: 'Not bundled. A PHP runtime you install keeps its own '
                      'license (PHP License 3.01).',
                ),

                const SizedBox(height: 10),
                PallSQLButton(
                  label: 'Open source licenses',
                  icon: Icons.article_outlined,
                  expand: false,
                  onPressed: () => showLicensePage(
                    context: context,
                    applicationName: AppInfo.appName,
                    applicationVersion:
                        '${AppInfo.version}+${AppInfo.buildNumber}',
                    applicationLegalese: AppInfo.copyright,
                  ),
                ),
                const SizedBox(height: 8),
                PallSQLButton(
                  label: 'PHP runtime details',
                  icon: Icons.code_rounded,
                  expand: false,
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (BuildContext context) => const PhpPage(),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                const Text(
                  'PALLSQL itself is distributed under the MIT license '
                  '(see LICENSE in the repository).',
                  style: TextStyle(
                    fontSize: 10.5,
                    color: PallSqlColors.textDisabled,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 22),
          const Center(
            child: Text(
              AppInfo.copyright,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 10.5,
                color: PallSqlColors.textDisabled,
                letterSpacing: 0.3,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Credit extends StatelessWidget {
  const _Credit({required this.name, required this.note});

  final String name;
  final String note;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Padding(
            padding: EdgeInsets.only(top: 5),
            child: Icon(
              Icons.circle,
              size: 5,
              color: PallSqlColors.accent,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  name,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: PallSqlColors.textPrimary,
                  ),
                ),
                Text(
                  note,
                  style: const TextStyle(
                    fontSize: 10.5,
                    height: 1.4,
                    color: PallSqlColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
