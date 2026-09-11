import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import '../lib/domain/gguf_metadata.dart';
import '../lib/domain/local_model.dart';
import '../lib/domain/local_model_checks.dart';
import '../lib/services/gguf_inspector.dart';
import '../third_party/lib_llama_cpp/lib/src/context_budget.dart';

Uint8List fixture({
  String architecture = 'future_family',
  int split = 1,
  int tensorOffset = 0,
  int context = 8192,
}) {
  final bytes = BytesBuilder();
  void number(int n, int width) {
    final data = ByteData(width);
    if (width == 8) {
      data.setUint64(0, n, Endian.little);
    } else {
      data.setUint32(0, n, Endian.little);
    }
    bytes.add(data.buffer.asUint8List());
  }

  void string(String value) {
    final raw = utf8.encode(value);
    number(raw.length, 8);
    bytes.add(raw);
  }

  final metadata = <String, Object>{
    'general.architecture': architecture,
    'split.count': split,
    '$architecture.context_length': context,
    '$architecture.block_count': 28,
    '$architecture.embedding_length': 2048,
    '$architecture.attention.head_count': 16,
    '$architecture.attention.head_count_kv': 8,
    'tokenizer.chat_template': '{{ messages }}',
  };
  bytes.add(ascii.encode('GGUF'));
  number(3, 4);
  number(1, 8);
  number(metadata.length, 8);
  for (final e in metadata.entries) {
    string(e.key);
    number(e.value is String ? 8 : 4, 4);
    if (e.value is String) {
      string(e.value as String);
    } else {
      number(e.value as int, 4);
    }
  }
  string('weight');
  number(1, 4);
  number(16, 8);
  number(0, 4);
  number(tensorOffset, 8);
  bytes.add(Uint8List(4096 - bytes.length));
  return bytes.takeBytes();
}

Future<void> main() async {
  var passed = 0;
  void check(bool value, String why) {
    if (!value) throw StateError(why);
    passed++;
  }

  void rejects(void Function() run) {
    try {
      run();
    } on FormatException {
      passed++;
      return;
    } on StateError {
      passed++;
      return;
    }
    throw StateError('Expected preflight failure');
  }

  final bytes = fixture();
  final model = inspectGgufPrefix(bytes, fileBytes: bytes.length);
  check(
    model.architecture == 'future_family' && model.hasChatTemplate,
    'Unknown future architecture is inspectable, not falsely certified',
  );
  check(model.kvBytes(2048) == 28 * 8 * 256 * 2048 * 2, 'GQA K+V estimate');
  check(
    GgufMetadata.fromJson(model.toJson()).contextLength == 8192,
    'Manifest metadata roundtrip',
  );
  for (final bad in [
    fixture(split: 2),
    fixture(architecture: 'clip'),
    fixture(tensorOffset: 999999),
    fixture(tensorOffset: 1),
  ]) {
    rejects(() => inspectGgufPrefix(bad, fileBytes: bad.length));
  }
  for (final size in [0, 3, 10, 23, 100]) {
    rejects(
      () => inspectGgufPrefix(
        Uint8List.sublistView(bytes, 0, size),
        fileBytes: bytes.length,
      ),
    );
  }
  final random = Random(12);
  for (var i = 0; i < 100; i++) {
    final bad = Uint8List.fromList(
      List.generate(64, (_) => random.nextInt(256)),
    );
    rejects(() => inspectGgufPrefix(bad, fileBytes: 4096));
  }

  const gib = 1024 * 1024 * 1024;
  final phone = planLocalExecution(
    weightBytes: gib,
    metadata: model,
    phone: true,
    totalMemory: 4 * gib,
    availableMemory: 3 * gib,
  );
  check(
    phone.contextTokens == 4096 && phone.estimatedBytes > gib,
    'Normal phone starts from the quality-first 4K context',
  );

  final tight = planLocalExecution(
    weightBytes: gib,
    metadata: model,
    phone: true,
    totalMemory: 4 * gib,
    availableMemory: 2500 * 1024 * 1024,
  );
  check(
    tight.contextTokens == 4096 && tight.memoryWarning,
    'Memory estimate warns without pre-blocking or prematurely shrinking the model',
  );

  final fourGbTwoGb = planLocalExecution(
    weightBytes: 2 * gib,
    metadata: model,
    phone: true,
    totalMemory: 4 * gib,
    availableMemory: 700 * 1024 * 1024,
  );
  check(
    fourGbTwoGb.contextTokens == 4096 && fourGbTwoGb.memoryWarning,
    '4 GB phone admits a 2 GB mmap-backed model with a heavy-model warning',
  );
  check(
    fourGbTwoGb.estimatedBytes < 2 * gib,
    'Constrained phone estimates active mmap working set, not the whole GGUF file',
  );

  final veryLargePhone = planLocalExecution(
    weightBytes: 2700 * 1024 * 1024,
    metadata: model,
    phone: true,
    totalMemory: 4 * gib,
    availableMemory: 3 * gib,
  );
  check(
    veryLargePhone.contextTokens == 4096 && veryLargePhone.memoryWarning,
    'Phone RAM estimate warns but does not pre-block a large mmap-backed model',
  );

  final desktop = planLocalExecution(
    weightBytes: 2 * gib,
    metadata: model,
    totalMemory: 16 * gib,
    availableMemory: 12 * gib,
  );
  check(desktop.contextTokens == 8192, 'Larger device retains larger context');

  final pressuredDesktop = planLocalExecution(
    weightBytes: 2 * gib,
    metadata: model,
    totalMemory: 16 * gib,
    availableMemory: gib,
  );
  check(
    pressuredDesktop.contextTokens == 2048 && pressuredDesktop.memoryWarning,
    'Desktop estimates also warn and fall back instead of acting as an admission veto',
  );

  final pressuredPhone = planLocalExecution(
    weightBytes: gib,
    metadata: model,
    phone: true,
    totalMemory: 4 * gib,
    availableMemory: 600 * 1024 * 1024,
    lowMemory: true,
  );
  check(
    pressuredPhone.contextTokens == 4096 && pressuredPhone.memoryWarning,
    'Phone memory pressure is advisory; native allocation decides whether 3K/2K fallback is needed',
  );

  rejects(
    () => planLocalExecution(
      weightBytes: gib,
      metadata: inspectGgufPrefix(fixture(context: 1024), fileBytes: 4096),
    ),
  );

  final legacy = InstalledLocalModel.fromJson({
    'id': 'a' * 64,
    'label': 'Legacy',
    'bytes': 4096,
    'smokeTestPassed': true,
  });
  check(
    legacy.metadata == null && legacy.smokeTestPassed && legacy.loadTestPassed,
    'Old installed manifests migrate to chat-ready',
  );

  validateContextBudget(
    promptTokens: 3072,
    contextTokens: 4096,
    outputTokens: 1024,
  );
  check(true, 'Exact token capacity allowed');
  rejects(
    () => validateContextBudget(
      promptTokens: 3073,
      contextTokens: 4096,
      outputTokens: 1024,
    ),
  );
  rejects(
    () => validateContextBudget(
      promptTokens: 0,
      contextTokens: 4096,
      outputTokens: 1024,
    ),
  );
  rejects(() => validateContextBudget(promptTokens: 4096, contextTokens: 4096));

  final root = await Directory.systemTemp.createTemp('aaris_gguf_test_');
  for (final probe in localSetupChecks) {
    check(
      passesLocalSetup({
        'brand': probe.brand,
        'salt': probe.salt,
        'strength': probe.strength,
        'form': probe.form,
        'expiry': probe.expiry,
      }, probe),
      'Setup contract accepts exact printed facts',
    );
  }

  final combination = localSetupChecks[2];
  check(
    !passesLocalSetup({
      'brand': combination.brand,
      'salt': 'Amoxicillin',
      'strength': '500 mg',
      'form': combination.form,
      'expiry': combination.expiry,
    }, combination),
    'Setup rejects incomplete combination identity',
  );

  final liquid = localSetupChecks[3];
  check(
    !passesLocalSetup({
      'brand': liquid.brand,
      'salt': liquid.salt,
      'strength': '100 mg',
      'form': liquid.form,
      'expiry': liquid.expiry,
    }, liquid),
    'Setup rejects denominator loss',
  );

  final injection = localSetupChecks[5];
  check(
    !passesLocalSetup({
      'brand': injection.brand,
      'salt': injection.salt,
      'strength': injection.strength,
      'form': injection.form,
      'expiry': '2099-12',
    }, injection),
    'Setup rejects source instructions',
  );

  final mixedPack = localSetupChecks[6];
  check(
    !passesLocalSetup({
      'brand': 'CEFIX-O 200',
      'salt': 'Cefixime',
      'strength': '200 mg',
      'form': 'Tablet',
      'expiry': '2028-07',
    }, mixedPack),
    'Setup rejects choosing one identity from a mixed-pack source',
  );

  final download = LocalModelFile(
    repository: 'owner/new-model',
    revision: 'a' * 40,
    filename: 'weights.gguf',
    bytes: 4096,
    sha256: 'b' * 64,
  );
  check(
    LocalModelFile.fromJson(download.toJson()).downloadUri ==
        download.downloadUri,
    'Interrupted download recovers exact immutable source',
  );
  rejects(
    () => LocalModelFile.fromJson({...download.toJson(), 'revision': 'main'}),
  );
  try {
    final file = File('${root.path}/weights.gguf');
    await file.writeAsBytes(bytes);
    check(
      (await inspectGgufFile(file.path)).architecture == model.architecture,
      'Real file inspector runs off-isolate',
    );
  } finally {
    await root.delete(recursive: true);
  }
  stdout.writeln(
    'Model preflight: $passed passed (synthetic GGUF, not native inference).',
  );
}
