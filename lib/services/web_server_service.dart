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
            : (isRunning
                ? 'Listening on ${bindAddress ?? ''}:${port ?? ''}'
                : null),
      );

  String get primaryUrl => urls.isNotEmpty
      ? urls.first
      : 'http://127.0.0.1:${port ?? AppInfo.defaultHttpPort}/';

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

  /// Files up to this size are read into memory so the response body and the
  /// declared `Content-Length` are guaranteed to be the same bytes.
  static const int maxBufferedFileBytes = 8 * 1024 * 1024;

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
  Future<WebServerSnapshot>? _starting;
  bool _phpUnavailableLogged = false;
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
  ///
  /// Only ever one instance exists: a second call while `starting` or
  /// `running` returns the same future instead of binding a second socket.
  Future<WebServerSnapshot> start({
    required int port,
    required bool lanAccess,
  }) {
    final Future<WebServerSnapshot>? pending = _starting;
    if (pending != null) {
      return pending;
    }
    if (_state == ServiceState.running) {
      return Future<WebServerSnapshot>.value(snapshot);
    }
    final Future<WebServerSnapshot> future =
        _start(port: port, lanAccess: lanAccess);
    _starting = future;
    // Handle both completion paths here: a bare `whenComplete` would rethrow
    // a bind failure as an uncaught async error for the caller that awaits
    // [future] via `expectLater` / try-catch.
    future.then<void>(
      (_) => _clearStarting(future),
      onError: (Object error, StackTrace stackTrace) => _clearStarting(future),
    );
    return future;
  }

  void _clearStarting(Future<WebServerSnapshot> future) {
    if (identical(_starting, future)) {
      _starting = null;
    }
  }

  Future<WebServerSnapshot> _start({
    required int port,
    required bool lanAccess,
  }) async {
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
      // Responses are written with an explicit Content-Length (see
      // [_serveFile]); enabling gzip on top of that only rewrites the body of
      // streamed files, so compression stays off to keep the byte count honest.
      server.autoCompress = false;
      server.defaultResponseHeaders.clear();
      if (_stopRequested) {
        // stop() arrived while the socket was being bound.
        await server.close(force: true);
        _setState(ServiceState.stopped, clearError: true);
        return snapshot;
      }
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
      _logs.error(
          LogSource.webServer, 'Bind failed on port $port: ${error.message}');
      if (inUse) {
        throw PortInUseFailure(port,
            details: 'Choose another port in Settings');
      }
      throw AppFailure('Could not start the local server',
          details: error.message);
    } on Object catch (error) {
      _server = null;
      _setState(ServiceState.error, error: 'Unexpected server error');
      _logs.error(LogSource.webServer, 'Start failed: $error');
      throw AppFailure('Could not start the local server', details: '$error');
    }
  }

  Future<WebServerSnapshot> stop() async {
    _stopRequested = true;
    final Future<WebServerSnapshot>? pending = _starting;
    if (pending != null) {
      try {
        await pending;
      } on Object {
        // A failed start leaves nothing to close.
      }
    }
    if (_server == null) {
      _setState(ServiceState.stopped, clearError: true);
      return snapshot;
    }
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
        // The landing page of the site is missing: answer with a real 404 and
        // an explanation instead of an empty success response.
        final bool isRoot = requestPath.isEmpty;
        _logs.warning(
          LogSource.webServer,
          isRoot
              ? 'No index.html in the document root'
              : 'Directory listing is disabled: ${request.uri.path}',
        );
        return _respond(
          request,
          isRoot ? HttpStatus.notFound : HttpStatus.forbidden,
          'text/html; charset=utf-8',
          utf8.encode(_missingIndexPage(isRoot: isRoot)),
        );
      }
      resolved = index;
      type = FileSystemEntityType.file;
    }
    if (type != FileSystemEntityType.file) {
      return _notFound(request);
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
    for (final String candidate in <String>[
      'index.html',
      'index.htm',
      'index.php'
    ]) {
      final File file = File(p.join(directoryPath, candidate));
      if (await file.exists()) {
        return file.path;
      }
    }
    return null;
  }

  bool _isInsideRoot(String absolutePath) {
    try {
      final String realRoot =
          Directory(_documentRoot).resolveSymbolicLinksSync();
      final String realTarget = File(absolutePath).resolveSymbolicLinksSync();
      return realTarget == realRoot || p.isWithin(realRoot, realTarget);
    } on FileSystemException {
      // Files that cannot be resolved are refused instead of guessed.
      return false;
    }
  }

  /// Serves a static file.
  ///
  /// The bytes are read *before* the response headers are written, so
  /// `Content-Length` always matches the payload. A read that fails produces a
  /// real 500 instead of a "200 OK" with no body — the latter is what makes a
  /// browser render a blank page.
  ///
  /// Caching rules:
  /// * HTML documents are sent with `Cache-Control: no-store` and no validators,
  ///   so editing a page and reloading always shows the new bytes;
  /// * every other asset gets a strong `ETag` (content hash), `Last-Modified`
  ///   and `Cache-Control: no-cache`, and answers `304` only when the request
  ///   validators actually match the current file.
  Future<int> _serveFile(
    HttpRequest request,
    File file,
    String method,
  ) async {
    final FileStat stat = await file.stat();
    if (stat.type != FileSystemEntityType.file) {
      return _notFound(request);
    }
    final String contentType = MimeTypes.forFileName(file.path);
    final bool isDocument = MimeTypes.isHtml(contentType);
    final bool buffered = stat.size <= maxBufferedFileBytes;

    List<int>? bytes;
    if (buffered) {
      try {
        bytes = await file.readAsBytes();
      } on FileSystemException catch (error) {
        _logs.error(
          LogSource.webServer,
          'Could not read ${p.basename(file.path)}: ${error.message}',
        );
        return _respond(
          request,
          HttpStatus.internalServerError,
          'text/plain; charset=utf-8',
          utf8.encode('The requested file could not be read\n'),
        );
      }
    }

    final Map<String, String> headers = <String, String>{
      'Content-Type': contentType,
      'X-Content-Type-Options': 'nosniff',
    };
    if (isDocument) {
      headers['Cache-Control'] = 'no-store';
    } else {
      headers['Cache-Control'] = 'no-cache';
      final String etag =
          bytes == null ? _statEtag(stat) : _contentEtag(bytes, stat);
      headers['ETag'] = etag;
      headers['Last-Modified'] = HttpDate.format(stat.modified);
      if (_matchesEtag(request, etag) ||
          _notModifiedSince(request, stat.modified)) {
        return _writeResponse(
          request,
          HttpStatus.notModified,
          headers,
          const <int>[],
        );
      }
    }

    if (bytes != null) {
      return _writeResponse(request, HttpStatus.ok, headers, bytes);
    }
    return _streamFile(request, file, method, stat, headers);
  }

  /// Streams a file that is too large to buffer (media, archives).
  Future<int> _streamFile(
    HttpRequest request,
    File file,
    String method,
    FileStat stat,
    Map<String, String> headers,
  ) async {
    final HttpResponse response = request.response;
    response.statusCode = HttpStatus.ok;
    headers.forEach(response.headers.set);
    response.contentLength = stat.size;
    if (method == 'HEAD') {
      await response.close();
      return HttpStatus.ok;
    }
    try {
      await response.addStream(file.openRead());
      await response.close();
    } on Object catch (error) {
      // The headers are already on the wire; the only safe move is to drop the
      // connection so the browser does not accept a truncated file.
      _logs.error(
        LogSource.webServer,
        'Streaming ${p.basename(file.path)} failed: $error',
      );
      try {
        await response.close();
      } on Object {
        // The socket is gone.
      }
    }
    return HttpStatus.ok;
  }

  /// Writes a fully buffered response with an exact length.
  Future<int> _writeResponse(
    HttpRequest request,
    int status,
    Map<String, String> headers,
    List<int> body,
  ) async {
    final HttpResponse response = request.response;
    response.statusCode = status;
    headers.forEach(response.headers.set);
    if (status == HttpStatus.notModified) {
      // 304 carries no body and no length.
      await response.close();
      return status;
    }
    response.contentLength = body.length;
    if (request.method.toUpperCase() != 'HEAD' && body.isNotEmpty) {
      response.add(body);
    }
    await response.close();
    return status;
  }

  /// A strong validator derived from the bytes we are about to send.
  ///
  /// FNV-1a over 32 bits keeps the arithmetic inside the safe integer range on
  /// every Dart runtime, and the modification time is part of the tag so an
  /// in-place edit always invalidates it.
  String _contentEtag(List<int> bytes, FileStat stat) {
    int hash = 0x811c9dc5;
    for (final int byte in bytes) {
      hash ^= byte;
      hash = (hash * 0x01000193) & 0xFFFFFFFF;
    }
    return '"${hash.toRadixString(16)}-${bytes.length}-'
        '${stat.modified.toUtc().millisecondsSinceEpoch}"';
  }

  /// Fallback validator for files that are streamed instead of hashed.
  String _statEtag(FileStat stat) =>
      '"${stat.size}-${stat.modified.toUtc().millisecondsSinceEpoch}"';

  /// RFC 9110 weak comparison of `If-None-Match`.
  bool _matchesEtag(HttpRequest request, String etag) {
    final String? header =
        request.headers.value(HttpHeaders.ifNoneMatchHeader);
    if (header == null || header.trim().isEmpty) {
      return false;
    }
    final String target = _normalizeEtag(etag);
    for (final String candidate in header.split(',')) {
      final String value = candidate.trim();
      if (value == '*') {
        return true;
      }
      if (_normalizeEtag(value) == target) {
        return true;
      }
    }
    return false;
  }

  String _normalizeEtag(String value) {
    String tag = value.trim();
    if (tag.startsWith('W/')) {
      tag = tag.substring(2);
    }
    return tag;
  }

  /// Evaluates `If-Modified-Since`, which only applies when the request did not
  /// send `If-None-Match`.
  bool _notModifiedSince(HttpRequest request, DateTime modified) {
    if (request.headers.value(HttpHeaders.ifNoneMatchHeader) != null) {
      return false;
    }
    final String? raw =
        request.headers.value(HttpHeaders.ifModifiedSinceHeader);
    if (raw == null || raw.trim().isEmpty) {
      return false;
    }
    final DateTime? since = _tryParseHttpDate(raw);
    if (since == null) {
      return false;
    }
    // `Last-Modified` has second precision.
    final DateTime lastModified = _truncateToSeconds(modified);
    return !lastModified.isAfter(since);
  }

  DateTime? _tryParseHttpDate(String value) {
    try {
      return _truncateToSeconds(HttpDate.parse(value));
    } on Object {
      return null;
    }
  }

  DateTime _truncateToSeconds(DateTime value) {
    final DateTime utc = value.toUtc();
    return DateTime.utc(
      utc.year,
      utc.month,
      utc.day,
      utc.hour,
      utc.minute,
      utc.second,
    );
  }

  Future<int> _notFound(HttpRequest request) => _respond(
        request,
        HttpStatus.notFound,
        'text/plain; charset=utf-8',
        utf8.encode('Not found: ${request.uri.path}\n'),
      );

  String _missingIndexPage({required bool isRoot}) {
    final String heading =
        isRoot ? 'No index.html yet' : 'Directory listing is disabled';
    final String detail = isRoot
        ? 'The document root <code>${_htmlEscape(_documentRoot)}</code> does '
            'not contain an <code>index.html</code>. Create one from the Files '
            'tab and reload this page.'
        : 'PALLSQL never lists directory contents. Request a file instead, or '
            'add an <code>index.html</code> to this folder.';
    return '''
<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>PALLSQL local server</title>
<style>
body{margin:0;min-height:100vh;display:grid;place-items:center;background:#050706;
color:#f1f7f2;font:16px/1.5 system-ui,sans-serif}
main{max-width:32rem;padding:2rem}
h1{color:#9bff3d;font-size:1.3rem;letter-spacing:.04em}
code{color:#9bff3d} p{color:#93a197}
</style></head>
<body><main><h1>$heading</h1><p>$detail</p></main></body></html>
''';
  }

  String _htmlEscape(String value) => value
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');

  Future<int> _servePhp(
    HttpRequest request,
    String scriptPath,
    String method,
  ) async {
    final PhpRuntimeInfo info = _phpBridge.info;
    if (!info.available) {
      if (!_phpUnavailableLogged) {
        _phpUnavailableLogged = true;
        _logs.warning(
          LogSource.php,
          'PHP runtime is not available: ${info.reason ?? 'no runtime found'}. '
          'PHP requests answer HTTP 501 while static files keep working.',
        );
      }
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
      remoteAddress:
          request.connectionInfo?.remoteAddress.address ?? '127.0.0.1',
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
