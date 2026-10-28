import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../core/errors/app_failure.dart';
import '../models/log_entry.dart';
import '../models/service_status.dart';
import 'log_sink.dart';
import 'workspace_service.dart';

/// Result of probing a PHP runtime.
///
/// PALLSQL never invents these values: when no runtime is installed
/// [available] is `false` and the UI shows "Not installed".
class PhpRuntimeInfo {
  const PhpRuntimeInfo({
    required this.available,
    this.version,
    this.binaryPath,
    this.extensions = const <String>[],
    this.iniValues = const <String, String>{},
    this.iniPath,
    this.reason,
    this.checkedAt,
  });

  final bool available;
  final String? version;
  final String? binaryPath;
  final List<String> extensions;
  final Map<String, String> iniValues;
  final String? iniPath;
  final String? reason;
  final DateTime? checkedAt;

  static const PhpRuntimeInfo unavailableReason =
      PhpRuntimeInfo(available: false, reason: 'No PHP runtime found');

  static PhpRuntimeInfo unavailable(String reason) =>
      PhpRuntimeInfo(available: false, reason: reason);

  ServiceStatus toStatus() => available
      ? ServiceStatus(ServiceState.running,
          message: 'PHP ${version ?? ''}'.trim())
      : ServiceStatus.unavailable(
          reason ?? 'PHP runtime not installed in this build');

  bool get supportsCgi => available && binaryPath != null;
}

/// A CGI style request forwarded to the PHP interpreter.
class PhpCgiRequest {
  const PhpCgiRequest({
    required this.scriptPath,
    required this.scriptName,
    required this.documentRoot,
    required this.method,
    required this.uri,
    required this.headers,
    required this.body,
    required this.remoteAddress,
    required this.serverName,
    required this.serverPort,
  });

  final String scriptPath;
  final String scriptName;
  final String documentRoot;
  final String method;
  final Uri uri;
  final Map<String, String> headers;
  final List<int> body;
  final String remoteAddress;
  final String serverName;
  final int serverPort;

  Map<String, String> toEnvironment() {
    final Map<String, String> env = <String, String>{
      'GATEWAY_INTERFACE': 'CGI/1.1',
      'REDIRECT_STATUS': '200',
      'SERVER_SOFTWARE': 'PALLSQL',
      'SERVER_PROTOCOL': 'HTTP/1.1',
      'SERVER_NAME': serverName,
      'SERVER_PORT': '$serverPort',
      'REQUEST_METHOD': method,
      'REQUEST_URI': uri.toString(),
      'SCRIPT_FILENAME': scriptPath,
      'SCRIPT_NAME': scriptName,
      'PATH_INFO': '',
      'DOCUMENT_ROOT': documentRoot,
      'QUERY_STRING': uri.query,
      'CONTENT_LENGTH': body.isEmpty ? '' : '${body.length}',
      'REMOTE_ADDR': remoteAddress,
    };
    headers.forEach((String name, String value) {
      final String lower = name.toLowerCase();
      if (lower == 'content-length' || lower == 'content-type') {
        return;
      }
      final String key = 'HTTP_${lower.toUpperCase().replaceAll('-', '_')}';
      env[key] = value;
    });
    for (final MapEntry<String, String> entry in headers.entries) {
      if (entry.key.toLowerCase() == 'content-type') {
        env['CONTENT_TYPE'] = entry.value;
        break;
      }
    }
    return env;
  }
}

/// Raw CGI response as produced by the interpreter.
class PhpCgiResponse {
  const PhpCgiResponse({
    required this.statusCode,
    required this.headers,
    required this.body,
    this.stderr = '',
  });

  final int statusCode;
  final Map<String, String> headers;
  final List<int> body;
  final String stderr;

  static PhpCgiResponse error(int status, String message) => PhpCgiResponse(
        statusCode: status,
        headers: const <String, String>{
          'Content-Type': 'text/plain; charset=utf-8',
        },
        body: utf8.encode('$message\n'),
      );
}

/// Interface the web server uses to execute PHP.
abstract class PhpBridge {
  PhpRuntimeInfo get info;

  Future<PhpCgiResponse> execute(PhpCgiRequest request);
}

/// Bridge used when no runtime exists; every execution is refused honestly.
class NullPhpBridge implements PhpBridge {
  const NullPhpBridge([this._reason = 'PHP runtime is not installed']);

  final String _reason;

  @override
  PhpRuntimeInfo get info => PhpRuntimeInfo.unavailable(_reason);

  @override
  Future<PhpCgiResponse> execute(PhpCgiRequest request) async =>
      PhpCgiResponse.error(501, _reason);
}

/// Runs a real `php-cgi` compatible binary through `Process.start`.
///
/// On Android the binary must live in the app's native library directory
/// (packaged as `libphp-cgi.so`) or an executable file inside the workspace.
/// See `docs/php-runtime.md` for the packaging contract.
class ProcessPhpRuntime implements PhpBridge {
  ProcessPhpRuntime({
    required this.binaryPath,
    required LogSink logs,
    this.timeout = const Duration(seconds: 30),
  })  : _logs = logs,
        _info = PhpRuntimeInfo(
          available: false,
          binaryPath: binaryPath,
          reason: 'Runtime has not been probed yet',
        );

  final String binaryPath;
  final Duration timeout;
  final LogSink _logs;
  PhpRuntimeInfo _info;

  @override
  PhpRuntimeInfo get info => _info;

  /// Runs `php-cgi -v`, `-m` and `-i` and parses the real output.
  Future<PhpRuntimeInfo> probe() async {
    final File binary = File(binaryPath);
    if (!await binary.exists()) {
      _info = PhpRuntimeInfo.unavailable('Runtime binary not found');
      return _info;
    }
    try {
      final ProcessResult versionResult =
          await Process.run(binaryPath, <String>['-v'], runInShell: false)
              .timeout(const Duration(seconds: 8));
      if (versionResult.exitCode != 0) {
        _info = PhpRuntimeInfo.unavailable(
          'Runtime exited with code ${versionResult.exitCode}',
        );
        return _info;
      }
      final String versionText =
          '${versionResult.stdout}${versionResult.stderr}';
      final RegExpMatch? match =
          RegExp(r'PHP\s+([0-9][0-9A-Za-z.\-]*)').firstMatch(versionText);
      final String version = match?.group(1) ?? 'unknown';

      final ProcessResult modulesResult = await Process.run(
        binaryPath,
        <String>['-m'],
        runInShell: false,
      ).timeout(const Duration(seconds: 8));
      final List<String> extensions = _parseModules('${modulesResult.stdout}');

      final ProcessResult iniResult = await Process.run(
        binaryPath,
        <String>['-i'],
        runInShell: false,
      ).timeout(const Duration(seconds: 12));
      final Map<String, String> iniValues = _parseIni('${iniResult.stdout}');

      _info = PhpRuntimeInfo(
        available: true,
        version: version,
        binaryPath: binaryPath,
        extensions: extensions,
        iniValues: iniValues,
        iniPath: iniValues['Loaded Configuration File'],
        checkedAt: DateTime.now(),
      );
      _logs.info(LogSource.php, 'PHP runtime detected: $version');
      return _info;
    } on TimeoutException {
      _info = PhpRuntimeInfo.unavailable('Runtime probe timed out');
      _logs.warning(LogSource.php, 'PHP probe timed out for $binaryPath');
      return _info;
    } on ProcessException catch (error) {
      _info = PhpRuntimeInfo.unavailable('Runtime could not be executed');
      _logs.warning(LogSource.php, 'PHP probe failed: ${error.message}');
      return _info;
    }
  }

  @override
  Future<PhpCgiResponse> execute(PhpCgiRequest request) async {
    if (!_info.available) {
      return PhpCgiResponse.error(501, 'PHP runtime is not available');
    }
    final String workingDirectory = p.dirname(request.scriptPath);
    Process process;
    try {
      process = await Process.start(
        binaryPath,
        const <String>[],
        workingDirectory: workingDirectory,
        environment: request.toEnvironment(),
        includeParentEnvironment: false,
        runInShell: false,
      );
    } on ProcessException catch (error) {
      _logs.error(LogSource.php, 'Could not start PHP: ${error.message}');
      return PhpCgiResponse.error(500, 'PHP runtime could not be started');
    }

    final Future<List<int>> stdoutFuture = _collect(process.stdout);
    final Future<List<int>> stderrFuture = _collect(process.stderr);
    try {
      if (request.body.isNotEmpty) {
        process.stdin.add(request.body);
      }
      await process.stdin.flush();
      await process.stdin.close();
    } on Object {
      // The interpreter may close stdin early; the exit code is authoritative.
    }

    try {
      final List<int> stdout = await stdoutFuture.timeout(timeout);
      final List<int> stderr = await stderrFuture.timeout(timeout);
      final int exitCode = await process.exitCode.timeout(timeout);
      final String stderrText =
          utf8.decode(stderr, allowMalformed: true).trim();
      if (exitCode != 0) {
        _logs.error(
          LogSource.php,
          'PHP exited with $exitCode: ${_short(stderrText)}',
        );
        return PhpCgiResponse.error(
            500, 'PHP script failed (exit code $exitCode)');
      }
      final PhpCgiResponse parsed = _parseCgiOutput(stdout, stderrText);
      _logs.info(
        LogSource.php,
        'PHP ${request.method} ${request.scriptName} -> ${parsed.statusCode}',
      );
      return parsed;
    } on TimeoutException {
      process.kill(ProcessSignal.sigkill);
      _logs.error(LogSource.php, 'PHP execution timed out after $timeout');
      return PhpCgiResponse.error(504, 'PHP execution timed out');
    }
  }

  static String _short(String value) =>
      value.length <= 500 ? value : '${value.substring(0, 500)}…';

  static Future<List<int>> _collect(Stream<List<int>> stream) async {
    final List<int> buffer = <int>[];
    await for (final List<int> chunk in stream) {
      buffer.addAll(chunk);
      if (buffer.length > 32 * 1024 * 1024) {
        break;
      }
    }
    return buffer;
  }

  static List<String> _parseModules(String output) {
    final List<String> modules = <String>[];
    for (final String rawLine in output.split('\n')) {
      final String line = rawLine.trim();
      if (line.isEmpty || line.startsWith('[') || line.startsWith('Zend')) {
        continue;
      }
      if (RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$').hasMatch(line)) {
        modules.add(line);
      }
    }
    modules.sort();
    return modules;
  }

  static Map<String, String> _parseIni(String output) {
    const List<String> wanted = <String>[
      'PHP Version',
      'Loaded Configuration File',
      'memory_limit',
      'max_execution_time',
      'upload_max_filesize',
      'post_max_size',
      'error_reporting',
      'display_errors',
      'max_input_time',
      'extension_dir',
    ];
    final Map<String, String> values = <String, String>{};
    for (final String rawLine in output.split('\n')) {
      final int separator = rawLine.indexOf('=>');
      if (separator <= 0) {
        continue;
      }
      final String key = rawLine.substring(0, separator).trim();
      if (!wanted.contains(key)) {
        continue;
      }
      values[key] = rawLine.substring(separator + 2).trim();
    }
    return values;
  }

  /// Splits a CGI response into status, headers and body.
  PhpCgiResponse _parseCgiOutput(List<int> stdout, String stderr) {
    final Uint8List bytes =
        stdout is Uint8List ? stdout : Uint8List.fromList(stdout);
    int headerEnd = -1;
    int separatorLength = 0;
    for (int i = 0; i < bytes.length - 1; i++) {
      if (bytes[i] == 13 && bytes[i + 1] == 10) {
        if (i + 3 < bytes.length && bytes[i + 2] == 13 && bytes[i + 3] == 10) {
          headerEnd = i;
          separatorLength = 4;
          break;
        }
      }
      if (bytes[i] == 10 && bytes[i + 1] == 10) {
        headerEnd = i;
        separatorLength = 2;
        break;
      }
    }
    if (headerEnd < 0) {
      // No CGI headers: return the payload as HTML rather than leaking source.
      return PhpCgiResponse(
        statusCode: 200,
        headers: const <String, String>{
          'Content-Type': 'text/html; charset=utf-8',
        },
        body: bytes,
        stderr: stderr,
      );
    }
    final String headerBlock =
        utf8.decode(bytes.sublist(0, headerEnd), allowMalformed: true);
    final Uint8List body = bytes.sublist(headerEnd + separatorLength);
    final Map<String, String> headers = <String, String>{};
    int status = 200;
    for (final String line in headerBlock.split('\n')) {
      final String trimmed = line.trim();
      if (trimmed.isEmpty) {
        continue;
      }
      final int colon = trimmed.indexOf(':');
      if (colon <= 0) {
        continue;
      }
      final String name = trimmed.substring(0, colon).trim();
      final String value = trimmed.substring(colon + 1).trim();
      if (name.toLowerCase() == 'status') {
        final int? parsed = int.tryParse(value.split(' ').first);
        if (parsed != null && parsed >= 100 && parsed <= 599) {
          status = parsed;
        }
        continue;
      }
      if (_isHopByHop(name)) {
        continue;
      }
      headers[name] = value;
    }
    headers.putIfAbsent('Content-Type', () => 'text/html; charset=utf-8');
    return PhpCgiResponse(
      statusCode: status,
      headers: headers,
      body: body,
      stderr: stderr,
    );
  }

  static bool _isHopByHop(String name) {
    const Set<String> blocked = <String>{
      'connection',
      'keep-alive',
      'transfer-encoding',
      'content-length',
      'upgrade',
      'proxy-connection',
    };
    return blocked.contains(name.toLowerCase());
  }
}

/// Locates, probes and exposes the PHP runtime for the current workspace.
class PhpRuntimeService implements PhpBridge {
  PhpRuntimeService({
    required Workspace workspace,
    required LogSink logs,
    String configuredRelativePath = '',
    Future<String?> Function()? nativeLibraryDirProvider,
  })  : _workspace = workspace,
        _logs = logs,
        _configuredPath = configuredRelativePath,
        _nativeLibraryDirProvider = nativeLibraryDirProvider;

  final Workspace _workspace;
  final LogSink _logs;
  final Future<String?> Function()? _nativeLibraryDirProvider;
  String _configuredPath;
  ProcessPhpRuntime? _runtime;
  PhpRuntimeInfo _info = PhpRuntimeInfo.unavailableReason;

  @override
  PhpRuntimeInfo get info => _info;

  void updateConfiguredPath(String relativePath) {
    _configuredPath = relativePath;
  }

  /// Candidate binary locations, in priority order.
  Future<List<String>> candidatePaths() async {
    final List<String> candidates = <String>[];
    if (_configuredPath.trim().isNotEmpty) {
      try {
        candidates
            .add(_workspace.guard.resolveRelative(_configuredPath.trim()));
      } on PathSecurityFailure {
        _logs.warning(LogSource.php, 'Ignoring unsafe PHP binary path');
      }
    }
    candidates
      ..add(p.join(_workspace.config.path, 'php', 'php-cgi'))
      ..add(p.join(_workspace.config.path, 'php', 'php'))
      ..add(p.join(_workspace.config.path, 'php', 'bin', 'php-cgi'));
    final Future<String?> Function()? provider = _nativeLibraryDirProvider;
    if (provider != null) {
      final String? nativeDir = await provider();
      if (nativeDir != null && nativeDir.isNotEmpty) {
        candidates
          ..add(p.join(nativeDir, 'libphp-cgi.so'))
          ..add(p.join(nativeDir, 'libphp.so'));
      }
    }
    return candidates;
  }

  /// Probes every candidate and keeps the first working runtime.
  Future<PhpRuntimeInfo> refresh() async {
    final List<String> candidates = await candidatePaths();
    for (final String candidate in candidates) {
      final File file = File(candidate);
      if (!await file.exists()) {
        continue;
      }
      final ProcessPhpRuntime runtime =
          ProcessPhpRuntime(binaryPath: candidate, logs: _logs);
      final PhpRuntimeInfo probed = await runtime.probe();
      if (probed.available) {
        _runtime = runtime;
        _info = probed;
        return _info;
      }
      _logs.warning(
        LogSource.php,
        'PHP candidate $candidate rejected: ${probed.reason ?? 'unknown'}',
      );
    }
    _runtime = null;
    _info = PhpRuntimeInfo.unavailable(
      'No PHP runtime installed. Place a php-cgi binary in '
      'config/php/php-cgi or package libphp-cgi.so for your ABI.',
    );
    _logs.info(LogSource.php, 'PHP runtime is not available');
    return _info;
  }

  @override
  Future<PhpCgiResponse> execute(PhpCgiRequest request) async {
    final ProcessPhpRuntime? runtime = _runtime;
    if (runtime == null || !_info.available) {
      return PhpCgiResponse.error(501, 'PHP runtime is not installed');
    }
    return runtime.execute(request);
  }
}
