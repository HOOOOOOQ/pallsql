import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/pallsql_colors.dart';
import '../../core/utils/validators.dart';
import '../../models/app_settings.dart';
import '../../models/log_entry.dart';
import '../../models/service_status.dart';
import '../../providers/app_providers.dart';
import '../../services/php_runtime_service.dart';
import '../../services/web_server_service.dart';
import '../../widgets/pallsql_app_bar.dart';
import '../../widgets/pallsql_card.dart';
import '../../widgets/pallsql_components.dart';
import '../../widgets/pallsql_dialogs.dart';
import '../../widgets/server_status_card.dart';
import '../../widgets/service_control_button.dart';
import '../logs/logs_page.dart';

/// PHP configuration and runtime diagnostics.
class PhpPage extends ConsumerStatefulWidget {
  const PhpPage({super.key});

  @override
  ConsumerState<PhpPage> createState() => _PhpPageState();
}

class _PhpPageState extends ConsumerState<PhpPage> {
  late final TextEditingController _pathController = TextEditingController(
    text: ref.read(settingsProvider).phpBinaryPath,
  );
  bool _busy = false;

  @override
  void dispose() {
    _pathController.dispose();
    super.dispose();
  }

  Future<void> _reDetect() async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    final PhpRuntimeInfo? detected =
        await ref.read(phpRuntimeProvider.notifier).refresh();
    if (!mounted) {
      return;
    }
    setState(() => _busy = false);
    showPallSqlSnack(
      messenger,
      detected?.available == true
          ? 'PHP ${detected?.version} detected'
          : 'No PHP runtime found',
      error: detected?.available != true,
    );
  }

  Future<void> _savePath() async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final String value = _pathController.text.trim();
    if (value.isNotEmpty && !Validators.isSafeRelativePath(value)) {
      showPallSqlSnack(
        messenger,
        'Path must be relative to the workspace (no .. or absolute paths)',
        error: true,
      );
      return;
    }
    final AppSettings current = ref.read(settingsProvider);
    final String? error = await ref
        .read(settingsProvider.notifier)
        .update(current.copyWith(phpBinaryPath: value));
    if (!mounted) {
      return;
    }
    if (error != null) {
      showPallSqlSnack(messenger, error, error: true);
      return;
    }
    await _reDetect();
  }

  Future<void> _verifyEndpoint() async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final WebServerSnapshot server = ref.read(webServerProvider);
    if (!server.isRunning) {
      showPallSqlSnack(messenger, 'Start the local server first', error: true);
      return;
    }
    setState(() => _busy = true);
    final HttpClient client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 5);
    String message;
    bool failed = false;
    try {
      final Uri target = Uri.parse(
        'http://127.0.0.1:${server.port}/index.php',
      );
      final HttpClientRequest request = await client.getUrl(target);
      final HttpClientResponse response = await request.close();
      await response.drain<void>();
      if (response.statusCode == HttpStatus.notImplemented) {
        message =
            'HTTP 501 - PHP runtime not installed (source was not served)';
        failed = true;
      } else if (response.statusCode >= 400) {
        message = 'HTTP ${response.statusCode} from /index.php';
        failed = true;
      } else {
        message = 'HTTP ${response.statusCode} - PHP responded successfully';
      }
    } on Object catch (error) {
      message = 'Request failed: $error';
      failed = true;
    } finally {
      client.close(force: true);
    }
    if (!mounted) {
      return;
    }
    setState(() => _busy = false);
    showPallSqlSnack(messenger, message, error: failed);
  }

  /// Runs a real script through the active bridge (501 when no runtime).
  Future<void> _runSelfTest() async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      final PhpSelfTest result =
          await ref.read(bootstrapProvider).php.selfTest();
      if (!mounted) {
        return;
      }
      setState(() => _busy = false);
      await PallSQLDialog.info(
        context: context,
        title: 'PHP execution test',
        message: '${result.summary}\n\n'
            'HTTP ${result.statusCode}\n'
            '${result.body.isEmpty ? '(empty body)' : result.body}'
            '${result.stderr.isEmpty ? '' : '\n\nstderr:\n${result.stderr}'}',
      );
    } on Object catch (error) {
      if (!mounted) {
        return;
      }
      setState(() => _busy = false);
      showPallSqlSnack(messenger, 'Test failed: $error', error: true);
    }
  }

  void _openLogs() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (BuildContext context) =>
            const LogsPage(initialSource: LogSource.php),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final AsyncValue<PhpRuntimeInfo> async = ref.watch(phpRuntimeProvider);
    final PhpRuntimeInfo info = async.valueOrNull ??
        PhpRuntimeInfo.unavailable('Runtime has not been probed yet');
    final ServiceStatus status = ref.watch(phpStatusProvider);
    final AppSettings settings = ref.watch(settingsProvider);
    final WebServerSnapshot server = ref.watch(webServerProvider);
    final bool available = info.available;

    return Scaffold(
      appBar: PallSQLAppBar(
        title: 'PHP',
        subtitle: 'Runtime status and configuration',
        showBack: true,
        actions: <Widget>[
          IconButton(
            tooltip: 'PHP logs',
            icon: const Icon(Icons.receipt_long_rounded, size: 19),
            onPressed: _openLogs,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(14, 6, 14, 24),
        children: <Widget>[
          if (async.isLoading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: LinearProgressIndicator(minHeight: 2),
            ),
          ServerStatusCard(
            title: 'PHP runtime',
            icon: Icons.code_rounded,
            status: status,
            subtitle: available
                ? 'php-cgi ${info.version ?? ''}'
                : 'Not installed in this build',
            details: available
                ? <String>[
                    'binary      ${info.binaryPath ?? '-'}',
                    'ini         ${info.iniPath ?? 'none'}',
                    'extensions  ${info.extensions.length}',
                  ]
                : <String>[
                    'candidate   ${settings.phpBinaryPath.isEmpty ? 'config/php/php-cgi' : settings.phpBinaryPath}',
                    'reason      ${info.reason ?? 'not probed yet'}',
                  ],
            actions: <Widget>[
              ServiceControlButton(
                label: 'Re-detect runtime',
                icon: Icons.search_rounded,
                busy: _busy,
                onPressed: _reDetect,
              ),
              ServiceControlButton(
                label: 'Verify /index.php',
                icon: Icons.play_circle_outline_rounded,
                busy: _busy,
                onPressed: _verifyEndpoint,
              ),
              ServiceControlButton(
                label: 'Test execution',
                icon: Icons.science_outlined,
                busy: _busy,
                onPressed: _runSelfTest,
              ),
            ],
          ),
          if (available)
            ..._availableSections(info)
          else
            ..._unavailableSections(),
          const SizedBox(height: 18),
          const PallSqlSectionHeader(title: 'Request bridge'),
          PallSqlCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                const PallSqlKeyValue(
                  label: 'Method',
                  value: 'CGI (php-cgi, one process per request)',
                  monospace: true,
                ),
                PallSqlKeyValue(
                  label: 'Server',
                  value: server.isRunning
                      ? 'running on port ${server.port}'
                      : 'stopped',
                  monospace: true,
                ),
                PallSqlKeyValue(
                  label: 'Document root',
                  value: server.documentRoot,
                  monospace: true,
                  maxLines: 2,
                ),
                const SizedBox(height: 8),
                const Text(
                  'POST bodies up to 8 MB are forwarded, CGI headers are parsed '
                  'back into a real HTTP response and stderr is logged. A failing '
                  'script returns HTTP 500 with a safe message instead of a PHP '
                  'stack trace.',
                  style: TextStyle(
                    fontSize: 11.5,
                    height: 1.45,
                    color: PallSqlColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          if (async.hasError) ...<Widget>[
            const SizedBox(height: 14),
            PallSqlCard(
              accentColor: PallSqlColors.error,
              child: Text(
                'Probe failed: ${async.error}',
                style: const TextStyle(
                  fontSize: 11.5,
                  color: PallSqlColors.error,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  List<Widget> _availableSections(PhpRuntimeInfo info) {
    return <Widget>[
      const SizedBox(height: 14),
      const PallSqlSectionHeader(title: 'Loaded configuration'),
      PallSqlCard(
        child: Column(
          children: <Widget>[
            for (final MapEntry<String, String> entry in info.iniValues.entries)
              PallSqlKeyValue(
                label: entry.key,
                value: entry.value,
                monospace: true,
              ),
          ],
        ),
      ),
      const SizedBox(height: 14),
      PallSqlSectionHeader(
        title: 'Extensions',
        subtitle: '${info.extensions.length} modules reported by php -m',
      ),
      PallSqlCard(
        child: Wrap(
          spacing: 6,
          runSpacing: 6,
          children: <Widget>[
            for (final String extension in info.extensions)
              PallSqlPill(label: extension, color: PallSqlColors.success),
          ],
        ),
      ),
      const SizedBox(height: 14),
      const PallSqlCard(
        child: Text(
          'Editing php.ini from the app is intentionally not implemented: the '
          'interpreter owns its ini file and PALLSQL only reports the values it '
          'really loaded. Ship the ini (or set PHP_INI_SCAN_DIR) when you build '
          'the runtime.',
          style: TextStyle(
            fontSize: 11.5,
            height: 1.45,
            color: PallSqlColors.textSecondary,
          ),
        ),
      ),
    ];
  }

  List<Widget> _unavailableSections() {
    const List<String> steps = <String>[
      'Build or obtain a php-cgi binary for the device ABI (arm64-v8a or '
          'armeabi-v7a). Desktop PHP binaries cannot run on Android.',
      'Package it as libphp-cgi.so inside android/app/src/main/jniLibs/<abi>/ '
          'so Android allows execution from the native library directory.',
      'Rebuild the APK. PALLSQL detects '
          '/data/app/.../lib/<abi>/libphp-cgi.so automatically at startup.',
      'For development builds you can instead place an executable at '
          'config/php/php-cgi inside the workspace.',
      'Required extensions: pdo, pdo_sqlite, sqlite3, mbstring, json, session, '
          'standard (plus openssl for TLS).',
    ];
    return <Widget>[
      const SizedBox(height: 14),
      const PallSqlSectionHeader(title: 'Unavailable - what this means'),
      const PallSqlCard(
        child: Text(
          'PALLSQL does not bundle a PHP interpreter. Requests for .php files '
          'return HTTP 501 and the source code is never sent to the browser, so '
          'a PHP file cannot leak by accident. Static HTML, CSS, JavaScript, '
          'JSON and images work without any runtime.',
          style: TextStyle(
            fontSize: 12,
            height: 1.5,
            color: PallSqlColors.textSecondary,
          ),
        ),
      ),
      const SizedBox(height: 14),
      const PallSqlSectionHeader(title: 'Install a runtime'),
      PallSqlCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            for (int index = 0; index < steps.length; index++)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  '${index + 1}. ${steps[index]}',
                  style: const TextStyle(
                    fontSize: 11.5,
                    height: 1.45,
                    color: PallSqlColors.textSecondary,
                  ),
                ),
              ),
          ],
        ),
      ),
      const SizedBox(height: 14),
      const PallSqlSectionHeader(title: 'Runtime path'),
      PallSqlCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            TextField(
              controller: _pathController,
              style: const TextStyle(
                color: PallSqlColors.textPrimary,
                fontSize: 12.5,
                fontFamily: PallSqlColors.monoFontFamily,
              ),
              decoration: InputDecoration(
                isDense: true,
                hintText: 'config/php/php-cgi',
                hintStyle: const TextStyle(
                  color: PallSqlColors.textDisabled,
                  fontSize: 12,
                ),
                helperText: 'Relative to the PALLSQL workspace',
                helperStyle: const TextStyle(
                  color: PallSqlColors.textDisabled,
                  fontSize: 10.5,
                ),
                filled: true,
                fillColor: PallSqlColors.background,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(9),
                  borderSide: const BorderSide(color: PallSqlColors.border),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(9),
                  borderSide: const BorderSide(color: PallSqlColors.border),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(9),
                  borderSide: const BorderSide(color: PallSqlColors.accent),
                ),
              ),
            ),
            const SizedBox(height: 10),
            ServiceControlButton(
              label: 'Save and detect',
              icon: Icons.save_rounded,
              busy: _busy,
              onPressed: _savePath,
            ),
          ],
        ),
      ),
    ];
  }
}
