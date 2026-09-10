from pathlib import Path


def rep(path, old, new, expected=1):
    p = Path(path)
    text = p.read_text()
    found = text.count(old)
    if found != expected:
        raise SystemExit(f'{path}: expected {expected} anchor(s), found {found}')
    p.write_text(text.replace(old, new, expected))


# 1) Separate chat/runtime readiness from the stricter scan-review check.
rep('lib/domain/local_model.dart', """    this.source = 'Local import',
    this.smokeTestPassed = false,
    this.metadata,
    this.testedRuntime,
  });
  final String id, label, source;
  final int bytes;
  final bool smokeTestPassed;
""", """    this.source = 'Local import',
    this.loadTestPassed = false,
    this.smokeTestPassed = false,
    this.metadata,
    this.testedRuntime,
  });
  final String id, label, source;
  final int bytes;
  final bool loadTestPassed, smokeTestPassed;
""")
rep('lib/domain/local_model.dart', """    'source': source,
    'smokeTestPassed': smokeTestPassed,
""", """    'source': source,
    'loadTestPassed': loadTestPassed,
    'smokeTestPassed': smokeTestPassed,
""")
rep('lib/domain/local_model.dart', """      source: json['source'] is String
          ? json['source'] as String
          : 'Local import',
      smokeTestPassed: json['smokeTestPassed'] == true,
""", """      source: json['source'] is String
          ? json['source'] as String
          : 'Local import',
      // Backward compatibility: every old model that passed the stricter scan
      // smoke test necessarily also passed native load/generation.
      loadTestPassed:
          json['loadTestPassed'] == true || json['smokeTestPassed'] == true,
      smokeTestPassed: json['smokeTestPassed'] == true,
""")
rep('lib/domain/local_model.dart', """bool isLocalModelReady({
  required InstalledLocalModel? model,
  required String? activeId,
}) => model != null && model.id == activeId && model.smokeTestPassed;
""", """bool isLocalModelReady({
  required InstalledLocalModel? model,
  required String? activeId,
}) => model != null && model.id == activeId && model.loadTestPassed;

bool isLocalModelScanReady({
  required InstalledLocalModel? model,
  required String? activeId,
}) =>
    isLocalModelReady(model: model, activeId: activeId) &&
    model!.smokeTestPassed;
""")

# 2) RAM estimates choose a conservative context and warn; native load remains
# the final authority instead of pre-blocking large phone models.
rep('lib/domain/gguf_metadata.dart', """    required this.estimatedKvBytes,
    required this.geometryKnown,
  });
  final int contextTokens, estimatedBytes, estimatedKvBytes;
  final bool geometryKnown;
""", """    required this.estimatedKvBytes,
    required this.geometryKnown,
    required this.memoryWarning,
  });
  final int contextTokens, estimatedBytes, estimatedKvBytes;
  final bool geometryKnown, memoryWarning;
""")
start = Path('lib/domain/gguf_metadata.dart').read_text()
marker = 'LocalExecutionPlan planLocalExecution({' 
prefix, sep, _ = start.partition(marker)
if not sep:
    raise SystemExit('gguf planner marker missing')
new_planner = r'''LocalExecutionPlan planLocalExecution({
  required int weightBytes,
  required GgufMetadata metadata,
  int? totalMemory,
  int? availableMemory,
  bool lowMemory = false,
  bool phone = false,
}) {
  if (weightBytes < 1024) {
    throw StateError('Invalid local model weight size.');
  }

  final constrainedPhone =
      phone &&
      (lowMemory ||
          (totalMemory != null &&
              weightBytes >= (totalMemory * .40).floor()) ||
          (availableMemory != null && availableMemory < 1024 * _mib));

  final totalBudget = totalMemory == null ? null : (totalMemory * .65).floor();
  final availableBudget = availableMemory == null
      ? null
      : (availableMemory * .8).floor();
  int? budget = totalBudget == null
      ? availableBudget
      : availableBudget == null
      ? totalBudget
      : math.min(totalBudget, availableBudget);

  // llama.cpp maps GGUF tensors from storage and Android can reclaim file-backed
  // pages. Memory facts are advisory on phones: they select a smaller context
  // and surface a warning instead of rejecting a model before native load.
  if (phone && totalMemory != null) {
    final reclaimAwareFloor = (totalMemory * .52).floor();
    budget = budget == null
        ? reclaimAwareFloor
        : math.max(budget, reclaimAwareFloor);
  }

  final contexts = phone
      ? constrainedPhone
            ? const [2048]
            : const [4096, 2048]
      : const [8192, 4096, 2048];
  LocalExecutionPlan? phoneFallback;
  for (final context in contexts) {
    if (metadata.contextLength != null && context > metadata.contextLength!) {
      continue;
    }
    final knownKv = metadata.kvBytes(context);
    final kv = knownKv ?? context * 256 * 1024;
    final residentWeights = constrainedPhone
        ? (weightBytes * .48).ceil()
        : weightBytes;
    final reserve = constrainedPhone ? 320 * _mib : 512 * _mib;
    final bytes = (residentWeights * 1.1 + kv * 1.1).ceil() + reserve;
    final warning =
        phone &&
        (lowMemory ||
            weightBytes >= 1536 * _mib ||
            (totalMemory != null &&
                weightBytes >= (totalMemory * .40).floor()) ||
            (budget != null && bytes > budget));
    final plan = LocalExecutionPlan(
      contextTokens: context,
      estimatedBytes: bytes,
      estimatedKvBytes: kv,
      geometryKnown: knownKv != null,
      memoryWarning: warning,
    );
    if (budget == null || bytes <= budget) return plan;
    if (phone) phoneFallback = plan;
  }

  // A phone estimate is not proof that mmap-backed native inference will fail.
  // Try the smallest supported context and let llama.cpp report the real error.
  if (phoneFallback != null) {
    return LocalExecutionPlan(
      contextTokens: phoneFallback.contextTokens,
      estimatedBytes: phoneFallback.estimatedBytes,
      estimatedKvBytes: phoneFallback.estimatedKvBytes,
      geometryKnown: phoneFallback.geometryKnown,
      memoryWarning: true,
    );
  }
  throw StateError(
    'Model weights + context cache do not fit this non-phone memory budget, or its context is below 2048.',
  );
}
'''
Path('lib/domain/gguf_metadata.dart').write_text(prefix + new_planner)

# 3) Plain text from a small model is reply-only; structured failures stay closed.
rep('lib/domain/local_ai_protocol.dart', """  return value;
}

String _bounded(String value, int length) =>
""", """  return value;
}

Map<String, dynamic> localChatObject(String input) {
  try {
    return localJsonObject(input);
  } on FormatException {
    final text = input.trim();
    final lower = text.toLowerCase();
    final looksStructured =
        text.contains('{') ||
        text.contains('}') ||
        lower.contains('\\\"tool\\\"') ||
        lower.contains('\\\"actions\\\"') ||
        lower.contains('\\\"op\\\"');
    if (text.isEmpty || text.length > 4000 || looksStructured) rethrow;
    return {'reply': _bounded(text, 2000), 'actions': <Object?>[]};
  }
}

String _bounded(String value, int length) =>
""")

# 4) Local service: native load/generation = chat Ready; scan probes only gate scan.
rep('lib/services/local_ai_service_io.dart', """  String get executionSummary => _executionPlan == null
      ? ''
      : '${_executionPlan!.contextTokens} token context · estimated ${modelSize(_executionPlan!.estimatedBytes)} working memory';
""", """  String get executionSummary => _executionPlan == null
      ? ''
      : '${_executionPlan!.contextTokens} token context · estimated ${modelSize(_executionPlan!.estimatedBytes)} working memory${_executionPlan!.memoryWarning ? ' · heavy model' : ''}';
  bool get memoryWarning => _executionPlan?.memoryWarning ?? false;
""")
rep('lib/services/local_ai_service_io.dart', """  bool get ready => isLocalModelReady(model: activeModel, activeId: _activeId);
  bool isModelReady(String id) =>
      _activeId == id &&
      isLocalModelReady(
        model: _models.where((model) => model.id == id).firstOrNull,
        activeId: _activeId,
      );
""", """  bool get ready => isLocalModelReady(model: activeModel, activeId: _activeId);
  bool get scanReady =>
      isLocalModelScanReady(model: activeModel, activeId: _activeId);
  bool isModelReady(String id) =>
      _activeId == id &&
      isLocalModelReady(
        model: _models.where((model) => model.id == id).firstOrNull,
        activeId: _activeId,
      );
  bool isModelScanReady(String id) =>
      _activeId == id &&
      isLocalModelScanReady(
        model: _models.where((model) => model.id == id).firstOrNull,
        activeId: _activeId,
      );
""")
old_activate = r'''  Future<void> activate(String id) => _exclusive((generation) async {
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
      if (await _hash(file.path) != id)
        throw StateError(
          'Model changed since installation. Re-import a trusted file.',
        );
      _checkRequest(generation);
      _setupStage = LocalModelSetupStage.connecting;
      _status = 'Connecting on this device…';
      notifyListeners();
      await _loadSelected();
      _setupStage = LocalModelSetupStage.testing;
      for (var i = 0; i < localSetupChecks.length; i++) {
        final probe = localSetupChecks[i];
        _status = 'Testing on this phone…';
        notifyListeners();
        final answer = localJsonObject(
          await _runtime!.generate(
            localSetupPrompt,
            jsonEncode({'SOURCE': probe.source}),
            maxTokens: 180,
          ),
        );
        _checkRequest(generation);
        if (!passesLocalSetup(answer, probe))
          throw StateError(
            'Setup check ${i + 1} failed: printed fields/unknowns/decimal or denominator handling. Try another instruction-tuned model.',
          );
      }
      _models[_models.indexOf(model)] = InstalledLocalModel(
        id: model.id,
        label: model.label,
        bytes: model.bytes,
        source: model.source,
        smokeTestPassed: true,
        metadata: metadata,
        testedRuntime: '$localRuntimeBuild/setup-$localSetupCheckVersion',
      );
      await _save();
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
    }
  });
'''
new_activate = r'''  Future<void> activate(String id) => _exclusive((generation) async {
    final model = _models.where((m) => m.id == id).firstOrNull;
    if (model == null) throw StateError('Download or import this model first.');
    if (isModelReady(id)) {
      _setupStage = LocalModelSetupStage.ready;
      _status = isModelScanReady(id)
          ? 'Local AI Ready'
          : 'Local AI Ready · chat works; scan review not verified';
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
      if (await _hash(file.path) != id) {
        throw StateError(
          'Model changed since installation. Re-import a trusted file.',
        );
      }
      _checkRequest(generation);
      _setupStage = LocalModelSetupStage.connecting;
      _status = 'Connecting on this device…';
      notifyListeners();
      await _loadSelected();

      var scanTestPassed = true;
      _setupStage = LocalModelSetupStage.testing;
      for (var i = 0; i < localSetupChecks.length; i++) {
        final probe = localSetupChecks[i];
        _status = 'Testing optional scan review…';
        notifyListeners();
        final raw = await _runtime!.generate(
          localSetupPrompt,
          jsonEncode({'SOURCE': probe.source}),
          maxTokens: 180,
        );
        _checkRequest(generation);
        Map<String, dynamic> answer;
        try {
          answer = localJsonObject(raw);
        } on FormatException {
          scanTestPassed = false;
          break;
        }
        if (!passesLocalSetup(answer, probe)) {
          scanTestPassed = false;
          break;
        }
      }
      _models[_models.indexOf(model)] = InstalledLocalModel(
        id: model.id,
        label: model.label,
        bytes: model.bytes,
        source: model.source,
        loadTestPassed: true,
        smokeTestPassed: scanTestPassed,
        metadata: metadata,
        testedRuntime: scanTestPassed
            ? '$localRuntimeBuild/setup-$localSetupCheckVersion'
            : '$localRuntimeBuild/chat-load',
      );
      await _save();
      _setupStage = LocalModelSetupStage.ready;
      _status = scanTestPassed
          ? 'Local AI Ready'
          : 'Local AI Ready · chat works; scan review not verified';
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
    }
  });
'''
rep('lib/services/local_ai_service_io.dart', old_activate, new_activate)
rep('lib/services/local_ai_service_io.dart', """  Future<void> deactivate() => _exclusive((_) async {
""", """  Future<void> suspend() => _exclusive((_) async {
    await _release();
    _status = hasSelection
        ? 'Local model selected · Aaris Brain off'
        : 'Local AI stopped';
  });

  Future<void> deactivate() => _exclusive((_) async {
""")
rep('lib/services/local_ai_service_io.dart', """  Future<void> setScannerEnabled(bool value) => _exclusive((_) async {
    if (value && !ready) {
      throw StateError('Choose a local model and wait for Ready first.');
    }
""", """  Future<void> setScannerEnabled(bool value) => _exclusive((_) async {
    if (value && !scanReady) {
      throw StateError(
        'This model is Chat Ready but has not passed the stricter scan-review test.',
      );
    }
""")
rep('lib/services/local_ai_service_io.dart', """      final answer = localJsonObject(raw);
      if (!answer.containsKey('tool')) {
""", """      final answer = localChatObject(raw);
      if (!answer.containsKey('tool')) {
""")
rep('lib/services/local_ai_service_io.dart', """    if (!hasSelection || !scannerEnabled) return draft;
""", """    if (!hasSelection || !scannerEnabled || !scanReady) return draft;
""")
rep('lib/services/local_ai_service_io.dart', """  if (weightBytes > 0 && info?['lowMemory'] == true) {
    throw StateError(
      'Device memory is under pressure. Close other apps or choose smaller weights.',
    );
  }
""", """  // Memory data is advisory. The planner chooses context/warning; native
  // llama.cpp remains the final authority on whether the weights can load.
""")

# 5) Persist one explicit chat route. Saving an API route turns Local Brain off.
rep('lib/services/ai_service.dart', """  const AiConfiguration({
    this.provider = 'Gemini',
    this.model = '',
    this.endpoint = '',
    this.key = '',
  });
  final String provider, model, endpoint, key;
  Map<String, dynamic> toJson() => {
    'provider': provider,
    'model': model,
    'endpoint': endpoint,
    'key': key,
  };
  factory AiConfiguration.fromJson(Map<String, dynamic> data) =>
      AiConfiguration(
        provider: data['provider'] as String? ?? 'Gemini',
        model: data['model'] as String? ?? '',
        endpoint: data['endpoint'] as String? ?? '',
        key: data['key'] as String? ?? '',
      );
""", """  const AiConfiguration({
    this.provider = 'Gemini',
    this.model = '',
    this.endpoint = '',
    this.key = '',
    this.localBrainEnabled = false,
  });
  final String provider, model, endpoint, key;
  final bool localBrainEnabled;

  AiConfiguration copyWith({
    String? provider,
    String? model,
    String? endpoint,
    String? key,
    bool? localBrainEnabled,
  }) => AiConfiguration(
    provider: provider ?? this.provider,
    model: model ?? this.model,
    endpoint: endpoint ?? this.endpoint,
    key: key ?? this.key,
    localBrainEnabled: localBrainEnabled ?? this.localBrainEnabled,
  );

  Map<String, dynamic> toJson() => {
    'provider': provider,
    'model': model,
    'endpoint': endpoint,
    'key': key,
    'localBrainEnabled': localBrainEnabled,
  };
  factory AiConfiguration.fromJson(Map<String, dynamic> data) =>
      AiConfiguration(
        provider: data['provider'] as String? ?? 'Gemini',
        model: data['model'] as String? ?? '',
        endpoint: data['endpoint'] as String? ?? '',
        key: data['key'] as String? ?? '',
        localBrainEnabled: data['localBrainEnabled'] == true,
      );
""")
rep('lib/services/ai_service.dart', """  Future<AiConfiguration> loadConfiguration() async {
    // AI Hub startup is also a route warm-up: restore an already-installed
    // Aaris Default AI before the UI decides that a cloud connection is needed.
    // No inventory is read or exported during this preflight.
    await preparePreferredLocalRoute();
    final raw = await _storage.read(key: 'pharmacy.ai.configuration');
    return raw == null
        ? const AiConfiguration()
        : AiConfiguration.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  }

  Future<void> saveConfiguration(AiConfiguration config) async {
    config.uri;
""", """  Future<AiConfiguration> loadConfiguration() async {
    final local = LocalAiService.instance;
    await local.initialize();
    final raw = await _storage.read(key: 'pharmacy.ai.configuration');
    final config = raw == null
        ? const AiConfiguration()
        : AiConfiguration.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    if (config.localBrainEnabled) await preparePreferredLocalRoute();
    return config;
  }

  Future<void> saveConfiguration(AiConfiguration config) async {
""")
rep('lib/services/ai_service.dart', """    final hasLocalRoute = await preparePreferredLocalRoute();
    final local = LocalAiService.instance;

    // Selection is authoritative even while unloaded/missing/busy. No local
    // failure can fall through to config.uri or the HTTP client below.
    if (hasLocalRoute) {
      _localRequest = true;
      try {
        return await local.ask(
          localContext,
          instruction,
          conversation: conversation,
        );
      } finally {
        _localRequest = false;
      }
    }
""", """    final local = LocalAiService.instance;

    // One explicit route owns typed chat. Local failures never fall through to
    // the API; API mode never wakes or consults the local model.
    if (config.localBrainEnabled) {
      final hasLocalRoute = await preparePreferredLocalRoute();
      if (!hasLocalRoute) {
        throw StateError(
          'Aaris Brain is on, but no local model is selected. Choose a model or turn Aaris Brain off.',
        );
      }
      _localRequest = true;
      try {
        return await local.ask(
          localContext,
          instruction,
          conversation: conversation,
        );
      } finally {
        _localRequest = false;
      }
    }
""")

# 6) Low-confidence direct lookup guesses (for example Hello) do not hijack chat.
rep('lib/ui/brain_screen.dart', """    final preParsed = _pendingChoice == null ? parseAppBrainIntent(text) : null;
    if (preParsed?.action == AppBrainAction.unknown) return null;
""", """    final preParsed = _pendingChoice == null ? parseAppBrainIntent(text) : null;
    if (_pendingChoice == null &&
        (preParsed == null ||
            preParsed.action == AppBrainAction.unknown ||
            preParsed.confidence < .90)) {
      return null;
    }
""")

# 7) Composer directly uses configured Local/API route; deterministic Brain is fallback.
rep('lib/ui/ai_screen.dart', """  int _generation = 0;

  @override
""", """  int _generation = 0;

  bool get _hasAiRoute => _configuration.localBrainEnabled
      ? _local.hasSelection
      : _configuration.key.isNotEmpty;

  @override
""")
rep('lib/ui/ai_screen.dart', """    if (!mounted || result == null) return;
    if (result == _AiConnectionsSheet.externalAction) {
      await _share();
      return;
    }
    if (result is AiConfiguration) {
      setState(() => _configuration = result);
    }
""", """    if (!mounted) return;
    try {
      final latest = await _service.loadConfiguration();
      if (mounted) setState(() => _configuration = latest);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
    if (!mounted || result == null) return;
    if (result == _AiConnectionsSheet.externalAction) {
      await _share();
    }
""")
rep('lib/ui/ai_screen.dart', """      if (!_local.hasSelection && _configuration.key.isEmpty) {
        await _openConnections();
        if (!mounted || (!_local.hasSelection && _configuration.key.isEmpty))
          return;
      }
""", """      if (!_hasAiRoute) {
        await _openConnections();
        if (!mounted || !_hasAiRoute) return;
      }
""")
rep('lib/ui/ai_screen.dart', """    final localHandler = widget.onLocalCommand;
    if (localHandler != null) {
""", """    final localHandler = widget.onLocalCommand;
    if (!_hasAiRoute && localHandler != null) {
""")
rep('lib/ui/ai_screen.dart', """          _AiHubHeader(
            configured: _local.hasSelection || _configuration.key.isNotEmpty,
""", """          _AiHubHeader(
            configured: _hasAiRoute,
""")
rep('lib/ui/ai_screen.dart', """          if (_local.hasSelection)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 6),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'On-device · ${_local.activeLabel}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 10.5, color: muted),
                ),
              ),
            ),
""", """          if (_configuration.localBrainEnabled && _local.hasSelection)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 6),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Aaris Brain · On-device · ${_local.activeLabel}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 10.5, color: muted),
                ),
              ),
            )
          else if (_configuration.key.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 6),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'AI route · ${_configuration.provider} API',
                  style: const TextStyle(fontSize: 10.5, color: muted),
                ),
              ),
            ),
""")
rep('lib/ui/ai_screen.dart', """  late final TextEditingController key;
  bool obscure = true;
""", """  late final TextEditingController key;
  final local = LocalAiService.instance;
  late bool localBrainEnabled;
  bool obscure = true;
""")
rep('lib/ui/ai_screen.dart', """    key = TextEditingController(text: widget.initial.key);
  }
""", """    key = TextEditingController(text: widget.initial.key);
    localBrainEnabled = widget.initial.localBrainEnabled;
  }
""")
rep('lib/ui/ai_screen.dart', """      final config = AiConfiguration(
        provider: provider,
        model: model.text.trim(),
        endpoint: endpoint.text.trim(),
        key: key.text.trim(),
      );
      await widget.service.saveConfiguration(config);
      if (mounted) Navigator.pop(context, config);
""", """      final config = AiConfiguration(
        provider: provider,
        model: model.text.trim(),
        endpoint: endpoint.text.trim(),
        key: key.text.trim(),
        localBrainEnabled: false,
      );
      config.uri;
      await widget.service.saveConfiguration(config);
      await local.suspend();
      if (mounted) Navigator.pop(context, config);
""")
rep('lib/ui/ai_screen.dart', """  Future<void> _remove() async {
""", """  Future<void> _setLocalBrain(bool value) async {
    if (busy) return;
    setState(() {
      busy = true;
      error = '';
    });
    try {
      if (value) {
        await local.initialize();
        final id = local.activeId;
        if (id == null) {
          throw StateError('Download or choose a Local AI model first.');
        }
        if (!local.isModelReady(id)) await local.activate(id);
      } else {
        await local.suspend();
      }
      await widget.service.saveConfiguration(
        widget.initial.copyWith(localBrainEnabled: value),
      );
      if (mounted) setState(() => localBrainEnabled = value);
    } catch (e) {
      if (mounted) {
        setState(() => error = e.toString().replaceFirst('Bad state: ', ''));
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Widget _brainRouteCard(BuildContext context) => AnimatedBuilder(
    animation: local,
    builder: (context, _) => Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
      decoration: BoxDecoration(
        color: _aiPurple.withAlpha(localBrainEnabled ? 20 : 10),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: _aiPurple.withAlpha(55)),
      ),
      child: Row(
        children: [
          const Icon(Icons.psychology_alt_rounded, color: _aiPurple, size: 28),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Activate Aaris Brain',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w900),
                ),
                const SizedBox(height: 2),
                Text(
                  localBrainEnabled
                      ? 'ON · typed messages use ${local.activeLabel.isEmpty ? 'the selected local model' : local.activeLabel}.'
                      : widget.initial.key.isNotEmpty
                      ? 'OFF · typed messages use the saved API.'
                      : local.hasSelection
                      ? 'OFF · turn on to chat with the selected local model.'
                      : 'Download a local model below, or add an API key.',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: muted, fontSize: 11.5),
                ),
              ],
            ),
          ),
          Switch.adaptive(
            value: localBrainEnabled,
            onChanged: busy || (!localBrainEnabled && !local.hasSelection)
                ? null
                : _setLocalBrain,
          ),
        ],
      ),
    ),
  );

  Future<void> _remove() async {
""")
rep('lib/ui/ai_screen.dart', """              const LocalModelsPanel(),
              const SizedBox(height: 14),
              Material(
""", """              const LocalModelsPanel(),
              const SizedBox(height: 10),
              _brainRouteCard(context),
              const SizedBox(height: 14),
              Material(
""")

# 8) Local model UI distinguishes Chat Ready from scan verification and warns.
rep('lib/ui/local_models_panel.dart', """    LocalModelSetupStage.ready => 'Local AI · Ready',
""", """    LocalModelSetupStage.ready =>
      local.scanReady ? 'Local AI · Ready' : 'Local AI · Chat Ready',
""")
rep('lib/ui/local_models_panel.dart', """      return '${_shortLabel(active.label)} · ${modelSize(active.bytes)} · Active';
""", """      return local.scanReady
          ? '${_shortLabel(active.label)} · ${modelSize(active.bytes)} · Active'
          : '${_shortLabel(active.label)} · ${modelSize(active.bytes)} · Active · scan review not verified';
""")
rep('lib/ui/local_models_panel.dart', """                      'Aaris will download it, check it, test it on this phone, and show Ready only if it works.',
""", """                      'Aaris will download, verify and load it. Chat can work even if this model does not pass the optional stricter scan-review check.',
""")
rep('lib/ui/local_models_panel.dart', """                            '${modelSize(file.bytes)} download. Aaris will verify and test it before showing Ready.',
""", """                            file.bytes >= 1536 * 1024 * 1024
                                ? '${modelSize(file.bytes)} download. This is a large local model and may be slower or heavy on some phones. Aaris will still try it instead of blocking it from a RAM estimate.'
                                : '${modelSize(file.bytes)} download. Aaris will verify it and try the native model on this phone.',
""")
rep('lib/ui/local_models_panel.dart', """              subtitle: Text(
                local.isModelReady(model.id)
                    ? '${modelSize(model.bytes)} · Ready'
                    : '${modelSize(model.bytes)} · Installed',
              ),
""", """              subtitle: Text(
                local.isModelReady(model.id)
                    ? local.isModelScanReady(model.id)
                          ? '${modelSize(model.bytes)} · Ready'
                          : '${modelSize(model.bytes)} · Chat Ready · scan review limited'
                    : '${modelSize(model.bytes)} · Installed',
              ),
""")
rep('lib/ui/local_models_panel.dart', """            subtitle: Text(
              local.ready
                  ? 'Use the Ready model after OCR.'
                  : 'Choose a model and wait for Ready first.',
            ),
            value: local.ready && local.scannerEnabled,
            onChanged: local.ready && !_locked
                ? (value) => _run(() => local.setScannerEnabled(value))
                : null,
""", """            subtitle: Text(
              local.scanReady
                  ? 'Use the scan-verified model after OCR.'
                  : local.ready
                  ? 'Chat is Ready. This model did not pass the stricter scan-review check.'
                  : 'Choose a model and wait for Chat Ready first.',
            ),
            value: local.scanReady && local.scannerEnabled,
            onChanged: local.scanReady && !_locked
                ? (value) => _run(() => local.setScannerEnabled(value))
                : null,
""")
rep('lib/ui/local_models_panel.dart', """  if (lower.contains('memory') || lower.contains('ram'))
    return 'This model is too large for the phone right now. Close other apps or choose a smaller model.';
  if (lower.contains('setup check') || lower.contains('activation'))
    return 'This model could not pass the on-device test. Try another model.';
""", """  if (lower.contains('memory') || lower.contains('ram'))
    return 'The native model load could not start right now. Aaris does not block models by a RAM estimate; close other apps and retry if needed.';
  if (lower.contains('setup check') || lower.contains('activation'))
    return 'The optional scan-review test was not verified. Chat can still be used when the model shows Chat Ready.';
""")
rep('lib/ui/local_models_panel.dart', """          if (local.transferring) ...[
""", """          if (local.ready && local.memoryWarning) ...[
            const SizedBox(height: 8),
            Text(
              'Large-model mode · this model may use more memory or run slower. Aaris will still try native inference instead of blocking it by RAM estimate.',
              style: TextStyle(
                color: Theme.of(context).colorScheme.tertiary,
                fontSize: 11.5,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
          if (local.transferring) ...[
""")

# 9) Regression checks.
Path('test/local_model_readiness_test.dart').write_text(r'''import 'package:aaris_pharmacy/domain/local_model.dart';
import 'package:flutter_test/flutter_test.dart';

InstalledLocalModel model({required bool loaded, required bool scanTested}) =>
    InstalledLocalModel(
      id: 'a' * 64,
      label: 'Qwen2.5-0.5B.gguf',
      bytes: 339 * 1024 * 1024,
      loadTestPassed: loaded,
      smokeTestPassed: scanTested,
    );

void main() {
  test('Chat readiness is independent from strict scan-review readiness', () {
    final installedOnly = model(loaded: false, scanTested: false);
    expect(
      isLocalModelReady(model: installedOnly, activeId: installedOnly.id),
      isFalse,
    );
    final chatReady = model(loaded: true, scanTested: false);
    expect(isLocalModelReady(model: chatReady, activeId: chatReady.id), isTrue);
    expect(
      isLocalModelScanReady(model: chatReady, activeId: chatReady.id),
      isFalse,
    );
    final scanReady = model(loaded: true, scanTested: true);
    expect(isLocalModelReady(model: scanReady, activeId: null), isFalse);
    expect(isLocalModelReady(model: scanReady, activeId: 'b' * 64), isFalse);
    expect(isLocalModelReady(model: scanReady, activeId: scanReady.id), isTrue);
    expect(
      isLocalModelScanReady(model: scanReady, activeId: scanReady.id),
      isTrue,
    );
  });

  test('Old smoke-tested manifests migrate as chat-ready', () {
    final legacy = InstalledLocalModel.fromJson({
      'id': 'b' * 64,
      'label': 'Legacy.gguf',
      'bytes': 4096,
      'smokeTestPassed': true,
    });
    expect(legacy.loadTestPassed, isTrue);
    expect(legacy.smokeTestPassed, isTrue);
  });
}
''')
rep('tool/check_model_preflight.dart', """  check(
    fourGbTwoGb.contextTokens == 2048,
    '4 GB phone admits a 2 GB mmap-backed model with constrained context',
  );
""", """  check(
    fourGbTwoGb.contextTokens == 2048 && fourGbTwoGb.memoryWarning,
    '4 GB phone admits a 2 GB mmap-backed model with a heavy-model warning',
  );
""")
rep('tool/check_model_preflight.dart', """  rejects(
    () => planLocalExecution(
      weightBytes: 2700 * 1024 * 1024,
      metadata: model,
      phone: true,
      totalMemory: 4 * gib,
      availableMemory: 3 * gib,
    ),
  );
""", """  final veryLargePhone = planLocalExecution(
    weightBytes: 2700 * 1024 * 1024,
    metadata: model,
    phone: true,
    totalMemory: 4 * gib,
    availableMemory: 3 * gib,
  );
  check(
    veryLargePhone.contextTokens == 2048 && veryLargePhone.memoryWarning,
    'Phone RAM estimate warns but does not pre-block a large mmap-backed model',
  );
""")
rep('tool/check_model_preflight.dart', """  rejects(
    () =>
        planLocalExecution(weightBytes: gib, metadata: model, lowMemory: true),
  );
""", """  final pressuredPhone = planLocalExecution(
    weightBytes: gib,
    metadata: model,
    phone: true,
    totalMemory: 4 * gib,
    availableMemory: 600 * 1024 * 1024,
    lowMemory: true,
  );
  check(
    pressuredPhone.contextTokens == 2048 && pressuredPhone.memoryWarning,
    'Phone memory pressure becomes a warning and conservative context',
  );
""")
rep('tool/check_model_preflight.dart', """    legacy.metadata == null && legacy.smokeTestPassed,
    'Old installed manifests still load',
""", """    legacy.metadata == null && legacy.smokeTestPassed && legacy.loadTestPassed,
    'Old installed manifests migrate to chat-ready',
""")
Path('test/ai_routing_configuration_test.dart').write_text(r'''import 'package:aaris_pharmacy/domain/local_ai_protocol.dart';
import 'package:aaris_pharmacy/services/ai_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Aaris Brain route preference survives serialization', () {
    const config = AiConfiguration(
      provider: 'Gemini',
      model: 'gemini-test',
      key: 'secret',
      localBrainEnabled: true,
    );
    final restored = AiConfiguration.fromJson(config.toJson());
    expect(restored.localBrainEnabled, isTrue);
    expect(restored.key, 'secret');
    expect(restored.copyWith(localBrainEnabled: false).localBrainEnabled, isFalse);
  });

  test('Plain local chat fallback can never propose inventory changes', () {
    expect(
      localChatObject('Hello, kaise ho?'),
      {'reply': 'Hello, kaise ho?', 'actions': <Object?>[]},
    );
    expect(
      () => localChatObject('{"actions":[{"op":"remove"}]} broken'),
      throwsFormatException,
    );
  });
}
''')
