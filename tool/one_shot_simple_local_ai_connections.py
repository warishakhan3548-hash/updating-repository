from pathlib import Path


def replace_once(path, old, new):
    p = Path(path)
    s = p.read_text()
    count = s.count(old)
    if count != 1:
        raise SystemExit(f'{path}: expected one match, found {count}')
    p.write_text(s.replace(old, new, 1))


# 1) Pure readiness contract: a green Ready mark requires BOTH active selection
# and a successful on-device setup test. Download alone never means Ready.
replace_once(
    'lib/domain/local_model.dart',
    "String modelSize(int bytes) => bytes >= 1024 * 1024 * 1024\n",
    """enum LocalModelSetupStage {
  unavailable,
  chooseModel,
  downloading,
  verifying,
  connecting,
  testing,
  ready,
  attention,
}

bool isLocalModelReady({
  required InstalledLocalModel? model,
  required String? activeId,
}) =>
    model != null && model.id == activeId && model.smokeTestPassed;

String modelSize(int bytes) => bytes >= 1024 * 1024 * 1024
""",
)

# 2) LocalAiService owns the real setup state. UI observes it; it does not
# duplicate/infer a second state machine.
replace_once(
    'lib/services/local_ai_service_io.dart',
    "  bool _working = false, _transferring = false, _scannerEnabled = true;\n",
    """  bool _working = false, _transferring = false, _scannerEnabled = true;
  LocalModelSetupStage _setupStage = LocalModelSetupStage.chooseModel;
""",
)
replace_once(
    'lib/services/local_ai_service_io.dart',
    "  String? get activeId => _activeId;\n  List<InstalledLocalModel> get installed => List.unmodifiable(_models);\n",
    """  String? get activeId => _activeId;
  LocalModelSetupStage get setupStage => _setupStage;
  InstalledLocalModel? get activeModel =>
      _models.where((model) => model.id == _activeId).firstOrNull;
  bool get ready => isLocalModelReady(model: activeModel, activeId: _activeId);
  bool isModelReady(String id) =>
      _activeId == id &&
      isLocalModelReady(
        model: _models.where((model) => model.id == id).firstOrNull,
        activeId: _activeId,
      );
  List<InstalledLocalModel> get installed => List.unmodifiable(_models);
""",
)
replace_once(
    'lib/services/local_ai_service_io.dart',
    """      _status = hasSelection
          ? 'Local selected · loads on demand'
          : 'No local model selected';
    }
    if (!_observingMemory) {
""",
    """      _status = hasSelection
          ? 'Local model selected'
          : 'No local model selected';
    }
    _setupStage = ready
        ? LocalModelSetupStage.ready
        : LocalModelSetupStage.chooseModel;
    if (!_observingMemory) {
""",
)
replace_once(
    'lib/services/local_ai_service_io.dart',
    """  Future<void> download(LocalModelFile model) async {
    model.validate();
    await initialize();
    if (_transferring || busy)
      throw StateError('Finish the current local AI operation first.');
    if (_models.any((m) => m.id == model.sha256)) {
      await _save();
      return;
    }
    final generation = ++_transferGeneration;
    _transferring = true;
    _progress = null;
    _status = 'Downloading model · inventory stays on device';
""",
    """  Future<void> download(LocalModelFile model) async {
    model.validate();
    await initialize();
    if (_transferring || busy)
      throw StateError('Finish the current local AI operation first.');
    final existing = _models
        .where((installed) => installed.id == model.sha256)
        .firstOrNull;
    if (existing != null) {
      if (!isModelReady(existing.id)) await activate(existing.id);
      return;
    }
    final generation = ++_transferGeneration;
    _transferring = true;
    _progress = null;
    _setupStage = LocalModelSetupStage.downloading;
    _status = 'Downloading local AI…';
""",
)
replace_once(
    'lib/services/local_ai_service_io.dart',
    """    _transfer = client;
    final part = File('${_directory!.path}/${model.sha256}.part');
    RandomAccessFile? writer;
    try {
""",
    """    _transfer = client;
    final part = File('${_directory!.path}/${model.sha256}.part');
    RandomAccessFile? writer;
    String? activateAfterDownload;
    try {
""",
)
replace_once(
    'lib/services/local_ai_service_io.dart',
    """      _status = 'Verifying SHA-256 on device…';
      _progress = null;
""",
    """      _setupStage = LocalModelSetupStage.verifying;
      _status = 'Checking downloaded model…';
      _progress = null;
""",
)
replace_once(
    'lib/services/local_ai_service_io.dart',
    """      _downloads.removeWhere((m) => m.sha256 == model.sha256);
      await _save();
      _status = 'Download verified. Activate to test this model.';
    } catch (error) {
      _status = generation != _transferGeneration
          ? 'Download paused; partial file retained'
          : error.toString();
      rethrow;
""",
    """      _downloads.removeWhere((m) => m.sha256 == model.sha256);
      await _save();
      activateAfterDownload = hash;
      _setupStage = LocalModelSetupStage.connecting;
      _status = 'Download complete · connecting…';
    } catch (error) {
      _setupStage = ready
          ? LocalModelSetupStage.ready
          : LocalModelSetupStage.attention;
      _status = generation != _transferGeneration
          ? 'Download paused'
          : 'Could not finish this model setup';
      rethrow;
""",
)
replace_once(
    'lib/services/local_ai_service_io.dart',
    """        notifyListeners();
      }
    }
  }

  void cancelTransfer() {
""",
    """        notifyListeners();
      }
    }
    // One tap means one understandable outcome: downloaded weights are
    // immediately load-tested and activated. A model is never labelled Ready
    // until activate() completes all setup probes successfully.
    if (activateAfterDownload != null) {
      await activate(activateAfterDownload);
    }
  }

  void cancelTransfer() {
""",
)
replace_once(
    'lib/services/local_ai_service_io.dart',
    """      await _save();
      _status =
          'Import ready. Publisher authenticity is not verified; activate to test compatibility.';
    } catch (error) {
      _status = error.toString();
      rethrow;
""",
    """      await _save();
      _setupStage = LocalModelSetupStage.chooseModel;
      _status = 'Model imported · choose Use to test it';
    } catch (error) {
      _setupStage = ready
          ? LocalModelSetupStage.ready
          : LocalModelSetupStage.attention;
      _status = 'Could not import this model';
      rethrow;
""",
)
replace_once(
    'lib/services/local_ai_service_io.dart',
    """  Future<void> activate(String id) => _exclusive((generation) async {
    final model = _models.where((m) => m.id == id).firstOrNull;
    if (model == null) throw StateError('Download or import this model first.');
    final previous = _activeId;
    await _release();
    _activeId = id;
    try {
      final file = _weights(id);
      final metadata = await _checkGguf(file);
      _status = 'Verifying model before activation…';
      notifyListeners();
""",
    """  Future<void> activate(String id) => _exclusive((generation) async {
    final model = _models.where((m) => m.id == id).firstOrNull;
    if (model == null) throw StateError('Download or import this model first.');
    if (isModelReady(id)) {
      _setupStage = LocalModelSetupStage.ready;
      _status = 'Local AI Ready';
      return;
    }
    final previous = _activeId;
    await _release();
    _activeId = id;
    try {
      final file = _weights(id);
      _setupStage = LocalModelSetupStage.verifying;
      _status = 'Checking model…';
      notifyListeners();
      final metadata = await _checkGguf(file);
""",
)
replace_once(
    'lib/services/local_ai_service_io.dart',
    """      _checkRequest(generation);
      await _loadSelected();
      for (var i = 0; i < localSetupChecks.length; i++) {
        final probe = localSetupChecks[i];
        _status =
            'Setup check ${i + 1}/${localSetupChecks.length} · structured extraction';
""",
    """      _checkRequest(generation);
      _setupStage = LocalModelSetupStage.connecting;
      _status = 'Connecting on this device…';
      notifyListeners();
      await _loadSelected();
      _setupStage = LocalModelSetupStage.testing;
      for (var i = 0; i < localSetupChecks.length; i++) {
        final probe = localSetupChecks[i];
        _status = 'Testing on this phone…';
""",
)
replace_once(
    'lib/services/local_ai_service_io.dart',
    """      await _save();
      _status =
          'Local active · ${localSetupChecks.length} setup checks passed · review required';
    } catch (_) {
      _activeId = previous;
      final index = _models.indexWhere((m) => m.id == model.id);
      if (index >= 0) _models[index] = model;
      await _release();
      _status = 'Activation failed; previous selection preserved';
      rethrow;
""",
    """      await _save();
      _setupStage = LocalModelSetupStage.ready;
      _status = 'Local AI Ready';
    } catch (_) {
      _activeId = previous;
      final index = _models.indexWhere((m) => m.id == model.id);
      if (index >= 0) _models[index] = model;
      await _release();
      _setupStage = ready
          ? LocalModelSetupStage.ready
          : LocalModelSetupStage.attention;
      _status = ready
          ? 'That model could not start · previous Local AI is still Ready'
          : 'This model could not become Ready';
      rethrow;
""",
)
replace_once(
    'lib/services/local_ai_service_io.dart',
    """    _status = 'Local disabled · existing provider settings apply';
  });

  Future<void> setScannerEnabled(bool value) => _exclusive((_) async {
    final previous = _scannerEnabled;
""",
    """    _setupStage = LocalModelSetupStage.chooseModel;
    _status = 'Local AI turned off';
  });

  Future<void> setScannerEnabled(bool value) => _exclusive((_) async {
    if (value && !ready) {
      throw StateError('Choose a local model and wait for Ready first.');
    }
    final previous = _scannerEnabled;
""",
)

# Stub exposes the same authoritative contract.
replace_once(
    'lib/services/local_ai_service_stub.dart',
    """  String? get activeId => null;
  List<InstalledLocalModel> get installed => const [];
""",
    """  String? get activeId => null;
  LocalModelSetupStage get setupStage => LocalModelSetupStage.unavailable;
  InstalledLocalModel? get activeModel => null;
  bool get ready => false;
  bool isModelReady(String id) => false;
  List<InstalledLocalModel> get installed => const [];
""",
)

# Default AI reuses LocalAiService's readiness instead of maintaining a second
# interpretation of "active".
replace_once(
    'lib/services/aaris_default_ai_service_io.dart',
    "  bool get active => hasDefault && _local.activeId == _defaultId;\n",
    "  bool get active => hasDefault && _local.isModelReady(_defaultId!);\n",
)
replace_once(
    'lib/services/aaris_default_ai_service_io.dart',
    """    _status = 'Restoring Aaris Default AI…';
    notifyListeners();
    await _local.activate(_defaultId!);
    _status = 'Aaris Default AI active';
""",
    """    _status = 'Making Aaris Default AI ready…';
    notifyListeners();
    if (!_local.isModelReady(_defaultId!)) {
      await _local.activate(_defaultId!);
    }
    _status = 'Aaris Default AI Ready';
""",
)
replace_once(
    'lib/services/aaris_default_ai_service_io.dart',
    """      _status = 'Verifying and activating Aaris Default AI…';
      notifyListeners();
      await _local.activate(model.sha256);
      await _persistDefault(model.sha256);
      _status = 'Aaris Default AI active · permanent fallback ready';
""",
    """      _status = 'Making Aaris Default AI ready…';
      notifyListeners();
      if (!_local.isModelReady(model.sha256)) {
        await _local.activate(model.sha256);
      }
      await _persistDefault(model.sha256);
      _status = 'Aaris Default AI Ready';
""",
)

# 3) Replace the original LocalModelsPanel directly. No overlay, wrapper or
# duplicate controller is introduced.
Path('lib/ui/local_models_panel.dart').write_text(r'''import 'dart:async';

import 'package:flutter/material.dart';

import '../domain/default_local_model.dart';
import '../domain/local_model.dart';
import '../domain/model_catalogue.dart';
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
    LocalModelSetupStage.chooseModel => local.installed.isEmpty
        ? 'Local AI not set up'
        : 'Choose a Local AI',
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
      LocalModelSetupStage.unavailable => 'Use the installed Android or desktop app.',
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
            child: local.setupStage == LocalModelSetupStage.downloading ||
                    local.setupStage == LocalModelSetupStage.verifying ||
                    local.setupStage == LocalModelSetupStage.connecting ||
                    local.setupStage == LocalModelSetupStage.testing
                ? Padding(
                    padding: const EdgeInsets.all(14),
                    child: CircularProgressIndicator(
                      strokeWidth: 3,
                      value: local.setupStage == LocalModelSetupStage.downloading
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
              Text(
                '~400 MB · easiest setup',
                style: TextStyle(fontSize: 11.5),
              ),
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
                      : () async {
                          if (await _confirm(
                            'Download and use this model?',
                            '${modelSize(file.bytes)} download. Aaris will verify and test it before showing Ready.',
                          )) {
                            await _run(() => local.download(file));
                          }
                        },
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
            Text('${local.installed.length}', style: Theme.of(context).textTheme.bodySmall),
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
                            PopupMenuItem(value: 'remove', child: Text('Remove')),
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
  final text = error.toString().replaceFirst('StateError: ', '').replaceFirst('FormatException: ', '');
  final lower = text.toLowerCase();
  if (lower.contains('storage')) return 'Not enough phone storage for this model. Choose a smaller one.';
  if (lower.contains('memory') || lower.contains('ram')) return 'This model is too large for the phone right now. Close other apps or choose a smaller model.';
  if (lower.contains('setup check') || lower.contains('activation')) return 'This model could not pass the on-device test. Try another model.';
  if (lower.contains('paused')) return 'Download paused. You can resume it below.';
  if (lower.contains('publisher access') || lower.contains('gated')) return 'This model needs publisher access. Choose another public model.';
  if (text.length <= 120) return text;
  return 'Could not complete Local AI setup. Try again or choose another model.';
}
''')

# 4) Simplify the existing AI connections sheet in place. Local models,
# external-AI sharing, and API setup remain on one scrollable page; API details
# expand only when the user asks for them.
p = Path('lib/ui/ai_screen.dart')
s = p.read_text()
state_start = s.index('class _AiConnectionsSheetState extends State<_AiConnectionsSheet> {')
external_start = s.index('class _ExternalAiIcon extends StatelessWidget {', state_start)
state = s[state_start:external_start]
state = state.replace(
    "  bool obscure = true;\n  bool busy = false;\n",
    "  bool obscure = true;\n  bool busy = false;\n  bool apiExpanded = false;\n",
    1,
)
build_start = state.index('  @override\n  Widget build(BuildContext context) {')
new_build = r'''  String get _providerLabel =>
      provider == 'Gemini' ? 'Google Gemini' : 'OpenAI-compatible';

  Widget _apiFields(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(14, 4, 14, 14),
    child: Column(
      children: [
        DropdownButtonFormField<String>(
          initialValue: provider,
          decoration: const InputDecoration(labelText: 'Provider'),
          items: const [
            DropdownMenuItem(value: 'Gemini', child: Text('Google Gemini')),
            DropdownMenuItem(
              value: 'Compatible',
              child: Text('OpenAI-compatible'),
            ),
          ],
          onChanged: busy
              ? null
              : (value) => setState(() => provider = value ?? 'Gemini'),
        ),
        const SizedBox(height: 10),
        TextField(
          controller: model,
          enabled: !busy,
          decoration: const InputDecoration(labelText: 'Model name'),
        ),
        if (provider == 'Compatible') ...[
          const SizedBox(height: 10),
          TextField(
            controller: endpoint,
            enabled: !busy,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(labelText: 'HTTPS endpoint'),
          ),
        ],
        const SizedBox(height: 10),
        TextField(
          controller: key,
          enabled: !busy,
          obscureText: obscure,
          enableSuggestions: false,
          autocorrect: false,
          decoration: InputDecoration(
            labelText: 'API key',
            helperText: 'Saved securely on this device.',
            suffixIcon: IconButton(
              tooltip: obscure ? 'Show API key' : 'Hide API key',
              onPressed: busy
                  ? null
                  : () => setState(() => obscure = !obscure),
              icon: Icon(
                obscure
                    ? Icons.visibility_rounded
                    : Icons.visibility_off_rounded,
              ),
            ),
          ),
        ),
        if (error.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Text(error, style: const TextStyle(color: red, fontSize: 12)),
          ),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: busy ? null : _save,
            icon: const Icon(Icons.lock_rounded),
            label: Text(busy ? 'Saving…' : 'Save connection'),
          ),
        ),
        if (widget.initial.key.isNotEmpty)
          TextButton(
            onPressed: busy ? null : _remove,
            child: const Text('Remove saved key'),
          ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.viewInsetsOf(context).bottom;
    final scheme = Theme.of(context).colorScheme;
    final configured = widget.initial.key.isNotEmpty;
    return Padding(
      padding: EdgeInsets.only(bottom: bottom),
      child: Container(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * .92,
        ),
        decoration: BoxDecoration(
          color: scheme.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(30)),
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(18, 10, 18, 28),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 42,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 16),
                  decoration: BoxDecoration(
                    color: muted.withAlpha(70),
                    borderRadius: BorderRadius.circular(99),
                  ),
                ),
              ),
              const Text(
                'AI connections',
                style: TextStyle(
                  color: ink,
                  fontSize: 23,
                  fontWeight: FontWeight.w900,
                  letterSpacing: -.4,
                ),
              ),
              const SizedBox(height: 4),
              const Text(
                'Choose how Aaris uses AI.',
                style: TextStyle(color: muted, fontSize: 12.5),
              ),
              const SizedBox(height: 16),
              const LocalModelsPanel(),
              const SizedBox(height: 14),
              Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: busy
                      ? null
                      : () => Navigator.pop(
                          context,
                          _AiConnectionsSheet.externalAction,
                        ),
                  borderRadius: BorderRadius.circular(20),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 15,
                      vertical: 14,
                    ),
                    decoration: BoxDecoration(
                      color: _aiPurple.withAlpha(14),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: _aiPurple.withAlpha(60)),
                    ),
                    child: const Row(
                      children: [
                        _ExternalAiIcon(),
                        SizedBox(width: 13),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Connect with Other AI',
                                style: TextStyle(
                                  color: _aiPurple,
                                  fontSize: 16,
                                  fontWeight: FontWeight.w900,
                                ),
                              ),
                              SizedBox(height: 2),
                              Text(
                                'Share TXT · bring JSON back for review',
                                style: TextStyle(color: muted, fontSize: 11.5),
                              ),
                            ],
                          ),
                        ),
                        Icon(
                          Icons.chevron_right_rounded,
                          color: _aiPurple,
                          size: 26,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Container(
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerLowest,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: scheme.outlineVariant.withAlpha(90)),
                ),
                child: Column(
                  children: [
                    InkWell(
                      onTap: busy
                          ? null
                          : () => setState(() => apiExpanded = !apiExpanded),
                      borderRadius: BorderRadius.circular(20),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 15,
                          vertical: 14,
                        ),
                        child: Row(
                          children: [
                            Container(
                              width: 48,
                              height: 48,
                              decoration: BoxDecoration(
                                color: primary.withAlpha(16),
                                shape: BoxShape.circle,
                              ),
                              child: const Icon(Icons.key_rounded, color: primary),
                            ),
                            const SizedBox(width: 13),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Text(
                                    'Use AI inside the app',
                                    style: TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w900,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    configured
                                        ? '$_providerLabel · Connected'
                                        : 'API key · Not configured',
                                    style: const TextStyle(
                                      color: muted,
                                      fontSize: 11.5,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            if (configured)
                              const Icon(
                                Icons.check_circle,
                                color: Colors.green,
                                size: 22,
                              ),
                            const SizedBox(width: 6),
                            Icon(
                              apiExpanded
                                  ? Icons.expand_less_rounded
                                  : Icons.chevron_right_rounded,
                            ),
                          ],
                        ),
                      ),
                    ),
                    if (apiExpanded) _apiFields(context),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

'''
state = state[:build_start] + new_build
s = s[:state_start] + state + s[external_start:]
p.write_text(s)

# 5) Tests: readiness rule + source/UI regression against accidental re-bloat.
Path('test/local_model_readiness_test.dart').write_text(r'''import 'package:aaris_pharmacy/domain/local_model.dart';
import 'package:flutter_test/flutter_test.dart';

InstalledLocalModel model({required bool tested}) => InstalledLocalModel(
  id: 'a' * 64,
  label: 'Qwen2.5-0.5B.gguf',
  bytes: 339 * 1024 * 1024,
  smokeTestPassed: tested,
);

void main() {
  test('Ready requires both active selection and passed on-device setup test', () {
    final downloadedOnly = model(tested: false);
    expect(
      isLocalModelReady(model: downloadedOnly, activeId: downloadedOnly.id),
      isFalse,
    );

    final tested = model(tested: true);
    expect(isLocalModelReady(model: tested, activeId: null), isFalse);
    expect(
      isLocalModelReady(model: tested, activeId: 'b' * 64),
      isFalse,
    );
    expect(isLocalModelReady(model: tested, activeId: tested.id), isTrue);
  });
});
''')

Path('test/simple_ai_connections_source_test.dart').write_text(r'''import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('AI connections stays simple and uses one authoritative local setup flow', () {
    final panel = File('lib/ui/local_models_panel.dart').readAsStringSync();
    final service = File('lib/services/local_ai_service_io.dart').readAsStringSync();
    final ai = File('lib/ui/ai_screen.dart').readAsStringSync();

    expect(panel, contains('Download / Change model'));
    expect(panel, contains('Local AI · Ready'));
    expect(panel, contains('Search Qwen, Gemma, Llama or paste model link'));
    expect(panel, contains('Installed models'));
    expect(panel, contains('Use Local AI for scan review'));
    expect(panel, isNot(contains('Weight-file size filter only')));
    expect(panel, isNot(contains('Browse current public GGUF models or paste an exact')));

    expect(service, contains('LocalModelSetupStage.testing'));
    expect(service, contains('await activate(activateAfterDownload);'));
    expect(service, contains('Choose a local model and wait for Ready first.'));

    expect(ai, contains('Choose how Aaris uses AI.'));
    expect(ai, contains('Connect with Other AI'));
    expect(ai, contains('Use AI inside the app'));
    expect(ai, contains('if (apiExpanded) _apiFields(context)'));
    expect(ai, isNot(contains('Models, external AI, or your own API.')));
    expect(ai, isNot(contains('Key stays in secure device storage.')));
  });
}
''')

Path('docs/SIMPLE_LOCAL_AI_CONNECTIONS_2026_09_10.md').write_text('''# Simple Local AI connections\n\nThe AI connections page now uses `LocalAiService` as the single setup-state authority. A downloaded model is automatically verified, loaded, tested, and only then becomes **Ready**. The green Ready mark requires an active model whose on-device setup checks passed; merely having a GGUF file on disk is insufficient.\n\nThe page keeps model search, public catalogue sorting, verified/resumable downloads, device import, activation, removal, Aaris Default AI, scan-review routing, external-AI TXT/JSON flow, and API-provider setup. Advanced model controls stay collapsed until requested. API fields also stay collapsed until requested. No duplicate model controller or overlay state machine was added.\n''')
