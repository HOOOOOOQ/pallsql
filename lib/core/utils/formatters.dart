/// Small formatting helpers used by the UI (no localisation dependencies).
class Formatters {
  const Formatters._();

  static String bytes(int value) {
    if (value < 0) {
      return '-';
    }
    const List<String> units = <String>['B', 'KB', 'MB', 'GB', 'TB'];
    double size = value.toDouble();
    int unit = 0;
    while (size >= 1024 && unit < units.length - 1) {
      size /= 1024;
      unit++;
    }
    final String digits = unit == 0 ? '0' : (size >= 100 ? '0' : '1');
    return '${size.toStringAsFixed(int.parse(digits))} ${units[unit]}';
  }

  static String clock(DateTime time) {
    final DateTime local = time.toLocal();
    return '${_two(local.hour)}:${_two(local.minute)}:${_two(local.second)}';
  }

  static String dateTime(DateTime time) {
    final DateTime local = time.toLocal();
    return '${local.year}-${_two(local.month)}-${_two(local.day)} '
        '${_two(local.hour)}:${_two(local.minute)}';
  }

  static String relativeTime(DateTime time, {DateTime? now}) {
    final DateTime reference = now ?? DateTime.now();
    final Duration delta = reference.difference(time);
    if (delta.inSeconds < 60) {
      return '${delta.inSeconds.clamp(0, 59)}s ago';
    }
    if (delta.inMinutes < 60) {
      return '${delta.inMinutes}m ago';
    }
    if (delta.inHours < 24) {
      return '${delta.inHours}h ago';
    }
    if (delta.inDays < 7) {
      return '${delta.inDays}d ago';
    }
    return dateTime(time);
  }

  static String duration(Duration value) {
    if (value.inMilliseconds < 1000) {
      return '${value.inMilliseconds} ms';
    }
    final double seconds = value.inMilliseconds / 1000;
    if (seconds < 60) {
      return '${seconds.toStringAsFixed(2)} s';
    }
    return '${value.inMinutes}m ${value.inSeconds % 60}s';
  }

  static String count(int value, String singular, [String? plural]) {
    final String label = plural ?? '${singular}s';
    return '$value ${value == 1 ? singular : label}';
  }

  static String truncate(String value, int max) {
    if (value.length <= max) {
      return value;
    }
    return '${value.substring(0, max - 1)}…';
  }

  static String _two(int value) => value.toString().padLeft(2, '0');
}
