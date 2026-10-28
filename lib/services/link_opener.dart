import 'package:url_launcher/url_launcher.dart';

import '../models/log_entry.dart';
import 'log_sink.dart';
import 'native_bridge.dart';

/// Opens external links (the local website in a browser).
abstract class LinkOpener {
  Future<bool> open(String url);
}

/// Uses the Android intent bridge first and falls back to `url_launcher`.
class NativeLinkOpener implements LinkOpener {
  NativeLinkOpener({required NativeBridge native, required LogSink logs})
      : _native = native,
        _logs = logs;

  final NativeBridge _native;
  final LogSink _logs;

  @override
  Future<bool> open(String url) async {
    final Uri? uri = Uri.tryParse(url);
    if (uri == null) {
      return false;
    }
    if (await _native.openUrl(url)) {
      return true;
    }
    try {
      final bool launched =
          await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!launched) {
        _logs.warning(LogSource.app, 'No browser available for $url');
      }
      return launched;
    } on Object catch (error) {
      _logs.error(LogSource.app, 'Could not open $url: $error');
      return false;
    }
  }
}
