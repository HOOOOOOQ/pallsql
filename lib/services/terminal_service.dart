import '../core/constants/app_info.dart';
import '../core/errors/app_failure.dart';
import '../core/utils/formatters.dart';
import '../models/app_settings.dart';
import '../models/database_models.dart';
import '../models/file_entry.dart';
import '../models/log_entry.dart';
import '../models/project.dart';
import 'php_runtime_service.dart';
import 'web_server_service.dart';

/// One line of terminal output.
class TerminalLine {
  const TerminalLine(this.text, {this.level = LogLevel.info});

  final String text;
  final LogLevel level;
}

/// Result of executing a command.
class TerminalResult {
  const TerminalResult(this.lines, {this.clearScreen = false});

  final List<TerminalLine> lines;
  final bool clearScreen;

  static const TerminalResult empty = TerminalResult(<TerminalLine>[]);
}

/// Everything the terminal is allowed to touch.
///
/// The terminal never spawns a shell: every command goes through this narrow
/// API which maps onto real PALLSQL services.
abstract class TerminalApi {
  String get workspaceRoot;

  Future<List<FileEntry>> listFiles(String relativePath);

  Future<String> readTextFile(String relativePath);

  WebServerSnapshot get serverSnapshot;

  Future<String> startServer();

  Future<String> stopServer();

  Future<String> restartServer();

  Future<PhpRuntimeInfo> phpInfo({bool refresh = false});

  Future<List<DatabaseInfo>> databases();

  Future<List<TableInfo>> tables(String database);

  Future<EngineAvailability> databaseAvailability();

  /// Runs SQL against a real database through the shared repository.
  Future<QueryResult> runSql(
    String database,
    String sql, {
    bool allowDestructive = false,
  });

  /// Creates a real SQLite database file in `PALLSQL/database`.
  Future<void> createDatabase(String name);

  Future<List<Project>> projects();

  List<LogEntry> recentLogs({LogSource? source, int limit = 20});

  AppSettings get settings;

  Future<String> storageSummary();
}

/// A registered, allow-listed command.
class TerminalCommand {
  const TerminalCommand({
    required this.name,
    required this.usage,
    required this.description,
    required this.run,
  });

  final String name;
  final String usage;
  final String description;
  final Future<TerminalResult> Function(TerminalApi api, List<String> args) run;
}

/// Renders a [QueryResult] as monospace text for the terminal / SQL console.
List<TerminalLine> renderQueryResult(
  QueryResult result, {
  int maxRows = 25,
}) {
  final List<TerminalLine> lines = <TerminalLine>[];
  if (result.isError) {
    lines.add(TerminalLine('Error: ${result.error}', level: LogLevel.error));
    for (final String notice in result.notices) {
      lines.add(TerminalLine('  $notice', level: LogLevel.debug));
    }
    return lines;
  }
  if (result.hasResultSet) {
    final List<String> headers = result.columns;
    final List<List<String>> cells = result.rows
        .map((List<String?> row) => row
            .map((String? cell) => cell ?? 'NULL')
            .toList(growable: false))
        .toList(growable: false);
    final List<int> widths = <int>[
      for (int i = 0; i < headers.length; i++)
        _columnWidth(headers[i], cells, i),
    ];
    final StringBuffer header = StringBuffer();
    for (int i = 0; i < headers.length; i++) {
      if (i > 0) {
        header.write('  ');
      }
      header.write(_pad(headers[i], widths[i]));
    }
    lines.add(TerminalLine(header.toString(), level: LogLevel.info));
    final StringBuffer rule = StringBuffer();
    for (int i = 0; i < widths.length; i++) {
      if (i > 0) {
        rule.write('  ');
      }
      rule.write('-' * widths[i]);
    }
    lines.add(TerminalLine(rule.toString(), level: LogLevel.debug));
    final int shown =
        cells.length > maxRows ? maxRows : cells.length;
    for (int row = 0; row < shown; row++) {
      final StringBuffer buffer = StringBuffer();
      for (int i = 0; i < headers.length; i++) {
        if (i > 0) {
          buffer.write('  ');
        }
        buffer.write(_pad(cells[row][i], widths[i]));
      }
      lines.add(TerminalLine(buffer.toString()));
    }
    if (cells.length > shown) {
      lines.add(
        TerminalLine(
          '... ${cells.length - shown} more row(s) not shown',
          level: LogLevel.debug,
        ),
      );
    }
    lines.add(
      TerminalLine(
        '${Formatters.count(cells.length, 'row')} in '
        '${Formatters.duration(result.duration)}',
        level: LogLevel.debug,
      ),
    );
  } else {
    lines.add(
      TerminalLine(
        '${Formatters.count(result.statementsExecuted, 'statement')} ok in '
        '${Formatters.duration(result.duration)}'
        '${result.rowsAffected > 0 ? ', ${result.rowsAffected} row(s) affected' : ''}',
        level: LogLevel.debug,
      ),
    );
  }
  for (final String notice in result.notices) {
    lines.add(TerminalLine('  $notice', level: LogLevel.debug));
  }
  if (result.cancelled) {
    lines.add(const TerminalLine('Stopped by user', level: LogLevel.warning));
  }
  return lines;
}

int _columnWidth(String header, List<List<String>> rows, int index) {
  int width = header.length;
  for (final List<String> row in rows) {
    if (index < row.length && row[index].length > width) {
      width = row[index].length;
    }
  }
  if (width > 26) {
    width = 26;
  }
  return width < 3 ? 3 : width;
}

String _pad(String value, int width) {
  if (value.length > width) {
    return value.substring(0, width);
  }
  return value.padRight(width);
}

/// Allow-listed command interpreter plus a SQL console.
///
/// Two modes share one input field:
/// * **shell** - the registered commands below (never a Linux shell);
/// * **sql** - every line is executed against the selected SQLite database
///   through [TerminalApi.runSql]. Dot commands (`.tables`, `.use`, ...) and
///   `\q` stay inside the console.
class TerminalService {
  TerminalService(this.api);

  final TerminalApi api;

  bool _sqlMode = false;
  bool _allowDestructive = false;
  String? _database;

  List<TerminalCommand> get commands => _commands;

  bool get sqlMode => _sqlMode;

  bool get allowDestructive => _allowDestructive;

  String? get currentDatabase => _database;

  /// Prompt prefix shown by the terminal screen.
  String get prompt {
    if (!_sqlMode) {
      return '>';
    }
    final String? database = _database;
    return database == null ? 'sql>' : 'sql($database)>';
  }

  /// Executes a single line of input (shell command or SQL statement).
  Future<TerminalResult> execute(String input) async {
    final String trimmed = input.trim();
    if (trimmed.isEmpty) {
      return TerminalResult.empty;
    }
    if (_sqlMode) {
      return _executeInSqlMode(trimmed);
    }
    final List<String> tokens = _tokenize(trimmed);
    if (tokens.isEmpty) {
      return TerminalResult.empty;
    }
    final String name = tokens.first.toLowerCase();
    final List<String> args = tokens.sublist(1);
    if (name == 'clear') {
      return const TerminalResult(<TerminalLine>[], clearScreen: true);
    }
    final TerminalCommand? command = _find(name);
    if (command == null) {
      return TerminalResult(<TerminalLine>[
        TerminalLine(
          'Unknown command: $name. Type "help" for the list of supported '
          'commands, or "sql" to open the SQL console. PALLSQL does not '
          'provide a Linux shell.',
          level: LogLevel.error,
        ),
      ]);
    }
    try {
      return await command.run(api, args);
    } on AppFailure catch (failure) {
      return TerminalResult(<TerminalLine>[
        TerminalLine(failure.combined, level: LogLevel.error),
      ]);
    } on Object catch (error) {
      return TerminalResult(<TerminalLine>[
        TerminalLine('Command failed: $error', level: LogLevel.error),
      ]);
    }
  }

  /// Leaves the SQL console (also used by the UI's mode chip).
  void exitSqlMode() {
    _sqlMode = false;
  }

  /// Selects the console database; returns `false` when it does not exist.
  Future<bool> selectDatabase(String name) async {
    final List<DatabaseInfo> databases = await api.databases();
    for (final DatabaseInfo database in databases) {
      if (database.name == name) {
        _database = database.name;
        return true;
      }
    }
    return false;
  }

  Future<TerminalResult> _executeInSqlMode(String input) async {
    final String lower = input.toLowerCase();
    if (lower == '\\q' || lower == 'exit' || lower == '.exit' || lower == '\\quit') {
      _sqlMode = false;
      return const TerminalResult(<TerminalLine>[
        TerminalLine('Left the SQL console. PALLSQL shell commands are active again.'),
      ]);
    }
    if (input.startsWith('.')) {
      return _dotCommand(input);
    }
    if (lower == '\\help') {
      return _sqlHelp();
    }
    return _runSql(input);
  }

  Future<TerminalResult> _dotCommand(String input) async {
    final List<String> tokens = _tokenize(input.substring(1));
    if (tokens.isEmpty) {
      return _sqlHelp();
    }
    final String name = tokens.first.toLowerCase();
    final List<String> args = tokens.sublist(1);
    switch (name) {
      case 'exit':
      case 'quit':
        _sqlMode = false;
        return const TerminalResult(<TerminalLine>[
          TerminalLine('Left the SQL console.'),
        ]);
      case 'help':
        return _sqlHelp();
      case 'databases':
        return _listDatabases();
      case 'tables':
        final String? database = _database;
        if (database == null) {
          return _noDatabase();
        }
        return _describeTables(database);
      case 'use':
        if (args.isEmpty) {
          return const TerminalResult(<TerminalLine>[
            TerminalLine('Usage: .use <database>', level: LogLevel.warning),
          ]);
        }
        final bool found = await selectDatabase(args.first);
        if (!found) {
          return TerminalResult(<TerminalLine>[
            TerminalLine('Unknown database: ${args.first}', level: LogLevel.error),
          ]);
        }
        return TerminalResult(<TerminalLine>[
          TerminalLine('Using ${args.first}.db'),
        ]);
      case 'force':
        final String value = args.isEmpty ? '' : args.first.toLowerCase();
        if (value == 'on' || value == 'off') {
          _allowDestructive = value == 'on';
          return TerminalResult(<TerminalLine>[
            TerminalLine(
              _allowDestructive
                  ? 'Destructive statements are allowed in this console '
                      'session. .force off restores the guard.'
                  : 'Destructive statements need .force on first.',
              level: _allowDestructive ? LogLevel.warning : LogLevel.info,
            ),
          ]);
        }
        return const TerminalResult(<TerminalLine>[
          TerminalLine('Usage: .force on|off', level: LogLevel.warning),
        ]);
      case 'read':
        if (args.isEmpty) {
          return const TerminalResult(<TerminalLine>[
            TerminalLine('Usage: .read <path/to/file.sql>', level: LogLevel.warning),
          ]);
        }
        return _runSqlFile(args.first);
      default:
        return TerminalResult(<TerminalLine>[
          TerminalLine(
            'Unknown console command: .$name. Type .help for the list.',
            level: LogLevel.error,
          ),
        ]);
    }
  }

  TerminalResult _sqlHelp() {
    return const TerminalResult(<TerminalLine>[
      TerminalLine('SQL console - statements run through the PALLSQL engine.'),
      TerminalLine('  <sql>;              run a statement (SQLite dialect)'),
      TerminalLine('  SHOW DATABASES;     translated from real workspace files'),
      TerminalLine('  SHOW TABLES;        real sqlite_master metadata'),
      TerminalLine('  DESCRIBE <table>;   real PRAGMA table_info metadata'),
      TerminalLine('  SELECT VERSION();   real engine version'),
      TerminalLine('  .databases          list database files'),
      TerminalLine('  .tables             list tables of the current database'),
      TerminalLine('  .use <database>     switch database'),
      TerminalLine('  .read <file.sql>    execute a script from the workspace'),
      TerminalLine('  .force on|off       allow destructive statements'),
      TerminalLine('  \\q                  leave the SQL console', level: LogLevel.debug),
    ]);
  }

  TerminalResult _noDatabase() {
    return const TerminalResult(<TerminalLine>[
      TerminalLine(
        'No database selected. Type .databases then .use <name>, or create one '
        'with: database create <name>',
        level: LogLevel.warning,
      ),
    ]);
  }

  Future<TerminalResult> _listDatabases() async {
    final List<DatabaseInfo> databases = await api.databases();
    if (databases.isEmpty) {
      return const TerminalResult(<TerminalLine>[
        TerminalLine('No databases yet. Create one with: database create <name>'),
      ]);
    }
    return TerminalResult(<TerminalLine>[
      TerminalLine('SQLite databases (${databases.length}):'),
      for (final DatabaseInfo database in databases)
        TerminalLine(
          '  ${database.name.padRight(24)} ${database.sizeBytes} bytes '
          '${database.name == _database ? '<- current' : ''}',
        ),
    ]);
  }

  Future<TerminalResult> _describeTables(String database) async {
    final List<TableInfo> tables = await api.tables(database);
    if (tables.isEmpty) {
      return const TerminalResult(<TerminalLine>[
        TerminalLine('(no tables)'),
      ]);
    }
    return TerminalResult(<TerminalLine>[
      for (final TableInfo table in tables)
        TerminalLine('  ${table.type.padRight(6)} ${table.name}'),
    ]);
  }

  Future<TerminalResult> _runSql(String sql) async {
    final String? database = _database;
    if (database == null) {
      return _noDatabase();
    }
    if (sql.length > AppInfo.maxSqlScriptBytes) {
      return const TerminalResult(<TerminalLine>[
        TerminalLine('Script is too large for the console', level: LogLevel.error),
      ]);
    }
    try {
      final QueryResult result = await api.runSql(
        database,
        sql,
        allowDestructive: _allowDestructive,
      );
      return TerminalResult(renderQueryResult(result));
    } on AppFailure catch (failure) {
      return TerminalResult(<TerminalLine>[
        TerminalLine(failure.combined, level: LogLevel.error),
      ]);
    } on Object catch (error) {
      return TerminalResult(<TerminalLine>[
        TerminalLine('$error', level: LogLevel.error),
      ]);
    }
  }

  Future<TerminalResult> _runSqlFile(String path) async {
    final String? database = _database;
    if (database == null) {
      return _noDatabase();
    }
    String script;
    try {
      script = await api.readTextFile(path);
    } on Object catch (error) {
      return TerminalResult(<TerminalLine>[
        TerminalLine('Could not read $path: $error', level: LogLevel.error),
      ]);
    }
    if (script.trim().isEmpty) {
      return TerminalResult(<TerminalLine>[
        TerminalLine('$path is empty', level: LogLevel.warning),
      ]);
    }
    return _runSql(script);
  }

  TerminalCommand? _find(String name) {
    for (final TerminalCommand command in _commands) {
      if (command.name == name) {
        return command;
      }
    }
    return null;
  }

  static List<String> _tokenize(String input) {
    final List<String> tokens = <String>[];
    final StringBuffer current = StringBuffer();
    String quote = '';
    for (int i = 0; i < input.length; i++) {
      final String char = input[i];
      if (quote.isNotEmpty) {
        if (char == quote) {
          quote = '';
        } else {
          current.write(char);
        }
        continue;
      }
      if (char == '"' || char == "'") {
        quote = char;
        continue;
      }
      if (char.trim().isEmpty) {
        if (current.isNotEmpty) {
          tokens.add(current.toString());
          current.clear();
        }
        continue;
      }
      current.write(char);
    }
    if (current.isNotEmpty) {
      tokens.add(current.toString());
    }
    return tokens;
  }

  late final List<TerminalCommand> _commands = <TerminalCommand>[
    TerminalCommand(
      name: 'help',
      usage: 'help [command]',
      description: 'List the commands PALLSQL supports',
      run: (TerminalApi api, List<String> args) async {
        if (args.isNotEmpty) {
          if (args.first.toLowerCase() == 'sql') {
            return _sqlHelp();
          }
          final TerminalCommand? command = _find(args.first);
          if (command == null) {
            return TerminalResult(<TerminalLine>[
              TerminalLine('No such command: ${args.first}',
                  level: LogLevel.error),
            ]);
          }
          return TerminalResult(<TerminalLine>[
            TerminalLine(command.usage),
            TerminalLine(command.description),
          ]);
        }
        return TerminalResult(<TerminalLine>[
          const TerminalLine('PALLSQL command registry (no shell access):'),
          for (final TerminalCommand command in _commands)
            TerminalLine(
                '  ${command.usage.padRight(34)}${command.description}'),
          const TerminalLine(''),
          const TerminalLine(
            'Type "sql" for the SQL console (real SQLite statements). '
            'Commands call internal PALLSQL APIs; arbitrary shell commands are '
            'not executed.',
            level: LogLevel.debug,
          ),
        ]);
      },
    ),
    TerminalCommand(
      name: 'sql',
      usage: 'sql [database]',
      description: 'Open the SQL console against a real SQLite database',
      run: (TerminalApi api, List<String> args) async {
        final List<DatabaseInfo> databases = await api.databases();
        if (databases.isEmpty) {
          return const TerminalResult(<TerminalLine>[
            TerminalLine(
              'No databases yet. Create one first: database create <name>',
              level: LogLevel.warning,
            ),
          ]);
        }
        String? target;
        if (args.isNotEmpty) {
          for (final DatabaseInfo database in databases) {
            if (database.name == args.first) {
              target = database.name;
              break;
            }
          }
          if (target == null) {
            return TerminalResult(<TerminalLine>[
              TerminalLine('Unknown database: ${args.first}', level: LogLevel.error),
              TerminalLine('Available: '
                  '${databases.map((DatabaseInfo d) => d.name).join(', ')}'),
            ]);
          }
        } else if (_database != null &&
            databases.any((DatabaseInfo d) => d.name == _database)) {
          target = _database;
        } else {
          target = databases.first.name;
        }
        _sqlMode = true;
        _database = target;
        return TerminalResult(<TerminalLine>[
          TerminalLine('SQL console - SQLite dialect, database ${target}.db'),
          const TerminalLine(
            'Statements are executed for real. .help lists console commands, '
            '\\q returns to the PALLSQL shell.',
            level: LogLevel.debug,
          ),
        ]);
      },
    ),
    TerminalCommand(
      name: 'use',
      usage: 'use <database>',
      description: 'Select the database used by the SQL console',
      run: (TerminalApi api, List<String> args) async {
        if (args.isEmpty) {
          return const TerminalResult(<TerminalLine>[
            TerminalLine('Usage: use <database>', level: LogLevel.warning),
          ]);
        }
        final bool found = await selectDatabase(args.first);
        if (!found) {
          return TerminalResult(<TerminalLine>[
            TerminalLine('Unknown database: ${args.first}', level: LogLevel.error),
          ]);
        }
        return TerminalResult(<TerminalLine>[
          TerminalLine('Selected ${args.first}.db'),
        ]);
      },
    ),
    TerminalCommand(
      name: 'tables',
      usage: 'tables [database]',
      description: 'List tables of a database',
      run: (TerminalApi api, List<String> args) async {
        final String? database = args.isNotEmpty ? args.first : _database;
        if (database == null) {
          return const TerminalResult(<TerminalLine>[
            TerminalLine('Usage: tables <database>', level: LogLevel.warning),
          ]);
        }
        return _describeTables(database);
      },
    ),
    TerminalCommand(
      name: 'desc',
      usage: 'desc <table>',
      description: 'Describe a table (real SQLite metadata)',
      run: (TerminalApi api, List<String> args) async {
        final String? database = _database;
        if (args.isEmpty || database == null) {
          return const TerminalResult(<TerminalLine>[
            TerminalLine('Usage: desc <table> (select a database with "use")',
                level: LogLevel.warning),
          ]);
        }
        final QueryResult result =
            await api.runSql(database, 'DESCRIBE ${args.first};');
        return TerminalResult(renderQueryResult(result));
      },
    ),
    TerminalCommand(
      name: 'pwd',
      usage: 'pwd',
      description: 'Print the workspace root path',
      run: (TerminalApi api, List<String> args) async => TerminalResult(
        <TerminalLine>[TerminalLine(api.workspaceRoot)],
      ),
    ),
    TerminalCommand(
      name: 'ls',
      usage: 'ls [path]',
      description: 'List a workspace folder (default: root)',
      run: (TerminalApi api, List<String> args) async {
        final String path = args.isEmpty ? '' : args.first;
        final List<FileEntry> entries = await api.listFiles(path);
        if (entries.isEmpty) {
          return const TerminalResult(<TerminalLine>[TerminalLine('(empty)')]);
        }
        return TerminalResult(<TerminalLine>[
          for (final FileEntry entry in entries)
            TerminalLine(
              '${entry.isDirectory ? 'd' : '-'} '
              '${entry.displaySize.padLeft(9)}  ${entry.name}',
            ),
        ]);
      },
    ),
    TerminalCommand(
      name: 'cd',
      usage: 'cd <path>',
      description: 'Check that a workspace folder exists',
      run: (TerminalApi api, List<String> args) async {
        final String path = args.isEmpty ? '' : args.first;
        final List<FileEntry> entries = await api.listFiles(path);
        return TerminalResult(<TerminalLine>[
          TerminalLine('${api.workspaceRoot}/$path'.replaceAll('//', '/')),
          TerminalLine('${entries.length} item(s)', level: LogLevel.debug),
        ]);
      },
    ),
    TerminalCommand(
      name: 'cat',
      usage: 'cat <file>',
      description: 'Print a small UTF-8 text file',
      run: (TerminalApi api, List<String> args) async {
        if (args.isEmpty) {
          return const TerminalResult(<TerminalLine>[
            TerminalLine('Usage: cat <file>', level: LogLevel.warning),
          ]);
        }
        final String content = await api.readTextFile(args.first);
        final List<String> lines = content.split('\n');
        return TerminalResult(<TerminalLine>[
          for (final String line in lines.take(300)) TerminalLine(line),
          if (lines.length > 300)
            const TerminalLine(
              '... output truncated (300 lines)',
              level: LogLevel.debug,
            ),
        ]);
      },
    ),
    TerminalCommand(
      name: 'run',
      usage: 'run <file.sql>',
      description: 'Execute a .sql script from the workspace',
      run: (TerminalApi api, List<String> args) async {
        if (args.isEmpty) {
          return const TerminalResult(<TerminalLine>[
            TerminalLine('Usage: run <file.sql>', level: LogLevel.warning),
          ]);
        }
        final String? database = _database;
        if (database == null) {
          return const TerminalResult(<TerminalLine>[
            TerminalLine(
              'Select a database first: use <database>',
              level: LogLevel.warning,
            ),
          ]);
        }
        String script;
        try {
          script = await api.readTextFile(args.first);
        } on Object catch (error) {
          return TerminalResult(<TerminalLine>[
            TerminalLine('Could not read ${args.first}: $error',
                level: LogLevel.error),
          ]);
        }
        final QueryResult result = await api.runSql(
          database,
          script,
          allowDestructive: _allowDestructive,
        );
        return TerminalResult(renderQueryResult(result));
      },
    ),
    TerminalCommand(
      name: 'projects',
      usage: 'projects',
      description: 'List website projects',
      run: (TerminalApi api, List<String> args) async {
        final List<Project> projects = await api.projects();
        if (projects.isEmpty) {
          return const TerminalResult(<TerminalLine>[
            TerminalLine('No projects yet. Create one in the Projects tab.'),
          ]);
        }
        return TerminalResult(<TerminalLine>[
          TerminalLine('${projects.length} project(s):'),
          for (final Project project in projects)
            TerminalLine(
              '  ${project.directory.padRight(24)} ${project.name}',
            ),
        ]);
      },
    ),
    TerminalCommand(
      name: 'server',
      usage: 'server status|start|stop|restart',
      description: 'Inspect or control the local web server',
      run: (TerminalApi api, List<String> args) async {
        final String action =
            args.isEmpty ? 'status' : args.first.toLowerCase();
        switch (action) {
          case 'status':
            final WebServerSnapshot snapshot = api.serverSnapshot;
            return TerminalResult(<TerminalLine>[
              TerminalLine('state: ${snapshot.state.name}'),
              TerminalLine('port: ${snapshot.port ?? '-'}'),
              TerminalLine('address: ${snapshot.bindAddress ?? '-'}'),
              TerminalLine('document root: ${snapshot.documentRoot}'),
              TerminalLine('requests: ${snapshot.requestCount}'),
              if (snapshot.error != null)
                TerminalLine('error: ${snapshot.error}', level: LogLevel.error),
            ]);
          case 'start':
            return TerminalResult(<TerminalLine>[
              TerminalLine(await api.startServer()),
            ]);
          case 'stop':
            return TerminalResult(<TerminalLine>[
              TerminalLine(await api.stopServer()),
            ]);
          case 'restart':
            return TerminalResult(<TerminalLine>[
              TerminalLine(await api.restartServer()),
            ]);
          default:
            return const TerminalResult(<TerminalLine>[
              TerminalLine(
                'Usage: server status|start|stop|restart',
                level: LogLevel.warning,
              ),
            ]);
        }
      },
    ),
    TerminalCommand(
      name: 'logs',
      usage: 'logs [count]',
      description: 'Show the most recent log entries',
      run: (TerminalApi api, List<String> args) async {
        final int limit = args.isEmpty ? 15 : (int.tryParse(args.first) ?? 15);
        final List<LogEntry> entries =
            api.recentLogs(limit: limit < 1 ? 1 : (limit > 100 ? 100 : limit));
        if (entries.isEmpty) {
          return const TerminalResult(
              <TerminalLine>[TerminalLine('(no logs)')]);
        }
        return TerminalResult(<TerminalLine>[
          for (final LogEntry entry in entries)
            TerminalLine(
              '${entry.level.label.padRight(7)} ${entry.source.label.padRight(9)}'
              ' ${entry.message}',
              level: entry.level,
            ),
        ]);
      },
    ),
    TerminalCommand(
      name: 'php',
      usage: 'php version|status',
      description: 'Report the PHP runtime status',
      run: (TerminalApi api, List<String> args) async {
        final PhpRuntimeInfo info = await api.phpInfo(refresh: true);
        if (!info.available) {
          return TerminalResult(<TerminalLine>[
            TerminalLine(
              'PHP runtime: not installed (${info.reason ?? 'unknown'})',
              level: LogLevel.warning,
            ),
            const TerminalLine(
              'PHP files answer HTTP 501 until a runtime is installed. See the '
              'PHP page in Settings.',
              level: LogLevel.debug,
            ),
          ]);
        }
        return TerminalResult(<TerminalLine>[
          TerminalLine('PHP ${info.version ?? 'unknown'}'),
          TerminalLine('binary: ${info.binaryPath ?? '-'}'),
          TerminalLine('extensions: ${info.extensions.length}'),
          if (info.iniPath != null) TerminalLine('ini: ${info.iniPath}'),
        ]);
      },
    ),
    TerminalCommand(
      name: 'database',
      usage: 'database list|create <name>|use <name>|tables <name>|status',
      description: 'Inspect and manage the offline SQLite engine',
      run: (TerminalApi api, List<String> args) async {
        final String action = args.isEmpty ? 'list' : args.first.toLowerCase();
        if (action == 'status') {
          final EngineAvailability availability =
              await api.databaseAvailability();
          return TerminalResult(<TerminalLine>[
            TerminalLine('engine: ${availability.engine.label}'),
            TerminalLine(
              'dialect: ${availability.engine.label} dialect '
              '(not MySQL/MariaDB)',
            ),
            TerminalLine(
              'state: ${availability.available ? 'available' : 'unavailable'}',
            ),
            if (availability.version != null)
              TerminalLine('version: ${availability.version}'),
            if (availability.reason != null)
              TerminalLine(availability.reason!, level: LogLevel.warning),
          ]);
        }
        if (action == 'create') {
          if (args.length < 2) {
            return const TerminalResult(<TerminalLine>[
              TerminalLine('Usage: database create <name>',
                  level: LogLevel.warning),
            ]);
          }
          await api.createDatabase(args[1]);
          _database = args[1];
          final List<DatabaseInfo> databases = await api.databases();
          final bool exists =
              databases.any((DatabaseInfo d) => d.name == args[1]);
          return TerminalResult(<TerminalLine>[
            TerminalLine(
              exists
                  ? 'Created ${args[1]}.db and selected it'
                  : 'Database ${args[1]} was not created',
              level: exists ? LogLevel.info : LogLevel.error,
            ),
          ]);
        }
        if (action == 'use') {
          if (args.length < 2) {
            return const TerminalResult(<TerminalLine>[
              TerminalLine('Usage: database use <name>', level: LogLevel.warning),
            ]);
          }
          final bool found = await selectDatabase(args[1]);
          return TerminalResult(<TerminalLine>[
            TerminalLine(
              found ? 'Using ${args[1]}.db' : 'Unknown database: ${args[1]}',
              level: found ? LogLevel.info : LogLevel.error,
            ),
          ]);
        }
        if (action == 'info') {
          final String? database = args.length > 1 ? args[1] : _database;
          if (database == null) {
            return const TerminalResult(<TerminalLine>[
              TerminalLine('Usage: database info [name]', level: LogLevel.warning),
            ]);
          }
          final List<TableInfo> tables = await api.tables(database);
          return TerminalResult(<TerminalLine>[
            TerminalLine('database: $database.db'),
            TerminalLine('tables: ${tables.length}'),
            for (final TableInfo table in tables)
              TerminalLine('  ${table.type.padRight(6)} ${table.name}'),
          ]);
        }
        if (action == 'tables') {
          if (args.length < 2) {
            return const TerminalResult(<TerminalLine>[
              TerminalLine('Usage: database tables <name>',
                  level: LogLevel.warning),
            ]);
          }
          return _describeTables(args[1]);
        }
        final List<DatabaseInfo> databases = await api.databases();
        if (databases.isEmpty) {
          return const TerminalResult(<TerminalLine>[
            TerminalLine('No databases yet. Create one: database create appdb'),
          ]);
        }
        return TerminalResult(<TerminalLine>[
          TerminalLine('SQLite databases (${databases.length}):'),
          for (final DatabaseInfo info in databases)
            TerminalLine('  ${info.name.padRight(24)} ${info.sizeBytes} bytes'),
        ]);
      },
    ),
    TerminalCommand(
      name: 'storage',
      usage: 'storage',
      description: 'Show workspace storage usage',
      run: (TerminalApi api, List<String> args) async => TerminalResult(
          <TerminalLine>[TerminalLine(await api.storageSummary())]),
    ),
    TerminalCommand(
      name: 'version',
      usage: 'version',
      description: 'Print the PALLSQL version',
      run: (TerminalApi api, List<String> args) async => TerminalResult(
        <TerminalLine>[
          const TerminalLine('${AppInfo.appName} ${AppInfo.version}'),
          const TerminalLine(
            '${AppInfo.productTagline} - developer ${AppInfo.developer}',
            level: LogLevel.debug,
          ),
        ],
      ),
    ),
    TerminalCommand(
      name: 'settings',
      usage: 'settings',
      description: 'Show the effective server settings',
      run: (TerminalApi api, List<String> args) async {
        final AppSettings settings = api.settings;
        return TerminalResult(<TerminalLine>[
          TerminalLine('port: ${settings.httpPort}'),
          TerminalLine('lan access: ${settings.lanAccess}'),
          TerminalLine('autostart: ${settings.autoStartServer}'),
          TerminalLine(
              'php binary: ${settings.phpBinaryPath.isEmpty ? 'auto' : settings.phpBinaryPath}'),
        ]);
      },
    ),
  ];
}
