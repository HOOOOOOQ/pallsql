import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'mysql_protocol.dart';
import 'mysql_values.dart';

/// Where and how PALLSQL connects to a MariaDB server.
///
/// The default is the loopback interface of the phone, which is the only
/// address a locally started `mariadbd` listens on unless the user explicitly
/// changes it in Settings.
class MariaDbConnectionConfig {
  const MariaDbConnectionConfig({
    this.host = '127.0.0.1',
    this.port = 3306,
    this.user = 'root',
    this.password = '',
    this.database,
    this.connectTimeout = const Duration(seconds: 8),
    this.queryTimeout = const Duration(seconds: 60),
    this.applicationName = 'PALLSQL',
  });

  final String host;
  final int port;
  final String user;
  final String password;
  final String? database;
  final Duration connectTimeout;

  /// Upper bound for a single command. `SELECT SLEEP(120)` is a real query the
  /// app must not hang on forever.
  final Duration queryTimeout;

  /// Sent as `CLIENT_CONNECT_ATTRS` so `SHOW PROCESSLIST` can identify PALLSQL.
  final String applicationName;

  String get endpoint => '$host:$port';

  MariaDbConnectionConfig copyWith({
    String? host,
    int? port,
    String? user,
    String? password,
    String? database,
    Duration? connectTimeout,
    Duration? queryTimeout,
    bool clearDatabase = false,
  }) {
    return MariaDbConnectionConfig(
      host: host ?? this.host,
      port: port ?? this.port,
      user: user ?? this.user,
      password: password ?? this.password,
      database: clearDatabase ? null : (database ?? this.database),
      connectTimeout: connectTimeout ?? this.connectTimeout,
      queryTimeout: queryTimeout ?? this.queryTimeout,
      applicationName: applicationName,
    );
  }

  /// Config without the password, safe for logs and error messages.
  String describe() => '$user@$endpoint';

  @override
  String toString() => 'MariaDbConnectionConfig(${describe()})';
}

/// One result set (or one OK summary) returned by the server.
class MariaDbResult {
  const MariaDbResult({
    required this.columns,
    required this.rows,
    required this.affectedRows,
    required this.lastInsertId,
    required this.warningCount,
    required this.duration,
    this.info = '',
  });

  final List<String> columns;
  final List<List<String?>> rows;
  final int affectedRows;
  final int lastInsertId;
  final int warningCount;
  final Duration duration;
  final String info;

  bool get hasResultSet => columns.isNotEmpty;

  int get rowCount => rows.length;
}

/// Every result a multi statement command produced, plus the first error.
///
/// MariaDB stops a multi statement batch at the failing statement; the results
/// of the statements that already ran stay valid, which is why this type keeps
/// both instead of throwing the partial work away.
class MariaDbBatch {
  const MariaDbBatch({
    required this.results,
    required this.error,
    required this.statementsExecuted,
    required this.duration,
  });

  final List<MariaDbResult> results;
  final MysqlServerException? error;
  final int statementsExecuted;
  final Duration duration;

  MariaDbResult? get last => results.isEmpty ? null : results.last;

  bool get isError => error != null;
}

/// A prepared statement on the server (binary protocol).
class MariaDbPreparedStatement {
  MariaDbPreparedStatement._({
    required this.id,
    required this.parameterCount,
    required this.columns,
    required MariaDbConnection connection,
  }) : _connection = connection;

  final int id;
  final int parameterCount;
  final List<MysqlColumn> columns;
  final MariaDbConnection _connection;

  bool _closed = false;

  /// Executes the statement with [parameters], bound by the server (no string
  /// interpolation, so quoting and SQL injection are not the caller's problem).
  Future<MariaDbResult> execute(
    List<Object?> parameters, {
    Duration? timeout,
  }) async {
    if (_closed) {
      throw const MysqlProtocolException('Prepared statement is closed');
    }
    if (parameters.length != parameterCount) {
      throw MysqlProtocolException(
        'Statement expects $parameterCount parameter(s), '
        'received ${parameters.length}',
      );
    }
    return _connection._executePrepared(this, parameters, timeout: timeout);
  }

  Future<void> close() async {
    if (_closed) {
      return;
    }
    _closed = true;
    await _connection._closePrepared(this);
  }
}

/// A real client connection that speaks the MariaDB wire protocol.
///
/// This is the only way PALLSQL talks to MariaDB: no SQLite fallback, no HTTP
/// proxy, no external API. It implements the parts of the protocol PALLSQL
/// needs: handshake with `mysql_native_password`, `COM_QUERY` (text protocol,
/// including multi statements), `COM_INIT_DB`, `COM_PING`, `COM_QUIT` and
/// `COM_STMT_PREPARE`/`COM_STMT_EXECUTE` (binary protocol).
class MariaDbConnection {
  MariaDbConnection._(this._socket, this.config) {
    _subscription = _socket.listen(
      _onData,
      onError: _onSocketError,
      onDone: _onSocketDone,
      cancelOnError: false,
    );
  }

  /// Opens a TCP connection and completes the handshake.
  static Future<MariaDbConnection> open(MariaDbConnectionConfig config) async {
    Socket socket;
    try {
      socket = await Socket.connect(
        config.host,
        config.port,
        timeout: config.connectTimeout,
      );
    } on SocketException catch (error) {
      throw MysqlProtocolException(
        'Cannot reach MariaDB at ${config.endpoint}',
        detail: error.osError?.message ?? error.message,
      );
    }
    socket.setOption(SocketOption.tcpNoDelay, true);
    final MariaDbConnection connection = MariaDbConnection._(socket, config);
    try {
      await connection._handshake();
    } on Object {
      await connection.close(gracefully: false);
      rethrow;
    }
    return connection;
  }

  final MariaDbConnectionConfig config;
  final Socket _socket;

  late final StreamSubscription<Uint8List> _subscription;

  final _ByteQueue _incoming = _ByteQueue();
  Completer<void>? _dataAvailable;
  Object? _socketFailure;
  bool _done = false;
  int _sequence = 0;
  bool _open = true;

  int _connectionId = 0;
  String _serverVersion = '';
  String _authPlugin = '';
  int _serverCapabilities = 0;
  final Map<int, MariaDbPreparedStatement> _statements =
      <int, MariaDbPreparedStatement>{};
  int _preparedCounter = 0;

  String get serverVersion => _serverVersion;

  int get connectionId => _connectionId;

  String get authPlugin => _authPlugin;

  bool get isOpen => _open;

  int get serverCapabilities => _serverCapabilities;

  String get endpoint => config.endpoint;

  // -------------------------------------------------------------------
  // Socket plumbing
  // -------------------------------------------------------------------

  void _onData(Uint8List data) {
    _incoming.add(data);
    _dataAvailable?.complete();
    _dataAvailable = null;
  }

  void _onSocketError(Object error) {
    _socketFailure = error;
    _dataAvailable?.complete();
    _dataAvailable = null;
  }

  void _onSocketDone() {
    _done = true;
    _dataAvailable?.complete();
    _dataAvailable = null;
  }

  Future<void> _waitForData(Duration timeout) async {
    if (_done || _socketFailure != null) {
      return;
    }
    final Completer<void> completer = Completer<void>();
    _dataAvailable = completer;
    try {
      await completer.future.timeout(timeout);
    } on TimeoutException {
      throw MysqlProtocolException(
        'MariaDB did not answer within ${timeout.inSeconds}s',
        detail: 'endpoint ${config.endpoint}',
      );
    }
  }

  Future<Uint8List> _readPacket(Duration timeout) async {
    while (true) {
      if (_incoming.length >= 4) {
        final int length = _incoming.peekUint3();
        if (_incoming.length >= 4 + length) {
          _incoming.skip(3); // payload length
          final int sequence = _incoming.readUint1();
          _sequence = (sequence + 1) & 0xff;
          final Uint8List payload = _incoming.take(length);
          if (length == 0xffffff) {
            // A payload larger than 16 MiB is split over several packets.
            final Uint8List rest = await _readPacket(timeout);
            return Uint8List.fromList(<int>[...payload, ...rest]);
          }
          return payload;
        }
      }
      if (_socketFailure != null) {
        throw MysqlProtocolException(
          'Connection to ${config.endpoint} failed',
          detail: '$_socketFailure',
        );
      }
      if (_done) {
        throw MysqlProtocolException(
          'MariaDB closed the connection to ${config.endpoint}',
          detail: 'the server stopped or restarted',
        );
      }
      await _waitForData(timeout);
    }
  }

  void _writePacket(Uint8List payload) {
    if (!_open) {
      throw const MysqlProtocolException('Connection is closed');
    }
    final int length = payload.length;
    final Uint8List header = Uint8List(4);
    header[0] = length & 0xff;
    header[1] = (length >> 8) & 0xff;
    header[2] = (length >> 16) & 0xff;
    header[3] = _sequence & 0xff;
    _sequence = (_sequence + 1) & 0xff;
    _socket.add(header);
    _socket.add(payload);
  }

  void _resetSequence() => _sequence = 0;

  // -------------------------------------------------------------------
  // Handshake
  // -------------------------------------------------------------------

  int _clientCapabilities({bool withDatabase = false}) {
    int flags = MysqlCapability.base | MysqlCapability.pluginAuthLenEncClientData;
    if (withDatabase) {
      flags |= MysqlCapability.connectWithDb;
    }
    return flags;
  }

  Future<void> _handshake() async {
    _resetSequence();
    final Uint8List greeting = await _readPacket(config.connectTimeout);
    final MysqlHandshake handshake = MysqlHandshake.parse(greeting);
    _serverVersion = handshake.serverVersion;
    _connectionId = handshake.connectionId;
    _serverCapabilities = handshake.capabilities;
    _authPlugin = handshake.authPluginName;

    final int capabilities = _clientCapabilities(
      withDatabase: config.database != null && config.database!.isNotEmpty,
    );
    final MysqlWriter response = MysqlWriter()
      ..writeInt4(capabilities)
      ..writeInt4(16 * 1024 * 1024)
      ..writeInt1(45) // utf8mb4_general_ci
      ..writeZeros(23)
      ..writeNulString(config.user);

    final List<int> scramble =
        nativePasswordScramble(config.password, handshake.scramble);
    response
      ..writeLengthEncodedInt(scramble.length)
      ..writeBytes(scramble);
    if (capabilities & MysqlCapability.connectWithDb != 0) {
      response.writeNulString(config.database!);
    }
    response.writeNulString(handshake.authPluginName);
    _writePacket(response.takeBytes());

    await _readAuthResult();
  }

  Future<void> _readAuthResult() async {
    while (true) {
      final Uint8List payload = await _readPacket(config.connectTimeout);
      if (payload.isEmpty) {
        throw const MysqlProtocolException('Empty packet during authentication');
      }
      final int header = payload[0];
      if (header == 0x00) {
        _open = true;
        return;
      }
      if (header == 0xff) {
        _open = false;
        throw MysqlErrPacket.parse(payload).toException();
      }
      if (header == 0xfe) {
        // Authentication switch request: plugin name + new scramble.
        final MysqlReader reader = MysqlReader(payload, 1);
        final String plugin = reader.readNulString();
        final Uint8List data = reader.readRest();
        _authPlugin = plugin;
        if (plugin != 'mysql_native_password') {
          throw MysqlProtocolException(
            'MariaDB asked for the "$plugin" authentication plugin',
            detail: 'PALLSQL implements mysql_native_password; '
                'create the app user with '
                'IDENTIFIED VIA mysql_native_password',
          );
        }
        final List<int> switched = nativePasswordScramble(
          config.password,
          List<int>.from(data),
        );
        _writePacket(Uint8List.fromList(switched));
        continue;
      }
      if (header == 0x01) {
        // AuthMoreData. MariaDB only uses it for plugins PALLSQL does not
        // implement, so the server message is surfaced instead of guessing.
        final MysqlReader reader = MysqlReader(payload, 1);
        if (reader.hasMore && reader.bytes[reader.offset] == 0x03) {
          reader.offset++;
        }
        throw MysqlProtocolException(
          'MariaDB sent extra authentication data for "$_authPlugin"',
          detail: 'extended authentication is not supported by PALLSQL',
        );
      }
      throw MysqlProtocolException(
        'Unexpected packet 0x${header.toRadixString(16)} during authentication',
      );
    }
  }

  // -------------------------------------------------------------------
  // Commands
  // -------------------------------------------------------------------

  /// Runs [sql]; several statements separated by `;` are executed in order and
  /// every result is returned.
  Future<MariaDbBatch> query(String sql, {Duration? timeout}) async {
    final Duration limit = timeout ?? config.queryTimeout;
    final Stopwatch stopwatch = Stopwatch()..start();
    final MysqlWriter writer = MysqlWriter()
      ..writeInt1(MysqlCommand.query)
      ..writeBytes(utf8.encode(sql));
    _resetSequence();
    _writePacket(writer.takeBytes());

    final List<MariaDbResult> results = <MariaDbResult>[];
    int executed = 0;
    while (true) {
      MariaDbResult? result;
      MysqlServerException? failure;
      try {
        final _RawResult raw = await _readResult(
          timeout: limit,
          binary: false,
        );
        result = raw.toResult();
        executed++;
      } on MysqlServerException catch (error) {
        failure = error;
      }
      if (result != null) {
        results.add(result);
      }
      if (failure != null) {
        stopwatch.stop();
        return MariaDbBatch(
          results: results,
          error: failure,
          statementsExecuted: results.length,
          duration: stopwatch.elapsed,
        );
      }
      final bool more = _lastStatus & MysqlServerStatus.moreResultsExist != 0;
      if (!more) {
        break;
      }
    }
    stopwatch.stop();
    final List<MariaDbResult> timed = results
        .map(
          (MariaDbResult result) => MariaDbResult(
            columns: result.columns,
            rows: result.rows,
            affectedRows: result.affectedRows,
            lastInsertId: result.lastInsertId,
            warningCount: result.warningCount,
            duration: stopwatch.elapsed,
            info: result.info,
          ),
        )
        .toList(growable: false);
    return MariaDbBatch(
      results: timed,
      error: null,
      statementsExecuted: executed,
      duration: stopwatch.elapsed,
    );
  }

  int _lastStatus = 0;

  /// Changes the default database (`COM_INIT_DB`, the protocol equivalent of
  /// `USE`).
  Future<void> selectDatabase(String database) async {
    final MysqlWriter writer = MysqlWriter()
      ..writeInt1(MysqlCommand.initDb)
      ..writeBytes(utf8.encode(database));
    _resetSequence();
    _writePacket(writer.takeBytes());
    final Uint8List payload = await _readPacket(config.queryTimeout);
    _throwIfError(payload);
    _lastStatus = MysqlOkPacket.parse(payload).statusFlags;
  }

  /// `COM_PING`; a real round trip to the server.
  Future<bool> ping({Duration? timeout}) async {
    try {
      _resetSequence();
      _writePacket(Uint8List.fromList(<int>[MysqlCommand.ping]));
      final Uint8List payload =
          await _readPacket(timeout ?? const Duration(seconds: 5));
      _throwIfError(payload);
      return true;
    } on MysqlProtocolException {
      return false;
    } on MysqlServerException {
      return false;
    }
  }

  void _throwIfError(Uint8List payload) {
    if (payload.isNotEmpty && payload[0] == 0xff) {
      throw MysqlErrPacket.parse(payload).toException();
    }
  }

  Future<MariaDbPreparedStatement> prepare(String sql) async {
    final MysqlWriter writer = MysqlWriter()
      ..writeInt1(MysqlCommand.stmtPrepare)
      ..writeBytes(utf8.encode(sql));
    _resetSequence();
    _writePacket(writer.takeBytes());

    final Uint8List first = await _readPacket(config.queryTimeout);
    _throwIfError(first);
    if (first.isEmpty || first[0] != 0x00) {
      throw const MysqlProtocolException(
        'COM_STMT_PREPARE returned an unexpected packet',
      );
    }
    final MysqlReader reader = MysqlReader(first, 1);
    final int statementId = reader.readInt4();
    final int columnCount = reader.readInt2();
    final int parameterCount = reader.readInt2();
    reader.readInt1(); // reserved
    if (reader.hasMore) {
      reader.readInt2(); // warning count
    }

    for (int i = 0; i < parameterCount; i++) {
      await _readPacket(config.queryTimeout);
    }
    if (parameterCount > 0) {
      await _readPacket(config.queryTimeout); // EOF after parameters
    }
    final List<MysqlColumn> columns = <MysqlColumn>[];
    for (int i = 0; i < columnCount; i++) {
      final Uint8List payload = await _readPacket(config.queryTimeout);
      columns.add(MysqlColumn.parse(payload));
    }
    if (columnCount > 0) {
      await _readPacket(config.queryTimeout); // EOF after columns
    }

    final MariaDbPreparedStatement statement = MariaDbPreparedStatement._(
      id: statementId,
      parameterCount: parameterCount,
      columns: columns,
      connection: this,
    );
    _statements[statementId] = statement;
    _preparedCounter++;
    return statement;
  }

  Future<MariaDbResult> _executePrepared(
    MariaDbPreparedStatement statement,
    List<Object?> parameters, {
    Duration? timeout,
  }) async {
    final List<MysqlParam> bound =
        parameters.map(MysqlParam.from).toList(growable: false);
    final MysqlWriter writer = MysqlWriter()
      ..writeInt1(MysqlCommand.stmtExecute)
      ..writeInt4(statement.id)
      ..writeInt1(0) // CURSOR_TYPE_NO_CURSOR
      ..writeInt4(1); // iteration count

    if (bound.isNotEmpty) {
      final int bitmapLength = (bound.length + 7) ~/ 8;
      final Uint8List nullBitmap = Uint8List(bitmapLength);
      for (int i = 0; i < bound.length; i++) {
        if (parameters[i] == null) {
          nullBitmap[i ~/ 8] |= 1 << (i % 8);
        }
      }
      writer
        ..writeBytes(nullBitmap)
        ..writeInt1(1); // new params bound
      for (final MysqlParam param in bound) {
        writer.writeInt1(param.type);
        writer.writeInt1(param.unsigned ? 0x80 : 0x00);
      }
      for (final MysqlParam param in bound) {
        param.writeValue(writer);
      }
    }

    _resetSequence();
    _writePacket(writer.takeBytes());
    final _RawResult raw = await _readResult(
      timeout: timeout ?? config.queryTimeout,
      binary: true,
    );
    return raw.toResult();
  }

  Future<void> _closePrepared(MariaDbPreparedStatement statement) async {
    if (!_open) {
      return;
    }
    _statements.remove(statement.id);
    final MysqlWriter writer = MysqlWriter()
      ..writeInt1(MysqlCommand.stmtClose)
      ..writeInt4(statement.id);
    _resetSequence();
    try {
      _writePacket(writer.takeBytes());
    } on MysqlProtocolException {
      // The connection is already gone; nothing to close on the server.
    }
  }

  /// Reads one result (a result set or an OK summary).
  Future<_RawResult> _readResult({
    required Duration timeout,
    required bool binary,
  }) async {
    final Uint8List first = await _readPacket(timeout);
    if (first.isEmpty) {
      throw const MysqlProtocolException('Empty response packet');
    }
    final int header = first[0];
    if (header == 0xff) {
      throw MysqlErrPacket.parse(first).toException();
    }
    if (header == 0x00) {
      final MysqlOkPacket ok = MysqlOkPacket.parse(first);
      _lastStatus = ok.statusFlags;
      return _RawResult(
        columns: const <String>[],
        rows: const <List<String?>>[],
        affectedRows: ok.affectedRows,
        lastInsertId: ok.lastInsertId,
        warningCount: ok.warningCount,
        info: ok.info,
      );
    }
    if (header == 0xfb) {
      // LOCAL INFILE request. PALLSQL never reads arbitrary device files for
      // the server, so the request is answered with an empty payload and the
      // server reports its own error.
      _writePacket(Uint8List(0));
      return _readResult(timeout: timeout, binary: binary);
    }

    final MysqlReader countReader = MysqlReader(first);
    final int? columnCount = countReader.readLengthEncodedInt();
    if (columnCount == null || columnCount <= 0) {
      throw const MysqlProtocolException('Invalid column count in result set');
    }
    final List<MysqlColumn> definitions = <MysqlColumn>[];
    for (int i = 0; i < columnCount; i++) {
      definitions.add(MysqlColumn.parse(await _readPacket(timeout)));
    }
    // EOF after the column definitions (PALLSQL never sets CLIENT_DEPRECATE_EOF).
    final Uint8List afterColumns = await _readPacket(timeout);
    if (afterColumns.isNotEmpty && afterColumns[0] == 0xff) {
      throw MysqlErrPacket.parse(afterColumns).toException();
    }
    MysqlEofPacket eof = MysqlEofPacket.parse(afterColumns);

    final List<String> names = definitions
        .map((MysqlColumn column) =>
            column.name.isEmpty ? column.originalName : column.name)
        .toList(growable: false);
    final List<List<String?>> rows = <List<String?>>[];

    while (true) {
      final Uint8List payload = await _readPacket(timeout);
      if (payload.isEmpty) {
        continue;
      }
      if (payload[0] == 0xfe && payload.length < 9) {
        eof = MysqlEofPacket.parse(payload);
        break;
      }
      if (payload[0] == 0xff) {
        throw MysqlErrPacket.parse(payload).toException();
      }
      rows.add(_decodeRow(payload, definitions, binary));
    }
    _lastStatus = eof.statusFlags;
    return _RawResult(
      columns: names,
      rows: rows,
      affectedRows: 0,
      lastInsertId: 0,
      warningCount: eof.warningCount,
      info: '',
    );
  }

  List<String?> _decodeRow(
    Uint8List payload,
    List<MysqlColumn> columns,
    bool binary,
  ) {
    if (!binary) {
      final MysqlReader reader = MysqlReader(payload);
      return <String?>[
        for (final MysqlColumn column in columns) readTextCell(reader, column),
      ];
    }
    // Binary row: 0x00 header, null bitmap with a 2 bit offset.
    final MysqlReader reader = MysqlReader(payload, 1);
    final int bitmapLength = (columns.length + 7 + 2) ~/ 8;
    final Uint8List nullBitmap = reader.readBytes(bitmapLength);
    final List<String?> values = <String?>[];
    for (int i = 0; i < columns.length; i++) {
      final int bitIndex = i + 2;
      final bool isNull =
          (nullBitmap[bitIndex ~/ 8] >> (bitIndex % 8)) & 0x01 == 1;
      if (isNull) {
        values.add(null);
        continue;
      }
      values.add(formatCell(readBinaryCell(reader, columns[i])));
    }
    return values;
  }

  /// Reads the server error log? No: reads the warnings of the last statement
  /// through `SHOW WARNINGS`, which is a normal query.
  Future<List<List<String?>>> warnings() async {
    final MariaDbBatch batch = await query('SHOW WARNINGS');
    final MariaDbResult? result = batch.last;
    return result?.rows ?? const <List<String?>>[];
  }

  /// Number of prepared statements the app still holds.
  int get openStatementCount => _statements.length;

  int get preparedTotal => _preparedCounter;

  Future<void> close({bool gracefully = true}) async {
    if (!_open && _done) {
      return;
    }
    _open = false;
    if (gracefully) {
      try {
        _resetSequence();
        _writePacket(Uint8List.fromList(<int>[MysqlCommand.quit]));
      } on Object {
        // Best effort: the socket is closed below either way.
      }
    }
    _statements.clear();
    await _subscription.cancel();
    _socket.destroy();
    _done = true;
    _incoming.clear();
  }
}

class _RawResult {
  const _RawResult({
    required this.columns,
    required this.rows,
    required this.affectedRows,
    required this.lastInsertId,
    required this.warningCount,
    required this.info,
  });

  final List<String> columns;
  final List<List<String?>> rows;
  final int affectedRows;
  final int lastInsertId;
  final int warningCount;
  final String info;

  MariaDbResult toResult() => MariaDbResult(
        columns: columns,
        rows: rows,
        affectedRows: affectedRows,
        lastInsertId: lastInsertId,
        warningCount: warningCount,
        duration: Duration.zero,
        info: info,
      );
}

/// Growable byte queue used by the packet reader.
class _ByteQueue {
  Uint8List _buffer = Uint8List(8192);
  int _start = 0;
  int _end = 0;

  int get length => _end - _start;

  void add(Uint8List data) {
    if (_end + data.length > _buffer.length) {
      final int used = length;
      final int needed = used + data.length;
      int capacity = _buffer.length;
      while (capacity < needed) {
        capacity *= 2;
      }
      final Uint8List grown = Uint8List(capacity);
      grown.setRange(0, used, _buffer, _start);
      _buffer = grown;
      _start = 0;
      _end = used;
    }
    _buffer.setRange(_end, _end + data.length, data);
    _end += data.length;
  }

  void _require(int count) {
    if (length < count) {
      throw const MysqlProtocolException('Byte queue underflow');
    }
  }

  int peekUint1(int offset) {
    _require(offset + 1);
    return _buffer[_start + offset];
  }

  int readUint1() {
    _require(1);
    return _buffer[_start++];
  }

  int peekUint3() {
    _require(3);
    return _buffer[_start] | (_buffer[_start + 1] << 8) | (_buffer[_start + 2] << 16);
  }

  void skip(int count) {
    _require(count);
    _start += count;
  }

  Uint8List take(int count) {
    _require(count);
    final Uint8List slice =
        Uint8List.fromList(Uint8List.sublistView(_buffer, _start, _start + count));
    _start += count;
    return slice;
  }

  void clear() {
    _start = 0;
    _end = 0;
  }
}
