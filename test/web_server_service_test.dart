import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pallsql/core/errors/app_failure.dart';
import 'package:pallsql/models/service_status.dart';
import 'package:pallsql/services/log_sink.dart';
import 'package:pallsql/services/php_runtime_service.dart';
import 'package:pallsql/services/web_server_service.dart';

/// Fake PHP bridge that records the request it received.
class _FakePhpBridge implements PhpBridge {
  PhpCgiRequest? lastRequest;

  @override
  PhpRuntimeInfo get info => const PhpRuntimeInfo(
        available: true,
        version: '8.3.0',
        binaryPath: '/tmp/php-cgi',
      );

  @override
  Future<PhpCgiResponse> execute(PhpCgiRequest request) async {
    lastRequest = request;
    return PhpCgiResponse(
      statusCode: 200,
      headers: const <String, String>{'Content-Type': 'text/plain'},
      body:
          utf8.encode('hello from php: ${request.method} ${request.uri.path}'),
    );
  }
}

Future<HttpClientResponse> get(String url,
    {Map<String, String>? headers}) async {
  final HttpClient client = HttpClient();
  final HttpClientRequest request = await client.getUrl(Uri.parse(url));
  headers?.forEach(request.headers.set);
  final HttpClientResponse response = await request.close();
  return response;
}

void main() {
  late Directory root;
  late WebServerService service;
  late HttpClient client;
  late int port;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('pallsql_www_');
    await File('${root.path}/index.html').writeAsString('<h1>home</h1>');
    await File('${root.path}/style.css').writeAsString('body { color: red; }');
    await File('${root.path}/app.json').writeAsString('{"ok": true}');
    await File('${root.path}/secret.txt').writeAsString('top secret');
    await File('${root.path}/leak.php')
        .writeAsString('<?php echo "LEAKED SOURCE"; ?>');
    await Directory('${root.path}/listing').create();
    await File('${root.path}/listing/a.txt').writeAsString('a');
    service = WebServerService(documentRoot: root, logs: const NullLogSink());
    await service.start(port: 0, lanAccess: false);
    port = service.snapshot.port!;
    client = HttpClient();
  });

  tearDown(() async {
    client.close(force: true);
    await service.dispose();
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  });

  test('serves the directory index with the right content type', () async {
    final HttpClientResponse response = await get('http://127.0.0.1:$port/');
    expect(response.statusCode, 200);
    expect(response.headers.contentType?.mimeType, 'text/html');
    final String body = await utf8.decodeStream(response);
    expect(body, contains('home'));
  });

  test('serves nested assets with proper MIME types', () async {
    final HttpClientResponse css =
        await get('http://127.0.0.1:$port/style.css');
    expect(css.headers.contentType?.mimeType, 'text/css');
    await css.drain<void>();

    final HttpClientResponse json =
        await get('http://127.0.0.1:$port/app.json');
    expect(json.headers.contentType?.mimeType, 'application/json');
    await json.drain<void>();
  });

  test('returns 404 for missing files', () async {
    final HttpClientResponse response =
        await get('http://127.0.0.1:$port/missing.html');
    expect(response.statusCode, 404);
    await response.drain<void>();
  });

  test('blocks traversal including encoded variants', () async {
    // The Dart HTTP client normalises a literal `/../` before it reaches the
    // server, so only encoded traversal attempts are meaningful here.
    for (final String path in <String>[
      '/..%2fsecret.txt',
      '/%252e%252e/secret.txt',
      '/..%5csecret.txt',
      '/%2e%2e%2fsecret.txt',
      '/%252e%252e%252fsecret.txt',
    ]) {
      final HttpClientResponse response =
          await get('http://127.0.0.1:$port$path');
      expect(
        response.statusCode,
        anyOf(403, 404),
        reason: 'path $path should not be served',
      );
      final String body = await utf8.decodeStream(response);
      expect(body.contains('top secret'), isFalse);
    }
  });

  test('does not serve hidden files', () async {
    await File('${root.path}/.env').writeAsString('SECRET=1');
    final HttpClientResponse response =
        await get('http://127.0.0.1:$port/.env');
    expect(response.statusCode, anyOf(403, 404));
    final String body = await utf8.decodeStream(response);
    expect(body.contains('SECRET=1'), isFalse);
  });

  test('disables directory listing', () async {
    final HttpClientResponse response =
        await get('http://127.0.0.1:$port/listing/');
    expect(response.statusCode, 403);
    final String body = await utf8.decodeStream(response);
    expect(body, contains('listing is disabled'));
    expect(body.contains('a.txt'), isFalse);
  });

  test('rejects unsupported methods', () async {
    final HttpClientRequest request =
        await client.postUrl(Uri.parse('http://127.0.0.1:$port/'));
    final HttpClientResponse response = await request.close();
    expect(response.statusCode, 405);
    expect(response.headers.value('allow'), contains('GET'));
    await response.drain<void>();
  });

  test('answers HEAD without a body', () async {
    final HttpClientRequest request =
        await client.headUrl(Uri.parse('http://127.0.0.1:$port/index.html'));
    final HttpClientResponse response = await request.close();
    expect(response.statusCode, 200);
    expect(response.contentLength, greaterThan(0));
    final List<int> body = await response.fold<List<int>>(
      <int>[],
      (List<int> previous, List<int> chunk) => previous..addAll(chunk),
    );
    expect(body, isEmpty);
  });

  test('supports ETag revalidation', () async {
    final HttpClientResponse first =
        await get('http://127.0.0.1:$port/index.html');
    await first.drain<void>();
    final String? etag = first.headers.value('etag');
    expect(etag, isNotNull);
    final HttpClientResponse second = await get(
      'http://127.0.0.1:$port/index.html',
      headers: <String, String>{'if-none-match': etag!},
    );
    expect(second.statusCode, 304);
    await second.drain<void>();
  });

  test('never serves PHP sources and answers 501 without a runtime', () async {
    final HttpClientResponse response =
        await get('http://127.0.0.1:$port/leak.php');
    expect(response.statusCode, 501);
    final String body = await utf8.decodeStream(response);
    expect(body.contains('LEAKED SOURCE'), isFalse);
    expect(body.contains('<?php'), isFalse);
    expect(body.toLowerCase(), contains('php runtime not installed'));
  });

  test('executes PHP through the injected runtime bridge', () async {
    final _FakePhpBridge bridge = _FakePhpBridge();
    service.updatePhpBridge(bridge);
    final HttpClientResponse response =
        await get('http://127.0.0.1:$port/leak.php');
    expect(response.statusCode, 200);
    final String body = await utf8.decodeStream(response);
    expect(body, contains('hello from php'));
    expect(bridge.lastRequest?.scriptPath, endsWith('leak.php'));
    expect(body.contains('LEAKED SOURCE'), isFalse);
  });

  test('blocks symlinks that escape the document root', () async {
    final Directory outside =
        await Directory.systemTemp.createTemp('pallsql_outside_');
    final File secret = File('${outside.path}/outside.txt');
    await secret.writeAsString('outside secret');
    final Link link = Link('${root.path}/link.txt');
    await link.create(secret.path);
    final HttpClientResponse response =
        await get('http://127.0.0.1:$port/link.txt');
    expect(response.statusCode, anyOf(403, 404));
    final String body = await utf8.decodeStream(response);
    expect(body.contains('outside secret'), isFalse);
    await outside.delete(recursive: true);
  });

  test('exposes a health endpoint', () async {
    final HttpClientResponse response =
        await get('http://127.0.0.1:$port/__pallsql/health');
    expect(response.statusCode, 200);
    final Map<String, Object?> payload = jsonDecode(
      await utf8.decodeStream(response),
    ) as Map<String, Object?>;
    expect(payload['app'], 'PALLSQL');
    expect(payload['state'], 'running');
    expect(payload['port'], port);
  });

  test('binds to loopback when LAN access is disabled', () async {
    expect(service.snapshot.bindAddress, '127.0.0.1');
    expect(service.snapshot.urls.first, startsWith('http://127.0.0.1:'));
  });

  test('detects port conflicts', () async {
    final WebServerService second =
        WebServerService(documentRoot: root, logs: const NullLogSink());
    await expectLater(
      second.start(port: port, lanAccess: false),
      throwsA(isA<PortInUseFailure>()),
    );
    expect(second.snapshot.state, ServiceState.error);
    await second.dispose();
  });

  test('stops and reports the real state', () async {
    await service.stop();
    expect(service.snapshot.state, ServiceState.stopped);
    expect(service.snapshot.port, isNull);
    await expectLater(
      get('http://127.0.0.1:$port/'),
      throwsA(isA<SocketException>()),
    );
  });

  test('switches the document root', () async {
    final Directory other =
        await Directory.systemTemp.createTemp('pallsql_www2_');
    await File('${other.path}/index.html').writeAsString('<h1>second</h1>');
    await service.switchDocumentRoot(other, port: port, lanAccess: false);
    final HttpClientResponse response = await get('http://127.0.0.1:$port/');
    final String body = await utf8.decodeStream(response);
    expect(body, contains('second'));
    await other.delete(recursive: true);
  });
}
