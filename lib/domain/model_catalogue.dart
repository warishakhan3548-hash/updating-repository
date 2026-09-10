import 'local_model.dart';

/// Discovery is extensible metadata, never permission to execute a model.
enum ModelSort {
  popular('downloads', 'Popular'),
  updated('lastModified', 'Recently updated'),
  newest('createdAt', 'New releases'),
  trending('trendingScore', 'Trending');

  const ModelSort(this.apiValue, this.label);
  final String apiValue, label;
}

class ModelSearchPage {
  ModelSearchPage(
    Iterable<String> repositories, {
    this.next,
    this.cached = false,
  }) : repositories = List.unmodifiable(repositories);
  final List<String> repositories;
  final Uri? next;
  final bool cached;
}

/// Accept an exact Hub repository or file URL without trusting an arbitrary
/// download host. Named refs are resolved to an immutable SHA by the provider.
class ModelRepositoryLocation {
  const ModelRepositoryLocation(this.repository, {this.ref, this.filename});
  final String repository;
  final String? ref, filename;

  static ModelRepositoryLocation? parse(String input) {
    final text = input.trim();
    if (isModelRepository(text)) return ModelRepositoryLocation(text);
    if (!text.contains('://')) return null;
    final uri = Uri.tryParse(text);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host != 'huggingface.co' ||
        uri.userInfo.isNotEmpty ||
        uri.port != 443) {
      throw const FormatException('Use a https://huggingface.co model link.');
    }
    final parts = uri.pathSegments.toList();
    if (parts.isNotEmpty && parts.last.isEmpty) parts.removeLast();
    if (parts.length < 2 || !isModelRepository('${parts[0]}/${parts[1]}')) {
      throw const FormatException('Use a publisher/repository model link.');
    }
    final repository = '${parts[0]}/${parts[1]}';
    if (parts.length == 2) return ModelRepositoryLocation(repository);
    if (parts.length < 4 ||
        !{'tree', 'blob', 'resolve'}.contains(parts[2]) ||
        !RegExp(r'^[A-Za-z0-9_.-]{1,128}$').hasMatch(parts[3])) {
      throw const FormatException(
        'Unsupported model link. Use its repository page.',
      );
    }
    final filename = parts.length > 4 ? parts.skip(4).join('/') : null;
    if (filename != null && !isSafeModelPath(filename)) {
      throw const FormatException('Invalid model file path.');
    }
    return ModelRepositoryLocation(
      repository,
      ref: parts[3],
      filename: parts[2] == 'tree' ? null : filename,
    );
  }
}

bool isModelRepository(String value) =>
    value.length <= 250 &&
    RegExp(r'^[A-Za-z0-9_][A-Za-z0-9_.-]*/[A-Za-z0-9_][A-Za-z0-9_.-]*$')
        .hasMatch(value) &&
    !value.split('/').any((p) => p.contains('..'));

bool isSafeModelPath(String name) =>
    name.isNotEmpty &&
    name.length <= 250 &&
    !name.contains('\\') &&
    !name.contains(RegExp(r'[\x00-\x1f\x7f]')) &&
    !name.split('/').any((p) => p.isEmpty || p == '.' || p == '..');

/// A cursor is supplied by the Hub, not a free-form URL to fetch. Keep it on
/// exactly the read-only model-list endpoint, even when cached or replayed.
Uri validateModelCursor(Uri uri) {
  if (uri.toString().length > 8192 ||
      uri.scheme != 'https' ||
      uri.host != 'huggingface.co' ||
      uri.port != 443 ||
      uri.userInfo.isNotEmpty ||
      uri.path != '/api/models' ||
      uri.fragment.isNotEmpty) {
    throw const FormatException('Invalid model catalogue cursor.');
  }
  return uri;
}

Uri? nextModelPage(String? link) {
  if (link == null) return null;
  for (final match in RegExp(
    r'<([^>]+)>\s*;\s*rel="?([^",;]+)"?',
  ).allMatches(link)) {
    if (match[2]!.split(' ').contains('next')) {
      return validateModelCursor(Uri.parse(match[1]!));
    }
  }
  return null;
}

class ModelRepositoryFiles {
  ModelRepositoryFiles({
    required this.repository,
    required this.revision,
    required Iterable<LocalModelFile> files,
    this.unavailable = const {},
    this.gated = false,
    this.cached = false,
  }) : files = List.unmodifiable(files);
  final String repository, revision;
  final List<LocalModelFile> files;
  final Map<String, int> unavailable;
  final bool gated, cached;
}

/// Explain unsupported artifacts instead of silently presenting an empty repo.
String? modelArtifactLimitation(String name) {
  final base = name.split('/').last.toLowerCase();
  if (!isSafeModelPath(name)) return 'Invalid file path';
  if (!base.endsWith('.gguf')) {
    if (base.endsWith('.safetensors') ||
        base.endsWith('.onnx') ||
        base.endsWith('.tflite') ||
        base.endsWith('.task') ||
        base.endsWith('.bin')) {
      return 'Needs another runtime or GGUF conversion';
    }
    return 'Non-model file';
  }
  if (RegExp(r'\d{5}-of-\d{5}').hasMatch(base))
    return 'Split GGUF not supported yet';
  if (RegExp(
    r'(^|[_.-])(mmproj|projector|adapter|lora|tokenizer|vocab|imatrix|importance|calibration)([_.-]|$)',
  ).hasMatch(base))
    return 'Companion or calibration data; not a standalone chat model';
  return null;
}
