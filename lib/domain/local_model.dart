import 'gguf_metadata.dart';

/// Public catalogue facts, not execution authority. Native load is the final
/// architecture/quantization compatibility check for the pinned runtime.
class LocalModelFile {
  const LocalModelFile({
    required this.repository,
    required this.revision,
    required this.filename,
    required this.bytes,
    required this.sha256,
    this.license = 'Check publisher model card',
  });
  final String repository, revision, filename, sha256, license;
  final int bytes;
  String get label => '$repository · ${filename.split('/').last}';

  void validate() {
    if (!RegExp(
          r'^[A-Za-z0-9_][A-Za-z0-9_.-]*/[A-Za-z0-9_][A-Za-z0-9_.-]*$',
        ).hasMatch(repository) ||
        repository.contains('..') ||
        repository.length > 250 ||
        !RegExp(r'^[a-f0-9]{40}$').hasMatch(revision) ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(sha256) ||
        bytes < 1024 ||
        bytes > 128 * 1024 * 1024 * 1024 ||
        !isSingleGguf(filename)) {
      throw const FormatException(
        'Choose a single GGUF weight file with a pinned revision, size and SHA-256.',
      );
    }
  }

  Map<String, Object?> toJson() => {
    'repository': repository,
    'revision': revision,
    'filename': filename,
    'bytes': bytes,
    'sha256': sha256,
    'license': license,
  };

  factory LocalModelFile.fromJson(Map<String, dynamic> json) {
    if ([
          'repository',
          'revision',
          'filename',
          'sha256',
        ].any((k) => json[k] is! String) ||
        json['bytes'] is! int) {
      throw const FormatException('Invalid saved model download.');
    }
    final file = LocalModelFile(
      repository: json['repository'] as String,
      revision: json['revision'] as String,
      filename: json['filename'] as String,
      bytes: json['bytes'] as int,
      sha256: json['sha256'] as String,
      license: json['license'] is String
          ? json['license'] as String
          : 'Check publisher model card',
    );
    file.validate();
    return file;
  }

  Uri get downloadUri {
    validate();
    return Uri(
      scheme: 'https',
      host: 'huggingface.co',
      pathSegments: [
        ...repository.split('/'),
        'resolve',
        revision,
        ...filename.split('/'),
      ],
    );
  }
}

bool isSingleGguf(String name) {
  final lower = name.split('/').last.toLowerCase();
  return lower.endsWith('.gguf') &&
      name.length <= 250 &&
      !name.contains('\\') &&
      !name.contains(RegExp(r'[\x00-\x1f\x7f]')) &&
      !name.startsWith('/') &&
      !name.split('/').any((p) => p.isEmpty || p == '.' || p == '..') &&
      !RegExp(
        r'((^|[_.-])(mmproj|projector|adapter|lora|tokenizer|vocab)([_.-]|$)|\d{5}-of-\d{5})',
      ).hasMatch(lower);
}

class InstalledLocalModel {
  const InstalledLocalModel({
    required this.id,
    required this.label,
    required this.bytes,
    this.source = 'Local import',
    this.smokeTestPassed = false,
    this.metadata,
    this.testedRuntime,
  });
  final String id, label, source;
  final int bytes;
  final bool smokeTestPassed;
  final GgufMetadata? metadata;
  final String? testedRuntime;
  Map<String, Object?> toJson() => {
    'id': id,
    'label': label,
    'bytes': bytes,
    'source': source,
    'smokeTestPassed': smokeTestPassed,
    if (metadata != null) 'metadata': metadata!.toJson(),
    if (testedRuntime != null) 'testedRuntime': testedRuntime,
  };
  factory InstalledLocalModel.fromJson(Map<String, dynamic> json) {
    final id = json['id'], label = json['label'], bytes = json['bytes'];
    if (id is! String ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(id) ||
        label is! String ||
        label.length > 600 ||
        bytes is! int ||
        bytes < 1024) {
      throw const FormatException('Invalid installed model manifest.');
    }
    return InstalledLocalModel(
      id: id,
      label: label,
      bytes: bytes,
      source: json['source'] is String
          ? json['source'] as String
          : 'Local import',
      smokeTestPassed: json['smokeTestPassed'] == true,
      metadata: json['metadata'] is Map
          ? GgufMetadata.fromJson(
              Map<String, dynamic>.from(json['metadata'] as Map),
            )
          : null,
      testedRuntime: json['testedRuntime'] is String
          ? json['testedRuntime'] as String
          : null,
    );
  }
}

String modelSize(int bytes) => bytes >= 1024 * 1024 * 1024
    ? '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB'
    : '${(bytes / (1024 * 1024)).toStringAsFixed(0)} MB';
