from pathlib import Path
import re


def replace_once(path: str, old: str, new: str) -> None:
    p = Path(path)
    text = p.read_text()
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{path}: expected one match, found {count}: {old[:80]!r}")
    p.write_text(text.replace(old, new, 1))


# 1) Discovery: reject helper/calibration GGUF artifacts before users can pick them.
replace_once(
    "lib/domain/model_catalogue.dart",
    "r'(^|[_.-])(mmproj|projector|adapter|lora|tokenizer|vocab)([_.-]|$)'",
    "r'(^|[_.-])(mmproj|projector|adapter|lora|tokenizer|vocab|imatrix|importance|calibration)([_.-]|$)'",
)
replace_once(
    "lib/domain/model_catalogue.dart",
    "return 'Companion weights; not a standalone chat model';",
    "return 'Companion or calibration data; not a standalone chat model';",
)
replace_once(
    "lib/domain/local_model.dart",
    "r'((^|[_.-])(mmproj|projector|adapter|lora|tokenizer|vocab)([_.-]|$)|\\d{5}-of-\\d{5})'",
    "r'((^|[_.-])(mmproj|projector|adapter|lora|tokenizer|vocab|imatrix|importance|calibration)([_.-]|$)|\\d{5}-of-\\d{5})'",
)

# 2) Activation: technical ping only. Keep pharmacy QA separate from native readiness.
p = Path("lib/domain/local_model_checks.dart")
text = p.read_text()
anchor = "const localSetupCheckVersion = 2;\n"
if text.count(anchor) != 1:
    raise SystemExit("local_model_checks.dart activation anchor mismatch")
text = text.replace(
    anchor,
    anchor
    + "\n/// Technical activation probe only. Pharmacy extraction quality is validated\n"
    + "/// when that feature is used, not confused with whether native inference works.\n"
    + "const localRuntimeProbeSystem =\n"
    + "    'This is a device readiness check. Return one short non-empty reply.';\n"
    + "const localRuntimeProbeInput = 'Reply with READY.';\n\n"
    + "bool passesLocalRuntimeProbe(String output) => output.trim().isNotEmpty;\n",
    1,
)
p.write_text(text)

# 3) Runtime: allow adaptive low-context fallback on memory-constrained phones.
replace_once(
    "lib/services/local_ai_runtime.dart",
    "if (contextTokens < 2048 || contextTokens > 8192)",
    "if (contextTokens < 512 || contextTokens > 8192)",
)

# Replace RAM planner as one authoritative core policy.
p = Path("lib/domain/gguf_metadata.dart")
text = p.read_text()
start = text.index("class LocalExecutionPlan {")
end_marker = "  throw StateError(\n    'Model weights + context cache + scanner reserve do not fit the current memory budget, or its context is below 2048. Choose smaller weights or free memory.',\n  );\n}"
end_start = text.index(end_marker, start)
end = end_start + len(end_marker)
new_planner = '''class LocalExecutionPlan {
  const LocalExecutionPlan({
    required this.contextTokens,
    required this.estimatedBytes,
    required this.estimatedKvBytes,
    required this.geometryKnown,
    this.memoryWarning = false,
    this.budgetBytes,
  });

  final int contextTokens, estimatedBytes, estimatedKvBytes;
  final bool geometryKnown, memoryWarning;
  final int? budgetBytes;

  int get outputTokens => contextTokens <= 512
      ? 160
      : contextTokens <= 1024
      ? 256
      : contextTokens <= 2048
      ? 512
      : contextTokens <= 4096
      ? 1000
      : 1200;

  int get evidenceCharacters => contextTokens <= 512
      ? 700
      : contextTokens <= 1024
      ? 1200
      : contextTokens <= 2048
      ? 1800
      : contextTokens <= 4096
      ? 5000
      : 7000;

  int get inventoryRows => contextTokens <= 1024
      ? 1
      : contextTokens <= 2048
      ? 2
      : contextTokens <= 4096
      ? 3
      : 8;

  int get conversationCharacters => contextTokens <= 1024
      ? 250
      : contextTokens <= 2048
      ? 400
      : 1500;
}

/// Mmap-aware soft admission. Download size is not treated as fully committed
/// heap RAM. The planner chooses a sensible context and warns when tight, while
/// actual llama.cpp model loading remains the final compatibility authority.
LocalExecutionPlan planLocalExecution({
  required int weightBytes,
  required GgufMetadata metadata,
  int? totalMemory,
  int? availableMemory,
  bool lowMemory = false,
  bool phone = false,
  int? contextCeiling,
}) {
  if (weightBytes < 1024) {
    throw StateError('Model weights are incomplete.');
  }

  final totalBudget = totalMemory == null ? null : (totalMemory * .80).floor();
  final availableBudget = availableMemory == null
      ? null
      : availableMemory + (phone ? 512 * _mib : 256 * _mib);
  final budget = totalBudget == null
      ? availableBudget
      : availableBudget == null
      ? totalBudget
      : math.min(totalBudget, availableBudget);

  final contexts = phone
      ? const [4096, 2048, 1024, 512]
      : const [8192, 4096, 2048, 1024, 512];
  LocalExecutionPlan? smallest;
  for (final context in contexts) {
    if (contextCeiling != null && context > contextCeiling) continue;
    if (metadata.contextLength != null && context > metadata.contextLength!) {
      continue;
    }
    final knownKv = metadata.kvBytes(context);
    final kv = knownKv ?? context * 128 * 1024;
    final residentWeights = (weightBytes * (phone ? .55 : .70)).ceil();
    final workspace = phone ? 320 * _mib : 512 * _mib;
    final bytes = residentWeights + (kv * 1.10).ceil() + workspace;
    final plan = LocalExecutionPlan(
      contextTokens: context,
      estimatedBytes: bytes,
      estimatedKvBytes: kv,
      geometryKnown: knownKv != null,
      memoryWarning: lowMemory || (budget != null && bytes > budget),
      budgetBytes: budget,
    );
    smallest = plan;
    if (!plan.memoryWarning) return plan;
  }

  if (smallest != null) return smallest;
  throw StateError(
    'This model exposes less than a 512-token context and cannot be used safely.',
  );
}'''
p.write_text(text[:start] + new_planner + text[end:])

# Data object used by core preflight and UI warning.
p = Path("lib/domain/local_model.dart")
text = p.read_text()
anchor = "enum LocalModelSetupStage {\n"
if text.count(anchor) != 1:
    raise SystemExit("local_model.dart preflight anchor mismatch")
text = text.replace(
    anchor,
    "class LocalModelPreflight {\n"
    "  const LocalModelPreflight({\n"
    "    required this.metadata,\n"
    "    required this.plan,\n"
    "    this.warning,\n"
    "  });\n\n"
    "  final GgufMetadata metadata;\n"
    "  final LocalExecutionPlan plan;\n"
    "  final String? warning;\n"
    "}\n\n"
    + anchor,
    1,
)
p.write_text(text)

# 4) Service core: remote header preflight, soft RAM guard, adaptive load retry,
# debounced memory pressure, and technical activation ping.
p = Path("lib/services/local_ai_service_io.dart")
text = p.read_text()
replace = lambda old, new: (_ for _ in ()).throw(SystemExit("local_ai_service_io.dart patch mismatch")) if text.count(old) != 1 else None

if "import 'dart:typed_data';" not in text:
    if text.count("import 'dart:isolate';\n") != 1:
        raise SystemExit("typed_data import anchor mismatch")
    text = text.replace("import 'dart:isolate';\n", "import 'dart:isolate';\nimport 'dart:typed_data';\n", 1)

old = "  Timer? _idle;\n  bool _observingMemory = false, _releaseForMemory = false;\n"
new = "  Timer? _idle, _memoryPressureTimer;\n  int _memoryPressureSignals = 0;\n  bool _observingMemory = false, _releaseForMemory = false;\n  final Map<String, GgufMetadata> _remotePreflight = {};\n"
if text.count(old) != 1:
    raise SystemExit("service fields anchor mismatch")
text = text.replace(old, new, 1)

old = '''  @override
  void didHaveMemoryPressure() {
    _releaseForMemory = true;
    cancelRequest();
    if (!busy && !_transferring) {
      unawaited(_exclusive((_) async {}).catchError((Object _) {}));
    }
  }
'''
new = '''  @override
  void didHaveMemoryPressure() {
    _memoryPressureSignals++;
    _memoryPressureTimer?.cancel();
    _status = 'Memory pressure detected · checking…';
    notifyListeners();
    _memoryPressureTimer = Timer(const Duration(seconds: 12), () {
      unawaited(_handleSustainedMemoryPressure());
    });
  }

  Future<void> _handleSustainedMemoryPressure() async {
    final signals = _memoryPressureSignals;
    _memoryPressureSignals = 0;
    if (_runtime == null) return;
    try {
      final facts = await _readDeviceInfo();
      final available = facts?['availableMemory'];
      final severe = facts?['lowMemory'] == true ||
          (available is int && available < 384 * 1024 * 1024) ||
          signals >= 3;
      if (!severe) {
        if (ready) _status = 'Local AI Ready';
        notifyListeners();
        return;
      }
      _releaseForMemory = true;
      cancelRequest();
      if (!busy && !_transferring) {
        await _exclusive((_) async {});
      }
    } catch (_) {
      if (ready) _status = 'Local AI Ready';
      notifyListeners();
    }
  }
'''
if text.count(old) != 1:
    raise SystemExit("memory pressure block mismatch")
text = text.replace(old, new, 1)

# Keep helper local to this service file; no wrapper state machine.
class_anchor = "class LocalAiService extends ChangeNotifier with WidgetsBindingObserver {\n"
if text.count(class_anchor) != 1:
    raise SystemExit("LocalAiService class anchor mismatch")
text = text.replace(class_anchor, "int _minInt(int a, int b) => a < b ? a : b;\n\n" + class_anchor, 1)

files_anchor = '''  Future<List<LocalModelFile>> files(String repository) async =>
      (await repositoryFiles(repository)).files;

'''
preflight_code = '''  Future<List<LocalModelFile>> files(String repository) async =>
      (await repositoryFiles(repository)).files;

  Future<LocalModelPreflight> preflight(LocalModelFile model) async {
    model.validate();
    await initialize();
    final metadata = _remotePreflight[model.sha256] ??
        await _inspectRemoteGguf(model);
    _remotePreflight[model.sha256] = metadata;
    final facts = await _checkResources(
      storageBytes: model.bytes,
      weightBytes: model.bytes,
    );
    final plan = planLocalExecution(
      weightBytes: model.bytes,
      metadata: metadata,
      totalMemory: facts?['totalMemory'] as int?,
      availableMemory: facts?['availableMemory'] as int?,
      lowMemory: facts?['lowMemory'] == true,
      phone: Platform.isAndroid || Platform.isIOS,
    );
    return LocalModelPreflight(
      metadata: metadata,
      plan: plan,
      warning: plan.memoryWarning
          ? 'This model is large for the phone right now. Aaris will start with '
                '${plan.contextTokens} tokens and can step down to 512 if memory is tight. '
                'You can still continue.'
          : null,
    );
  }

  Future<GgufMetadata> _inspectRemoteGguf(LocalModelFile model) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 20)
      ..autoUncompress = false;
    var uri = model.downloadUri;
    final limit = _minInt(model.bytes, maxGgufMetadataBytes);
    try {
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
        request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-${limit - 1}');
        final response = await request.close().timeout(
          const Duration(seconds: 40),
        );
        if ([301, 302, 303, 307, 308].contains(response.statusCode)) {
          final next = response.headers.value(HttpHeaders.locationHeader);
          if (next == null) throw StateError('Missing model redirect.');
          await response.drain<void>().timeout(const Duration(seconds: 20));
          uri = uri.resolve(next);
          continue;
        }
        if (response.statusCode != 200 && response.statusCode != 206) {
          throw StateError(
            'Could not inspect this model before download (${response.statusCode}).',
          );
        }
        if (response.statusCode == 206) {
          final range = response.headers.value(HttpHeaders.contentRangeHeader);
          final match = RegExp(r'^bytes 0-(\\d+)/(\\d+)$').firstMatch(range ?? '');
          if (match == null || int.parse(match[2]!) != model.bytes) {
            throw StateError('Model server returned inconsistent file metadata.');
          }
        }
        final builder = BytesBuilder(copy: false);
        await for (final chunk in response.timeout(const Duration(seconds: 45))) {
          final remaining = limit - builder.length;
          if (remaining <= 0) break;
          if (chunk.length <= remaining) {
            builder.add(chunk);
          } else {
            builder.add(Uint8List.fromList(chunk.take(remaining).toList()));
          }
          if (builder.length >= limit) break;
        }
        final prefix = builder.takeBytes();
        if (prefix.length < _minInt(model.bytes, 1024)) {
          throw StateError('Model header download was incomplete.');
        }
        return inspectGgufPrefix(prefix, fileBytes: model.bytes);
      }
      throw StateError('Too many model download redirects.');
    } finally {
      client.close(force: true);
    }
  }

'''
if text.count(files_anchor) != 1:
    raise SystemExit("remote preflight insertion anchor mismatch")
text = text.replace(files_anchor, preflight_code, 1)

# Fresh downloads perform the cached small header preflight before full transfer.
download_anchor = "    final generation = ++_transferGeneration;\n    _transferring = true;\n"
if text.count(download_anchor) < 1:
    raise SystemExit("download start anchor mismatch")
text = text.replace(download_anchor, "    await preflight(model);\n" + download_anchor, 1)

old = '''    if (_runtime?.modelPath != file.path) {
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
'''
new = '''    if (_runtime?.modelPath != file.path) {
      final metadata = await _checkGguf(file);
      final facts = await _checkResources(weightBytes: model.bytes);
      int? ceiling;
      Object? lastError;
      for (var attempt = 0; attempt < 4; attempt++) {
        final plan = planLocalExecution(
          weightBytes: model.bytes,
          metadata: metadata,
          totalMemory: facts?['totalMemory'] as int?,
          availableMemory: facts?['availableMemory'] as int?,
          lowMemory: facts?['lowMemory'] == true,
          phone: Platform.isAndroid || Platform.isIOS,
          contextCeiling: ceiling,
        );
        _executionPlan = plan;
        _runtime ??= LocalAiRuntime();
        _status = 'Local AI · loading · $executionSummary';
        notifyListeners();
        try {
          await _runtime!.load(file.path, contextTokens: plan.contextTokens);
          return;
        } catch (error) {
          lastError = error;
          final lower = error.toString().toLowerCase();
          final memoryLike = plan.memoryWarning ||
              lower.contains('memory') ||
              lower.contains('alloc') ||
              lower.contains('buffer') ||
              lower.contains('kv');
          if (!memoryLike || plan.contextTokens <= 512) rethrow;
          await _release();
          ceiling = plan.contextTokens ~/ 2;
          _status = 'Retrying Local AI with a lighter context…';
          notifyListeners();
        }
      }
      throw StateError('Local model could not load: $lastError');
    }
'''
if text.count(old) != 1:
    raise SystemExit("adaptive load block mismatch")
text = text.replace(old, new, 1)

old = '''      _setupStage = LocalModelSetupStage.testing;
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
'''
new = '''      _setupStage = LocalModelSetupStage.testing;
      _status = 'Testing Local AI…';
      notifyListeners();
      final probe = await _runtime!.generate(
        localRuntimeProbeSystem,
        localRuntimeProbeInput,
        maxTokens: 24,
      );
      _checkRequest(generation);
      if (!passesLocalRuntimeProbe(probe)) {
        throw StateError(
          'The native model loaded but did not return a readiness reply.',
        );
      }
'''
if text.count(old) != 1:
    raise SystemExit("technical activation block mismatch")
text = text.replace(old, new, 1)

# Memory pressure becomes advisory. ABI and storage remain hard gates.
old = '''  if (weightBytes > 0 && info?['lowMemory'] == true) {
    throw StateError(
      'Device memory is under pressure. Close other apps or choose smaller weights.',
    );
  }
  return info;
}
'''
if text.count(old) != 1:
    raise SystemExit("low-memory hard gate mismatch")
text = text.replace(old, "  return info;\n}\n", 1)

old = '''  const channel = MethodChannel('com.aaris.pharmacy/documents');
  final info = await channel.invokeMapMethod<String, dynamic>(
    'localAiDeviceInfo',
  );
'''
if text.count(old) != 1:
    raise SystemExit("device telemetry anchor mismatch")
text = text.replace(old, "  final info = await _readDeviceInfo();\n", 1)

# Add one telemetry function used by both resource checks and debounced pressure logic.
end_anchor = "Future<String> _hash(String path) => Isolate.run(\n"
if text.count(end_anchor) != 1:
    raise SystemExit("device info helper insertion anchor mismatch")
helper = "Future<Map<String, dynamic>?> _readDeviceInfo() async {\n  if (!Platform.isAndroid) return null;\n  return const MethodChannel('com.aaris.pharmacy/documents')\n      .invokeMapMethod<String, dynamic>('localAiDeviceInfo');\n}\n\n"
text = text.replace(end_anchor, helper + end_anchor, 1)
p.write_text(text)

# UI: call core preflight before full download and show a warning, not a blind block.
p = Path("lib/ui/local_models_panel.dart")
text = p.read_text()
old = '''                  onPressed: _locked
                      ? null
                      : () async {
                          if (await _confirm(
                            'Download and use this model?',
                            '${modelSize(file.bytes)} download. Aaris will verify and test it before showing Ready.',
                          )) {
                            await _run(() => local.download(file));
                          }
                        },
'''
new = '''                  onPressed: _locked
                      ? null
                      : () => _run(() async {
                          final check = await local.preflight(file);
                          final message = check.warning ??
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
'''
if text.count(old) != 1:
    raise SystemExit("UI model download action mismatch")
text = text.replace(old, new, 1)

old = '''  if (lower.contains('setup check') || lower.contains('activation'))
    return 'This model could not pass the on-device test. Try another model.';
'''
new = '''  if (lower.contains('architecture metadata') ||
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
'''
if text.count(old) != 1:
    raise SystemExit("friendly Local AI error mapping mismatch")
text = text.replace(old, new, 1)
p.write_text(text)

# Focused regressions: the 4 GB / 2 GB case must be *attemptable*, not guaranteed.
Path("test/local_ai_smart_guard_test.dart").write_text('''import 'package:flutter_test/flutter_test.dart';
import 'package:aaris_pharmacy/domain/gguf_metadata.dart';
import 'package:aaris_pharmacy/domain/local_model.dart';
import 'package:aaris_pharmacy/domain/local_model_checks.dart';
import 'package:aaris_pharmacy/domain/model_catalogue.dart';

void main() {
  test('auxiliary imatrix GGUF is never offered as a standalone model', () {
    expect(isSingleGguf('imatrix-qwen3.8-27b.gguf'), isFalse);
    expect(
      modelArtifactLimitation('imatrix-qwen3.8-27b.gguf'),
      contains('not a standalone'),
    );
  });

  test('runtime readiness is a technical non-empty ping only', () {
    expect(passesLocalRuntimeProbe('READY'), isTrue);
    expect(passesLocalRuntimeProbe(' hello '), isTrue);
    expect(passesLocalRuntimeProbe('   '), isFalse);
  });

  test('4 GB phone can attempt 2 GB weights with a low-context smart guard', () {
    const gib = 1024 * 1024 * 1024;
    const mib = 1024 * 1024;
    const metadata = GgufMetadata(architecture: 'qwen2', tensorCount: 1);
    final plan = planLocalExecution(
      weightBytes: 2 * gib,
      metadata: metadata,
      totalMemory: 4 * gib,
      availableMemory: 1400 * mib,
      lowMemory: true,
      phone: true,
    );
    expect(plan.contextTokens, inInclusiveRange(512, 2048));
    expect(plan.outputTokens, greaterThan(0));
    expect(plan.memoryWarning, isTrue);
  });

  test('planner can step all the way down to 512 tokens', () {
    const metadata = GgufMetadata(
      architecture: 'llama',
      tensorCount: 1,
      contextLength: 512,
    );
    final plan = planLocalExecution(
      weightBytes: 700 * 1024 * 1024,
      metadata: metadata,
      phone: true,
    );
    expect(plan.contextTokens, 512);
  });
}
''')
