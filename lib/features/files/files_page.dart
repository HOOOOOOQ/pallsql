import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../core/errors/app_failure.dart';
import '../../core/theme/pallsql_colors.dart';
import '../../core/utils/validators.dart';
import '../../models/file_entry.dart';
import '../../providers/app_providers.dart';
import '../../repositories/file_repository.dart';
import '../../widgets/pallsql_app_bar.dart';
import '../../widgets/pallsql_card.dart';
import '../../widgets/pallsql_dialogs.dart';
import '../../widgets/service_control_button.dart';
import '../database/database_detail_page.dart';
import 'file_editor_page.dart';

/// Workspace file manager.
class FilesPage extends ConsumerStatefulWidget {
  const FilesPage({super.key, this.initialPath = ''});

  /// Folder to open first (relative to the workspace root).
  final String initialPath;

  @override
  ConsumerState<FilesPage> createState() => _FilesPageState();
}

class _FilesPageState extends ConsumerState<FilesPage> {
  late String _path = widget.initialPath;
  List<FileEntry> _entries = const <FileEntry>[];
  List<FileEntry> _searchResults = const <FileEntry>[];
  FileSortOrder _sort = FileSortOrder.nameAsc;
  bool _showHidden = false;
  bool _loading = true;
  bool _searching = false;
  String _query = '';
  final Set<String> _selection = <String>{};

  FileRepository get _files => ref.read(fileRepositoryProvider);

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    setState(() => _loading = true);
    try {
      final List<FileEntry> entries = await _files.list(
        _path,
        showHidden: _showHidden,
        order: _sort,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _entries = entries;
        _loading = false;
        _selection.clear();
      });
    } on AppFailure catch (failure) {
      if (!mounted) {
        return;
      }
      setState(() => _loading = false);
      showPallSqlSnack(ScaffoldMessenger.of(context), failure.combined, error: true);
    }
  }

  Future<void> _open(FileEntry entry) async {
    if (entry.isDirectory) {
      setState(() {
        _path = entry.relativePath;
        _selection.clear();
      });
      await _reload();
      return;
    }
    if (entry.extension == 'db' || entry.extension == 'sqlite') {
      final String name = p.basenameWithoutExtension(entry.name);
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (BuildContext context) => DatabaseDetailPage(databaseName: name),
        ),
      );
      return;
    }
    if (!entry.isEditable) {
      showPallSqlSnack(
        ScaffoldMessenger.of(context),
        '${entry.name} is not a text file. Use Export to share it.',
      );
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (BuildContext context) => FileEditorPage(relativePath: entry.relativePath),
      ),
    );
    if (mounted) {
      await _reload();
    }
  }

  Future<void> _createEntry({required bool directory}) async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final String? name = await showPromptDialog(
      context: context,
      title: directory ? 'New folder' : 'New file',
      label: 'Name',
      initialValue: directory ? '' : 'index.html',
      confirmLabel: 'Create',
      validator: Validators.entryNameError,
    );
    if (name == null || !mounted) {
      return;
    }
    try {
      if (directory) {
        await _files.createDirectory(_path, name);
      } else {
        await _files.createFile(_path, name);
      }
      if (!mounted) {
        return;
      }
      await _reload();
      if (!mounted) {
        return;
      }
      showPallSqlSnack(messenger, '$name created');
    } on AppFailure catch (failure) {
      if (!mounted) {
        return;
      }
      showPallSqlSnack(messenger, failure.combined, error: true);
    }
  }

  Future<void> _rename(FileEntry entry) async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final String? name = await showPromptDialog(
      context: context,
      title: 'Rename',
      label: 'New name',
      initialValue: entry.name,
      confirmLabel: 'Rename',
      validator: Validators.entryNameError,
    );
    if (name == null || !mounted || name == entry.name) {
      return;
    }
    try {
      await _files.rename(entry.relativePath, name);
      if (!mounted) {
        return;
      }
      await _reload();
      if (!mounted) {
        return;
      }
      showPallSqlSnack(messenger, 'Renamed to $name');
    } on AppFailure catch (failure) {
      if (!mounted) {
        return;
      }
      showPallSqlSnack(messenger, failure.combined, error: true);
    }
  }

  Future<void> _delete(FileEntry entry) async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final bool confirmed = await showConfirmDialog(
      context: context,
      title: 'Delete ${entry.name}?',
      message: entry.isDirectory
          ? 'The folder and everything inside it is removed.'
          : 'The file is removed from the workspace.',
      confirmLabel: 'Delete',
      destructive: true,
    );
    if (!confirmed || !mounted) {
      return;
    }
    try {
      await _files.delete(entry.relativePath);
      if (!mounted) {
        return;
      }
      await _reload();
      if (!mounted) {
        return;
      }
      showPallSqlSnack(messenger, '${entry.name} deleted');
    } on AppFailure catch (failure) {
      if (!mounted) {
        return;
      }
      showPallSqlSnack(messenger, failure.combined, error: true);
    }
  }

  Future<void> _copyOrMove(FileEntry entry, {required bool move}) async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final String? destination = await showPromptDialog(
      context: context,
      title: move ? 'Move' : 'Copy',
      label: 'Destination path (relative to workspace)',
      message: 'Example: htdocs/${entry.name}',
      initialValue: _path.isEmpty ? entry.name : '$_path/${entry.name}',
      confirmLabel: move ? 'Move' : 'Copy',
      validator: (String value) => Validators.isSafeRelativePath(value)
          ? null
          : 'Use a relative path inside the workspace',
    );
    if (destination == null || !mounted) {
      return;
    }
    try {
      if (move) {
        await _files.move(entry.relativePath, destination);
      } else {
        await _files.copy(entry.relativePath, destination);
      }
      if (!mounted) {
        return;
      }
      await _reload();
      if (!mounted) {
        return;
      }
      showPallSqlSnack(messenger, move ? 'Moved' : 'Copied');
    } on AppFailure catch (failure) {
      if (!mounted) {
        return;
      }
      showPallSqlSnack(messenger, failure.combined, error: true);
    }
  }

  Future<void> _importFile() async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final String? picked = await ref.read(nativeBridgeProvider).pickFileToImport(
          destinationDirectory: ref.read(bootstrapProvider).workspace.tmp.path,
        );
    if (!mounted) {
      return;
    }
    if (picked == null) {
      showPallSqlSnack(
        messenger,
        'File picking is only available on Android',
        error: true,
      );
      return;
    }
    try {
      final String name = p.basename(picked);
      final String destination = _path.isEmpty ? name : '$_path/$name';
      await _files.importPickedFile(picked, destination);
      if (!mounted) {
        return;
      }
      await _reload();
      if (!mounted) {
        return;
      }
      showPallSqlSnack(messenger, '$name imported');
    } on AppFailure catch (failure) {
      if (!mounted) {
        return;
      }
      showPallSqlSnack(messenger, failure.combined, error: true);
    }
  }

  Future<void> _exportFile(FileEntry entry) async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    try {
      final File target = File(
        p.join(ref.read(bootstrapProvider).workspace.tmp.path, entry.name),
      );
      await _files.exportFile(entry.relativePath, target.parent);
      final bool shared = await ref.read(nativeBridgeProvider).shareFile(target.path);
      if (!mounted) {
        return;
      }
      showPallSqlSnack(
        messenger,
        shared
            ? '${entry.name} shared'
            : 'Saved a copy at ${target.path} (sharing unavailable)',
      );
    } on AppFailure catch (failure) {
      if (!mounted) {
        return;
      }
      showPallSqlSnack(messenger, failure.combined, error: true);
    }
  }

  Future<void> _search(String query) async {
    setState(() => _query = query);
    if (query.trim().isEmpty) {
      setState(() {
        _searching = false;
        _searchResults = const <FileEntry>[];
      });
      return;
    }
    final List<FileEntry> results = await _files.search(query);
    if (!mounted) {
      return;
    }
    setState(() {
      _searching = true;
      _searchResults = results;
    });
  }

  Future<void> _deleteSelection() async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final bool confirmed = await showConfirmDialog(
      context: context,
      title: 'Delete ${_selection.length} item(s)?',
      message: 'Selected files and folders are removed permanently.',
      confirmLabel: 'Delete',
      destructive: true,
    );
    if (!confirmed || !mounted) {
      return;
    }
    for (final String path in _selection.toList(growable: false)) {
      try {
        await _files.delete(path);
      } on AppFailure catch (failure) {
        if (!mounted) {
          return;
        }
        showPallSqlSnack(messenger, failure.combined, error: true);
      }
    }
    if (!mounted) {
      return;
    }
    await _reload();
  }

  void _goUp() {
    if (_path.isEmpty) {
      return;
    }
    setState(() {
      _path = p.posix.dirname(_path);
      _path = _path == '.' ? '' : _path;
      _selection.clear();
    });
    _reload();
  }

  List<Widget> _breadcrumbs() {
    final List<String> segments = _path.isEmpty ? <String>[] : _path.split('/');
    return <Widget>[
      InkWell(
        onTap: () {
          setState(() => _path = '');
          _reload();
        },
        child: const Text(
          'PALLSQL',
          style: TextStyle(
            fontSize: 11.5,
            color: PallSqlColors.accent,
            fontFamily: PallSqlColors.monoFontFamily,
          ),
        ),
      ),
      for (int index = 0; index < segments.length; index++) ...<Widget>[
        const Text(
          ' / ',
          style: TextStyle(fontSize: 11.5, color: PallSqlColors.textDisabled),
        ),
        InkWell(
          onTap: () {
            setState(() {
              _path = segments.take(index + 1).join('/');
              _selection.clear();
            });
            _reload();
          },
          child: Text(
            segments[index],
            style: TextStyle(
              fontSize: 11.5,
              fontFamily: PallSqlColors.monoFontFamily,
              color: index == segments.length - 1
                  ? PallSqlColors.textPrimary
                  : PallSqlColors.accent,
            ),
          ),
        ),
      ],
    ];
  }

  @override
  Widget build(BuildContext context) {
    final List<FileEntry> visible = _searching ? _searchResults : _entries;
    return Scaffold(
      appBar: PallSQLAppBar(
        title: 'Files',
        subtitle: _path.isEmpty ? 'PALLSQL workspace' : _path,
        actions: <Widget>[
          IconButton(
            tooltip: 'Import file',
            icon: const Icon(Icons.upload_file_rounded, size: 19),
            onPressed: _importFile,
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert_rounded, size: 19),
            color: PallSqlColors.surfaceElevated,
            onSelected: (String value) {
              if (value == 'file') {
                _createEntry(directory: false);
              } else if (value == 'folder') {
                _createEntry(directory: true);
              } else if (value == 'hidden') {
                setState(() => _showHidden = !_showHidden);
                _reload();
              } else if (value == 'refresh') {
                _reload();
              } else {
                final FileSortOrder? order = _orderOf(value);
                if (order != null) {
                  setState(() => _sort = order);
                  _reload();
                }
              }
            },
            itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
              const PopupMenuItem<String>(value: 'file', child: Text('New file')),
              const PopupMenuItem<String>(value: 'folder', child: Text('New folder')),
              const PopupMenuItem<String>(value: 'hidden', child: Text('Toggle hidden')),
              const PopupMenuItem<String>(value: 'refresh', child: Text('Refresh')),
              const PopupMenuDivider(),
              for (final FileSortOrder order in FileSortOrder.values)
                PopupMenuItem<String>(value: order.name, child: Text(order.label)),
            ],
          ),
        ],
      ),
      body: Column(
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 4, 14, 8),
            child: Column(
              children: <Widget>[
                Row(
                  children: <Widget>[
                    IconButton(
                      onPressed: _path.isEmpty ? null : _goUp,
                      icon: const Icon(Icons.arrow_upward_rounded, size: 16),
                      visualDensity: VisualDensity.compact,
                      tooltip: 'Up',
                    ),
                    Expanded(
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(children: _breadcrumbs()),
                      ),
                    ),
                  ],
                ),
                TextField(
                  onChanged: _search,
                  style: const TextStyle(
                    fontSize: 12.5,
                    color: PallSqlColors.textPrimary,
                  ),
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: 'Search the workspace',
                    hintStyle: const TextStyle(
                      color: PallSqlColors.textDisabled,
                      fontSize: 12.5,
                    ),
                    prefixIcon: const Icon(Icons.search_rounded, size: 17),
                    filled: true,
                    fillColor: PallSqlColors.surface,
                    contentPadding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(9),
                      borderSide: const BorderSide(color: PallSqlColors.border),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(9),
                      borderSide: const BorderSide(color: PallSqlColors.border),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(9),
                      borderSide: const BorderSide(color: PallSqlColors.accent),
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (_loading) const LinearProgressIndicator(minHeight: 2),
          Expanded(
            child: visible.isEmpty
                ? PallSqlEmptyState(
                    icon: _searching
                        ? Icons.search_off_rounded
                        : Icons.folder_open_rounded,
                    title: _searching ? 'No matches' : 'This folder is empty',
                    message: _searching
                        ? 'Nothing matched "$_query"'
                        : 'Create a file or folder to get started.',
                  )
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    itemCount: visible.length,
                    itemBuilder: (BuildContext context, int index) {
                      final FileEntry entry = visible[index];
                      final bool selected =
                          _selection.contains(entry.relativePath);
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: PallSqlCard(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 10,
                          ),
                          accentColor: selected ? PallSqlColors.accent : null,
                          onTap: () {
                            if (_selection.isEmpty) {
                              _open(entry);
                              return;
                            }
                            setState(() {
                              if (selected) {
                                _selection.remove(entry.relativePath);
                              } else {
                                _selection.add(entry.relativePath);
                              }
                            });
                          },
                          child: Row(
                            children: <Widget>[
                              Icon(
                                entry.isDirectory
                                    ? Icons.folder_rounded
                                    : _iconFor(entry),
                                size: 18,
                                color: entry.isDirectory
                                    ? PallSqlColors.accent
                                    : PallSqlColors.textSecondary,
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: <Widget>[
                                    Text(
                                      entry.name,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        fontSize: 13,
                                        color: PallSqlColors.textPrimary,
                                        fontFamily: PallSqlColors.monoFontFamily,
                                      ),
                                    ),
                                    Text(
                                      _searching
                                          ? entry.relativePath
                                          : entry.displaySize,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        fontSize: 10,
                                        color: PallSqlColors.textDisabled,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              PopupMenuButton<String>(
                                icon: const Icon(Icons.more_vert_rounded, size: 16),
                                color: PallSqlColors.surfaceElevated,
                                onSelected: (String value) {
                                  if (value == 'select') {
                                    setState(() {
                                      if (selected) {
                                        _selection.remove(entry.relativePath);
                                      } else {
                                        _selection.add(entry.relativePath);
                                      }
                                    });
                                  } else if (value == 'rename') {
                                    _rename(entry);
                                  } else if (value == 'copy') {
                                    _copyOrMove(entry, move: false);
                                  } else if (value == 'move') {
                                    _copyOrMove(entry, move: true);
                                  } else if (value == 'export') {
                                    _exportFile(entry);
                                  } else if (value == 'delete') {
                                    _delete(entry);
                                  }
                                },
                                itemBuilder: (BuildContext context) =>
                                    <PopupMenuEntry<String>>[
                                  const PopupMenuItem<String>(
                                    value: 'select',
                                    child: Text('Select'),
                                  ),
                                  const PopupMenuItem<String>(
                                    value: 'rename',
                                    child: Text('Rename'),
                                  ),
                                  const PopupMenuItem<String>(
                                    value: 'copy',
                                    child: Text('Copy'),
                                  ),
                                  const PopupMenuItem<String>(
                                    value: 'move',
                                    child: Text('Move'),
                                  ),
                                  const PopupMenuItem<String>(
                                    value: 'export',
                                    child: Text('Export / share'),
                                  ),
                                  const PopupMenuItem<String>(
                                    value: 'delete',
                                    child: Text('Delete'),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
          if (_selection.isNotEmpty)
            Container(
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
              decoration: const BoxDecoration(
                color: PallSqlColors.surface,
                border: Border(top: BorderSide(color: PallSqlColors.border)),
              ),
              child: Row(
                children: <Widget>[
                  Text(
                    '${_selection.length} selected',
                    style: const TextStyle(
                      fontSize: 12,
                      color: PallSqlColors.textSecondary,
                    ),
                  ),
                  const Spacer(),
                  ServiceControlButton(
                    label: 'Clear',
                    icon: Icons.close_rounded,
                    compact: true,
                    expand: false,
                    onPressed: () => setState(_selection.clear),
                  ),
                  const SizedBox(width: 8),
                  ServiceControlButton(
                    label: 'Delete',
                    icon: Icons.delete_outline_rounded,
                    compact: true,
                    destructive: true,
                    expand: false,
                    onPressed: _deleteSelection,
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  FileSortOrder? _orderOf(String name) {
    for (final FileSortOrder order in FileSortOrder.values) {
      if (order.name == name) {
        return order;
      }
    }
    return null;
  }

  IconData _iconFor(FileEntry entry) {
    switch (entry.extension) {
      case 'php':
        return Icons.code_rounded;
      case 'html':
      case 'htm':
        return Icons.html_rounded;
      case 'css':
        return Icons.css_rounded;
      case 'js':
        return Icons.javascript_rounded;
      case 'json':
        return Icons.data_object_rounded;
      case 'sql':
        return Icons.storage_rounded;
      case 'db':
      case 'sqlite':
        return Icons.dns_rounded;
      case 'md':
        return Icons.article_outlined;
      case 'png':
      case 'jpg':
      case 'jpeg':
      case 'gif':
      case 'webp':
      case 'svg':
        return Icons.image_outlined;
      default:
        return Icons.insert_drive_file_outlined;
    }
  }
}
