import 'dart:async';

import 'package:flutter/material.dart';

import '../services/aaris_default_ai_service.dart';
import '../services/local_ai_service.dart';

/// The single Local AI setup surface inside the existing AI connections sheet.
/// LocalAiService remains the only source of truth for download/activation state.
class LocalModelsPanel extends StatefulWidget {
  const LocalModelsPanel({super.key});

  @override
  State<LocalModelsPanel> createState() => _LocalModelsPanelState();
}

class _LocalModelsPanelState extends State<LocalModelsPanel> {
  final local = LocalAiService.instance;
  final defaults = AarisDefaultAiService.instance;
  final query = TextEditingController();

  List<String> repositories = [];
  List<LocalModelFile> files = [];
  String error = '';
  String catalogueNote = '';
  ModelSort sort = ModelSort.popular;
  Uri? nextPage;
  String _lastQuery = '';
  int? maxFileBytes;
  final _seenPages = <String>{};
  bool searching = false;
  bool finderOpen = false;
  bool advancedOpen = false;
  int _generation = 0;

  bool get _locked => local.busy || local.transferring || defaults.busy;

  @override
  void initState() {
    super.initState();
    unawaited(
      _run(() async {
        await local.initialize();
        await defaults.initialize();
      }),
    );
  }

  @override
  void dispose() {
    ++_generation;
    query.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    if (mounted) setState(() => error = '');
    try {
      await action();
    } catch (e) {
      if (mounted) setState(() => error = _friendlyError(e));
    }
  }

  Future<bool> _confirm(String title, String message) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Continue'),
            ),
          ],
        ),
      ) ??
      false;

  Future<void> _search([String? repository]) async {
    final generation = ++_generation;
    final text = repository ?? query.text.trim();
    setState(() {
      searching = true;
      error = '';
      catalogueNote = '';
      files = [];
      repositories = [];
      nextPage = null;
      _seenPages.clear();
    });
    try {
      final location = ModelRepositoryLocation.parse(text);
      if (location != null) {
        final result = await local.repositoryFiles(text);
        if (!mounted || generation != _generation) return;
        setState(() {
          files = result.files;
          catalogueNote = result.gated
              ? 'Publisher access is required for this model.'
              : files.isEmpty
              ? 'No compatible one-file GGUF model found here.'
              : '';
        });
      } else {
        _lastQuery = text;
        final result = await local.searchPage(text, sort: sort);
        if (!mounted || generation != _generation) return;
        setState(() {
          repositories = result.repositories;
          nextPage = result.next;
          if (repositories.isEmpty) {
            catalogueNote = 'No models found. Try Qwen, Gemma, Llama, or paste a model link.';
          }
        });
      }
    } catch (e) {
      if (mounted && generation == _generation) {
        setState(() => error = _friendlyError(e));
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() => searching = false);
      }
    }
  }

  Future<void> _more() async {
    final cursor = nextPage;
    if (cursor == null || searching) return;
    final generation = ++_generation;
    setState(() {
      searching = true;
      error = '';
    });
    try {
      final result = await local.searchPage(
        _lastQuery,
        sort: sort,
        cursor: cursor,
      );
      if (!mounted || generation != _generation) return;
      setState(() {
        _seenPages.add(cursor.toString());
        repositories = {...repositories, ...result.repositories}.toList();
        nextPage =
            repositories.length >= 200 ||
                _seenPages.contains(result.next.toString())
            ? null
            : result.next;
      });
    } catch (e) {
      if (mounted && generation == _generation) {
        setState(() => error = _friendlyError(e));
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() => searching = false);
      }
    }
  }

  String _stageTitle() => switch (local.setupStage) {
    LocalModelSetupStage.unavailable => 'Local AI unavailable',
    LocalModelSetupStage.chooseModel =>
      local.installed.isEmpty ? 'Local AI not set up' : 'Choose a Local AI',
    LocalModelSetupStage.downloading => 'Downloading…',
    LocalModelSetupStage.verifying => 'Checking download…',
    LocalModelSetupStage.connecting => 'Connecting…',
    LocalModelSetupStage.testing => 'Testing on this phone…',
    LocalModelSetupStage.ready => 'Local AI · Ready',
    LocalModelSetupStage.attention => 'Setup needs attention',
  };

  String _stageSubtitle() {
    final active = local.activeModel;
    if (local.setupStage == LocalModelSetupStage.ready && active != null) {
      return '${_shortLabel(active.label)} · ${modelSize(active.bytes)} · Active';
    }
    if (local.setupStage == LocalModelSetupStage.downloading &&
        local.progress != null) {
      return '${(local.progress! * 100).clamp(0, 100).toStringAsFixed(0)}% downloaded';
    }
    if (local.setupStage == LocalModelSetupStage.chooseModel &&
        local.installed.isNotEmpty) {
      return '${local.installed.length} model${local.installed.length == 1 ? '' : 's'} installed';
    }
    return switch (local.setupStage) {
      LocalModelSetupStage.verifying => 'Making sure the file is complete.',
      LocalModelSetupStage.connecting => 'Loading the model on this device.',
      LocalModelSetupStage.testing => 'Running a quick compatibility test.',
      LocalModelSetupStage.attention => 'Try again or choose another model.',
      LocalModelSetupStage.unavailable =>
        'Use the installed Android or desktop app.',
      _ => 'Choose a model below. Aaris will test it before use.',
    };
  }

  Widget _statusCard(BuildContext context) {
    final ready = local.ready;
    final scheme = Theme.of(context).colorScheme;
    final accent = ready ? Colors.green : scheme.primary;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: ready
            ? Colors.green.withAlpha(18)
            : scheme.primaryContainer.withAlpha(55),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: accent.withAlpha(55)),
      ),
      child: Row(
        children: [
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              color: accent.withAlpha(28),
              shape: BoxShape.circle,
            ),
            child:
                local.setupStage == LocalModelSetupStage.downloading ||
                    local.setupStage == LocalModelSetupStage.verifying ||
                    local.setupStage == LocalModelSetupStage.connecting ||
                    local.setupStage == LocalModelSetupStage.testing
                ? Padding(
                    padding: const EdgeInsets.all(14),
                    child: CircularProgressIndicator(
                      strokeWidth: 3,
                      value:
                          local.setupStage == LocalModelSetupStage.downloading
                          ? local.progress
                          : null,
                    ),
                  )
                : Icon(
                    ready ? Icons.check_rounded : Icons.memory_rounded,
                    color: accent,
                    size: 31,
                  ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _stageTitle(),
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  _stageSubtitle(),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          if (ready)
            const Padding(
              padding: EdgeInsets.only(left: 8),
              child: Icon(Icons.check_circle, color: Colors.green, size: 30),
            ),
        ],
      ),
    );
  }

  Widget _recommendedModel(BuildContext context) => Container(
    margin: const EdgeInsets.only(bottom: 12),
    padding: const EdgeInsets.fromLTRB(13, 11, 10, 11),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.primaryContainer.withAlpha(38),
      borderRadius: BorderRadius.circular(18),
    ),
    child: Row(
      children: [
        const Icon(Icons.auto_awesome_rounded),
        const SizedBox(width: 10),
        const Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Aaris recommended',
                style: TextStyle(fontWeight: FontWeight.w800),
              ),
              SizedBox(height: 2),
              Text('~400 MB · easiest setup', style: TextStyle(fontSize: 11.5)),
            ],
          ),
        ),
        if (defaults.active)
          const Icon(Icons.check_circle, color: Colors.green)
        else
          TextButton(
            onPressed: _locked
                ? null
                : () async {
                    if (await _confirm(
                      'Set up Aaris recommended AI?',
                      'Aaris will download it, check it, test it on this phone, and show Ready only if it works.',
                    )) {
                      await _run(defaults.installAndActivate);
                    }
                  },
            child: const Text('Use'),
          ),
      ],
    ),
  );

  Widget _finder(BuildContext context) {
    final visibleFiles = files
        .where((f) => maxFileBytes == null || f.bytes <= maxFileBytes!)
        .toList(growable: false);
    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: Theme.of(context).colorScheme.outlineVariant.withAlpha(90),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _recommendedModel(context),
          TextField(
            controller: query,
            enabled: !searching && !_locked,
            onSubmitted: (_) => _search(),
            decoration: InputDecoration(
              hintText: 'Search Qwen, Gemma, Llama or paste model link',
              prefixIcon: const Icon(Icons.search_rounded),
              suffixIcon: IconButton(
                tooltip: 'Search models',
                onPressed: searching || _locked ? null : _search,
                icon: const Icon(Icons.arrow_forward_rounded),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 7,
            runSpacing: 6,
            children: [
              for (final option in ModelSort.values)
                ChoiceChip(
                  label: Text(_sortLabel(option)),
                  selected: sort == option,
                  onSelected: searching || _locked
                      ? null
                      : (_) {
                          setState(() => sort = option);
                          unawaited(_search());
                        },
                ),
            ],
          ),
          if (searching) ...[
            const SizedBox(height: 10),
            const LinearProgressIndicator(),
          ],
          if (catalogueNote.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(catalogueNote, style: Theme.of(context).textTheme.bodySmall),
          ],
          if (repositories.isNotEmpty && files.isEmpty) ...[
            const SizedBox(height: 6),
            for (final repository in repositories.take(8))
              ListTile(
                dense: true,
                contentPadding: const EdgeInsets.symmetric(horizontal: 2),
                leading: const Icon(Icons.smart_toy_outlined),
                title: Text(
                  repository.split('/').last,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  repository.split('/').first,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: searching || _locked ? null : () => _search(repository),
              ),
            if (nextPage != null)
              TextButton(
                onPressed: searching || _locked ? null : _more,
                child: const Text('Show more'),
              ),
          ],
          if (files.isNotEmpty) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                const Expanded(
                  child: Text(
                    'Choose a size',
                    style: TextStyle(fontWeight: FontWeight.w800),
                  ),
                ),
                TextButton(
                  onPressed: () => setState(() {
                    repositories = [];
                    files = [];
                    catalogueNote = '';
                  }),
                  child: const Text('Back'),
                ),
              ],
            ),
            for (final file in visibleFiles.take(8))
              ListTile(
                dense: true,
                contentPadding: const EdgeInsets.symmetric(horizontal: 2),
                title: Text(
                  _shortLabel(file.filename),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(modelSize(file.bytes)),
                trailing: TextButton.icon(
                  onPressed: _locked
                      ? null
                      : () => _run(() async {
                          final check = await local.preflight(file);
                          final message =
                              check.warning ??
                              '${modelSize(file.bytes)} download. Aaris will verify, load and ping it before showing Ready.';
                          if (await _confirm(
                            check.warning == null
                                ? 'Download and use this model?'
                                : 'Large model · continue?',
                            message,
                          )) {
                            await local.download(file);
                          }
                        }),
                  icon: const Icon(Icons.download_rounded, size: 18),
                  label: const Text('Use'),
                ),
              ),
          ],
          if (local.pendingDownloads.isNotEmpty) ...[
            const Divider(height: 22),
            const Text(
              'Paused downloads',
              style: TextStyle(fontWeight: FontWeight.w800),
            ),
            for (final pending in local.pendingDownloads.take(3))
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text(
                  _shortLabel(pending.label),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(modelSize(pending.bytes)),
                trailing: Wrap(
                  children: [
                    TextButton(
                      onPressed: _locked
                          ? null
                          : () => _run(() => local.download(pending)),
                      child: const Text('Resume'),
                    ),
                    IconButton(
                      tooltip: 'Remove paused download',
                      onPressed: _locked
                          ? null
                          : () => _run(
                              () => local.discardDownload(pending.sha256),
                            ),
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ],
                ),
              ),
          ],
          const SizedBox(height: 4),
          InkWell(
            onTap: () => setState(() => advancedOpen = !advancedOpen),
            borderRadius: BorderRadius.circular(14),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 9),
              child: Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Advanced model options',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                  Icon(
                    advancedOpen
                        ? Icons.expand_less_rounded
                        : Icons.expand_more_rounded,
                  ),
                ],
              ),
            ),
          ),
          if (advancedOpen) ...[
            if (files.isNotEmpty)
              Wrap(
                spacing: 7,
                children: [
                  for (final limit in <int?>[
                    null,
                    1024 * 1024 * 1024,
                    2 * 1024 * 1024 * 1024,
                    4 * 1024 * 1024 * 1024,
                  ])
                    ChoiceChip(
                      label: Text(
                        limit == null ? 'All sizes' : '≤ ${modelSize(limit)}',
                      ),
                      selected: maxFileBytes == limit,
                      onSelected: (_) => setState(() => maxFileBytes = limit),
                    ),
                ],
              ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: _locked ? null : () => _run(local.importModel),
                icon: const Icon(Icons.file_open_outlined),
                label: const Text('Import GGUF from device'),
              ),
            ),
            if (local.hasSelection)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: _locked ? null : () => _run(local.deactivate),
                  child: const Text('Turn off Local AI'),
                ),
              ),
          ],
        ],
      ),
    );
  }

  Widget _installedModels(BuildContext context) {
    if (local.installed.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 16),
        Row(
          children: [
            const Expanded(
              child: Text(
                'Installed models',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w900),
              ),
            ),
            Text(
              '${local.installed.length}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
        const SizedBox(height: 5),
        for (final model in local.installed)
          Container(
            margin: const EdgeInsets.only(bottom: 6),
            decoration: BoxDecoration(
              color: local.isModelReady(model.id)
                  ? Colors.green.withAlpha(14)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(16),
            ),
            child: ListTile(
              dense: true,
              leading: Icon(
                local.isModelReady(model.id)
                    ? Icons.check_circle
                    : Icons.circle_outlined,
                color: local.isModelReady(model.id) ? Colors.green : null,
              ),
              title: Text(
                defaults.defaultId == model.id
                    ? 'Aaris Default · ${_shortLabel(model.label)}'
                    : _shortLabel(model.label),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              subtitle: Text(
                local.isModelReady(model.id)
                    ? '${modelSize(model.bytes)} · Ready'
                    : '${modelSize(model.bytes)} · Installed',
              ),
              trailing: local.isModelReady(model.id)
                  ? const Icon(Icons.check_rounded, color: Colors.green)
                  : Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        TextButton(
                          onPressed: _locked
                              ? null
                              : () => _run(() => local.activate(model.id)),
                          child: const Text('Use'),
                        ),
                        PopupMenuButton<String>(
                          tooltip: 'Model options',
                          onSelected: (value) async {
                            if (value != 'remove') return;
                            if (await _confirm(
                              'Remove this model?',
                              'Only the downloaded model is removed. Pharmacy data stays unchanged.',
                            )) {
                              await _run(() => local.remove(model.id));
                            }
                          },
                          itemBuilder: (_) => const [
                            PopupMenuItem(
                              value: 'remove',
                              child: Text('Remove'),
                            ),
                          ],
                        ),
                      ],
                    ),
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([local, defaults]),
    builder: (context, _) => Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
          color: Theme.of(context).colorScheme.outlineVariant.withAlpha(80),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Local AI',
            style: TextStyle(fontSize: 19, fontWeight: FontWeight.w900),
          ),
          const SizedBox(height: 10),
          _statusCard(context),
          if (local.transferring) ...[
            const SizedBox(height: 8),
            LinearProgressIndicator(value: local.progress),
          ],
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: FilledButton.tonalIcon(
              onPressed: local.supported && !_locked
                  ? () => setState(() => finderOpen = !finderOpen)
                  : null,
              icon: Icon(
                finderOpen ? Icons.expand_less_rounded : Icons.download_rounded,
              ),
              label: Text(
                finderOpen ? 'Hide models' : 'Download / Change model',
              ),
            ),
          ),
          if (finderOpen) _finder(context),
          _installedModels(context),
          const SizedBox(height: 8),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text(
              'Use Local AI for scan review',
              style: TextStyle(fontWeight: FontWeight.w800),
            ),
            subtitle: Text(
              local.ready
                  ? 'Use the Ready model after OCR.'
                  : 'Choose a model and wait for Ready first.',
            ),
            value: local.ready && local.scannerEnabled,
            onChanged: local.ready && !_locked
                ? (value) => _run(() => local.setScannerEnabled(value))
                : null,
          ),
          if (error.isNotEmpty)
            Container(
              width: double.infinity,
              margin: const EdgeInsets.only(top: 6),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.errorContainer,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Text(
                error,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onErrorContainer,
                  fontSize: 12,
                ),
              ),
            ),
        ],
      ),
    ),
  );
}

String _sortLabel(ModelSort sort) => switch (sort) {
  ModelSort.popular => 'Popular',
  ModelSort.updated => 'Updated',
  ModelSort.newest => 'New',
  ModelSort.trending => 'Trending',
};

String _shortLabel(String raw) {
  var value = raw.split('·').last.trim().split('/').last;
  if (value.toLowerCase().endsWith('.gguf')) {
    value = value.substring(0, value.length - 5);
  }
  return value.replaceAll('_', ' ');
}

String _friendlyError(Object error) {
  final text = error
      .toString()
      .replaceFirst('StateError: ', '')
      .replaceFirst('FormatException: ', '');
  final lower = text.toLowerCase();
  if (lower.contains('storage'))
    return 'Not enough phone storage for this model. Choose a smaller one.';
  if (lower.contains('memory') || lower.contains('ram'))
    return 'This model is too large for the phone right now. Close other apps or choose a smaller model.';
  if (lower.contains('architecture metadata') ||
      lower.contains('companion') ||
      lower.contains('calibration') ||
      lower.contains('split weights')) {
    return 'This GGUF is not a complete standalone chat model. Choose another model file.';
  }
  if (lower.contains('native model') || lower.contains('unsupported gguf')) {
    return 'This model format is not supported by the current Local AI runtime. Choose another GGUF.';
  }
  if (lower.contains('setup check') || lower.contains('activation'))
    return 'This model could not pass the on-device test. Try another model.';
  if (lower.contains('paused'))
    return 'Download paused. You can resume it below.';
  if (lower.contains('publisher access') || lower.contains('gated'))
    return 'This model needs publisher access. Choose another public model.';
  if (text.length <= 120) return text;
  return 'Could not complete Local AI setup. Try again or choose another model.';
}
