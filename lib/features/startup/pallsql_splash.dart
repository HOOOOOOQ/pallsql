import 'package:flutter/material.dart';

import '../../core/constants/app_info.dart';
import '../../core/theme/pallsql_colors.dart';
import '../../widgets/pallsql_app_bar.dart';
import '../../widgets/pallsql_components.dart';

/// The steps shown while the local environment boots.
///
/// The order matches [AppBootstrap.create]; the loading screen only ever
/// advances when a step really finished (the bootstrap calls back as it goes).
const List<String> startupSteps = <String>[
  'Workspace folders',
  'Configuration',
  'Log buffer',
  'Device information',
  'PHP runtime',
  'SQLite engine',
  'Project metadata',
  'Web server',
];

/// In-app loading screen (distinct from the Android launch window).
///
/// It shows the brand, the tagline and the step that is currently running. The
/// caller drives [step] and [progress]; the widget itself never starts work.
class PallsqlSplashScreen extends StatelessWidget {
  const PallsqlSplashScreen({
    super.key,
    this.step = 'Starting',
    this.progress = 0,
    this.failed = false,
  });

  /// Human readable label of the running step.
  final String step;

  /// 0..1 completion of the known boot steps.
  final double progress;

  /// Turns the accent red when the boot sequence failed.
  final bool failed;

  @override
  Widget build(BuildContext context) {
    final Color accent = failed ? PallSqlColors.error : PallSqlColors.accent;
    return Scaffold(
      backgroundColor: PallSqlColors.background,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                TweenAnimationBuilder<double>(
                  tween: Tween<double>(begin: 0.92, end: 1),
                  duration: const Duration(milliseconds: 420),
                  curve: Curves.easeOutCubic,
                  builder: (BuildContext context, double scale, Widget? child) {
                    return Transform.scale(scale: scale, child: child);
                  },
                  child: const PallSqlLogoMark(size: 74),
                ),
                const SizedBox(height: 20),
                const Text(
                  AppInfo.appName,
                  style: TextStyle(
                    color: PallSqlColors.textPrimary,
                    fontSize: 26,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 5,
                  ),
                ),
                const SizedBox(height: 6),
                const Text(
                  'Mobile Development Environment',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: PallSqlColors.textSecondary,
                    fontSize: 12,
                    letterSpacing: 0.6,
                  ),
                ),
                const SizedBox(height: 28),
                SizedBox(
                  width: 230,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(999),
                    child: TweenAnimationBuilder<double>(
                      tween: Tween<double>(begin: 0, end: progress),
                      duration: const Duration(milliseconds: 320),
                      curve: Curves.easeOut,
                      builder:
                          (BuildContext context, double value, Widget? child) {
                        return LinearProgressIndicator(
                          value: value.clamp(0.02, 1.0),
                          minHeight: 4,
                          backgroundColor: PallSqlColors.surfaceMuted,
                          valueColor: AlwaysStoppedAnimation<Color>(accent),
                        );
                      },
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 220),
                  child: Text(
                    step,
                    key: ValueKey<String>(step),
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: PallSqlColors.textSecondary,
                      fontFamily: PallSqlColors.monoFontFamily,
                      fontSize: 11.5,
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                const Text(
                  'Initializing local environment',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: PallSqlColors.textDisabled,
                    fontSize: 11,
                  ),
                ),
                const SizedBox(height: 30),
                Text(
                  '${AppInfo.appName} ${AppInfo.version} - offline, on device',
                  style: const TextStyle(
                    color: PallSqlColors.textDisabled,
                    fontSize: 10,
                    letterSpacing: 0.4,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Shown when the environment could not be created.
///
/// The message is short and actionable, the technical detail is written to the
/// app log and can be copied from the Logs screen once the app starts.
class StartupFailureScreen extends StatelessWidget {
  const StartupFailureScreen({
    super.key,
    required this.message,
    this.detail,
    required this.onRetry,
  });

  final String message;
  final String? detail;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: PallSqlColors.background,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                const Icon(
                  Icons.report_gmailerrorred_rounded,
                  color: PallSqlColors.error,
                  size: 40,
                ),
                const SizedBox(height: 14),
                const Text(
                  'PALLSQL could not start',
                  style: TextStyle(
                    color: PallSqlColors.textPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  message,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: PallSqlColors.textSecondary,
                    fontSize: 12.5,
                    height: 1.45,
                  ),
                ),
                if (detail != null) ...<Widget>[
                  const SizedBox(height: 12),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: PallSqlColors.surface,
                      borderRadius: BorderRadius.circular(9),
                      border: Border.all(color: PallSqlColors.border),
                    ),
                    child: SelectableText(
                      detail!,
                      style: const TextStyle(
                        color: PallSqlColors.textDisabled,
                        fontSize: 10.5,
                        height: 1.4,
                        fontFamily: PallSqlColors.monoFontFamily,
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 18),
                PallSQLButton(
                  label: 'Retry',
                  icon: Icons.refresh_rounded,
                  variant: PallSQLButtonVariant.primary,
                  expand: false,
                  onPressed: onRetry,
                ),
                const SizedBox(height: 10),
                const Text(
                  'Check that app storage is writable and that no other PALLSQL '
                  'instance is using the same folder.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: PallSqlColors.textDisabled,
                    fontSize: 10.5,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Small caption used under the splash on wide screens.
class StartupFooter extends StatelessWidget {
  const StartupFooter({super.key});

  @override
  Widget build(BuildContext context) {
    return const Text(
      '© 2026 PALLSQL. Developed by pallxXx.',
      style: TextStyle(color: PallSqlColors.textDisabled, fontSize: 10),
    );
  }
}
