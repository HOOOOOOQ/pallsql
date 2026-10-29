import 'dart:convert';
import 'dart:typed_data';

/// MySQL/MariaDB client capability flags used by PALLSQL.
///
/// The values come from the protocol documentation that MariaDB Server
/// implements (`include/mysql_com.h` in the server source). PALLSQL sets a
/// conservative subset: protocol 4.1 with `CLIENT_SECURE_CONNECTION`,
/// multi statements and multi results, and it deliberately **keeps** the legacy
/// EOF packet (`CLIENT_DEPRECATE_EOF` is never requested) because every MariaDB
/// version in the 10.x/11.x range still speaks it.
class MysqlCapability {
  const MysqlCapability._();

  static const int longPassword = 0x00000001;
  static const int foundRows = 0x00000002;
  static const int longFlag = 0x00000004;
  static const int connectWithDb = 0x00000008;
  static const int localFiles = 0x00000080;
  static const int protocol41 = 0x00000200;
  static const int ssl = 0x00000800;
  static const int transactions = 0x00002000;
  static const int secureConnection = 0x00008000;
  static const int multiStatements = 0x00010000;
  static const int multiResults = 0x00020000;
  static const int psMultiResults = 0x00040000;
  static const int pluginAuth = 0x00080000;
  static const int connectAttrs = 0x00100000;
  static const int pluginAuthLenEncClientData = 0x00200000;
  static const int sessionTrack = 0x00800000;
  static const int deprecateEof = 0x01000000;

  /// Flags PALLSQL always requests.
  static const int base =
      longPassword | longFlag | protocol41 | transactions | secureConnection |
      pluginAuth | multiResults | psMultiResults | multiStatements;
}

/// Server status flags carried by OK and EOF packets.
class MysqlServerStatus {
  const MysqlServerStatus._();

  static const int inTransaction = 0x0001;
  static const int autocommit = 0x0002;
  static const int moreResultsExist = 0x0008;
  static const int noGoodIndexUsed = 0x0010;
  static const int cursorExists = 0x0040;
  static const int lastRowSent = 0x0080;
}

/// Client command bytes.
class MysqlCommand {
  const MysqlCommand._();

  static const int quit = 0x01;
  static const int initDb = 0x02;
  static const int query = 0x03;
  static const int ping = 0x0e;
  static const int stmtPrepare = 0x16;
  static const int stmtExecute = 0x17;
  static const int stmtClose = 0x19;
  static const int stmtReset = 0x1a;
}

/// Column type codes (`enum_field_types`).
class MysqlType {
  const MysqlType._();

  static const int decimal = 0x00;
  static const int tiny = 0x01;
  static const int short = 0x02;
  static const int long = 0x03;
  static const int float = 0x04;
  static const int double = 0x05;
  static const int nullType = 0x06;
  static const int timestamp = 0x07;
  static const int longLong = 0x08;
  static const int int24 = 0x09;
  static const int date = 0x0a;
  static const int time = 0x0b;
  static const int dateTime = 0x0c;
  static const int year = 0x0d;
  static const int newDate = 0x0e;
  static const int varchar = 0x0f;
  static const int bit = 0x10;
  static const int timestamp2 = 0x11;
  static const int dateTime2 = 0x12;
  static const int time2 = 0x13;
  static const int json = 0xf5;
  static const int newDecimal = 0xf6;
  static const int enumType = 0xf7;
  static const int setType = 0xf8;
  static const int tinyBlob = 0xf9;
  static const int mediumBlob = 0xfa;
  static const int longBlob = 0xfb;
  static const int blob = 0xfc;
  static const int varString = 0xfd;
  static const int string = 0xfe;
  static const int geometry = 0xff;

  static const Map<int, String> names = <int, String>{
    decimal: 'DECIMAL',
    tiny: 'TINYINT',
    short: 'SMALLINT',
    long: 'INT',
    float: 'FLOAT',
    double: 'DOUBLE',
    null: 'NULL',
    timestamp: 'TIMESTAMP',
    longLong: 'BIGINT',
    int24: 'MEDIUMINT',
    date: 'DATE',
    time: 'TIME',
    dateTime: 'DATETIME',
    year: 'YEAR',
    newDate: 'DATE',
    varchar: 'VARCHAR',
    bit: 'BIT',
    json: 'JSON',
    newDecimal: 'DECIMAL',
    enumType: 'ENUM',
    setType: 'SET',
    tinyBlob: 'BLOB',
    mediumBlob: 'BLOB',
    longBlob: 'BLOB',
    blob: 'BLOB',
    varString: 'VARCHAR',
    string: 'CHAR',
    geometry: 'GEOMETRY',
  };

  static String name(int type) => names[type] ?? 'TYPE_$type';

  static bool isBinary(int type) =>
      type == tinyBlob ||
      type == mediumBlob ||
      type == longBlob ||
      type == blob ||
      type == geometry;
}

/// Raised when the server answers with an ERR packet.
class MysqlServerException implements Exception {
  const MysqlServerException({
    required this.code,
    required this.message,
    this.sqlState = 'HY000',
    this.severity = 'ERROR',
  });

  /// Numeric MariaDB error code (`ER_*`).
  final int code;

  /// SQLSTATE, for example `42S02`.
  final String sqlState;

  /// Server message exactly as sent.
  final String message;

  /// `ERROR` for normal errors, `WARNING`/`NOTE` after `SHOW WARNINGS`.
  final String severity;

  @override
  String toString() => 'MariaDB $severity $code ($sqlState): $message';
}

/// Raised when the connection breaks or the handshake is not understood.
class MysqlProtocolException implements Exception {
  const MysqlProtocolException(this.message, {this.detail});

  final String message;
  final String? detail;

  @override
  String toString() => detail == null ? message : '$message ($detail)';
}

/// Little endian reader over a packet payload.
class MysqlReader {
  MysqlReader(this.bytes, [this.offset = 0]);

  final Uint8List bytes;
  int offset;

  int get remaining => bytes.length - offset;

  bool get hasMore => offset < bytes.length;

  void _require(int count) {
    if (remaining < count) {
      throw MysqlProtocolException(
        'Truncated packet: needed $count byte(s), found $remaining',
      );
    }
  }

  int readInt1() {
    _require(1);
    return bytes[offset++];
  }

  int readInt2() {
    _require(2);
    final int value = bytes[offset] | (bytes[offset + 1] << 8);
    offset += 2;
    return value;
  }

  int readInt3() {
    _require(3);
    final int value =
        bytes[offset] | (bytes[offset + 1] << 8) | (bytes[offset + 2] << 16);
    offset += 3;
    return value;
  }

  int readInt4() {
    _require(4);
    final int value = bytes[offset] |
        (bytes[offset + 1] << 8) |
        (bytes[offset + 2] << 16) |
        (bytes[offset + 3] << 24);
    offset += 4;
    return value;
  }

  /// 6 byte integer, used by the binary protocol for time values.
  int readInt6() {
    _require(6);
    int value = 0;
    for (int i = 5; i >= 0; i--) {
      value = (value << 8) | bytes[offset + i];
    }
    offset += 6;
    return value;
  }

  int readInt8() {
    _require(8);
    int value = 0;
    for (int i = 7; i >= 0; i--) {
      value = (value << 8) | bytes[offset + i];
    }
    offset += 8;
    return value;
  }

  /// Length encoded integer; returns `null` for the `0xFB` NULL marker.
  int? readLengthEncodedInt() {
    if (!hasMore) {
      throw const MysqlProtocolException('Missing length encoded integer');
    }
    final int first = bytes[offset];
    if (first < 0xfb) {
      offset++;
      return first;
    }
    if (first == 0xfb) {
      offset++;
      return null;
    }
    if (first == 0xfc) {
      offset++;
      return readInt2();
    }
    if (first == 0xfd) {
      offset++;
      return readInt3();
    }
    if (first == 0xfe) {
      offset++;
      final int value = readInt8();
      return value < 0 ? value.toUnsigned(64) : value;
    }
    throw MysqlProtocolException('Invalid length encoded integer 0x$first');
  }

  Uint8List readBytes(int count) {
    _require(count);
    final Uint8List slice = Uint8List.sublistView(bytes, offset, offset + count);
    offset += count;
    return slice;
  }

  Uint8List readRest() {
    final Uint8List slice = Uint8List.sublistView(bytes, offset);
    offset = bytes.length;
    return slice;
  }

  String readNulString() {
    int end = offset;
    while (end < bytes.length && bytes[end] != 0) {
      end++;
    }
    final String value = _decode(bytes, offset, end);
    offset = end < bytes.length ? end + 1 : bytes.length;
    return value;
  }

  String readFixedString(int count) => _decode(readBytes(count));

  String readLengthEncodedString() {
    final int? length = readLengthEncodedInt();
    if (length == null) {
      return '';
    }
    return _decode(readBytes(length));
  }

  static String _decode(Uint8List source, [int start = 0, int? end]) =>
      utf8.decode(
        Uint8List.sublistView(source, start, end ?? source.length),
        allowMalformed: true,
      );
}

/// Little endian writer used to build client packets.
class MysqlWriter {
  final BytesBuilder _builder = BytesBuilder(copy: true);

  int get length => _builder.length;

  Uint8List takeBytes() => _builder.takeBytes();

  void writeInt1(int value) => _builder.addByte(value & 0xff);

  void writeInt2(int value) {
    _builder.addByte(value & 0xff);
    _builder.addByte((value >> 8) & 0xff);
  }

  void writeInt3(int value) {
    _builder.addByte(value & 0xff);
    _builder.addByte((value >> 8) & 0xff);
    _builder.addByte((value >> 16) & 0xff);
  }

  void writeInt4(int value) {
    _builder.addByte(value & 0xff);
    _builder.addByte((value >> 8) & 0xff);
    _builder.addByte((value >> 16) & 0xff);
    _builder.addByte((value >> 24) & 0xff);
  }

  void writeInt8(int value) {
    for (int i = 0; i < 8; i++) {
      _builder.addByte((value >> (8 * i)) & 0xff);
    }
  }

  void writeLengthEncodedInt(int value) {
    if (value < 0xfb) {
      writeInt1(value);
    } else if (value <= 0xffff) {
      writeInt1(0xfc);
      writeInt2(value);
    } else if (value <= 0xffffff) {
      writeInt1(0xfd);
      writeInt3(value);
    } else {
      writeInt1(0xfe);
      writeInt8(value);
    }
  }

  void writeBytes(List<int> bytes) => _builder.add(bytes);

  void writeNulString(String value) {
    _builder.add(utf8.encode(value));
    _builder.addByte(0);
  }

  void writeLengthEncodedString(String value) {
    final List<int> encoded = utf8.encode(value);
    writeLengthEncodedInt(encoded.length);
    _builder.add(encoded);
  }

  void writeZeros(int count) {
    for (int i = 0; i < count; i++) {
      _builder.addByte(0);
    }
  }
}

/// A parsed OK packet (`0x00`).
class MysqlOkPacket {
  const MysqlOkPacket({
    required this.affectedRows,
    required this.lastInsertId,
    required this.statusFlags,
    required this.warningCount,
    required this.info,
  });

  final int affectedRows;
  final int lastInsertId;
  final int statusFlags;
  final int warningCount;
  final String info;

  bool get moreResults => (statusFlags & MysqlServerStatus.moreResultsExist) != 0;

  static MysqlOkPacket parse(Uint8List payload) {
    final MysqlReader reader = MysqlReader(payload, 1);
    final int affected = reader.readLengthEncodedInt() ?? 0;
    final int insertId = reader.readLengthEncodedInt() ?? 0;
    final int status = reader.hasMore ? reader.readInt2() : 0;
    final int warnings = reader.hasMore ? reader.readInt2() : 0;
    final String info = reader.hasMore ? reader.readRestString() : '';
    return MysqlOkPacket(
      affectedRows: affected,
      lastInsertId: insertId,
      statusFlags: status,
      warningCount: warnings,
      info: info,
    );
  }
}

/// A parsed ERR packet (`0xFF`).
class MysqlErrPacket {
  const MysqlErrPacket({
    required this.code,
    required this.sqlState,
    required this.message,
  });

  final int code;
  final String sqlState;
  final String message;

  static MysqlErrPacket parse(Uint8List payload) {
    final MysqlReader reader = MysqlReader(payload, 1);
    final int code = reader.readInt2();
    String sqlState = 'HY000';
    if (reader.hasMore && reader.bytes[reader.offset] == 0x23) {
      reader.offset++;
      sqlState = reader.readFixedString(5);
    }
    final String message = reader.hasMore ? reader.readRestString() : '';
    return MysqlErrPacket(code: code, sqlState: sqlState, message: message);
  }

  MysqlServerException toException() => MysqlServerException(
        code: code,
        sqlState: sqlState,
        message: message,
      );
}

extension on MysqlReader {
  String readRestString() => MysqlReader._decode(readRest());
}

/// A parsed EOF packet (`0xFE`, length < 9).
class MysqlEofPacket {
  const MysqlEofPacket({required this.warningCount, required this.statusFlags});

  final int warningCount;
  final int statusFlags;

  bool get moreResults => (statusFlags & MysqlServerStatus.moreResultsExist) != 0;

  static MysqlEofPacket parse(Uint8List payload) {
    if (payload.length <= 1) {
      return const MysqlEofPacket(warningCount: 0, statusFlags: 0);
    }
    final MysqlReader reader = MysqlReader(payload, 1);
    final int warnings = reader.hasMore ? reader.readInt2() : 0;
    final int status = reader.hasMore ? reader.readInt2() : 0;
    return MysqlEofPacket(warningCount: warnings, statusFlags: status);
  }
}

/// One column of a result set (protocol 4.1 column definition).
class MysqlColumn {
  const MysqlColumn({
    required this.catalog,
    required this.schema,
    required this.table,
    required this.originalTable,
    required this.name,
    required this.originalName,
    required this.characterSet,
    required this.columnLength,
    required this.type,
    required this.flags,
    required this.decimals,
  });

  final String catalog;
  final String schema;
  final String table;
  final String originalTable;
  final String name;
  final String originalName;
  final int characterSet;
  final int columnLength;
  final int type;
  final int flags;
  final int decimals;

  bool get isUnsigned => (flags & 0x20) != 0;

  bool get isBinary => (characterSet == 63) || MysqlType.isBinary(type);

  String get typeName => MysqlType.name(type);

  static MysqlColumn parse(Uint8List payload) {
    final MysqlReader reader = MysqlReader(payload);
    final String catalog = reader.readLengthEncodedString();
    final String schema = reader.readLengthEncodedString();
    final String table = reader.readLengthEncodedString();
    final String originalTable = reader.readLengthEncodedString();
    final String name = reader.readLengthEncodedString();
    final String originalName = reader.readLengthEncodedString();
    // Length of the fixed fields, always 0x0c for protocol 4.1.
    reader.readLengthEncodedInt();
    final int characterSet = reader.readInt2();
    final int columnLength = reader.readInt4();
    final int type = reader.readInt1();
    final int flags = reader.readInt2();
    final int decimals = reader.readInt1();
    return MysqlColumn(
      catalog: catalog,
      schema: schema,
      table: table,
      originalTable: originalTable,
      name: name,
      originalName: originalName,
      characterSet: characterSet,
      columnLength: columnLength,
      type: type,
      flags: flags,
      decimals: decimals,
    );
  }
}

/// The server greeting (`protocol_version = 10`).
class MysqlHandshake {
  const MysqlHandshake({
    required this.protocolVersion,
    required this.serverVersion,
    required this.connectionId,
    required this.scramble,
    required this.capabilities,
    required this.characterSet,
    required this.statusFlags,
    required this.authPluginName,
  });

  final int protocolVersion;
  final String serverVersion;
  final int connectionId;
  final List<int> scramble;
  final int capabilities;
  final int characterSet;
  final int statusFlags;
  final String authPluginName;

  bool supports(int capability) => (capabilities & capability) != 0;

  static MysqlHandshake parse(Uint8List payload) {
    final MysqlReader reader = MysqlReader(payload);
    final int protocolVersion = reader.readInt1();
    if (protocolVersion != 10) {
      throw MysqlProtocolException(
        'Unsupported handshake protocol version $protocolVersion',
        detail: 'PALLSQL speaks MySQL/MariaDB protocol 10 only',
      );
    }
    final String serverVersion = reader.readNulString();
    final int connectionId = reader.readInt4();
    final List<int> partOne = List<int>.from(reader.readBytes(8));
    reader.readInt1(); // filler
    int capabilities = reader.readInt2();
    int characterSet = 0;
    int statusFlags = 0;
    List<int> partTwo = <int>[];
    String plugin = 'mysql_native_password';
    if (reader.hasMore) {
      characterSet = reader.readInt1();
      statusFlags = reader.readInt2();
      capabilities |= reader.readInt2() << 16;
      final int pluginLength = reader.readInt1();
      reader.readBytes(10); // reserved
      if ((capabilities & MysqlCapability.secureConnection) != 0) {
        final int length = pluginLength > 8 ? pluginLength - 8 : 12;
        final int available = length.clamp(0, reader.remaining);
        partTwo = List<int>.from(reader.readBytes(available));
        // The trailing NUL of the scramble is part of the field.
        if (partTwo.isNotEmpty && partTwo.last == 0) {
          partTwo = partTwo.sublist(0, partTwo.length - 1);
        }
      }
      if ((capabilities & MysqlCapability.pluginAuth) != 0 && reader.hasMore) {
        plugin = reader.readNulString();
      }
    }
    return MysqlHandshake(
      protocolVersion: protocolVersion,
      serverVersion: serverVersion,
      connectionId: connectionId,
      scramble: <int>[...partOne, ...partTwo],
      capabilities: capabilities,
      characterSet: characterSet,
      statusFlags: statusFlags,
      authPluginName: plugin.isEmpty ? 'mysql_native_password' : plugin,
    );
  }
}

/// `mysql_native_password` scramble: SHA1(password) XOR
/// SHA1(scramble + SHA1(SHA1(password))).
///
/// Implemented with a compact SHA-1 because Dart's `crypto` package is a
/// dependency PALLSQL does not need for anything else.
List<int> nativePasswordScramble(String password, List<int> scramble) {
  if (password.isEmpty) {
    return <int>[];
  }
  final List<int> stageOne = _sha1(utf8.encode(password));
  final List<int> stageTwo = _sha1(stageOne);
  final List<int> seeded = _sha1(<int>[...scramble, ...stageTwo]);
  final List<int> result = List<int>.filled(stageOne.length, 0);
  for (int i = 0; i < stageOne.length; i++) {
    result[i] = stageOne[i] ^ seeded[i];
  }
  return result;
}

/// Minimal SHA-1 implementation (FIPS 180-1), used for authentication only.
List<int> _sha1(List<int> message) {
  final int messageLength = message.length;
  final int bitLength = messageLength * 8;
  final int paddedLength = ((messageLength + 9 + 63) ~/ 64) * 64;
  final Uint8List buffer = Uint8List(paddedLength);
  buffer.setRange(0, messageLength, message);
  buffer[messageLength] = 0x80;
  final ByteData view = ByteData.sublistView(buffer);
  view.setUint32(paddedLength - 4, bitLength & 0xffffffff, Endian.big);
  view.setUint32(paddedLength - 8, (bitLength ~/ 0x100000000) & 0xffffffff,
      Endian.big);

  int h0 = 0x67452301;
  int h1 = 0xEFCDAB89;
  int h2 = 0x98BADCFE;
  int h3 = 0x10325476;
  int h4 = 0xC3D2E1F0;

  final List<int> w = List<int>.filled(80, 0);
  for (int chunk = 0; chunk < paddedLength; chunk += 64) {
    for (int i = 0; i < 16; i++) {
      w[i] = view.getUint32(chunk + i * 4, Endian.big);
    }
    for (int i = 16; i < 80; i++) {
      w[i] = _rotateLeft(w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16], 1);
    }
    int a = h0;
    int b = h1;
    int c = h2;
    int d = h3;
    int e = h4;
    for (int i = 0; i < 80; i++) {
      int f;
      int k;
      if (i < 20) {
        f = (b & c) | ((~b & 0xffffffff) & d);
        k = 0x5A827999;
      } else if (i < 40) {
        f = b ^ c ^ d;
        k = 0x6ED9EBA1;
      } else if (i < 60) {
        f = (b & c) | (b & d) | (c & d);
        k = 0x8F1BBCDC;
      } else {
        f = b ^ c ^ d;
        k = 0xCA62C1D6;
      }
      final int temp =
          (_rotateLeft(a, 5) + f + e + k + w[i]) & 0xffffffff;
      e = d;
      d = c;
      c = _rotateLeft(b, 30);
      b = a;
      a = temp;
    }
    h0 = (h0 + a) & 0xffffffff;
    h1 = (h1 + b) & 0xffffffff;
    h2 = (h2 + c) & 0xffffffff;
    h3 = (h3 + d) & 0xffffffff;
    h4 = (h4 + e) & 0xffffffff;
  }

  final Uint8List digest = Uint8List(20);
  final ByteData out = ByteData.sublistView(digest);
  out.setUint32(0, h0, Endian.big);
  out.setUint32(4, h1, Endian.big);
  out.setUint32(8, h2, Endian.big);
  out.setUint32(12, h3, Endian.big);
  out.setUint32(16, h4, Endian.big);
  return digest;
}

int _rotateLeft(int value, int bits) {
  final int v = value & 0xffffffff;
  return ((v << bits) | (v >> (32 - bits))) & 0xffffffff;
}

/// Exposed for the protocol tests: SHA-1 of [message] as lowercase hex.
String sha1Hex(List<int> message) {
  final List<int> digest = _sha1(message);
  final StringBuffer buffer = StringBuffer();
  for (final int byte in digest) {
    buffer.write(byte.toRadixString(16).padLeft(2, '0'));
  }
  return buffer.toString();
}
