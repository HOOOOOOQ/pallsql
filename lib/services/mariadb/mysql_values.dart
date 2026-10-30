import 'dart:convert';
import 'dart:typed_data';

import 'mysql_protocol.dart';

/// Decodes the text protocol representation of one cell.
///
/// Every value arrives as a length encoded byte string; `0xFB` means SQL NULL.
/// PALLSQL keeps the textual form because the UI (result grid, terminal, CSV
/// export) works with `String?` values, and because it is exactly what the
/// server sent.
String? readTextCell(MysqlReader reader, MysqlColumn column) {
  if (!reader.hasMore) {
    return null;
  }
  if (reader.bytes[reader.offset] == 0xfb) {
    reader.offset++;
    return null;
  }
  final int? length = reader.readLengthEncodedInt();
  if (length == null) {
    return null;
  }
  final Uint8List raw = reader.readBytes(length);
  if (column.isBinary && !_isUtf8(raw)) {
    return binaryToHex(raw);
  }
  return utf8.decode(raw, allowMalformed: true);
}

/// Decodes one value of the binary protocol (prepared statement result).
Object? readBinaryCell(MysqlReader reader, MysqlColumn column) {
  switch (column.type) {
    case MysqlType.tiny:
      return column.isUnsigned
          ? reader.readInt1()
          : _signed(reader.readInt1(), 8);
    case MysqlType.short:
    case MysqlType.year:
      return column.isUnsigned
          ? reader.readInt2()
          : _signed(reader.readInt2(), 16);
    case MysqlType.int24:
      return column.isUnsigned
          ? reader.readInt3()
          : _signed(reader.readInt3(), 24);
    case MysqlType.long:
      return column.isUnsigned
          ? reader.readInt4()
          : _signed(reader.readInt4(), 32);
    case MysqlType.longLong:
      return reader.readInt8();
    case MysqlType.float:
      return ByteData.sublistView(reader.readBytes(4))
          .getFloat32(0, Endian.little);
    case MysqlType.double:
      return ByteData.sublistView(reader.readBytes(8))
          .getFloat64(0, Endian.little);
    case MysqlType.date:
    case MysqlType.newDate:
    case MysqlType.dateTime:
    case MysqlType.dateTime2:
    case MysqlType.timestamp:
    case MysqlType.timestamp2:
      return _readBinaryDateTime(reader);
    case MysqlType.time:
    case MysqlType.time2:
      return _readBinaryTime(reader);
    case MysqlType.bit:
      {
        final int length = reader.readLengthEncodedInt() ?? 0;
        final Uint8List raw = reader.readBytes(length);
        int value = 0;
        for (final int byte in raw) {
          value = (value << 8) | byte;
        }
        return value;
      }
    case MysqlType.blob:
    case MysqlType.tinyBlob:
    case MysqlType.mediumBlob:
    case MysqlType.longBlob:
    case MysqlType.geometry:
      {
        final int length = reader.readLengthEncodedInt() ?? 0;
        final Uint8List raw = reader.readBytes(length);
        return _isUtf8(raw)
            ? utf8.decode(raw, allowMalformed: true)
            : binaryToHex(raw);
      }
    default:
      return reader.readLengthEncodedString();
  }
}

int _signed(int value, int bits) {
  final int signBit = 1 << (bits - 1);
  if (value & signBit == 0) {
    return value;
  }
  return value - (1 << bits);
}

String? _readBinaryDateTime(MysqlReader reader) {
  final int length = reader.readInt1();
  if (length == 0) {
    return '0000-00-00';
  }
  final int year = reader.readInt2();
  final int month = reader.readInt1();
  final int day = reader.readInt1();
  final StringBuffer buffer = StringBuffer()
    ..write(year.toString().padLeft(4, '0'))
    ..write('-')
    ..write(month.toString().padLeft(2, '0'))
    ..write('-')
    ..write(day.toString().padLeft(2, '0'));
  if (length >= 7) {
    final int hour = reader.readInt1();
    final int minute = reader.readInt1();
    final int second = reader.readInt1();
    buffer
      ..write(' ')
      ..write(hour.toString().padLeft(2, '0'))
      ..write(':')
      ..write(minute.toString().padLeft(2, '0'))
      ..write(':')
      ..write(second.toString().padLeft(2, '0'));
    if (length >= 11) {
      final int micros = reader.readInt4();
      if (micros > 0) {
        buffer.write('.${micros.toString().padLeft(6, '0')}');
      }
    }
  }
  return buffer.toString();
}

String _readBinaryTime(MysqlReader reader) {
  final int length = reader.readInt1();
  if (length == 0) {
    return '00:00:00';
  }
  final int negative = reader.readInt1();
  final int days = reader.readInt4();
  final int hours = reader.readInt1();
  final int minutes = reader.readInt1();
  final int seconds = reader.readInt1();
  final int totalHours = days * 24 + hours;
  final StringBuffer buffer = StringBuffer();
  if (negative == 1) {
    buffer.write('-');
  }
  buffer
    ..write(totalHours.toString().padLeft(2, '0'))
    ..write(':')
    ..write(minutes.toString().padLeft(2, '0'))
    ..write(':')
    ..write(seconds.toString().padLeft(2, '0'));
  if (length >= 12) {
    final int micros = reader.readInt4();
    if (micros > 0) {
      buffer.write('.${micros.toString().padLeft(6, '0')}');
    }
  }
  return buffer.toString();
}

/// Renders a binary protocol value for the grid / terminal / export.
String? formatCell(Object? value) {
  if (value == null) {
    return null;
  }
  if (value is double) {
    if (value == value.roundToDouble() && value.abs() < 1e15) {
      return value.toStringAsFixed(1);
    }
    return value.toString();
  }
  return value.toString();
}

String binaryToHex(Uint8List raw) {
  final StringBuffer buffer = StringBuffer('0x');
  for (final int byte in raw) {
    buffer.write(byte.toRadixString(16).padLeft(2, '0'));
  }
  return buffer.toString();
}

bool _isUtf8(Uint8List raw) {
  try {
    utf8.decode(raw);
    return true;
  } on FormatException {
    return false;
  }
}

/// One bound parameter of a prepared statement.
class MysqlParam {
  const MysqlParam(this.type, this.unsigned, this._write);

  final int type;
  final bool unsigned;
  final void Function(MysqlWriter writer) _write;

  void writeValue(MysqlWriter writer) => _write(writer);

  /// Builds the bound parameter for a Dart value.
  ///
  /// Everything except `int`, `double`, `bool` and `Uint8List` is sent as a
  /// UTF-8 string; [identifier] values are **never** bound, because MariaDB
  /// cannot parameterise identifiers (those go through [quoteIdentifier]).
  factory MysqlParam.from(Object? value) {
    if (value == null) {
      return MysqlParam(MysqlType.nullType, false, (MysqlWriter w) {});
    }
    if (value is bool) {
      return MysqlParam(
        MysqlType.tiny,
        false,
        (MysqlWriter w) => w.writeInt1(value ? 1 : 0),
      );
    }
    if (value is int) {
      return MysqlParam(
        MysqlType.longLong,
        false,
        (MysqlWriter w) => w.writeInt8(value),
      );
    }
    if (value is BigInt) {
      return MysqlParam(
        MysqlType.longLong,
        false,
        (MysqlWriter w) => w.writeInt8(value.toInt()),
      );
    }
    if (value is double) {
      return MysqlParam(
        MysqlType.double,
        false,
        (MysqlWriter w) {
          final ByteData data = ByteData(8)
            ..setFloat64(0, value, Endian.little);
          w.writeBytes(data.buffer.asUint8List());
        },
      );
    }
    if (value is Uint8List) {
      return MysqlParam(
        MysqlType.blob,
        false,
        (MysqlWriter w) => w
          ..writeLengthEncodedInt(value.length)
          ..writeBytes(value),
      );
    }
    if (value is DateTime) {
      final String formatted = value
          .toUtc()
          .toIso8601String()
          .replaceFirst('T', ' ')
          .split('.')
          .first;
      return MysqlParam(
        MysqlType.varString,
        false,
        (MysqlWriter w) => w.writeLengthEncodedString(formatted),
      );
    }
    final String text = value.toString();
    return MysqlParam(
      MysqlType.varString,
      false,
      (MysqlWriter w) => w.writeLengthEncodedString(text),
    );
  }
}

/// Quotes an identifier with backticks, which MariaDB understands without
/// `ANSI_QUOTES`. Inner backticks are doubled.
String quoteIdentifier(String identifier) {
  final String trimmed = identifier.trim();
  if (trimmed.isEmpty) {
    throw ArgumentError.value(identifier, 'identifier', 'must not be empty');
  }
  return '`${trimmed.replaceAll('`', '``')}`';
}

/// Quotes a string literal for the rare places where SQL is assembled instead
/// of bound (no parameters accepted by the statement, e.g. `SHOW GRANTS FOR`).
String quoteLiteral(String value) {
  final String escaped = value.replaceAll('\\', '\\\\').replaceAll("'", "\\'");
  return "'$escaped'";
}

/// Escapes a value the way the server would, for logging and script export.
String escapeForLog(String value) {
  return value.replaceAll('\n', r'\n').replaceAll('\r', r'\r');
}
