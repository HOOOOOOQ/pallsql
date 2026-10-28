import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../core/constants/app_info.dart';
import '../core/errors/app_failure.dart';
import '../core/utils/path_guard.dart';
import '../models/log_entry.dart';
import '../models/service_status.dart';
import 'log_sink.dart';
import 'mime_types.dart';
import 'php_runtime_service.dart';

/// Immutable view of the local web server.
class WebServerSnapshot {
  const WebServerSnapshot({
    required this.state,
    required this.documentRoot,
    required this.lanAccess,
    this.port,
    this.bindAddress,
    this.startedAt,
    this.requestCount = 0,
    this.errorCount = 0,
    this.error,
    this.urls = const <String>[],
  });

  final ServiceState state;
  final String documentRoot;
  final bool lanAccess;
  final int? port;
  final String? bindAddress;
  final DateTime? startedAt;
  final int requestCount;
  final int errorCount;
  final String? error;
  final List<String> urls;

  bool get isRunning => state.isRunning;

  ServiceStatus toStatus() => ServiceStatus(
        state,
        message: state == ServiceState.error
            ? error
            : (isRunning ? 'Listening on ${bindAddress ?? ''}:${port ?? ''}' : null),
      );

  String get primaryUrl =>
      urls.isNotEmpty ? urls.first : 'http://127.0.0.1:${port ?? AppInfo.defaultHttpPort}/';

  Duration get uptime =>
      startedAt == null ? Duration.zero : DateTime.now().difference(startedAt!);

  WebServerSnapshot copyWith({
    ServiceState? state,
    int? port,
    String? bindAddress,
    String? documentRoot,
    bool? lanAccess,
    DateTime? startedAt,
    int? requestCount,
    int? errorCount,
    String? error,
    List<String>? urls,
    bool clearError = false,
  }) {
    return WebServerSnapshot(
      state: state ?? this.state,
      documentRoot: documentRoot ?? this.documentRoot,
      lanAccess: lanAccess ?? this.lanAccess,
      port: port ?? this.port,
      bindAddress: bindAddress ?? this.bindAddress,
      startedAt: startedAt ?? this.startedAt,
      requestCount: requestCount ?? this.requestCount,
      errorCount: errorCount ?? this.errorCount,
      error: clearError ? null : (error ?? this.error),
      urls: urls ?? this.urls,
    );
  }
}

/// The local HTTP server that serves the PALLSQL document root.
///
/// Security properties enforced here:
/// * binds to loopback unless the user explicitly enables LAN access;
/// * rejects absolute paths, `..` segments (including URL encoded variants),
///   NUL bytes, dotfiles and symlinks that escape the document root;
/// * never sends PHP sources; `.php` requires a real runtime, otherwise 501;
/// * directory listing is disabled;
/// * only `GET` and `HEAD` are allowed.
class WebServerService {
  WebServerService({
    required Directory documentRoot,
    required LogSink logs,
    PhpBridge? phpBridge,
    String serverName = AppInfo.appName,
  })  : _documentRoot = p.normalize(p.absolute(documentRoot.path)),
        _logs = logs,
        _phpBridge = phpBridge ?? const NullPhpBridge(),
        _serverName = serverName;

  static const int maxRequestBytes = 8 * 1024 * 1024;

  final LogSink _logs;
  final String _serverName;
  String _documentRoot;
  PhpBridge _phpBridge;
  HttpServer? _server;
  StreamSubscription<HttpRequest>? _subscription;
  ServiceState _state = ServiceState.stopped;
  DateTime? _startedAt;
  int _requestCount = 0;
  int _errorCount = 0;
  String? _error;
  bool _stopRequested = false;
  bool _lanAccess = false;
  String? _bindAddress;
  List<String> _urls = const <String>[];
  final StreamController<WebServerSnapshot> _controller =
      StreamController<WebServerSnapshot>.broadcast();

  String get documentRoot => _documentRoot;

  Stream<WebServerSnapshot> get changes => _controller.stream;

  WebServerSnapshot get snapshot => WebServerSnapshot(
        state: _state,
        documentRoot: _documentRoot,
        lanAccess: _lanAccess,
        port: _server?.port,
        bindAddress: _bindAddress,
        startedAt: _startedAt,
        requestCount: _requestCount,
        errorCount: _errorCount,
        error: _error,
        urls: _urls,
      );

  PhpBridge get phpBridge => _phpBridge;

  void updatePhpBridge(PhpBridge bridge) {
    _phpBridge = bridge;
  }

  /// Replaces the document root. The server must be stopped (use
  /// [switchDocumentRoot] to restart automatically).
  void updateDocumentRoot(Directory directory) {
    _documentRoot = p.normalize(p.absolute(directory.path));
    _emit();
  }

  /// Starts the server. Throws [PortInUseFailure] when the port is taken and
  /// [NotFoundFailure] when the document root does not exist.
  Future<WebServerSnapshot> start({
    required int port,
    required bool lanAccess,
  }) async {
    if (_state == ServiceState.running || _state == ServiceState.starting) {
      return snapshot;
    }
    if (port < 0 || port > 65535) {
      throw const ValidationFailure('Port must be between 0 and 65535');
    }
    final Directory root = Directory(_documentRoot);
    if (!await root.exists()) {
      _setState(ServiceState.error, error: 'Document root does not exist');
      throw const NotFoundFailure('Document root does not exist');
    }
    _lanAccess = lanAccess;
    _stopRequested = false;
    _error = null;
    _setState(ServiceState.starting);

    final InternetAddress address =
        lanAccess ? InternetAddress.anyIPv4 : InternetAddress.loopbackIPv4;
    try {
      final HttpServer server =
          await HttpServer.bind(address, port, shared: false);
      server.autoCompress = true;
      server.defaultResponseHeaders.clear();
      _server = server;
      _bindAddress = address.address;
      _startedAt = DateTime.now();
      _requestCount = 0;
      _errorCount = 0;
      _urls = await _buildUrls(server.port, lanAccess);
      _subscription = server.listen(
        _handleRequest,
        onError: _handleServerError,
        onDone: _handleServerDone,
        cancelOnError: false,
      );
      _setState(ServiceState.running);
      _logs.info(
        LogSource.webServer,
        'Serving $_documentRoot on ${address.address}:${server.port}',
      );
      return snapshot;
    } on SocketException catch (error) {
      final int? code = error.osError?.errorCode;
      final String detail =
          '${error.message} ${error.osError?.message ?? ''}'.toLowerCase();
      bool inUse = code == 98 ||
          code == 48 ||
          code == 10048 ||
          detail.contains('in use') ||
          detail.contains('address already');
      if (!inUse && port != 0) {
        // Some Android/Dart combinations report a generic socket failure. In
        // that case probe the port to tell "already bound" from "not allowed".
        Socket? probe;
        try {
          probe = await Socket.connect(
            address,
            port,
            timeout: const Duration(milliseconds: 400),
          );
          inUse = true;
        } on Object {
          inUse = false;
        } finally {
          probe?.destroy();
        }
      }
      _server = null;
      _setState(
        ServiceState.error,
        error: inUse
            ? 'Port $port is already in use'
            : 'Could not bind port $port',
      );
      _logs.error(LogSource.webServer, 'Bind failed on port $port: ${error.message}');
      if (inUse) {
        throw PortInUseFailure(port, details: 'Choose another port in Settings');
      }
      throw AppFailure('Could not start the local server', details: error.message);
    } on Object catch (error) {
      _server = null;
      _setState(ServiceState.error, error: 'Unexpected server error');
      _logs.error(LogSource.webServer, 'Start failed: $error');
      throw AppFailure('Could not start the local server', details: '$error');
    }
  }

  Future<WebServerSnapshot> stop() async {
    if (_server == null) {
      _setState(ServiceState.stopped, clearError: true);
      return snapshot;
    }
    _stopRequested = true;
    _setState(ServiceState.stopping);
    final StreamSubscription<HttpRequest>? subscription = _subscription;
    _subscription = null;
    try {
      await subscription?.cancel();
    } on Object {
      // Cancelling an already closed subscription is harmless.
    }
    final HttpServer? server = _server;
    _server = null;
    try {
      await server?.close(force: true);
    } on Object {
      // Ignore double close.
    }
    _startedAt = null;
    _urls = const <String>[];
    _bindAddress = null;
    _setState(ServiceState.stopped, clearError: true);
    _logs.info(LogSource.webServer, 'Server stopped');
    return snapshot;
  }

  Future<WebServerSnapshot> restart({
    int? port,
    bool? lanAccess,
  }) async {
    final int targetPort = port ?? _server?.port ?? AppInfo.defaultHttpPort;
    final bool targetLan = lanAccess ?? _lanAccess;
    await stop();
    return start(port: targetPort, lanAccess: targetLan);
  }

  /// Switches the served folder, restarting the server if it was running.
  Future<WebServerSnapshot> switchDocumentRoot(
    Directory directory, {
    required int port,
    required bool lanAccess,
  }) async {
    final bool wasRunning = _state == ServiceState.running;
    await stop();
    updateDocumentRoot(directory);
    if (wasRunning) {
      return start(port: port, lanAccess: lanAccess);
    }
    return snapshot;
  }

  Future<void> dispose() async {
    await stop();
    await _controller.close();
  }

  Future<List<String>> _buildUrls(int port, bool lanAccess) async {
    final List<String> urls = <String>['http://127.0.0.1:$port/'];
    if (lanAccess) {
      for (final String ip in await _localIpv4Addresses()) {
        urls.add('http://$ip:$port/');
      }
    }
    return urls;
  }

  static Future<List<String>> _localIpv4Addresses() async {
    final List<String> addresses = <String>[];
    try {
      final List<NetworkInterface> interfaces =
          await NetworkInterface.list(type: InternetAddressType.IPv4);
      for (final NetworkInterface interface in interfaces) {
        for (final InternetAddress address in interface.addresses) {
          if (!address.isLoopback) {
            addresses.add(address.address);
          }
        }
      }
    } on SocketException {
      // LAN addresses are informational only.
    }
    return addresses;
  }

  void _setState(ServiceState state, {String? error, bool clearError = false}) {
    _state = state;
    if (clearError) {
      _error = null;
    } else if (error != null) {
      _error = error;
    }
    _emit();
  }

  void _emit() {
    if (!_controller.isClosed) {
      _controller.add(snapshot);
    }
  }

  void _handleServerError(Object error) {
    _errorCount++;
    _error = 'Server error: $error';
    _logs.error(LogSource.webServer, 'Server error: $error');
    _setState(ServiceState.error, error: _error);
  }

  void _handleServerDone() {
    if (_stopRequested) {
      return;
    }
    _error = 'Server stopped unexpectedly';
    _logs.error(LogSource.webServer, _error!);
    _server = null;
    _startedAt = null;
    _urls = const <String>[];
    _setState(ServiceState.error, error: _error);
  }

  Future<void> _handleRequest(HttpRequest request) async {
    final Stopwatch stopwatch = Stopwatch()..start();
    int status = 500;
    _requestCount++;
    try {
      status = await _route(request);
    } on Object catch (error, stackTrace) {
      _errorCount++;
      _logs.error(
        LogSource.webServer,
        '${request.method} ${request.uri.path} failed: $error',
      );
      _logs.debug(LogSource.webServer, '$stackTrace');
      status = await _safeError(request, HttpStatus.internalServerError);
    } finally {
      stopwatch.stop();
      _logs.info(
        LogSource.webServer,
        '${request.method} ${request.uri.path} -> $status '
            '(${stopwatch.elapsedMilliseconds} ms)',
      );
      _emit();
    }
  }

  Future<int> _route(HttpRequest request) async {
    final String method = request.method.toUpperCase();
    if (method != 'GET' && method != 'HEAD') {
      request.response.headers.set(HttpHeaders.allowHeader, 'GET, HEAD');
      return _respond(
        request,
        HttpStatus.methodNotAllowed,
        'text/plain; charset=utf-8',
        utf8.encode('Only GET and HEAD are supported\n'),
      );
    }

    final String requestPath;
    try {
      requestPath = _resolveRequestPath(request.uri);
    } on PathSecurityFailure {
      _logs.warning(
        LogSource.webServer,
        'Blocked suspicious path: ${request.uri.path}',
      );
      return _respond(
        request,
        HttpStatus.forbidden,
        'text/plain; charset=utf-8',
        utf8.encode('Forbidden\n'),
      );
    }

    if (requestPath == AppInfo.healthPath.substring(1)) {
      return _serveHealth(request);
    }

    final PathGuard guard = PathGuard(_documentRoot);
    final String target;
    try {
      target = requestPath.isEmpty
          ? guard.resolveRelative('.')
          : guard.resolveRelative(requestPath);
    } on AppFailure {
      return _respond(
        request,
        HttpStatus.forbidden,
        'text/plain; charset=utf-8',
        utf8.encode('Forbidden\n'),
      );
    }

    FileSystemEntityType type = FileSystemEntityType.notFound;
    try {
      type = await FileSystemEntity.type(target, followLinks: true);
    } on FileSystemException {
      type = FileSystemEntityType.notFound;
    }

    String resolved = target;
    if (type == FileSystemEntityType.directory) {
      final String? index = await _findIndex(resolved);
      if (index == null) {
        return _respond(
          request,
          HttpStatus.forbidden,
          'text/plain; charset=utf-8',
          utf8.encode('Directory listing is disabled\n'),
        );
      }
      resolved = index;
      type = FileSystemEntityType.file;
    }
    if (type != FileSystemEntityType.file) {
      return _respond(
        request,
        HttpStatus.notFound,
        'text/plain; charset=utf-8',
        utf8.encode('Not found\n'),
      );
    }
    if (!_isInsideRoot(resolved)) {
      _logs.warning(
        LogSource.webServer,
        'Blocked symlink escape: ${request.uri.path}',
      );
      return _respond(
        request,
        HttpStatus.forbidden,
        'text/plain; charset=utf-8',
        utf8.encode('Forbidden\n'),
      );
    }

    final String fileName = p.basename(resolved);
    if (p.extension(fileName).toLowerCase() == '.php') {
      return _servePhp(request, resolved, method);
    }
    return _serveFile(request, File(resolved), method);
  }

  /// Decodes the URI path defensively and rejects traversal attempts.
  String _resolveRequestPath(Uri uri) {
    String path = uri.path;
    for (int pass = 0; pass < 2; pass++) {
      if (!path.contains('%')) {
        break;
      }
      try {
        path = Uri.decodeComponent(path);
      } on FormatException {
        throw const PathSecurityFailure('Malformed percent encoding');
      } on ArgumentError {
        throw const PathSecurityFailure('Malformed percent encoding');
      }
    }
    if (path.contains('\u0000')) {
      throw const PathSecurityFailure('NUL byte in path');
    }
    path = path.replaceAll('\\', '/');
    if (RegExp(r'^[A-Za-z]:').hasMatch(path)) {
      throw const PathSecurityFailure('Drive letter in path');
    }
    final List<String> segments = <String>[];
    for (final String raw in path.split('/')) {
      if (raw.isEmpty) {
        continue;
      }
      if (raw == '.' || raw == '..') {
        throw const PathSecurityFailure('Traversal segment');
      }
      if (raw.startsWith('.')) {
        throw const PathSecurityFailure('Hidden paths are not served');
      }
      segments.add(raw);
    }
    return segments.join('/');
  }

  Future<String?> _findIndex(String directoryPath) async {
    for (final String candidate in <String>['index.html', 'index.htm', 'index.php']) {
      final File file = File(p.join(directoryPath, candidate));
      if (await file.exists()) {
        return file.path;
      }
    }
    return null;
  }

  bool _isInsideRoot(String absolutePath) {
    try {
      final String realRoot = Directory(_documentRoot).resolveSymbolicLinksSync();
      final String realTarget = File(absolutePath).resolveSymbolicLinksSync();
      return realTarget == realRoot || p.isWithin(realRoot, realTarget);
    } on FileSystemException {
      // Files that cannot be resolved are refused instead of guessed.
      return false;
    }
  }

  Future<int> _serveFile(
    HttpRequest request,
    File file,
    String method,
  ) async {
    final FileStat stat = await file.stat();
    if (stat.type != FileSystemEntityType.file) {
      return _respond(
        request,
        HttpStatus.notFound,
        'text/plain; charset=utf-8',
        utf8.encode('Not found\n'),
      );
    }
    final HttpResponse response = request.response;
    final String etag = 'W/"${stat.size}-${stat.modified.millisecondsSinceEpoch}"';
    response.headers
      ..set('Content-Type', MimeTypes.forFileName(file.path))
      ..set('X-Content-Type-Options', 'nosniff')
      ..set('ETag', etag)
      ..set('Last-Modified', HttpDate.format(stat.modified))
      ..set('Cache-Control', 'no-cache');
    final String? ifNoneMatch = request.headers.value('if-none-match');
    if (ifNoneMatch != null && ifNoneMatch == etag) {
      response.statusCode = HttpStatus.notModified;
      await response.close();
      return response.statusCode;
    }
    response.contentLength = stat.size;
    response.statusCode = HttpStatus.ok;
    if (method == 'HEAD') {
      await response.close();
      return response.statusCode;
    }
    try {
      await response.addStream(file.openRead());
      await response.close();
    } on FileSystemException {
      response.statusCode = HttpStatus.internalServerError;
      await response.close();
    }
    return response.statusCode;
  }

  Future<int> _servePhp(
    HttpRequest request,
    String scriptPath,
    String method,
  ) async {
    final PhpRuntimeInfo info = _phpBridge.info;
    if (!info.available) {
      final String message = '''
<!doctype html>
<html><head><meta charset="utf-8"><title>PHP runtime not installed</title></head>
<body style="font-family:sans-serif;background:#050706;color:#f1f7f2;padding:2rem">
<h1 style="color:#ffb03a">PHP runtime not installed</h1>
<p>PALLSQL served this request as a PHP script, but no PHP runtime is
installed, so the source code was <strong>not</strong> sent to the browser.</p>
<p>Install a <code>php-cgi</code> binary in <code>PALLSQL/config/php/php-cgi</code>
(or package <code>libphp-cgi.so</code> for the device ABI) and restart the
server. See the PHP page inside the app for details.</p>
</body></html>
''';
      return _respond(
        request,
        HttpStatus.notImplemented,
        'text/html; charset=utf-8',
        utf8.encode(message),
      );
    }

    List<int> body = const <int>[];
    if (method != 'HEAD') {
      try {
        body = await _readBody(request);
      } on AppFailure catch (failure) {
        return _respond(
          request,
          HttpStatus.requestEntityTooLarge,
          'text/plain; charset=utf-8',
          utf8.encode('${failure.message}\n'),
        );
      }
    }

    final String relativeScript =
        p.relative(scriptPath, from: _documentRoot).replaceAll('\\', '/');
    final PhpCgiRequest cgiRequest = PhpCgiRequest(
      scriptPath: scriptPath,
      scriptName: '/$relativeScript',
      documentRoot: _documentRoot,
      method: method,
      uri: request.uri,
      headers: _requestHeaders(request),
      body: body,
      remoteAddress: request.connectionInfo?.remoteAddress.address ?? '127.0.0.1',
      serverName: _bindAddress ?? '127.0.0.1',
      serverPort: _server?.port ?? AppInfo.defaultHttpPort,
    );

    final PhpCgiResponse cgiResponse = await _phpBridge.execute(cgiRequest);
    final HttpResponse response = request.response;
    response.statusCode = cgiResponse.statusCode;
    cgiResponse.headers.forEach((String name, String value) {
      if (name.toLowerCase() == 'content-length') {
        return;
      }
      response.headers.set(name, value);
    });
    response.headers.set('X-Content-Type-Options', 'nosniff');
    response.contentLength = cgiResponse.body.length;
    if (method != 'HEAD') {
      response.add(cgiResponse.body);
    }
    final String stderr = cgiResponse.stderr.trim();
    if (stderr.isNotEmpty) {
      final String preview =
          stderr.length > 400 ? '${stderr.substring(0, 400)}...' : stderr;
      _logs.warning(LogSource.php, 'PHP stderr: $preview');
    }
    await response.close();
    return response.statusCode;
  }

  Map<String, String> _requestHeaders(HttpRequest request) {
    final Map<String, String> headers = <String, String>{};
    request.headers.forEach((String name, List<String> values) {
      headers[name] = values.join(', ');
    });
    return headers;
  }

  Future<List<int>> _readBody(HttpRequest request) async {
    final List<int> buffer = <int>[];
    await for (final List<int> chunk in request) {
      buffer.addAll(chunk);
      if (buffer.length > maxRequestBytes) {
        throw ValidationFailure(
          'Request body exceeds ${maxRequestBytes ~/ (1024 * 1024)} MB',
        );
      }
    }
    return buffer;
  }

  Future<int> _serveHealth(HttpRequest request) async {
    final Map<String, Object?> payload = <String, Object?>{
      'app': _serverName,
      'state': _state.name,
      'port': _server?.port,
      'documentRoot': p.basename(_documentRoot),
      'requests': _requestCount,
      'errors': _errorCount,
      'php': _phpBridge.info.available,
      'uptimeSeconds': _startedAt == null
          ? 0
          : DateTime.now().difference(_startedAt!).inSeconds,
    };
    return _respond(
      request,
      HttpStatus.ok,
      'application/json; charset=utf-8',
      utf8.encode(jsonEncode(payload)),
    );
  }

  Future<int> _respond(
    HttpRequest request,
    int status,
    String contentType,
    List<int> body,
  ) async {
    final HttpResponse response = request.response;
    response.statusCode = status;
    response.headers
      ..set('Content-Type', contentType)
      ..set('X-Content-Type-Options', 'nosniff')
      ..set('Cache-Control', 'no-store');
    response.contentLength = body.length;
    if (request.method.toUpperCase() != 'HEAD') {
      response.add(body);
    }
    await response.close();
    return status;
  }

  Future<int> _safeError(HttpRequest request, int status) async {
    try {
      return await _respond(
        request,
        status,
        'text/plain; charset=utf-8',
        utf8.encode('Internal server error\n'),
      );
    } on Object {
      try {
        await request.response.close();
      } on Object {
        // Nothing else can be done for a broken connection.
      }
      return status;
    }
  }
}
