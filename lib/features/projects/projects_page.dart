import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../core/theme/pallsql_colors.dart';
import '../../core/utils/validators.dart';
import '../../models/project.dart';
import '../../providers/app_providers.dart';
import '../../repositories/project_repository.dart';
import '../../widgets/pallsql_app_bar.dart';
import '../../widgets/pallsql_card.dart';
import '../../widgets/pallsql_dialogs.dart';
import '../../widgets/project_card.dart';
import '../files/files_page.dart';

/// Website project manager.
class ProjectsPage extends ConsumerStatefulWidget {
  const ProjectsPage({super.key});

  @override
  ConsumerState<ProjectsPage> createState() => _ProjectsPageState();
}

class _ProjectsPageState extends ConsumerState<ProjectsPage> {
  bool _busy = false;

  Future<void> _createProject() async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final _ProjectDraft? draft = await showDialog<_ProjectDraft>(
      context: context,
      builder: (BuildContext context) => const _NewProjectDialog(),
    );
    if (draft == null || !mounted) {
      return;
    }
    setState(() => _busy = true);
    final String? error = await ref.read(projectsProvider.notifier).create(
          name: draft.name,
          template: draft.template,
          description: draft.description,
        );
    if (!mounted) {
      return;
    }
    setState(() => _busy = false);
    showPallSqlSnack(
      messenger,
      error ?? 'Project ${draft.name} created and set as document root',
      error: error != null,
    );
  }

  Future<void> _serve(Project project) async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    await ref.read(projectsProvider.notifier).activate(project);
    final String? error = await ref.read(webServerProvider.notifier).start();
    if (!mounted) {
      return;
    }
    setState(() => _busy = false);
    if (error != null) {
      showPallSqlSnack(messenger, error, error: true);
      return;
    }
    showPallSqlSnack(
      messenger,
      'Serving ${project.name} on ${ref.read(webServerProvider).primaryUrl}',
    );
  }

  Future<void> _delete(Project project) async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final bool confirmed = await showConfirmDialog(
      context: context,
      title: 'Delete ${project.name}?',
      message: 'The project folder projects/${project.directory} and all of '
          'its files are removed.',
      confirmLabel: 'Delete',
      destructive: true,
    );
    if (!confirmed || !mounted) {
      return;
    }
    final String? error =
        await ref.read(projectsProvider.notifier).delete(project);
    if (!mounted) {
      return;
    }
    showPallSqlSnack(
      messenger,
      error ?? '${project.name} deleted',
      error: error != null,
    );
  }

  Future<void> _duplicate(Project project) async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final String? name = await showPromptDialog(
      context: context,
      title: 'Duplicate project',
      label: 'New project name',
      initialValue: '${project.name} copy',
      confirmLabel: 'Duplicate',
      validator: Validators.projectNameError,
    );
    if (name == null || !mounted) {
      return;
    }
    final String? error =
        await ref.read(projectsProvider.notifier).duplicate(project, name);
    if (!mounted) {
      return;
    }
    showPallSqlSnack(messenger, error ?? 'Copied to $name',
        error: error != null);
  }

  Future<void> _export(Project project) async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    final File? file =
        await ref.read(projectsProvider.notifier).exportZip(project);
    if (!mounted) {
      return;
    }
    setState(() => _busy = false);
    if (file == null) {
      showPallSqlSnack(messenger, 'Export failed', error: true);
      return;
    }
    final bool shared =
        await ref.read(nativeBridgeProvider).shareFile(file.path);
    if (!mounted) {
      return;
    }
    showPallSqlSnack(
      messenger,
      shared ? 'Exported ${p.basename(file.path)}' : 'Saved ${file.path}',
    );
  }

  Future<void> _import() async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final String? picked = await ref
        .read(nativeBridgeProvider)
        .pickFileToImport(
          destinationDirectory: ref.read(bootstrapProvider).workspace.tmp.path,
        );
    if (!mounted) {
      return;
    }
    if (picked == null) {
      showPallSqlSnack(
        messenger,
        'Choosing a ZIP archive requires the Android picker',
        error: true,
      );
      return;
    }
    setState(() => _busy = true);
    final String? error =
        await ref.read(projectsProvider.notifier).importZip(File(picked));
    if (!mounted) {
      return;
    }
    setState(() => _busy = false);
    showPallSqlSnack(
      messenger,
      error ?? 'Project imported from ${p.basename(picked)}',
      error: error != null,
    );
  }

  void _openFiles(Project project) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (BuildContext context) =>
            FilesPage(initialPath: 'projects/${project.directory}'),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final AsyncValue<List<Project>> async = ref.watch(projectsProvider);
    final List<Project> projects = async.valueOrNull ?? const <Project>[];
    final Project? active = ref.watch(activeProjectProvider);

    return Scaffold(
      appBar: PallSQLAppBar(
        title: 'Projects',
        subtitle: '${projects.length} website project(s)',
        showBack: true,
        actions: <Widget>[
          IconButton(
            tooltip: 'Import ZIP',
            icon: const Icon(Icons.file_download_outlined, size: 19),
            onPressed: _busy ? null : _import,
          ),
          IconButton(
            tooltip: 'New project',
            icon: const Icon(Icons.add_rounded, size: 20),
            onPressed: _busy ? null : _createProject,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(14, 8, 14, 24),
        children: <Widget>[
          if (_busy) const LinearProgressIndicator(minHeight: 2),
          if (async.isLoading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 20),
              child: Center(child: CircularProgressIndicator()),
            ),
          if (async.hasError)
            PallSqlCard(
              accentColor: PallSqlColors.error,
              child: Text(
                '${async.error}',
                style: const TextStyle(
                  color: PallSqlColors.error,
                  fontSize: 11.5,
                ),
              ),
            ),
          if (!async.isLoading && projects.isEmpty)
            PallSqlCard(
              child: PallSqlEmptyState(
                icon: Icons.folder_special_rounded,
                title: 'No projects yet',
                message:
                    'Create a static site, a PHP hello world, an HTML form '
                    'or a database sample.',
                action: FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: PallSqlColors.accent,
                    foregroundColor: const Color(0xFF07130A),
                  ),
                  onPressed: _createProject,
                  child: const Text('Create project'),
                ),
              ),
            ),
          for (final Project project in projects)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: ProjectCard(
                project: project,
                isActive: active?.id == project.id,
                onOpen: () => _openFiles(project),
                onRun: () => _serve(project),
                onDuplicate: () => _duplicate(project),
                onExport: () => _export(project),
                onDelete: () => _delete(project),
              ),
            ),
          const SizedBox(height: 8),
          const PallSqlCard(
            child: Text(
              'Projects live in PALLSQL/projects/<folder>. Serving a project '
              'switches the document root of the local server; the shared '
              'PALLSQL/htdocs folder stays available as the default site.',
              style: TextStyle(
                fontSize: 11.5,
                height: 1.45,
                color: PallSqlColors.textSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ProjectDraft {
  const _ProjectDraft({
    required this.name,
    required this.template,
    required this.description,
  });

  final String name;
  final ProjectTemplate template;
  final String description;
}

class _NewProjectDialog extends StatefulWidget {
  const _NewProjectDialog();

  @override
  State<_NewProjectDialog> createState() => _NewProjectDialogState();
}

class _NewProjectDialogState extends State<_NewProjectDialog> {
  final TextEditingController _name = TextEditingController();
  final TextEditingController _description = TextEditingController();
  ProjectTemplate _template = ProjectTemplate.staticSite;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    super.dispose();
  }

  void _submit() {
    final String? error = Validators.projectNameError(_name.text);
    if (error != null) {
      setState(() => _error = error);
      return;
    }
    Navigator.of(context).pop(
      _ProjectDraft(
        name: _name.text.trim(),
        template: _template,
        description: _description.text.trim(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: PallSqlColors.surfaceElevated,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      title: const Text(
        'New project',
        style: TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w700,
          color: PallSqlColors.textPrimary,
        ),
      ),
      content: SizedBox(
        width: 380,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              TextField(
                controller: _name,
                autofocus: true,
                style: const TextStyle(
                  color: PallSqlColors.textPrimary,
                  fontSize: 13,
                ),
                decoration: InputDecoration(
                  isDense: true,
                  labelText: 'Project name',
                  errorText: _error,
                  labelStyle: const TextStyle(
                    color: PallSqlColors.textSecondary,
                    fontSize: 12,
                  ),
                  filled: true,
                  fillColor: PallSqlColors.background,
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
              const SizedBox(height: 10),
              TextField(
                controller: _description,
                maxLines: 2,
                style: const TextStyle(
                  color: PallSqlColors.textPrimary,
                  fontSize: 12.5,
                ),
                decoration: InputDecoration(
                  isDense: true,
                  labelText: 'Description (optional)',
                  labelStyle: const TextStyle(
                    color: PallSqlColors.textSecondary,
                    fontSize: 12,
                  ),
                  filled: true,
                  fillColor: PallSqlColors.background,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(9),
                    borderSide: const BorderSide(color: PallSqlColors.border),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(9),
                    borderSide: const BorderSide(color: PallSqlColors.border),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              const Text(
                'STARTER',
                style: TextStyle(
                  fontSize: 10,
                  letterSpacing: 1.4,
                  fontWeight: FontWeight.w700,
                  color: PallSqlColors.textSecondary,
                ),
              ),
              const SizedBox(height: 6),
              for (final ProjectTemplate template in ProjectTemplate.values)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: InkWell(
                    onTap: () => setState(() => _template = template),
                    borderRadius: BorderRadius.circular(9),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: _template == template
                            ? PallSqlColors.accent.withValues(alpha: 0.1)
                            : PallSqlColors.background,
                        borderRadius: BorderRadius.circular(9),
                        border: Border.all(
                          color: _template == template
                              ? PallSqlColors.accent.withValues(alpha: 0.5)
                              : PallSqlColors.border,
                        ),
                      ),
                      child: Row(
                        children: <Widget>[
                          Icon(
                            _template == template
                                ? Icons.radio_button_checked_rounded
                                : Icons.radio_button_off_rounded,
                            size: 15,
                            color: _template == template
                                ? PallSqlColors.accent
                                : PallSqlColors.textDisabled,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: <Widget>[
                                Text(
                                  template.label,
                                  style: const TextStyle(
                                    fontSize: 12.5,
                                    color: PallSqlColors.textPrimary,
                                  ),
                                ),
                                Text(
                                  template.description,
                                  style: const TextStyle(
                                    fontSize: 10.5,
                                    color: PallSqlColors.textSecondary,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          style: TextButton.styleFrom(
            foregroundColor: PallSqlColors.textSecondary,
          ),
          child: const Text('Cancel'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: PallSqlColors.accent,
            foregroundColor: const Color(0xFF07130A),
          ),
          onPressed: _submit,
          child: const Text('Create'),
        ),
      ],
    );
  }
}
