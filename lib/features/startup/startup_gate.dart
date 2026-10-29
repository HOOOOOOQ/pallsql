import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app.dart';
import '../../core/theme/pallsql_theme.dart';
import '../../providers/app_providers.dart';
import '../../services/app_bootstrap.dart';
import 'pallsql_splash.dart';

/// Boots PALLSQL behind a branded loading screen.
///
/// The gate owns the *first* frame: `runApp` happens immediately, the workspace
/// is built while the splash is visible, and a bounded timeout turns a hang
/// into an actionable error with a Retry button (never an endless spinner).
class StartupGate extends StatefulWidget {
  const StartupGate({
    super.key,
    required this.createBootstrap,
    this.initialTab = 0,
    this.timeout = const Duration(seconds: 30),
  });

  /// Builds the object graph. Receives a callback for the visible step label.
  final Future<AppBootstrap> Function(void Function(String step) onProgress)
      createBootstrap;

  final int initialTab;
  final Duration timeout;

  @override
  State<StartupGate> createState() => _StartupGateState();
}

class _StartupGateState extends State<StartupGate> {
  AppBootstrap? _bootstrap;
  String _step = 'Preparing workspace';
  String? _error;
  String? _detail;
  int _completed = 0;
  bool _running = false;

  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    setState(() {
      _running = true;
      _error = null;
      _detail = null;
      _completed = 0;
      _step = 'Preparing workspace';
    });
    try {
      final AppBootstrap bootstrap = await widget
          .createBootstrap(_onProgress)
          .timeout(
            widget.timeout,
            onTimeout: () => throw TimeoutException(
              'Startup took longer than ${widget.timeout.inSeconds}s',
            ),
          );
      if (!mounted) {
        await bootstrap.dispose();
        return;
      }
      setState(() {
        _bootstrap = bootstrap;
        _completed = startupSteps.length;
        _running = false;
      });
    } on Object catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _running = false;
        _error = _friendly(error);
        _detail = error.toString();
      });
    }
  }

  void _onProgress(String step) {
    if (!mounted) {
      return;
    }
    setState(() {
      _step = step;
      _completed = (_completed + 1).clamp(0, startupSteps.length);
    });
  }

  String _friendly(Object error) {
    if (error is TimeoutException) {
      return 'The environment took too long to start. Tap Retry; if it keeps '
          'happening, free up storage and close other PALLSQL windows.';
    }
    return 'The workspace could not be prepared. Tap Retry to try again.';
  }

  @override
  Widget build(BuildContext context) {
    final AppBootstrap? bootstrap = _bootstrap;
    if (bootstrap != null) {
      return ProviderScope(
        overrides: <Override>[
          bootstrapProvider.overrideWithValue(bootstrap),
        ],
        child: PallSqlApp(initialTab: widget.initialTab),
      );
    }
    return MaterialApp(
      title: 'PALLSQL',
      debugShowCheckedModeBanner: false,
      theme: PallSqlTheme.dark(),
      darkTheme: PallSqlTheme.dark(),
      themeMode: ThemeMode.dark,
      home: _error == null
          ? PallsqlSplashScreen(
              step: _step,
              progress: _completed / startupSteps.length,
            )
          : StartupFailureScreen(
              message: _error!,
              detail: _detail,
              onRetry: _running ? () {} : _boot,
            ),
    );
  }
}
