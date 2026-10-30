import 'package:flutter/material.dart';

import 'features/startup/startup_gate.dart';
import 'services/app_bootstrap.dart';

/// Entry point.
///
/// `runApp` happens immediately: the Android launch window hands over to the in
/// app loading screen, which prepares the workspace, detects the PHP runtime,
/// initialises and starts the **native MariaDB server** and finally brings the
/// web server up before the dashboard appears. A failure (or a timeout) shows a
/// readable error with Retry instead of an endless spinner - and every step
/// reports what really happened, never a guess.
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    StartupGate(
      createBootstrap: (void Function(String step) onProgress) =>
          AppBootstrap.create(onProgress: onProgress),
    ),
  );
}
