import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pallsql/services/mariadb/mysql_protocol.dart';
import 'package:pallsql/services/mariadb/mysql_values.dart';

/// Builds the greeting a MariaDB 10.11 server sends, so the parser is tested
/// against the real byte layout instead of a hand written subset.
Uint8List serverGreeting({
  String version = '10.11.6-MariaDB',
  int connectionId = 42,
  int capabilities = MysqlCapability.base,
  String plugin = 'mysql_native_password',
}) {
  final List<int> scramble = List<int>.generate(20, (int i) => i + 1);
  final MysqlWriter writer = MysqlWriter()
    ..writeInt1(10)
    ..writeNulString(version)
    ..writeInt4(connectionId)
    ..writeBytes(scramble.sublist(0, 8))
    ..writeInt1(0)
    ..writeInt2(capabilities & 0xffff)
    ..writeInt1(45)
    ..writeInt2(0x0002)
    ..writeInt2((capabilities >> 16) & 0xffff)
    ..writeInt1(21)
    ..writeZeros(10)
    ..writeBytes(scramble.sublist(8))
    ..writeInt1(0)
    ..writeNulString(plugin);
  return writer.takeBytes();
}

void main() {
  group('SHA-1 and native password', () {
    test('sha1 matches the FIPS vectors', () {
      expect(sha1Hex(utf8.encode('abc')),
          'a9993e364706816aba3e25717850c26c9cd0d89d');
      expect(sha1Hex(<int>[]), 'da39a3ee5e6b4b0d3255bfef95601890afd80709');
      expect(
        sha1Hex(utf8.encode(
            'abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq')),
        '84983e441c3bd26ebaae4aa1f95129e5e54670f1',
      );
    });

    test('mysql_native_password scramble matches an independent computation',
        () {
      final List<int> scramble =
          List<int>.generate(20, (int i) => i + 1);
      final List<int> digest =
          nativePasswordScramble('secret', scramble);
      final String hex = digest
          .map((int byte) => byte.toRadixString(16).padLeft(2, '0'))
          .join();
      // Expected value computed with Python hashlib from the same inputs.
      expect(hex, 'b32bb3a583e1340c0a1108d58b1be49781ad8c2f');
    });

    test('an empty password produces an empty scramble', () {
      expect(nativePasswordScramble('', <int>[1, 2, 3]), isEmpty);
    });
  });

  group('length encoded integers', () {
    test('round trip across every width', () {
      for (final int value in <int>[0, 1, 250, 251, 65535, 65536, 16777215,
        16777216, 4294967295]) {
        final MysqlWriter writer = MysqlWriter()
          ..writeLengthEncodedInt(value);
        final MysqlReader reader = MysqlReader(writer.takeBytes());
        expect(reader.readLengthEncodedInt(), value,
            reason: 'value $value did not survive the round trip');
        expect(reader.hasMore, isFalse);
      }
    });

    test('0xFB is the NULL marker', () {
      final MysqlReader reader = MysqlReader(Uint8List.fromList(<int>[0xfb]));
      expect(reader.readLengthEncodedInt(), isNull);
    });

    test('truncated input raises a protocol error, not a hang', () {
      final MysqlReader reader = MysqlReader(Uint8List.fromList(<int>[0xfc, 1]));
      expect(reader.readLengthEncodedInt, throwsA(isA<MysqlProtocolException>()));
    });
  });

  group('handshake', () {
    test('parses the real greeting layout', () {
      final MysqlHandshake handshake =
          MysqlHandshake.parse(serverGreeting());
      expect(handshake.protocolVersion, 10);
      expect(handshake.serverVersion, '10.11.6-MariaDB');
      expect(handshake.connectionId, 42);
      expect(handshake.authPluginName, 'mysql_native_password');
      expect(handshake.scramble.length, 20);
      expect(handshake.scramble.first, 1);
      expect(handshake.scramble.last, 20);
      expect(handshake.supports(MysqlCapability.protocol41), isTrue);
      expect(handshake.supports(MysqlCapability.secureConnection), isTrue);
    });

    test('a protocol that is not 10 is refused with the version in the text',
        () {
      final Uint8List payload = serverGreeting();
      payload[0] = 9;
      expect(
        () => MysqlHandshake.parse(payload),
        throwsA(
          isA<MysqlProtocolException>().having(
            (MysqlProtocolException error) => error.message,
            'message',
            contains('Unsupported handshake protocol version 9'),
          ),
        ),
      );
    });
  });

  group('packets', () {
    test('OK packet carries affected rows, insert id and warnings', () {
      final MysqlWriter writer = MysqlWriter()
        ..writeInt1(0x00)
        ..writeLengthEncodedInt(3)
        ..writeLengthEncodedInt(17)
        ..writeInt2(MysqlServerStatus.autocommit)
        ..writeInt2(2)
        ..writeBytes(utf8.encode('Rows matched: 3'));
      final MysqlOkPacket ok = MysqlOkPacket.parse(writer.takeBytes());
      expect(ok.affectedRows, 3);
      expect(ok.lastInsertId, 17);
      expect(ok.warningCount, 2);
      expect(ok.info, 'Rows matched: 3');
      expect(ok.moreResults, isFalse);
    });

    test('ERR packet keeps code, SQLSTATE and message', () {
      final MysqlWriter writer = MysqlWriter()
        ..writeInt1(0xff)
        ..writeInt2(1146)
        ..writeInt1(0x23)
        ..writeBytes(utf8.encode('42S02'))
        ..writeBytes(utf8.encode("Table 'app.users' doesn't exist"));
      final MysqlErrPacket error = MysqlErrPacket.parse(writer.takeBytes());
      expect(error.code, 1146);
      expect(error.sqlState, '42S02');
      expect(error.message, contains("doesn't exist"));
      final MysqlServerException exception = error.toException();
      expect(exception.toString(), contains('1146'));
      expect(exception.toString(), contains('42S02'));
    });

    test('EOF packet exposes the more-results flag', () {
      final MysqlWriter writer = MysqlWriter()
        ..writeInt1(0xfe)
        ..writeInt2(0)
        ..writeInt2(MysqlServerStatus.moreResultsExist);
      final MysqlEofPacket eof = MysqlEofPacket.parse(writer.takeBytes());
      expect(eof.moreResults, isTrue);
    });
  });

  group('column definitions', () {
    test('parses a protocol 4.1 definition', () {
      final MysqlWriter writer = MysqlWriter();
      for (final String part in <String>[
        'def',
        'app',
        'users',
        'users',
        'name',
        'name',
      ]) {
        writer.writeLengthEncodedString(part);
      }
      writer
        ..writeLengthEncodedInt(0x0c)
        ..writeInt2(45)
        ..writeInt4(765)
        ..writeInt1(MysqlType.varString)
        ..writeInt2(0)
        ..writeInt1(0)
        ..writeInt2(0);
      final MysqlColumn column = MysqlColumn.parse(writer.takeBytes());
      expect(column.catalog, 'def');
      expect(column.schema, 'app');
      expect(column.table, 'users');
      expect(column.name, 'name');
      expect(column.type, MysqlType.varString);
      expect(column.typeName, 'VARCHAR');
      expect(column.isBinary, isFalse);
    });

    test('unsigned and binary flags are decoded', () {
      const int unsignedFlag = 0x20;
      const MysqlColumn column = MysqlColumn(
        catalog: 'def',
        schema: 'app',
        table: 't',
        originalTable: 't',
        name: 'id',
        originalName: 'id',
        characterSet: 63,
        columnLength: 20,
        type: MysqlType.longLong,
        flags: unsignedFlag,
        decimals: 0,
      );
      expect(column.isUnsigned, isTrue);
      expect(column.isBinary, isTrue);
      expect(column.typeName, 'BIGINT');
    });
  });

  group('value encoding', () {
    test('identifiers are quoted with backticks and inner ticks doubled', () {
      expect(quoteIdentifier('users'), '`users`');
      expect(quoteIdentifier('we`ird'), '`we``ird`');
      expect(quoteIdentifier(''), throwsA(isA<ArgumentError>()));
    });

    test('string literals escape quotes and backslashes', () {
      expect(quoteLiteral("it's"), r"'it\'s'");
      expect(quoteLiteral(r'a\b'), r"'a\\b'");
    });

    test('parameters pick the right wire type', () {
      expect(MysqlParam.from(null).type, MysqlType.null);
      expect(MysqlParam.from(7).type, MysqlType.longLong);
      expect(MysqlParam.from(1.5).type, MysqlType.double);
      expect(MysqlParam.from(true).type, MysqlType.tiny);
      expect(MysqlParam.from('text').type, MysqlType.varString);
      expect(MysqlParam.from(Uint8List(2)).type, MysqlType.blob);
      expect(MysqlParam.from(DateTime.utc(2026, 1, 2, 3, 4, 5)).type,
          MysqlType.varString);
    });

    test('binary cell formatting keeps integers honest', () {
      expect(formatCell(3), '3');
      expect(formatCell(null), isNull);
      expect(formatCell('abc'), 'abc');
    });
  });
}
