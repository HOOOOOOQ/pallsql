import 'package:path/path.dart' as p;

/// Metadata of a ZIP backup stored in `PALLSQL/backups`.
class BackupInfo {
  const BackupInfo({
    required this.fileName,
    required this.path,
    required this.sizeBytes,
    required this.createdAt,
    this.entryCount,
  });

  final String fileName;
  final String path;
  final int sizeBytes;
  final DateTime createdAt;
  final int? entryCount;

  String get sizeLabel {
    if (sizeBytes < 1024) {
      return '$sizeBytes B';
    }
    if (sizeBytes < 1024 * 1024) {
      return '${(sizeBytes / 1024).toStringAsFixed(1)} KB';
    }
    return '${(sizeBytes / (1024 * 1024)).toStringAsFixed(2)} MB';
  }

  /// Backup timestamp is part of the file name so it survives file copies.
  static DateTime? timestampFromName(String fileName) {
    final RegExpMatch? match =
        RegExp(r'pallsql-backup-(\d{8})-(\d{6})').firstMatch(p.basename(fileName));
    if (match == null) {
      return null;
    }
    final String raw = '${match.group(1)}T${match.group(2)}';
    final String formatted =
        '${raw.substring(0, 4)}-${raw.substring(4, 6)}-${raw.substring(6, 8)}'
        'T${raw.substring(9, 11)}:${raw.substring(11, 13)}:${raw.substring(13, 15)}';
    return DateTime.tryParse(formatted);
  }
}
