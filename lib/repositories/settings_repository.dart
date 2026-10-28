import 'dart:convert';
import 'dart:io';

import '../core/errors/app_failure.dart';
import '../models/app_settings.dart';

/// Reads and writes `PALLSQL/config/settings.json`.
class SettingsRepository {
  SettingsRepository(this.file);

  final File file;

  Future<AppSettings> load() async {
    try {
      if (!await file.exists()) {
        final AppSettings defaults = AppSettings();
        await save(defaults);
        return defaults;
      }
      final String raw = await file.readAsString();
      if (raw.trim().isEmpty) {
        return AppSettings();
      }
      final Object? decoded = jsonDecode(raw);
      if (decoded is! Map<String, Object?>) {
        return AppSettings();
      }
      return AppSettings.fromJson(decoded);
    } on FormatException {
      // Damaged settings fall back to defaults instead of blocking startup.
      return AppSettings();
    } on FileSystemException {
      return AppSettings();
    }
  }

  Future<void> save(AppSettings settings) async {
    final List<String> issues = settings.validate();
    if (issues.isNotEmpty) {
      throw ValidationFailure('Invalid settings', details: issues.join('; '));
    }
    try {
      await file.parent.create(recursive: true);
      await file.writeAsString(
        const JsonEncoder.withIndent('  ').convert(settings.toJson()),
        flush: true,
      );
    } on FileSystemException catch (error) {
      throw AppFailure('Could not save settings', details: error.message);
    }
  }
}
