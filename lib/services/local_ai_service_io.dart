import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';

import '../domain/local_ai_protocol.dart';
import '../domain/gguf_metadata.dart';
import '../domain/local_model.dart';
import '../domain/local_model_checks.dart';
import '../domain/model_catalogue.dart';
import 'gguf_inspector.dart';
import '../domain/medicine_understanding.dart';
import 'local_ai_runtime.dart';

class LocalAiService extends ChangeNotifier with WidgetsBindingObserver {
  static final instance = LocalAiService();
  final List<InstalledLocalModel> _models = [];
  final List<LocalModelFile> _downloads = [];
  Future<void>? _initializing;
  Directory? _directory;
  LocalAiRuntime? _runtime;
  HttpClient? _transfer;
  String? _activeId;
  bool _working = false, _transferring = false, _scannerEnabled = true;
  LocalModelSetupStage _setupStage = LocalModelSetupStage.chooseModel;
  int _requestGeneration = 0, _transferGeneration = 0;
  double? _progress;
  String _status = 'No local model selected';
  Timer? _idle;
  bool _observingMemory = false, _releaseForMemory = false;
  LocalExecutionPlan? _executionPlan;
  String get executionSummary => _executionPlan == null
      ? ''
      : '${_executionPlan!.contextTokens} token context · estimated ${modelSize(_executionPlan!.estimatedBytes)} working memory${_executionPlan!.memoryWarning ? ' · heavy model' : ''}';
  bool get memoryWarning => _executionPlan?.memoryWarning ?? false;

  bool get supported =>
      Platform.isAndroid ||
      Platform.isIOS ||
      Platform.isLinux ||
      Platform.isMacOS ||
      Platform.isWindows;
  bool get hasSelection => _activeId != null;
  bool get busy => _working;
  bool get transferring => _transferring;
  bool get scannerEnabled => _scannerEnabled;
  double? get progress => _progress;
  String get status => _status;
  String? get activeId => _activeId;
  LocalModelSetupStage get setupStage => _setupStage;
  InstalledLocalModel? get activeModel =>
      _models.where((model) => model.id == _activeId).firstOrNull;
  bool get ready => isLocalModelReady(model: activeModel, activeId: _activeId);
  bool get scanReady =>
      isLocalModelScanReady(model: activeModel, activeId: _activeId);
  bool get scanVerified =>
      isLocalModelScanVerified(model: activeModel, activeId: _activeId);
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
  bool isModelScanVerified(String id) =>
      _activeId == id &&
      isLocalModelScanVerified(
        model: _models.where((model) => model.id == id).firstOrNull,
        activeId: _activeId,
      );
  List<InstalledLocalModel> get installed => List.unmodifiable(_models);
  List<LocalModelFile> get pendingDownloads => List.unmodifiable(_downloads);
  String get activeLabel =>
      _models.where((m) => m.id == _activeId).map((m) => m.label).firstOrNull ??
      (hasSelection ? 'Selected model unavailable' : '');

  Future<void> initialize() =>
      _initializing ??= _initialize().catchError((Object error) {
        _initializing = null;
        throw error;
      });

  Future<void> _initialize() async {
    if (!supported) return;
    final support = await getApplicationSupportDirectory();
    _directory = await Directory('${support.path}/local_ai')
        .create(recursive: true);
    final file = File('${_directory!.path}/models.json');
    if (await file.exists()) {
      if (await file.length() > 1000000)
        throw const FormatException('Model manifest is too large.');
      final json = jsonDecode(await file.readAsString());
      if (json is! Map || json['version'] != 1 || json['models'] is! List) {
        throw const FormatException(
          'Cannot read local model settings. No external AI was contacted.',
        );
      }
      final models = (json['models'] as List)
          .map(
            (m) => InstalledLocalModel.fromJson(
              Map<String, dynamic>.from(m as Map),
            ),
          )
          .toList();
      final id = json['activeId'];
      if (id != null &&
          (id is! String || !RegExp(r'^[a-f0-9]{64}$').hasMatch(id))) {
        throw const FormatException('Invalid active local model.');
      }
      _models
        ..clear()
        ..addAll(models);
      final downloads = json['downloads'] ?? [];
      if (downloads is! List ||
          downloads.length > 32 ||
          downloads.any((d) => d is! Map)) {
        throw const FormatException('Invalid saved model download list.');
      }
      _downloads
        ..clear()
        ..addAll(
          downloads.map(
            (d) => LocalModelFile.fromJson(Map<String, dynamic>.from(d as Map)),
          ),
        );
      _activeId = id as String?;
      _scannerEnabled = json['scannerEnabled'] != false;
      _status = hasSelection
          ? 'Local model selected'
          : 'No local model selected';
    }
    _setupStage = ready
        ? LocalModelSetupStage.ready
        : LocalModelSetupStage.chooseModel;
    if (!_observingMemory) {
      WidgetsBinding.instance.addObserver(this);
      _observingMemory = true;
    }
    notifyListeners();
  }

  @override
  void didHaveMemoryPressure() {
    // Android may emit memory-pressure callbacks while llama.cpp is actively
    // generating. Cancelling that turn here used to surface as random
    // "Connection Failed"/cancelled replies even when the model was healthy.
    // Finish the leased native command first, then unload once the lease is
    // released. Explicit user cancellation still goes through cancelRequest().
    _releaseForMemory = true;
    if (busy) {
      _status = 'Memory pressure noted · finishing current local answer safely';
      notifyListeners();
      return;
    }
    if (!_transferring) {
      unawaited(_exclusive((_) async {}).catchError((Object _) {}));
    }
  }

  File _weights(String id) {
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(id))
      throw const FormatException('Invalid model ID.');
    return File('${_directory!.path}/$id.gguf');
  }

  Future<void> _save() async {
    final temporary = File('${_directory!.path}/models.json.next');
    await temporary.writeAsString(
      jsonEncode({
        'version': 1,
        'activeId': _activeId,
        'scannerEnabled': _scannerEnabled,
        'models': _models.map((m) => m.toJson()).toList(),
        'downloads': _downloads.map((m) => m.toJson()).toList(),
      }),
      flush: true,
    );
    await temporary.rename('${_directory!.path}/models.json');
  }

  final ModelCatalogueProvider catalogue = HuggingFaceModelCatalogue();

  Future<ModelSearchPage> searchPage(
    String query, {
    ModelSort sort = ModelSort.popular,
    Uri? cursor,
  }) => catalogue.search(query, sort: sort, cursor: cursor);

  Future<List<String>> search(String query) async =>
      (await searchPage(query)).repositories;

  Future<ModelRepositoryFiles> repositoryFiles(String input) {
    final location = ModelRepositoryLocation.parse(input);
    if (location == null)
      throw const FormatException('Use publisher/repository or a model link.');
    return catalogue.files(location);
  }

  Future<List<LocalModelFile>> files(String repository) async =>
      (await repositoryFiles(repository)).files;

  Future<HttpClientResponse> _downloadResponse(
    HttpClient client,
    Uri uri,
    int offset,
  ) async {
    for (var redirects = 0; redirects <= 6; redirects++) {
      final host = uri.host.toLowerCase();
      if (uri.scheme != 'https' ||
          uri.port != 443 ||
          uri.userInfo.isNotEmpty ||
          !(host == 'huggingface.co' ||
              host.endsWith('.huggingface.co') ||
              host.endsWith('.hf.co') ||
              host.endsWith('.amazonaws.com'))) {
        throw StateError('Unsafe model download redirect was blocked.');
      }
      final request = await client.getUrl(uri);
      request.followRedirects = false;
      request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
      if (offset > 0)
        request.headers.set(HttpHeaders.rangeHeader, 'bytes=$offset-');
      final response = await request.close().timeout(
        const Duration(seconds: 40),
      );
      if (![301, 302, 303, 307, 308].contains(response.statusCode))
        return response;
      final next = response.headers.value(HttpHeaders.locationHeader);
      if (next == null) throw StateError('Missing model redirect.');
      await response.drain<void>().timeout(const Duration(seconds: 20));
      uri = uri.resolve(next);
    }
    throw StateError('Too many model download redirects.');
  }

  Future<void> download(LocalModelFile model) async {
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
    notifyListeners();
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 25)
      ..autoUncompress = false;
    _transfer = client;
    final part = File('${_directory!.path}/${model.sha256}.part');
    RandomAccessFile? writer;
    try {
      if (!_downloads.any((m) => m.sha256 == model.sha256)) {
        if (_downloads.length >= 32)
          throw StateError('Remove or finish a paused model download first.');
        _downloads.add(model);
      }
      // Save the exact revision + checksum before transferring any bytes.
      // Resume no longer depends on finding the same search result after restart.
      await _save();
      var offset = await part.exists() ? await part.length() : 0;
      if (offset > model.bytes) {
        await part.delete();
        offset = 0;
      }
      await _checkResources(storageBytes: model.bytes - offset);
      if (offset < model.bytes) {
        final response = await _downloadResponse(
          client,
          model.downloadUri,
          offset,
        );
        if (response.statusCode == 206) {
          final range = response.headers.value(HttpHeaders.contentRangeHeader);
          final match = RegExp(r'^bytes (\d+)-(\d+)/(\d+)$')
              .firstMatch(range ?? '');
          if (match == null ||
              int.parse(match[1]!) != offset ||
              int.parse(match[3]!) != model.bytes ||
              int.parse(match[2]!) != model.bytes - 1) {
            throw StateError('Server returned an inconsistent download range.');
          }
        } else if (response.statusCode == 200) {
          offset =
              0; // Server ignored Range: restart, never append a full file.
          // The old partial will be truncated, so its space can be reused.
          final occupied = await part.exists() ? await part.length() : 0;
          await _checkResources(storageBytes: model.bytes - occupied);
        } else {
          throw StateError(
            'Download failed (${response.statusCode}). No model activated.',
          );
        }
        writer = await part.open(
          mode: offset == 0 ? FileMode.write : FileMode.append,
        );
        var lastNotification = DateTime.now();
        await for (final chunk in response.timeout(
          const Duration(seconds: 45),
        )) {
          if (generation != _transferGeneration)
            throw StateError(
              'Download paused. Select Download again to resume.',
            );
          offset += chunk.length;
          if (offset > model.bytes)
            throw StateError(
              'Downloaded file is larger than its verified manifest.',
            );
          await writer.writeFrom(chunk);
          if (DateTime.now().difference(lastNotification).inMilliseconds >
              250) {
            _progress = offset / model.bytes;
            notifyListeners();
            lastNotification = DateTime.now();
          }
        }
        await writer.flush();
        await writer.close();
        writer = null;
      }
      if (generation != _transferGeneration)
        throw StateError('Download paused.');
      if (await part.length() != model.bytes)
        throw StateError('Incomplete download; resume to finish.');
      _setupStage = LocalModelSetupStage.verifying;
      _status = 'Checking downloaded model…';
      _progress = null;
      notifyListeners();
      final hash = await _hash(part.path);
      if (hash != model.sha256) {
        await part
            .delete(); // Only this newly downloaded, corrupt partial file.
        throw StateError(
          'Checksum mismatch. Corrupt download removed; download again.',
        );
      }
      if (generation != _transferGeneration)
        throw StateError('Download paused after verification.');
      final metadata = await _checkGguf(part);
      await part.rename(_weights(hash).path);
      _models.add(
        InstalledLocalModel(
          id: hash,
          label: model.label,
          bytes: model.bytes,
          source: '${model.repository}@${model.revision}',
          metadata: metadata,
        ),
      );
      _downloads.removeWhere((m) => m.sha256 == model.sha256);
      await _save();
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
    } finally {
      try {
        await writer?.close();
      } finally {
        client.close(force: true);
        _transfer = null;
        _transferring = false;
        _progress = null;
        if (_releaseForMemory)
          unawaited(_exclusive((_) async {}).catchError((Object _) {}));
        notifyListeners();
      }
    }
    // One tap means one understandable outcome: downloaded weights are
    // immediately load-tested and activated. A model is never labelled Ready
    // until activate() completes all setup probes successfully.
    await activate(model.sha256);
  }

  void cancelTransfer() {
    ++_transferGeneration;
    _transfer?.close(force: true);
    if (Platform.isAndroid) {
      unawaited(
        const MethodChannel('com.aaris.pharmacy/documents')
            .invokeMethod<void>('cancelModelImport')
            .catchError((Object _) {}),
      );
    }
  }

  Future<void> discardDownload(String sha256) => _exclusive((_) async {
    final model = _downloads.where((m) => m.sha256 == sha256).firstOrNull;
    if (model == null) return;
    _downloads.remove(model);
    try {
      await _save();
    } catch (_) {
      _downloads.add(model);
      rethrow;
    }
    final partial = File('${_directory!.path}/${model.sha256}.part');
    if (await partial.exists()) await partial.delete();
    _status = 'Partial download removed';
  });

  Future<void> importModel() async {
    await initialize();
    if (_transferring || busy)
      throw StateError('Finish the current local AI operation first.');
    _transferring = true;
    final generation = ++_transferGeneration;
    _status = 'Choose a trusted GGUF file · importing on device';
    notifyListeners();
    File? part;
    try {
      String name;
      String? verifiedHash;
      if (Platform.isAndroid) {
        final raw = await const MethodChannel('com.aaris.pharmacy/documents')
            .invokeMapMethod<String, dynamic>('pickLocalModel');
        if (raw == null) return;
        final path = raw['path'];
        if (path is! String ||
            !path.startsWith('${_directory!.path}/import_') ||
            !RegExp(r'^import_[a-f0-9-]{36}\.part$')
                .hasMatch(path.split('/').last)) {
          throw StateError('Unexpected native model staging path.');
        }
        part = File(path);
        name = raw['name'] as String;
        verifiedHash = raw['sha256'] as String;
        if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(verifiedHash)) {
          throw StateError('Invalid native import checksum.');
        }
      } else {
        final selected = await openFile(
          acceptedTypeGroups: const [
            XTypeGroup(label: 'GGUF weights', extensions: ['gguf']),
          ],
        );
        if (selected == null) return;
        name = selected.name;
        final source = File(selected.path);
        await _checkGguf(source);
        part = File('${_directory!.path}/import.part');
        await source.copy(part.path);
      }
      if (!isSingleGguf(name))
        throw const FormatException(
          'Import one complete GGUF language-model weight file.',
        );
      if (generation != _transferGeneration)
        throw StateError('Model import cancelled.');
      final metadata = await _checkGguf(part);
      final bytes = await part.length();
      final hash = verifiedHash ?? await _hash(part.path);
      if (generation != _transferGeneration) {
        throw StateError('Model import cancelled after verification.');
      }
      if (_models.any((m) => m.id == hash)) {
        await _save();
        await part.delete();
        part = null;
        _status = 'This model is already installed.';
        return;
      }
      await part.rename(_weights(hash).path);
      part = null;
      _models.add(
        InstalledLocalModel(
          id: hash,
          label: name,
          bytes: bytes,
          metadata: metadata,
        ),
      );
      await _save();
      _setupStage = LocalModelSetupStage.chooseModel;
      _status = 'Model imported · choose Use to test it';
    } catch (error) {
      _setupStage = ready
          ? LocalModelSetupStage.ready
          : LocalModelSetupStage.attention;
      _status = 'Could not import this model';
      rethrow;
    } finally {
      try {
        if (part != null && await part.exists()) await part.delete();
      } finally {
        _transferring = false;
        if (_releaseForMemory)
          unawaited(_exclusive((_) async {}).catchError((Object _) {}));
        notifyListeners();
      }
    }
  }

  Future<T> _exclusive<T>(Future<T> Function(int generation) action) async {
    await initialize();
    if (_working || _transferring)
      throw StateError('Local AI is busy. Wait for the current operation.');
    _working = true;
    _idle?.cancel();
    final generation = _requestGeneration;
    notifyListeners();
    Future<T> run() async {
      try {
        return await action(generation);
      } finally {
        if (_releaseForMemory) {
          _releaseForMemory = false;
          try {
            await _release();
          } catch (_) {}
          _status =
              'Memory pressure · local model unloaded after current turn; selection retained';
        }
        _working = false;
        notifyListeners();
        _idle = Timer(const Duration(minutes: 3), () {
          if (!busy && !_transferring && _runtime != null) {
            unawaited(
              _exclusive((_) async {
                await _release();
                _status = hasSelection
                    ? 'Local selected · memory released while idle'
                    : 'Local stopped';
              }).catchError((Object _) {}),
            );
          }
        });
      }
    }

    // Timeout returns control to UI, but the exclusive lease stays held until
    // the bounded native generation actually returns. Never start a second one.
    return run().timeout(
      const Duration(minutes: 4),
      onTimeout: () {
        cancelRequest();
        throw TimeoutException(
          'Local AI took too long; native work is draining. No changes saved.',
        );
      },
    );
  }

  void _checkRequest(int generation) {
    if (generation != _requestGeneration)
      throw StateError('Local AI request cancelled.');
  }

  void cancelRequest() {
    ++_requestGeneration;
    if (busy) _status = 'Cancelled · finishing native step before release';
    notifyListeners();
  }

  Future<void> _release() async {
    final runtime = _runtime;
    try {
      if (runtime != null) await runtime.close();
    } finally {
      _runtime = null;
      _executionPlan = null;
    }
  }

  void _adoptLoadedContextBudget() {
    final runtime = _runtime;
    final plan = _executionPlan;
    final loaded = runtime?.loadedContextTokens;
    if (plan == null || loaded == null || loaded >= plan.contextTokens) return;

    // LocalAiRuntime may rescue a heavy GGUF by retrying a smaller native
    // context after allocator/KV pressure. Prompt/evidence budgets must follow
    // that successful context as well, otherwise the next chat/OCR request can
    // immediately overflow the model we just rescued. 3072 is intentionally
    // budgeted like 2048 until the protocol has a dedicated 3K profile.
    final promptContext = loaded >= 4096 ? 4096 : 2048;
    _executionPlan = LocalExecutionPlan(
      contextTokens: promptContext,
      estimatedBytes: plan.estimatedBytes,
      estimatedKvBytes: plan.estimatedKvBytes,
      geometryKnown: plan.geometryKnown,
      memoryWarning: true,
    );
    _status =
        'Local AI · adapted after native memory pressure · $executionSummary';
    notifyListeners();
  }

  Future<void> _loadSelected() async {
    final id = _activeId;
    if (id == null) throw StateError('Select a local model first.');
    final model = _models.where((m) => m.id == id).firstOrNull;
    if (model == null)
      throw StateError('Selected model is missing. Open local model settings.');
    final file = _weights(id);
    if (!await file.exists() || await file.length() != model.bytes) {
      throw StateError(
        'Selected model file is incomplete. No external fallback was used.',
      );
    }
    if (_runtime?.modelPath != file.path) {
      final metadata = await _checkGguf(file);
      final facts = await _checkResources(weightBytes: model.bytes);
      _executionPlan = planLocalExecution(
        weightBytes: model.bytes,
        metadata: metadata,
        totalMemory: facts?['totalMemory'] as int?,
        availableMemory: facts?['availableMemory'] as int?,
        lowMemory: facts?['lowMemory'] == true,
        phone: Platform.isAndroid || Platform.isIOS,
      );
      _runtime ??= LocalAiRuntime();
      _status = 'Local AI · loading · $executionSummary';
      notifyListeners();
      await _runtime!.load(
        file.path,
        contextTokens: _executionPlan!.contextTokens,
      );
      _adoptLoadedContextBudget();
    }
  }

  Future<void> activate(String id) => _exclusive((generation) async {
    final model = _models.where((m) => m.id == id).firstOrNull;
    if (model == null) throw StateError('Download or import this model first.');
    if (isModelReady(id)) {
      _setupStage = LocalModelSetupStage.ready;
      _status = isModelScanVerified(id)
          ? 'Local AI Ready'
          : 'Local AI Ready · scan extraction is available with review warning';
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
          : 'Local AI Ready · scan extraction is available with review warning';
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

  Future<void> suspend() => _exclusive((_) async {
    await _release();
    _status = hasSelection
        ? 'Local model selected · Aaris Brain off'
        : 'Local AI stopped';
  });

  Future<void> deactivate() => _exclusive((_) async {
    await _release();
    final previous = _activeId;
    _activeId = null;
    try {
      await _save();
    } catch (_) {
      _activeId = previous;
      rethrow;
    }
    _setupStage = LocalModelSetupStage.chooseModel;
    _status = 'Local AI turned off';
  });

  Future<void> setScannerEnabled(bool value) => _exclusive((_) async {
    if (value && !scanReady) {
      throw StateError(
        'Load-test and activate this local model before enabling scan AI.',
      );
    }
    final previous = _scannerEnabled;
    _scannerEnabled = value;
    try {
      await _save();
    } catch (_) {
      _scannerEnabled = previous;
      rethrow;
    }
  });

  Future<void> remove(String id) => _exclusive((_) async {
    if (id == _activeId)
      throw StateError('Disable this active model before removing it.');
    final model = _models.where((m) => m.id == id).firstOrNull;
    if (model == null) return;
    final file = _weights(id);
    if (await file.exists()) await file.delete();
    _models.remove(model);
    await _save();
    _status = 'Model removed from this device; inventory unchanged';
  });

  Future<String> ask(
    LocalInventoryContext context,
    String instruction, {
    String conversation = '',
    void Function(String token)? onToken,
  }) => _exclusive((generation) async {
    if (instruction.trim().isEmpty || instruction.length > 3000) {
      throw const FormatException('Keep the request under 3000 characters.');
    }
    await _loadSelected();
    _checkRequest(generation);
    final conversationLimit = _executionPlan!.conversationCharacters;
    final recentConversation = conversation.length > conversationLimit
        ? conversation.substring(conversation.length - conversationLimit)
        : conversation;
    var input = jsonEncode({
      'ownerRequest': instruction,
      'recentConversation': recentConversation,
    });
    final results = <Map<String, Object?>>[];
    for (var round = 0; round <= 4; round++) {
      _status = round == 0
          ? 'Local AI · thinking…'
          : 'Local AI · reading verified local inventory…';
      notifyListeners();
      final raw = await _runtime!.generate(
        context.instructions,
        input,
        maxTokens: _executionPlan!.outputTokens,
        onToken: onToken,
      );
      _checkRequest(generation);
      final answer = localChatObject(raw);
      if (!answer.containsKey('tool')) {
        _status = 'Local answer ready · proposed changes require review';
        notifyListeners();
        return context.finish(answer);
      }
      if (round == 4)
        throw StateError(
          'Local AI reached the read-tool limit. Ask a narrower question.',
        );
      final facts = context.read(
        answer,
        rowLimit: _executionPlan!.inventoryRows,
      );
      results.add({'call': answer, 'result': facts});
      // Keep the last two pages, with explicit pagination metadata. The app
      // retains retrieved-ID authority independently of this bounded prompt.
      if (results.length > 2) results.removeAt(0);
      input = jsonEncode({
        'ownerRequest': instruction,
        'recentConversation': recentConversation,
        'toolResults': results,
        'remainingReadCalls': 3 - round,
        'next': 'Answer or request one more page. Never invent omitted facts.',
      });
      if (input.length > 15000)
        throw StateError('Tool result too large; ask a narrower question.');
    }
    throw StateError('No local answer.');
  });

  Future<MedicineScanDraft> understand(MedicineScanDraft draft) async {
    await initialize();
    if (!hasSelection || !scannerEnabled || !scanReady) return draft;
    return _exclusive((generation) async {
      await _loadSelected();
      _checkRequest(generation);
      final sourceLimit = _executionPlan!.evidenceCharacters;
      _status = 'Local AI · extracting brand, salt, strength and form from OCR…';
      notifyListeners();
      final raw = await _runtime!.generate(
        localScanPrompt(draft, sourceLimit: sourceLimit),
        'Return the evidence-grounded fields for this one medicine.',
        maxTokens: _executionPlan!.outputTokens.clamp(1, 1000),
      );
      _checkRequest(generation);
      final result = validateLocalScan(
        draft,
        localJsonObject(raw),
        sourceLimit: sourceLimit,
      );
      _status = 'AI scan preview ready · confirm before adding';
      notifyListeners();
      return result;
    });
  }
}

Future<Map<String, dynamic>?> _checkResources({
  int storageBytes = 0,
  int weightBytes = 0,
}) async {
  if (!Platform.isAndroid) return null;
  const channel = MethodChannel('com.aaris.pharmacy/documents');
  final info = await channel.invokeMapMethod<String, dynamic>(
    'localAiDeviceInfo',
  );
  final free = info?['freeStorage'];
  if (weightBytes > 0) {
    final abis = info?['abis'], sdk = info?['sdkInt'];
    // The pinned package ships an Android arm64 prebuilt. Keep unsupported
    // devices on the deterministic engine; never try to load a missing ABI.
    if (sdk is! int ||
        sdk < 28 ||
        abis is! List ||
        !abis.contains('arm64-v8a')) {
      throw StateError(
        'This local runtime needs arm64 Android 9+. The offline scanner still works without it.',
      );
    }
  }
  const reserve = 512 * 1024 * 1024;
  if (storageBytes > 0 && free is int && free < storageBytes + reserve) {
    throw StateError(
      'Not enough free storage for the model plus 512 MB safety reserve.',
    );
  }
  // Memory data is advisory. The planner chooses context/warning; native
  // llama.cpp remains the final authority on whether the weights can load.
  return info;
}

Future<String> _hash(String path) => Isolate.run(
  () async => (await sha256.bind(File(path).openRead()).first).toString(),
);

Future<GgufMetadata> _checkGguf(File file) => inspectGgufFile(file.path);