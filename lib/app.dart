import 'package:flutter/material.dart';
import 'features/dashboard/dashboard_page.dart';
import 'features/database/database_page.dart';
import 'features/files/files_page.dart';
import 'features/settings/settings_page.dart';
import 'features/servers/servers_page.dart';

const neon = Color(0xffa3ff12);

class PallSqlApp extends StatelessWidget {
  const PallSqlApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'PALLSQL', debugShowCheckedModeBanner: false,
    theme: ThemeData(useMaterial3: true, brightness: Brightness.dark, scaffoldBackgroundColor: const Color(0xff090b0a), colorScheme: ColorScheme.fromSeed(seedColor: neon, brightness: Brightness.dark, surface: const Color(0xff141715)), appBarTheme: const AppBarTheme(backgroundColor: Color(0xff090b0a), foregroundColor: Colors.white), cardTheme: CardThemeData(color: const Color(0xff141715), elevation: 0, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))), navigationBarTheme: const NavigationBarThemeData(backgroundColor: Color(0xff101210), indicatorColor: Color(0xff29351a))),
    home: const MainShell(),
  );
}

class MainShell extends StatefulWidget { const MainShell({super.key}); @override State<MainShell> createState()=>_MainShellState(); }
class _MainShellState extends State<MainShell> {
 int index=0;
 final pages=const [DashboardPage(), ServersPage(), DatabasePage(), FilesPage(), SettingsPage()];
 @override Widget build(BuildContext context)=>Scaffold(body: SafeArea(child: pages[index]), bottomNavigationBar: NavigationBar(selectedIndex:index,onDestinationSelected:(v)=>setState(()=>index=v), destinations: const [NavigationDestination(icon:Icon(Icons.dashboard_outlined),selectedIcon:Icon(Icons.dashboard),label:'Home'),NavigationDestination(icon:Icon(Icons.dns_outlined),label:'Servers'),NavigationDestination(icon:Icon(Icons.storage_outlined),label:'Database'),NavigationDestination(icon:Icon(Icons.folder_outlined),label:'Files'),NavigationDestination(icon:Icon(Icons.settings_outlined),label:'Settings')]));
}
