import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../domain/local_ai_protocol.dart';
import '../domain/local_model.dart';
import '../domain/medicine_understanding.dart';
import 'local_ai_runtime.dart';

class LocalAiService extends ChangeNotifier {
  static final instance = LocalAiService();
  final List<InstalledLocalModel> _models = [];
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
      _activeId = id as String?;
      _scannerEnabled = json['scannerEnabled'] != false;
      _status = hasSelection
          ? 'Local selected · loads on demand'
          : 'No local model selected';
    }
    notifyListeners();
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
      }),
      flush: true,
    );
    await temporary.rename('${_directory!.path}/models.json');
  }

  Future<Object?> _catalogue(Uri uri) async {
    // This client handles public model metadata ONLY. It has no pharmacy context,
    // no API key and no access to the active model prompt/session.
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 20);
    try {
      final request = await client.getUrl(uri);
      request.followRedirects = false;
      final response = await request.close().timeout(
        const Duration(seconds: 25),
      );
      if (response.statusCode != 200) {
        throw StateError(
          'Model catalogue unavailable (${response.statusCode}). Public, ungated repositories only.',
        );
      }
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in response.timeout(const Duration(seconds: 20))) {
        bytes.add(chunk);
        if (bytes.length > 4 * 1024 * 1024)
          throw StateError('Catalogue response too large.');
      }
      return jsonDecode(utf8.decode(bytes.takeBytes()));
    } finally {
      client.close(force: true);
    }
  }

  Future<List<String>> search(String query) async {
    final clean = query.trim();
    if (clean.isEmpty || clean.length > 100) return [];
    final json = await _catalogue(
      Uri.https('huggingface.co', '/api/models', {
        'search': clean,
        'filter': 'gguf',
        'limit': '30',
        'sort': 'downloads',
        'direction': '-1',
      }),
    );
    if (json is! List) throw const FormatException('Invalid model catalogue.');
    return json
        .whereType<Map>()
        .map((m) => m['id'])
        .whereType<String>()
        .where(
          (id) => RegExp(r'^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$').hasMatch(id),
        )
        .take(30)
        .toList();
  }

  Future<List<LocalModelFile>> files(String repository) async {
    if (!RegExp(r'^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$').hasMatch(repository)) {
      throw const FormatException('Use publisher/repository.');
    }
    final json = await _catalogue(
      Uri.https('huggingface.co', '/api/models/$repository', {'blobs': 'true'}),
    );
    if (json is! Map || json['siblings'] is! List || json['sha'] is! String) {
      throw const FormatException('Model file metadata is unavailable.');
    }
    final card = json['cardData'];
    final license = card is Map && card['license'] is String
        ? card['license'] as String
        : 'Check publisher model card';
    final result = <LocalModelFile>[];
    for (final item in (json['siblings'] as List).whereType<Map>()) {
      final name = item['rfilename'], lfs = item['lfs'];
      if (name is! String || !isSingleGguf(name) || lfs is! Map) continue;
      final size = lfs['size'] ?? item['size'], hash = lfs['sha256'];
      if (size is! int || hash is! String) continue;
      final file = LocalModelFile(
        repository: repository,
        revision: json['sha'] as String,
        filename: name,
        bytes: size,
        sha256: hash,
        license: license,
      );
      try {
        file.validate();
      } on FormatException {
        continue;
      }
      result.add(file);
    }
    result.sort((a, b) => a.bytes.compareTo(b.bytes));
    return result;
  }

  Future<HttpClientResponse> _downloadResponse(
    HttpClient client,
    Uri uri,
    int offset,
  ) async {
    for (var redirects = 0; redirects <= 6; redirects++) {
      final host = uri.host.toLowerCase();
      if (uri.scheme != 'https' ||
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
      await _checkGguf(part);
      await part.rename(_weights(hash).path);
      _models.add(
        InstalledLocalModel(
          id: hash,
          label: model.label,
          bytes: model.bytes,
          source: '${model.repository}@${model.revision}',
        ),
      );
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
      await _checkGguf(part);
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
      _models.add(InstalledLocalModel(id: hash, label: name, bytes: bytes));
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
    if (runtime != null) await runtime.close();
    _runtime = null;
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
      await _checkResources(weightBytes: model.bytes);
    }
    _runtime ??= LocalAiRuntime();
    _status = 'Local AI · loading / processing';
    notifyListeners();
    await _runtime!.load(file.path);
  }

  Future<void> activate(String id) => _exclusive((generation) async {
    final model = _models.where((m) => m.id == id).firstOrNull;
    if (model == null) throw StateError('Download or import this model first.');
    final previous = _activeId;
    await _release();
    _activeId = id;
    try {
      final file = _weights(id);
      await _checkGguf(file);
      _status = 'Verifying model before activation…';
      notifyListeners();
      if (await _hash(file.path) != id)
        throw StateError(
          'Model changed since installation. Re-import a trusted file.',
        );
      _checkRequest(generation);
      await _loadSelected();
      const system =
          'Extract salt and labelled expiry from SOURCE. Unknown is null. Return only JSON {"salt":null,"expiry":null}. Expiry format YYYY-MM. Never infer expiry from MFG.';
      final first = localJsonObject(
        await _runtime!.generate(
          system,
          'SOURCE: Paracetamol 500 mg. MFG 08/2026. EXP 07/2028.',
          maxTokens: 180,
        ),
      );
      _checkRequest(generation);
      final second = localJsonObject(
        await _runtime!.generate(
          system,
          'SOURCE: BATCH AB12. MFG 09/2026.',
          maxTokens: 180,
        ),
      );
      if (first['salt'] != 'Paracetamol' ||
          first['expiry'] != '2028-07' ||
          second['salt'] != null ||
          second['expiry'] != null) {
        throw StateError(
          'Setup checks failed: structured extraction/unknown fields. Try an instruction-tuned model.',
        );
      }
      _checkRequest(generation);
      _models[_models.indexOf(model)] = InstalledLocalModel(
        id: model.id,
        label: model.label,
        bytes: model.bytes,
        source: model.source,
        smokeTestPassed: true,
      );
      await _save();
      _status = 'Local active · 2 setup checks passed · review required';
    } catch (_) {
      _activeId = previous;
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
    var input = jsonEncode({
      'ownerRequest': instruction,
      'recentConversation': conversation.length > 2500
          ? conversation.substring(conversation.length - 2500)
          : conversation,
    });
    final results = <Map<String, Object?>>[];
    for (var round = 0; round <= 4; round++) {
      final raw = await _runtime!.generate(context.instructions, input);
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
      final facts = context.read(answer);
      results.add({'call': answer, 'result': facts});
      // Keep the last two pages, with explicit pagination metadata. The app
      // retains retrieved-ID authority independently of this bounded prompt.
      if (results.length > 2) results.removeAt(0);
      input = jsonEncode({
        'ownerRequest': instruction,
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
      final raw = await _runtime!.generate(
        localScanPrompt(draft),
        'Return the evidence-grounded fields for this one medicine.',
        maxTokens: 1000,
      );
      _checkRequest(generation);
      return validateLocalScan(draft, localJsonObject(raw));
    });
  }
}

Future<void> _checkResources({
  int storageBytes = 0,
  int weightBytes = 0,
}) async {
  if (!Platform.isAndroid) return;
  const channel = MethodChannel('com.aaris.pharmacy/documents');
  final info = await channel.invokeMapMethod<String, dynamic>(
    'localAiDeviceInfo',
  );
  final free = info?['freeStorage'], total = info?['totalMemory'];
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
  if (weightBytes > 0 &&
      (info?['lowMemory'] == true ||
          (total is int && weightBytes * 1.2 + reserve > total * .8))) {
    throw StateError(
      'This model exceeds the conservative memory budget for this device. Choose smaller quantized weights. File size is not runtime RAM.',
    );
  }
}

Future<String> _hash(String path) => Isolate.run(
  () async => (await sha256.bind(File(path).openRead()).first).toString(),
);

Future<void> _checkGguf(File file) async {
  if (await file.length() < 1024)
    throw const FormatException('Model file is incomplete.');
  final reader = await file.open();
  try {
    final bytes = await reader.read(24);
    if (bytes.length != 24 ||
        ascii.decode(bytes.take(4).toList(), allowInvalid: true) != 'GGUF') {
      throw const FormatException('This is not a GGUF model file.');
    }
    final version = ByteData.sublistView(bytes).getUint32(4, Endian.little);
    if (version != 2 && version != 3)
      throw const FormatException('Unsupported GGUF container version.');
  } finally {
    await reader.close();
  }
}
