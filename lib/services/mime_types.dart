import 'package:path/path.dart' as p;

/// Minimal, dependency free MIME type resolver used by the local web server.
class MimeTypes {
  const MimeTypes._();

  static const String defaultType = 'application/octet-stream';

  static const Map<String, String> _types = <String, String>{
    'html': 'text/html; charset=utf-8',
    'htm': 'text/html; charset=utf-8',
    'css': 'text/css; charset=utf-8',
    'js': 'text/javascript; charset=utf-8',
    'mjs': 'text/javascript; charset=utf-8',
    'json': 'application/json; charset=utf-8',
    'map': 'application/json; charset=utf-8',
    'xml': 'application/xml; charset=utf-8',
    'txt': 'text/plain; charset=utf-8',
    'md': 'text/markdown; charset=utf-8',
    'csv': 'text/csv; charset=utf-8',
    'log': 'text/plain; charset=utf-8',
    'svg': 'image/svg+xml',
    'png': 'image/png',
    'jpg': 'image/jpeg',
    'jpeg': 'image/jpeg',
    'gif': 'image/gif',
    'webp': 'image/webp',
    'avif': 'image/avif',
    'ico': 'image/x-icon',
    'bmp': 'image/bmp',
    'woff': 'font/woff',
    'woff2': 'font/woff2',
    'ttf': 'font/ttf',
    'otf': 'font/otf',
    'eot': 'application/vnd.ms-fontobject',
    'mp4': 'video/mp4',
    'webm': 'video/webm',
    'mp3': 'audio/mpeg',
    'ogg': 'audio/ogg',
    'wav': 'audio/wav',
    'pdf': 'application/pdf',
    'zip': 'application/zip',
    'wasm': 'application/wasm',
    'webmanifest': 'application/manifest+json',
    'php': 'text/html; charset=utf-8',
    'sql': 'text/plain; charset=utf-8',
    'ini': 'text/plain; charset=utf-8',
  };

  /// Resolves the content type for a file name (extension based).
  static String forFileName(String fileName) {
    final String extension =
        p.extension(fileName).replaceFirst('.', '').toLowerCase();
    return _types[extension] ?? defaultType;
  }

  /// Documents are the entry point of a site, so the server treats them
  /// specially: they are always revalidated and never cached by the browser.
  static bool isHtml(String contentType) => contentType.startsWith('text/html');

  static bool isTextual(String contentType) =>
      contentType.startsWith('text/') ||
      contentType.contains('json') ||
      contentType.contains('xml') ||
      contentType.contains('javascript') ||
      contentType.contains('svg');
}
