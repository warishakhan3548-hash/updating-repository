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
import 'gguf_inspector.dart';
import '../domain/local_model.dart';
import '../domain/local_model_checks.dart';
import '../domain/model_catalogue.dart';
import 'model_catalogue_service.dart';
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
  int _requestGeneration = 0, _transferGeneration = 0;
  double? _progress;
  String _status = 'No local model selected';
  Timer? _idle;
  bool _observingMemory = false, _releaseForMemory = false;
  LocalExecutionPlan? _executionPlan;
  String get executionSummary => _executionPlan == null
      ? ''
      : '${_executionPlan!.contextTokens} token context · estimated ${modelSize(_executionPlan!.estimatedBytes)} working memory';

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
    _directory = await Directory(
      '${support.path}/local_ai',
    ).create(recursive: true);
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
          ? 'Local selected · loads on demand'
          : 'No local model selected';
    }
    if (!_observingMemory) {
      WidgetsBinding.instance.addObserver(this);
      _observingMemory = true;
    }
    notifyListeners();
  }

  @override
  void didHaveMemoryPressure() {
    _releaseForMemory = true;
    cancelRequest();
    if (!busy && !_transferring) {
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
    if (_models.any((m) => m.id == model.sha256)) {
      await _save();
      return;
    }
    final generation = ++_transferGeneration;
    _transferring = true;
    _progress = null;
    _status = 'Downloading model · inventory stays on device';
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
          final match = RegExp(
            r'^bytes (\d+)-(\d+)/(\d+)$',
          ).firstMatch(range ?? '');
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
      _status = 'Verifying SHA-256 on device…';
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
      _status = 'Download verified. Activate to test this model.';
    } catch (error) {
      _status = generation != _transferGeneration
          ? 'Download paused; partial file retained'
          : error.toString();
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
  }

  void cancelTransfer() {
    ++_transferGeneration;
    _transfer?.close(force: true);
    if (Platform.isAndroid) {
      unawaited(
        const MethodChannel(
          'com.aaris.pharmacy/documents',
        ).invokeMethod<void>('cancelModelImport').catchError((Object _) {}),
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
        final raw = await const MethodChannel(
          'com.aaris.pharmacy/documents',
        ).invokeMapMethod<String, dynamic>('pickLocalModel');
        if (raw == null) return;
        final path = raw['path'];
        if (path is! String ||
            !path.startsWith('${_directory!.path}/import_') ||
            !RegExp(
              r'^import_[a-f0-9-]{36}\.part$',
            ).hasMatch(path.split('/').last)) {
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
      _status =
          'Import ready. Publisher authenticity is not verified; activate to test compatibility.';
    } catch (error) {
      _status = error.toString();
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
              'Memory pressure · local model unloaded; selection retained';
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
    }
  }

  Future<void> activate(String id) => _exclusive((generation) async {
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
      if (await _hash(file.path) != id)
        throw StateError(
          'Model changed since installation. Re-import a trusted file.',
        );
      _checkRequest(generation);
      await _loadSelected();
      for (var i = 0; i < localSetupChecks.length; i++) {
        final probe = localSetupChecks[i];
        _status =
            'Setup check ${i + 1}/${localSetupChecks.length} · structured extraction';
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
      _status =
          'Local active · ${localSetupChecks.length} setup checks passed · review required';
    } catch (_) {
      _activeId = previous;
      final index = _models.indexWhere((m) => m.id == model.id);
      if (index >= 0) _models[index] = model;
      await _release();
      _status = 'Activation failed; previous selection preserved';
      rethrow;
    }
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
    _status = 'Local disabled · existing provider settings apply';
  });

  Future<void> setScannerEnabled(bool value) => _exclusive((_) async {
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
      final raw = await _runtime!.generate(
        context.instructions,
        input,
        maxTokens: _executionPlan!.outputTokens,
      );
      _checkRequest(generation);
      final answer = localJsonObject(raw);
      if (!answer.containsKey('tool')) {
        _status = 'Local answer ready · proposed changes require review';
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
    if (!hasSelection || !scannerEnabled) return draft;
    return _exclusive((generation) async {
      await _loadSelected();
      _checkRequest(generation);
      final sourceLimit = _executionPlan!.evidenceCharacters;
      final raw = await _runtime!.generate(
        localScanPrompt(draft, sourceLimit: sourceLimit),
        'Return the evidence-grounded fields for this one medicine.',
        maxTokens: _executionPlan!.outputTokens.clamp(1, 1000),
      );
      _checkRequest(generation);
      return validateLocalScan(
        draft,
        localJsonObject(raw),
        sourceLimit: sourceLimit,
      );
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
  if (weightBytes > 0 && info?['lowMemory'] == true) {
    throw StateError(
      'Device memory is under pressure. Close other apps or choose smaller weights.',
    );
  }
  return info;
}

Future<String> _hash(String path) => Isolate.run(
  () async => (await sha256.bind(File(path).openRead()).first).toString(),
);

Future<GgufMetadata> _checkGguf(File file) => inspectGgufFile(file.path);
