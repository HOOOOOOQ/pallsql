import 'package:flutter/material.dart';

import '../../widgets/pallsql_bottom_navigation.dart';
import '../dashboard/dashboard_page.dart';
import '../database/database_page.dart';
import '../files/files_page.dart';
import '../servers/servers_page.dart';
import '../settings/settings_page.dart';

/// Root shell with the five primary destinations.
class HomeShell extends StatefulWidget {
  const HomeShell({super.key, this.initialIndex = 0});

  final int initialIndex;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  late int _index = widget.initialIndex.clamp(0, 4);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _index,
        children: const <Widget>[
          DashboardPage(),
          ServersPage(),
          DatabasePage(),
          FilesPage(),
          SettingsPage(),
        ],
      ),
      bottomNavigationBar: PallSQLBottomNavigation(
        currentIndex: _index,
        onSelected: (int index) => setState(() => _index = index),
        items: const <PallSQLNavItem>[
          PallSQLNavItem(label: 'Home', icon: Icons.home_rounded),
          PallSQLNavItem(label: 'Servers', icon: Icons.dns_rounded),
          PallSQLNavItem(label: 'Database', icon: Icons.storage_rounded),
          PallSQLNavItem(label: 'Files', icon: Icons.folder_rounded),
          PallSQLNavItem(label: 'Settings', icon: Icons.tune_rounded),
        ],
      ),
    );
  }

  /// Used by widget tests to verify navigation without tapping.
  @visibleForTesting
  int get currentIndex => _index;
}
