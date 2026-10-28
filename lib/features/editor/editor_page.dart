import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../core/errors/app_failure.dart';
import '../../core/theme/pallsql_colors.dart';
import '../../models/app_settings.dart';
import '../../providers/app_providers.dart';
import '../../widgets/code_editor_panel.dart';
import '../../widgets/pallsql_app_bar.dart';
import '../../widgets/pallsql_card.dart';
import '../../widgets/pallsql_dialogs.dart';
import '../../widgets/service_control_button.dart';
import 'syntax_highlighter.dart';

/// Text/code editor for a workspace file.
class EditorPage extends ConsumerStatefulWidget {
  const EditorPage({super.key, required this.relativePath});

  final String relativePath;

  @override
  ConsumerState<EditorPage> createState() => _EditorPageState();
}

class _EditorPageState extends ConsumerState<EditorPage> {
  late final String _fileName = p.basename(widget.relativePath);
  late final CodeLanguage _language = languageForFile(_fileName);
  final TextEditingController _searchController = TextEditingController();
  final TextEditingController _replaceController = TextEditingController();
  HighlightingTextController? _controller;
  String _original = '';
  bool _dirty = false;
  bool _loading = true;
  bool _saving = false;
  bool _searchVisible = false;
  String? _loadError;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _controller?.dispose();
    _searchController.dispose();
    _replaceController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final String content =
          await ref.read(fileRepositoryProvider).readText(widget.relativePath);
      if (!mounted) {
        return;
      }
      final HighlightingTextController controller =
          HighlightingTextController(language: _language, text: content);
      controller.addListener(_onTextChanged);
      setState(() {
        _controller = controller;
        _original = content;
        _loading = false;
        _dirty = false;
      });
    } on AppFailure catch (failure) {
      if (!mounted) {
        return;
      }
      setState(() {
        _loadError = failure.combined;
        _loading = false;
      });
    }
  }

  void _onTextChanged() {
    final HighlightingTextController? controller = _controller;
    if (controller == null) {
      return;
    }
    final bool dirty = controller.text != _original;
    if (dirty != _dirty) {
      setState(() => _dirty = dirty);
    }
  }

  Future<bool> _save() async {
    final HighlightingTextController? controller = _controller;
    if (controller == null) {
      return false;
    }
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    setState(() => _saving = true);
    try {
      await ref
          .read(fileRepositoryProvider)
          .writeText(widget.relativePath, controller.text);
      if (!mounted) {
        return false;
      }
      setState(() {
        _original = controller.text;
        _dirty = false;
        _saving = false;
      });
      showPallSqlSnack(messenger, '$_fileName saved');
      return true;
    } on AppFailure catch (failure) {
      if (!mounted) {
        return false;
      }
      setState(() => _saving = false);
      showPallSqlSnack(messenger, failure.combined, error: true);
      return false;
    }
  }

  Future<void> _confirmLeave() async {
    final bool discard = await showConfirmDialog(
      context: context,
      title: 'Discard changes?',
      message: '$_fileName has unsaved changes.',
      confirmLabel: 'Discard',
      destructive: true,
    );
    if (!discard || !mounted) {
      return;
    }
    setState(() => _dirty = false);
    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  void _findNext() {
    final HighlightingTextController? controller = _controller;
    final String needle = _searchController.text;
    if (controller == null || needle.isEmpty) {
      return;
    }
    final String text = controller.text;
    final int rawStart = controller.selection.end;
    final int start =
        rawStart < 0 ? 0 : (rawStart > text.length ? text.length : rawStart);
    int index = text.indexOf(needle, start);
    if (index < 0) {
      index = text.indexOf(needle);
    }
    if (index < 0) {
      showPallSqlSnack(ScaffoldMessenger.of(context), 'No match for "$needle"',
          error: true);
      return;
    }
    setState(() {
      controller.selection =
          TextSelection(baseOffset: index, extentOffset: index + needle.length);
    });
  }

  void _replaceCurrent() {
    final HighlightingTextController? controller = _controller;
    final String needle = _searchController.text;
    if (controller == null || needle.isEmpty) {
      return;
    }
    final TextSelection selection = controller.selection;
    final String text = controller.text;
    if (selection.start < 0 || selection.end > text.length) {
      return;
    }
    if (text.substring(selection.start, selection.end) == needle) {
      final String replacement = _replaceController.text;
      final String updated = text.replaceRange(
        selection.start,
        selection.end,
        replacement,
      );
      controller.value = TextEditingValue(
        text: updated,
        selection: TextSelection.collapsed(
          offset: selection.start + replacement.length,
        ),
      );
      _onTextChanged();
    }
    _findNext();
  }

  void _replaceAll() {
    final HighlightingTextController? controller = _controller;
    final String needle = _searchController.text;
    if (controller == null || needle.isEmpty) {
      return;
    }
    final String text = controller.text;
    final int count = RegExp(RegExp.escape(needle)).allMatches(text).length;
    if (count == 0) {
      showPallSqlSnack(ScaffoldMessenger.of(context), 'No match for "$needle"',
          error: true);
      return;
    }
    controller.value = TextEditingValue(
      text: text.replaceAll(needle, _replaceController.text),
      selection: const TextSelection.collapsed(offset: 0),
    );
    _onTextChanged();
    showPallSqlSnack(
      ScaffoldMessenger.of(context),
      'Replaced $count occurrence(s)',
    );
  }

  Future<void> _changeFontSize(double delta) async {
    final AppSettings settings = ref.read(settingsProvider);
    final double next =
        (settings.editorFontSize + delta).clamp(10.0, 28.0).toDouble();
    await ref
        .read(settingsProvider.notifier)
        .update(settings.copyWith(editorFontSize: next));
  }

  @override
  Widget build(BuildContext context) {
    final AppSettings settings = ref.watch(settingsProvider);
    final HighlightingTextController? controller = _controller;
    return PopScope<Object?>(
      canPop: !_dirty,
      onPopInvokedWithResult: (bool didPop, Object? result) {
        if (!didPop) {
          _confirmLeave();
        }
      },
      child: Scaffold(
        appBar: PallSQLAppBar(
          title: _dirty ? '$_fileName *' : _fileName,
          subtitle: '${_language.name} - ${widget.relativePath}',
          showBack: true,
          actions: <Widget>[
            IconButton(
              tooltip: 'Find and replace',
              icon: Icon(
                _searchVisible
                    ? Icons.search_off_rounded
                    : Icons.search_rounded,
                size: 19,
              ),
              onPressed: () => setState(() => _searchVisible = !_searchVisible),
            ),
            IconButton(
              tooltip: 'Save',
              icon: const Icon(Icons.save_rounded, size: 19),
              color: _dirty ? PallSqlColors.accent : null,
              onPressed: _dirty && !_saving ? _save : null,
            ),
          ],
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : _loadError != null
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        _loadError!,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: PallSqlColors.error,
                          fontSize: 12.5,
                        ),
                      ),
                    ),
                  )
                : Column(
                    children: <Widget>[
                      if (_searchVisible) _buildSearchBar(),
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                          child: CodeEditorPanel(
                            controller: controller!,
                            language: _language,
                            fontSize: settings.editorFontSize,
                            showLineNumbers: settings.showLineNumbers,
                            wordWrap: settings.editorWordWrap,
                            onChanged: (String value) => _onTextChanged(),
                          ),
                        ),
                      ),
                      _buildStatusBar(settings),
                    ],
                  ),
      ),
    );
  }

  Widget _buildSearchBar() {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
      decoration: const BoxDecoration(
        color: PallSqlColors.surface,
        border: Border(bottom: BorderSide(color: PallSqlColors.border)),
      ),
      child: Column(
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: _SearchField(
                  controller: _searchController,
                  hint: 'Find',
                  onSubmitted: (_) => _findNext(),
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: _SearchField(
                  controller: _replaceController,
                  hint: 'Replace with',
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: <Widget>[
              ServiceControlButton(
                label: 'Find next',
                icon: Icons.search_rounded,
                compact: true,
                expand: false,
                onPressed: _findNext,
              ),
              const SizedBox(width: 6),
              ServiceControlButton(
                label: 'Replace',
                icon: Icons.swap_horiz_rounded,
                compact: true,
                expand: false,
                onPressed: _replaceCurrent,
              ),
              const SizedBox(width: 6),
              ServiceControlButton(
                label: 'All',
                icon: Icons.done_all_rounded,
                compact: true,
                expand: false,
                onPressed: _replaceAll,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildStatusBar(AppSettings settings) {
    final HighlightingTextController? controller = _controller;
    final int lines =
        controller == null ? 0 : controller.text.split('\n').length;
    final int chars = controller?.text.length ?? 0;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: const BoxDecoration(
        color: PallSqlColors.surface,
        border: Border(top: BorderSide(color: PallSqlColors.border)),
      ),
      child: Row(
        children: <Widget>[
          Text(
            '$lines lines - $chars chars',
            style: const TextStyle(
              fontSize: 10.5,
              color: PallSqlColors.textSecondary,
              fontFamily: PallSqlColors.monoFontFamily,
            ),
          ),
          const Spacer(),
          IconButton(
            tooltip: 'Smaller text',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.text_decrease_rounded, size: 15),
            onPressed: () => _changeFontSize(-1),
          ),
          Text(
            '${settings.editorFontSize.toStringAsFixed(0)}pt',
            style: const TextStyle(
              fontSize: 10.5,
              color: PallSqlColors.textSecondary,
            ),
          ),
          IconButton(
            tooltip: 'Larger text',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.text_increase_rounded, size: 15),
            onPressed: () => _changeFontSize(1),
          ),
          IconButton(
            tooltip: 'Toggle line numbers',
            visualDensity: VisualDensity.compact,
            icon: Icon(
              settings.showLineNumbers
                  ? Icons.format_list_numbered_rounded
                  : Icons.format_list_numbered_rtl_rounded,
              size: 15,
            ),
            onPressed: () {
              ref.read(settingsProvider.notifier).update(
                    settings.copyWith(
                        showLineNumbers: !settings.showLineNumbers),
                  );
            },
          ),
          IconButton(
            tooltip: 'Toggle word wrap',
            visualDensity: VisualDensity.compact,
            icon: Icon(
              settings.editorWordWrap
                  ? Icons.wrap_text_rounded
                  : Icons.notes_rounded,
              size: 15,
            ),
            onPressed: () {
              ref.read(settingsProvider.notifier).update(
                    settings.copyWith(editorWordWrap: !settings.editorWordWrap),
                  );
            },
          ),
          if (_dirty)
            const Padding(
              padding: EdgeInsets.only(left: 4),
              child:
                  PallSqlPill(label: 'Unsaved', color: PallSqlColors.warning),
            ),
        ],
      ),
    );
  }
}

class _SearchField extends StatelessWidget {
  const _SearchField({
    required this.controller,
    required this.hint,
    this.onSubmitted,
  });

  final TextEditingController controller;
  final String hint;
  final ValueChanged<String>? onSubmitted;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      onSubmitted: onSubmitted,
      style: const TextStyle(
        fontSize: 12,
        color: PallSqlColors.textPrimary,
        fontFamily: PallSqlColors.monoFontFamily,
      ),
      decoration: InputDecoration(
        isDense: true,
        hintText: hint,
        hintStyle: const TextStyle(
          color: PallSqlColors.textDisabled,
          fontSize: 11.5,
        ),
        filled: true,
        fillColor: PallSqlColors.background,
        contentPadding: const EdgeInsets.symmetric(horizontal: 9, vertical: 8),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: PallSqlColors.border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: PallSqlColors.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: PallSqlColors.accent),
        ),
      ),
    );
  }
}
