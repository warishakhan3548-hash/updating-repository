import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

const localRuntimeBuild = 'lib_llama_cpp/0.7.3-aaris.2';
const maxGgufMetadataBytes = 32 * 1024 * 1024;
const _mib = 1024 * 1024;

/// Bounded GGUF v2/v3 preflight. It does not load tensors, Jinja templates or
/// executable code, and does not claim the pinned native build supports a family.
class GgufMetadata {
  const GgufMetadata({
    required this.architecture,
    required this.tensorCount,
    this.contextLength,
    this.layers,
    this.embedding,
    this.heads,
    this.kvHeads,
    this.keyLength,
    this.valueLength,
    this.hasChatTemplate = false,
  });
  final String architecture;
  final int tensorCount;
  final int? contextLength,
      layers,
      embedding,
      heads,
      kvHeads,
      keyLength,
      valueLength;
  final bool hasChatTemplate;

  int? kvBytes(int context) {
    final blocks = layers,
        width = embedding,
        count = heads,
        kv = kvHeads ?? heads;
    if (blocks == null ||
        width == null ||
        count == null ||
        kv == null ||
        blocks <= 0 ||
        count <= 0 ||
        width % count != 0 ||
        kv <= 0) {
      return null;
    }
    final key = keyLength ?? width ~/ count,
        value = valueLength ?? width ~/ count;
    // f16 K + V; conservative full attention even for sliding-window models.
    return blocks * kv * (key + value) * context * 2;
  }

  Map<String, Object?> toJson() => {
    'architecture': architecture,
    'tensorCount': tensorCount,
    'contextLength': contextLength,
    'layers': layers,
    'embedding': embedding,
    'heads': heads,
    'kvHeads': kvHeads,
    'keyLength': keyLength,
    'valueLength': valueLength,
    'hasChatTemplate': hasChatTemplate,
  };

  factory GgufMetadata.fromJson(Map<String, dynamic> json) {
    int? number(String key) {
      final n = json[key];
      if (n == null) return null;
      if (n is! int || n < 0 || n > 1000000000) {
        throw const FormatException('Invalid saved model metadata.');
      }
      return n;
    }

    final architecture = json['architecture'];
    if (architecture is! String ||
        !RegExp(r'^[a-zA-Z0-9_-]{1,128}$').hasMatch(architecture)) {
      throw const FormatException('Missing GGUF architecture.');
    }
    return GgufMetadata(
      architecture: architecture,
      tensorCount: number('tensorCount') ?? 0,
      contextLength: number('contextLength'),
      layers: number('layers'),
      embedding: number('embedding'),
      heads: number('heads'),
      kvHeads: number('kvHeads'),
      keyLength: number('keyLength'),
      valueLength: number('valueLength'),
      hasChatTemplate: json['hasChatTemplate'] == true,
    );
  }
}

GgufMetadata inspectGgufPrefix(Uint8List prefix, {required int fileBytes}) {
  final reader = _GgufReader(prefix);
  if (fileBytes < 1024 || reader.u32() != 0x46554747) {
    throw const FormatException('This is not a complete GGUF file.');
  }
  final version = reader.u32();
  if (version != 2 && version != 3) {
    throw const FormatException('Unsupported GGUF container version.');
  }
  final tensors = reader.u64(), count = reader.u64();
  if (tensors <= 0 || tensors > 100000 || count <= 0 || count > 4096) {
    throw const FormatException('Invalid or unsupported GGUF header counts.');
  }
  final values = <String, Object?>{};
  for (var i = 0; i < count; i++) {
    final key = reader.string(maximum: 1024);
    if (values.containsKey(key)) {
      throw const FormatException('Duplicate GGUF metadata key.');
    }
    final type = reader.u32();
    // Only small scalar facts are retained; vocabulary and templates are skipped.
    final value = reader.value(type, retain: key != 'tokenizer.chat_template');
    values[key] = key == 'tokenizer.chat_template' ? type == 8 : value;
  }
  final architecture = values['general.architecture'];
  if (architecture is! String ||
      !RegExp(r'^[a-zA-Z0-9_-]{1,128}$').hasMatch(architecture)) {
    throw const FormatException('GGUF has no valid architecture metadata.');
  }
  if (values['general.type'] == 'adapter' ||
      values['general.type'] == 'projector' ||
      {'clip', 'whisper'}.contains(architecture) ||
      (values['split.count'] is num && (values['split.count'] as num) > 1)) {
    throw const FormatException(
      'These are companion or split weights, not a complete language model.',
    );
  }
  final offsets = <int>[];
  for (var i = 0; i < tensors; i++) {
    reader.string(maximum: 1024);
    final dimensions = reader.u32();
    if (dimensions == 0 || dimensions > 4) {
      throw const FormatException('Invalid GGUF tensor dimensions.');
    }
    for (var d = 0; d < dimensions; d++) {
      final size = reader.u64();
      if (size <= 0 || size > 1000000000) {
        throw const FormatException('Invalid GGUF tensor shape.');
      }
    }
    reader.u32(); // Quantization types evolve; the native loader verifies them.
    offsets.add(reader.u64());
  }
  final alignment = values['general.alignment'] ?? 32;
  if (alignment is! int ||
      alignment <= 0 ||
      alignment > 4096 ||
      alignment & (alignment - 1) != 0) {
    throw const FormatException('Invalid GGUF alignment.');
  }
  final dataStart = ((reader.offset + alignment - 1) ~/ alignment) * alignment;
  if (dataStart >= fileBytes ||
      offsets.any((o) => o % alignment != 0 || o >= fileBytes - dataStart)) {
    throw const FormatException('GGUF tensor data is missing or truncated.');
  }

  int? dimension(String suffix) {
    final value = values['$architecture.$suffix'];
    // Some newer architectures use arrays for per-layer dimensions; report
    // unknown rather than guessing a scalar or rejecting a new model family.
    if (value is! int || value <= 0 || value > 1000000000) return null;
    return value;
  }

  return GgufMetadata(
    architecture: architecture,
    tensorCount: tensors,
    contextLength: dimension('context_length'),
    layers: dimension('block_count'),
    embedding: dimension('embedding_length'),
    heads: dimension('attention.head_count'),
    kvHeads: dimension('attention.head_count_kv'),
    keyLength: dimension('attention.key_length'),
    valueLength: dimension('attention.value_length'),
    hasChatTemplate: values['tokenizer.chat_template'] == true,
  );
}

class _GgufReader {
  _GgufReader(this.bytes) : data = ByteData.sublistView(bytes);
  final Uint8List bytes;
  final ByteData data;
  int offset = 0;

  void need(int length) {
    if (length < 0 ||
        offset + length > bytes.length ||
        offset + length > maxGgufMetadataBytes) {
      throw const FormatException(
        'GGUF metadata is truncated or exceeds the 32 MB inspection limit.',
      );
    }
  }

  int u32() {
    need(4);
    final n = data.getUint32(offset, Endian.little);
    offset += 4;
    return n;
  }

  int u64() {
    need(8);
    final low = data.getUint32(offset, Endian.little),
        high = data.getUint32(offset + 4, Endian.little);
    offset += 8;
    if (high > 0x1fffff) {
      throw const FormatException('GGUF integer exceeds supported range.');
    }
    return high * 4294967296 + low;
  }

  String string({int maximum = 32768}) {
    final size = u64();
    need(size);
    if (size > maximum) {
      throw const FormatException('GGUF string exceeds its inspection limit.');
    }
    final result = utf8.decode(
      Uint8List.sublistView(bytes, offset, offset + size),
    );
    offset += size;
    return result;
  }

  Object? value(int type, {bool retain = false}) {
    const widths = {
      0: 1,
      1: 1,
      2: 2,
      3: 2,
      4: 4,
      5: 4,
      6: 4,
      7: 1,
      10: 8,
      11: 8,
      12: 8,
    };
    if (type == 8) {
      final size = u64();
      need(size);
      final result = retain && size <= 32768
          ? utf8.decode(Uint8List.sublistView(bytes, offset, offset + size))
          : null;
      offset += size;
      return result;
    }
    if (type == 9) {
      final element = u32(), count = u64();
      if (element == 9 ||
          count > 2000000 ||
          (element != 8 && !widths.containsKey(element))) {
        throw const FormatException('Unsupported GGUF metadata array.');
      }
      if (element == 8) {
        for (var i = 0; i < count; i++) {
          final size = u64();
          need(size);
          offset += size;
        }
      } else {
        final size = widths[element]! * count;
        need(size);
        offset += size;
      }
      return null;
    }
    final width = widths[type];
    if (width == null) {
      throw const FormatException('Unknown GGUF metadata value type.');
    }
    need(width);
    Object? result;
    if (retain) {
      result = switch (type) {
        0 => data.getUint8(offset),
        1 => data.getInt8(offset),
        2 => data.getUint16(offset, Endian.little),
        3 => data.getInt16(offset, Endian.little),
        4 => data.getUint32(offset, Endian.little),
        5 => data.getInt32(offset, Endian.little),
        7 => data.getUint8(offset) != 0,
        10 => data.getUint64(offset, Endian.little),
        11 => data.getInt64(offset, Endian.little),
        _ => null,
      };
    }
    if (type == 10 &&
        result is int &&
        (result < 0 || result > 9007199254740991)) {
      throw const FormatException(
        'GGUF metadata integer exceeds supported range.',
      );
    }
    offset += width;
    return result;
  }
}

class LocalExecutionPlan {
  const LocalExecutionPlan({
    required this.contextTokens,
    required this.estimatedBytes,
    required this.estimatedKvBytes,
    required this.geometryKnown,
    required this.memoryWarning,
  });
  final int contextTokens, estimatedBytes, estimatedKvBytes;
  final bool geometryKnown, memoryWarning;

  int get outputTokens => contextTokens <= 2048
      ? 512
      : contextTokens <= 4096
      ? 1000
      : 1200;
  int get evidenceCharacters => contextTokens <= 2048
      ? 1800
      : contextTokens <= 4096
      ? 5000
      : 7000;
  int get inventoryRows => contextTokens <= 2048
      ? 1
      : contextTokens <= 4096
      ? 3
      : 8;
  int get conversationCharacters => contextTokens <= 2048 ? 400 : 1500;
}

/// Conservative planning estimate, not a model-size admission gate.
/// On phones, large GGUF files are mmap-backed by llama.cpp, so file size must
/// not be treated as if every byte were anonymous resident RAM. Device memory
/// facts choose an initial context and surface a warning; the native loader is
/// the final allocation authority and LocalAiRuntime can retry smaller contexts.
LocalExecutionPlan planLocalExecution({
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

  // Relative pressure replaces any fixed "1.5 GB model" admission rule. These
  // signals are warnings/context hints only; they never reject a phone model.
  final modelPressure =
      totalMemory != null && weightBytes >= (totalMemory * .40).floor();
  final availablePressure =
      totalMemory != null &&
      availableMemory != null &&
      availableMemory < (totalMemory * .18).floor();
  final constrainedPhone =
      phone && (lowMemory || modelPressure || availablePressure);
  final highEndPhone =
      phone &&
      !constrainedPhone &&
      totalMemory != null &&
      availableMemory != null &&
      totalMemory >= 8 * 1024 * _mib &&
      availableMemory >= (totalMemory * .30).floor();
  final ultraHighEndPhone =
      highEndPhone &&
      totalMemory! >= 16 * 1024 * _mib &&
      availableMemory! >= (totalMemory * .40).floor();

  final totalBudget = totalMemory == null ? null : (totalMemory * .65).floor();
  final availableBudget = availableMemory == null
      ? null
      : (availableMemory * .8).floor();
  int? budget = totalBudget == null
      ? availableBudget
      : availableBudget == null
      ? totalBudget
      : math.min(totalBudget, availableBudget);

  // Android can reclaim mmap-backed file pages. Keep a reclaim-aware planning
  // floor so the warning estimate does not masquerade as physical allocation.
  if (phone && totalMemory != null) {
    final reclaimAwareFloor = (totalMemory * .52).floor();
    budget = budget == null
        ? reclaimAwareFloor
        : math.max(budget, reclaimAwareFloor);
  }

  final contexts = phone
      ? constrainedPhone
            ? const [2048]
            : ultraHighEndPhone
            ? const [16384, 12288, 8192, 6144, 4096, 3072, 2048]
            : highEndPhone
            ? const [8192, 6144, 4096, 3072, 2048]
            : const [4096, 3072, 2048]
      : const [16384, 12288, 8192, 6144, 4096, 3072, 2048];

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
    final overBudget = budget != null && bytes > budget;
    final warning =
        phone &&
        (lowMemory || modelPressure || availablePressure || overBudget);
    final plan = LocalExecutionPlan(
      contextTokens: context,
      estimatedBytes: bytes,
      estimatedKvBytes: kv,
      geometryKnown: knownKv != null,
      memoryWarning: warning,
    );

    // Phones are native-loader authoritative: use the best context justified by
    // the live device profile and expose pressure as a Smart Warning. If real
    // allocation fails, LocalAiRuntime retries lower contexts. This prevents a
    // pessimistic Dart estimate from hard-blocking capable present/future phones.
    if (phone) return plan;
    if (!overBudget) return plan;
  }

  throw StateError(
    'Model weights + context cache do not fit this non-phone memory budget, or its context is below 2048.',
  );
}
