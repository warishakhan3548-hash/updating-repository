import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../domain/local_model.dart';
import '../domain/model_catalogue.dart';

class CatalogueResponse {
  const CatalogueResponse(this.body, {this.link});
  final Object? body;
  final String? link;
}

/// Additional metadata providers can implement this boundary without gaining
/// inventory access or permission to install code. One provider ships today.
abstract interface class ModelCatalogueProvider {
  Future<ModelSearchPage> search(String query, {ModelSort sort, Uri? cursor});
  Future<ModelRepositoryFiles> files(ModelRepositoryLocation location);
}

typedef CatalogueFetch = Future<CatalogueResponse> Function(Uri uri);

class HuggingFaceModelCatalogue implements ModelCatalogueProvider {
  HuggingFaceModelCatalogue({CatalogueFetch? fetch, DateTime Function()? clock})
    : _fetch = fetch ?? _publicMetadata,
      _clock = clock ?? DateTime.now;
  final CatalogueFetch _fetch;
  final DateTime Function() _clock;
  // Bounded in-memory cache contains public metadata only, never pharmacy data.
  final _cache = <String, (DateTime, CatalogueResponse)>{};

  Future<(CatalogueResponse, bool)> _get(Uri uri) async {
    final key = uri.toString(), saved = _cache[uri.toString()];
    if (saved != null &&
        _clock().difference(saved.$1) < const Duration(minutes: 5)) {
      return (saved.$2, true);
    }
    try {
      final response = await _fetch(uri);
      if (_cache.length >= 12) _cache.remove(_cache.keys.first);
      _cache[key] = (_clock(), response);
      return (response, false);
    } on IOException {
      if (saved != null) return (saved.$2, true);
      rethrow;
    } on TimeoutException {
      if (saved != null) return (saved.$2, true);
      rethrow;
    }
  }

  @override
  Future<ModelSearchPage> search(
    String query, {
    ModelSort sort = ModelSort.popular,
    Uri? cursor,
  }) async {
    final clean = query.trim();
    if (clean.length > 100)
      throw const FormatException('Use at most 100 search characters.');
    final uri = cursor == null
        ? Uri.https('huggingface.co', '/api/models', {
            if (clean.isNotEmpty) 'search': clean,
            'filter': 'gguf',
            'limit': '50',
            'sort': sort.apiValue,
            'direction': '-1',
          })
        : validateModelCursor(cursor);
    final (response, cached) = await _get(uri);
    final json = response.body;
    if (json is! List) throw const FormatException('Invalid model catalogue.');
    final ids = json
        .whereType<Map>()
        .map((m) => m['id'])
        .whereType<String>()
        .where(isModelRepository)
        .toSet();
    final next = nextModelPage(response.link);
    return ModelSearchPage(
      ids,
      next: next == uri ? null : next,
      cached: cached,
    );
  }

  @override
  Future<ModelRepositoryFiles> files(ModelRepositoryLocation location) async {
    if (!isModelRepository(location.repository)) {
      throw const FormatException('Use publisher/repository.');
    }
    final (response, cached) = await _get(
      Uri(
        scheme: 'https',
        host: 'huggingface.co',
        pathSegments: [
          'api',
          'models',
          ...location.repository.split('/'),
          if (location.ref != null) ...['revision', location.ref!],
        ],
        queryParameters: {'blobs': 'true'},
      ),
    );
    final json = response.body;
    if (json is! Map ||
        json['siblings'] is! List ||
        json['sha'] is! String ||
        !RegExp(r'^[a-f0-9]{40}$').hasMatch(json['sha'] as String)) {
      throw const FormatException('Pinned model file metadata is unavailable.');
    }
    final card = json['cardData'];
    final license = card is Map && card['license'] is String
        ? (card['license'] as String).substring(
            0,
            (card['license'] as String).length.clamp(0, 200),
          )
        : 'Check publisher model card';
    final files = <LocalModelFile>[], excluded = <String, int>{};
    void exclude(String reason) =>
        excluded.update(reason, (n) => n + 1, ifAbsent: () => 1);
    for (final item in (json['siblings'] as List).whereType<Map>()) {
      final name = item['rfilename'];
      if (name is! String ||
          (location.filename != null && name != location.filename))
        continue;
      final reason = modelArtifactLimitation(name);
      if (reason != null) {
        if (reason != 'Non-model file') exclude(reason);
        continue;
      }
      final lfs = item['lfs'];
      final size = lfs is Map ? lfs['size'] ?? item['size'] : item['size'];
      final hash = lfs is Map ? lfs['sha256'] : null;
      if (size is! int || hash is! String) {
        exclude('Missing size or SHA-256');
        continue;
      }
      final file = LocalModelFile(
        repository: location.repository,
        revision: json['sha'] as String,
        filename: name,
        bytes: size,
        sha256: hash,
        license: license,
      );
      try {
        file.validate();
        files.add(file);
      } on FormatException {
        exclude('Invalid or oversized model manifest');
      }
    }
    files.sort((a, b) => a.bytes.compareTo(b.bytes));
    return ModelRepositoryFiles(
      repository: location.repository,
      revision: json['sha'] as String,
      files: files,
      unavailable: Map.unmodifiable(excluded),
      cached: cached,
      gated: json['gated'] != null && json['gated'] != false,
    );
  }
}

Future<CatalogueResponse> _publicMetadata(Uri uri) async {
  // The provider builds every metadata URL. No credentials, cookies, prompts,
  // inventory or remote-code execution exist in this transport.
  if (uri.scheme != 'https' ||
      uri.host != 'huggingface.co' ||
      uri.userInfo.isNotEmpty ||
      uri.port != 443 ||
      !uri.path.startsWith('/api/models')) {
    throw const FormatException('Invalid catalogue endpoint.');
  }
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
  try {
    return await (() async {
      final request = await client.getUrl(uri);
      request.followRedirects = false;
      final response = await request.close();
      if (response.statusCode != 200) {
        throw HttpException(
          response.statusCode == 429
              ? 'Model catalogue rate limited. Wait and try again.'
              : 'Catalogue unavailable (${response.statusCode}); public, ungated models only.',
        );
      }
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in response) {
        if (bytes.length + chunk.length > 4 * 1024 * 1024) {
          throw const FormatException('Catalogue response exceeds 4 MB.');
        }
        bytes.add(chunk);
      }
      return CatalogueResponse(
        jsonDecode(utf8.decode(bytes.takeBytes())),
        link: response.headers.value('link'),
      );
    })().timeout(const Duration(seconds: 30));
  } finally {
    client.close(force: true);
  }
}
