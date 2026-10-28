import '../core/constants/app_info.dart';
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

/// Allow-listed command interpreter for the PALLSQL terminal.
class TerminalService {
  TerminalService(this.api);

  final TerminalApi api;

  List<TerminalCommand> get commands => _commands;

  /// Executes a single command line. Unknown commands fail with a clear hint.
  Future<TerminalResult> execute(String input) async {
    final String trimmed = input.trim();
    if (trimmed.isEmpty) {
      return TerminalResult.empty;
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
          'commands. PALLSQL does not provide a Linux shell.',
          level: LogLevel.error,
        ),
      ]);
    }
    try {
      return await command.run(api, args);
    } on Object catch (error) {
      return TerminalResult(<TerminalLine>[
        TerminalLine('Command failed: $error', level: LogLevel.error),
      ]);
    }
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
          final TerminalCommand? command = _find(args.first);
          if (command == null) {
            return TerminalResult(<TerminalLine>[
              TerminalLine('No such command: ${args.first}', level: LogLevel.error),
            ]);
          }
          return TerminalResult(<TerminalLine>[
            TerminalLine('${command.usage}'),
            TerminalLine(command.description),
          ]);
        }
        return TerminalResult(<TerminalLine>[
          const TerminalLine('PALLSQL command registry (no shell access):'),
          for (final TerminalCommand command in _commands)
            TerminalLine('  ${command.usage.padRight(28)}${command.description}'),
          const TerminalLine(''),
          const TerminalLine(
            'Commands call internal PALLSQL APIs. Arbitrary shell commands are '
            'not executed.',
            level: LogLevel.debug,
          ),
        ]);
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
        final String action = args.isEmpty ? 'status' : args.first.toLowerCase();
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
          return const TerminalResult(<TerminalLine>[TerminalLine('(no logs)')]);
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
      usage: 'database list|tables <name>|status',
      description: 'Inspect the offline database engine',
      run: (TerminalApi api, List<String> args) async {
        final String action = args.isEmpty ? 'list' : args.first.toLowerCase();
        if (action == 'status') {
          final EngineAvailability availability = await api.databaseAvailability();
          return TerminalResult(<TerminalLine>[
            TerminalLine('engine: ${availability.engine.label}'),
            TerminalLine(
              'state: ${availability.available ? 'available' : 'unavailable'}',
            ),
            if (availability.version != null)
              TerminalLine('version: ${availability.version}'),
            if (availability.reason != null)
              TerminalLine(availability.reason!, level: LogLevel.warning),
          ]);
        }
        if (action == 'tables') {
          if (args.length < 2) {
            return const TerminalResult(<TerminalLine>[
              TerminalLine('Usage: database tables <name>', level: LogLevel.warning),
            ]);
          }
          final List<TableInfo> tables = await api.tables(args[1]);
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
        final List<DatabaseInfo> databases = await api.databases();
        if (databases.isEmpty) {
          return const TerminalResult(<TerminalLine>[
            TerminalLine('No databases yet.'),
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
      run: (TerminalApi api, List<String> args) async =>
          TerminalResult(<TerminalLine>[TerminalLine(await api.storageSummary())]),
    ),
    TerminalCommand(
      name: 'version',
      usage: 'version',
      description: 'Print the PALLSQL version',
      run: (TerminalApi api, List<String> args) async => TerminalResult(
        <TerminalLine>[
          const TerminalLine('${AppInfo.appName} ${AppInfo.version}'),
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
          TerminalLine('php binary: ${settings.phpBinaryPath.isEmpty ? 'auto' : settings.phpBinaryPath}'),
        ]);
      },
    ),
  ];
}
