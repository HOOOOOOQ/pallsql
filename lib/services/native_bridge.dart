import 'dart:async';

import 'package:flutter/services.dart';

import '../core/constants/app_info.dart';
import '../models/log_entry.dart';
import 'log_sink.dart';

/// Static information about the Android device and the PALLSQL installation.
class NativeDeviceInfo {
  const NativeDeviceInfo({
    required this.androidVersion,
    required this.sdkInt,
    required this.abis,
    required this.appVersion,
    required this.packageName,
    this.appDataDir,
  });

  final String androidVersion;
  final int sdkInt;
  final List<String> abis;
  final String appVersion;
  final String packageName;
  final String? appDataDir;

  static const NativeDeviceInfo unknown = NativeDeviceInfo(
    androidVersion: 'unknown',
    sdkInt: 0,
    abis: <String>[],
    appVersion: AppInfo.version,
    packageName: AppInfo.packageName,
  );
}

/// Storage statistics reported by Android (`StatFs`).
class NativeStorageStats {
  const NativeStorageStats({
    required this.appBytes,
    required this.freeBytes,
    required this.totalBytes,
  });

  final int appBytes;
  final int freeBytes;
  final int totalBytes;
}

/// Bridge to the Kotlin side of PALLSQL.
///
/// Every method degrades gracefully: when the platform channel is not available
/// (unit tests, desktop) the call returns `null`/`false` instead of throwing, so
/// no UI path depends on native code being present.
class NativeBridge {
  NativeBridge({LogSink? logs, MethodChannel? channel})
      : _logs = logs,
        _channel = channel ?? const MethodChannel(AppInfo.nativeChannel) {
    _attach();
  }

  NativeBridge.unavailable({LogSink? logs})
      : _logs = logs,
        _channel = null;

  final LogSink? _logs;
  final MethodChannel? _channel;
  final StreamController<Map<String, Object?>> _events =
      StreamController<Map<String, Object?>>.broadcast();
  bool _attached = false;

  bool get isAvailable => _channel != null;

  /// Events pushed by Android (for example foreground service state changes).
  Stream<Map<String, Object?>> get events => _events.stream;

  void _attach() {
    final MethodChannel? channel = _channel;
    if (channel == null || _attached) {
      return;
    }
    _attached = true;
    channel.setMethodCallHandler((MethodCall call) async {
      if (call.method == 'serviceStateChanged') {
        final Object? arguments = call.arguments;
        if (arguments is Map) {
          _events.add(arguments.map<String, Object?>(
            (Object? key, Object? value) =>
                MapEntry<String, Object?>('$key', value),
          ));
        }
      }
      return null;
    });
  }

  Future<NativeDeviceInfo?> deviceInfo() async {
    final Map<String, Object?>? result =
        await _invokeMap('getDeviceInfo', LogSource.app);
    if (result == null) {
      return null;
    }
    final Object? abis = result['abis'];
    return NativeDeviceInfo(
      androidVersion: result['androidVersion']?.toString() ?? 'unknown',
      sdkInt: (result['sdkInt'] as num?)?.toInt() ?? 0,
      abis: abis is List
          ? abis.map((Object? value) => value.toString()).toList(growable: false)
          : const <String>[],
      appVersion: result['appVersion']?.toString() ?? AppInfo.version,
      packageName: result['packageName']?.toString() ?? AppInfo.packageName,
      appDataDir: result['appDataDir']?.toString(),
    );
  }

  Future<NativeStorageStats?> storageStats() async {
    final Map<String, Object?>? result =
        await _invokeMap('getStorageStats', LogSource.files);
    if (result == null) {
      return null;
    }
    return NativeStorageStats(
      appBytes: (result['appBytes'] as num?)?.toInt() ?? 0,
      freeBytes: (result['freeBytes'] as num?)?.toInt() ?? 0,
      totalBytes: (result['totalBytes'] as num?)?.toInt() ?? 0,
    );
  }

  /// Promotes the running server to a foreground service so Android does not
  /// suspend the process while it serves requests.
  Future<bool> startForegroundService({
    required String title,
    required String text,
  }) async {
    final bool? result = await _invoke<bool>(
      'startForegroundService',
      <String, Object?>{'title': title, 'text': text},
      LogSource.app,
    );
    return result ?? false;
  }

  /// Absolute path of the APK's native library directory, which is the only
  /// executable location Android allows for packaged runtimes.
  Future<String?> nativeLibraryDir() {
    return _invoke<String>('getNativeLibraryDir', null, LogSource.app);
  }

  Future<bool> stopForegroundService() async {
    final bool? result =
        await _invoke<bool>('stopForegroundService', null, LogSource.app);
    return result ?? false;
  }

  /// Opens the system document picker and copies the chosen file into
  /// [destinationDirectory] (an absolute path inside the workspace).
  Future<String?> pickFileToImport({required String destinationDirectory}) {
    return _invoke<String>(
      'pickFile',
      <String, Object?>{'destinationDirectory': destinationDirectory},
      LogSource.files,
    );
  }

  /// Shares a workspace file through the Android share sheet.
  Future<bool> shareFile(String absolutePath, {String? mimeType}) async {
    final bool? result = await _invoke<bool>(
      'shareFile',
      <String, Object?>{'path': absolutePath, 'mimeType': mimeType},
      LogSource.files,
    );
    return result ?? false;
  }

  /// Opens a URL (for example the local website) in an external browser.
  Future<bool> openUrl(String url) async {
    final bool? result =
        await _invoke<bool>('openUrl', <String, Object?>{'url': url}, LogSource.app);
    return result ?? false;
  }

  Future<void> dispose() async {
    await _events.close();
  }

  Future<Map<String, Object?>?> _invokeMap(String method, LogSource source) async {
    final Object? result = await _invoke<Object?>(method, null, source);
    if (result is Map) {
      return result.map<String, Object?>(
        (Object? key, Object? value) => MapEntry<String, Object?>('$key', value),
      );
    }
    return null;
  }

  Future<T?> _invoke<T>(String method, Object? arguments, LogSource source) async {
    final MethodChannel? channel = _channel;
    if (channel == null) {
      return null;
    }
    try {
      return await channel.invokeMethod<T>(method, arguments);
    } on MissingPluginException {
      _logs?.log(
        LogLevel.debug,
        source,
        'Native method $method is not available on this platform',
      );
      return null;
    } on PlatformException catch (error) {
      _logs?.log(
        LogLevel.error,
        source,
        'Native method $method failed: ${error.code}'
        '${error.message == null ? '' : ' ${error.message}'}',
      );
      return null;
    }
  }
}
