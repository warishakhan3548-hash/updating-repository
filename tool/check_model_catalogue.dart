import 'dart:io';

import '../lib/domain/local_model.dart';
import '../lib/domain/model_catalogue.dart';
import '../lib/services/model_catalogue_service.dart';

Future<void> main() async {
  var passed = 0;
  void check(bool value, String message) {
    if (!value) throw StateError(message);
    passed++;
  }

  void rejects(void Function() run) {
    try {
      run();
    } on FormatException {
      passed++;
      return;
    }
    throw StateError('Expected rejection');
  }

  check(
    ModelRepositoryLocation.parse('owner/new-model')!.repository ==
        'owner/new-model',
    'Exact untagged repo',
  );
  final file = ModelRepositoryLocation.parse(
    'https://huggingface.co/owner/repo/blob/v2/nested/model.gguf?download=true',
  )!;
  check(
    file.ref == 'v2' && file.filename == 'nested/model.gguf',
    'Pinned file link',
  );
  check(ModelRepositoryLocation.parse('family name') == null, 'Keyword query');
  for (final link in [
    'https://huggingface.co.evil.test/a/b',
    'http://huggingface.co/a/b',
    'https://user@huggingface.co/a/b',
    'https://huggingface.co:444/a/b',
  ]) {
    rejects(() => ModelRepositoryLocation.parse(link));
  }
  check(
    isSingleGguf('lora-research/Flora-chat.gguf'),
    'Folder and family substrings do not exclude full weights',
  );
  check(!isSingleGguf('bad\u0000.gguf'), 'Control character blocked');
  check(
    modelArtifactLimitation('nested/mmproj-Q8.gguf')!.contains('Companion'),
    'Projector explanation',
  );
  check(
    modelArtifactLimitation('x-00001-of-00002.gguf')!.contains('Split'),
    'Shard explanation',
  );
  check(
    modelArtifactLimitation('weights.safetensors')!.contains('runtime'),
    'Alternate format explanation',
  );
  final cursor = Uri.https('huggingface.co', '/api/models', {'cursor': 'next'});
  check(nextModelPage('<$cursor>; rel="next"') == cursor, 'Link pagination');
  rejects(() => nextModelPage('<https://evil.test/api/models>; rel="next"'));
  rejects(
    () => validateModelCursor(Uri.parse('https://huggingface.co/api/other')),
  );
  var calls = 0;
  var now = DateTime.utc(2026, 9, 9);
  var offline = false;
  final uris = <Uri>[];
  final catalog = HuggingFaceModelCatalogue(
    clock: () => now,
    fetch: (uri) async {
      calls++;
      uris.add(uri);
      if (offline) throw const SocketException('offline');
      if (uri.path == '/api/models')
        return CatalogueResponse(
          [
            {
              'id': uri.queryParameters['cursor'] == null
                  ? 'new/family'
                  : 'other/model',
            },
            {'id': 'new/family'},
            {'id': '../invalid'},
            {'id': 2},
          ],
          link: uri.queryParameters['cursor'] == null
              ? '<$cursor>; rel="next"'
              : null,
        );
      return CatalogueResponse({
        'sha': 'a' * 40,
        'gated': false,
        'cardData': {'license': 'apache-2.0'},
        'siblings': [
          {
            'rfilename': 'nested/model.gguf',
            'lfs': {'size': 4096, 'sha256': 'b' * 64},
          },
          {'rfilename': 'no-hash.gguf'},
          {'rfilename': 'model-00001-of-00002.gguf'},
          {'rfilename': 'mmproj-Q8.gguf'},
          {'rfilename': 'weights.safetensors'},
          {'rfilename': 'README.md'},
        ],
      });
    },
  );
  final first = await catalog.search('', sort: ModelSort.newest);
  check(
    first.repositories.length == 1 && first.next == cursor,
    'Deduplication and pagination',
  );
  check(
    uris.last.queryParameters['sort'] == 'createdAt',
    'Future models not popularity locked',
  );
  final second = await catalog.search('', cursor: first.next);
  check(
    second.repositories.contains('other/model') && second.next == null,
    'Next page reached',
  );
  final detail = await catalog.files(
    const ModelRepositoryLocation('owner/repo'),
  );
  check(
    detail.files.length == 1 && detail.unavailable.length == 4,
    'Actionable file explanations',
  );
  check(
    detail.files.single.downloadUri.path.contains('a' * 40),
    'Download pins immutable revision',
  );
  final exact = await catalog.files(file);
  check(
    exact.files.length == 1 && uris.last.path.endsWith('/revision/v2'),
    'URL revision resolved',
  );
  final before = calls;
  check(
    (await catalog.files(file)).cached && calls == before,
    'Bounded metadata cache hit',
  );
  now = now.add(const Duration(minutes: 6));
  offline = true;
  check(
    (await catalog.files(file)).cached && calls == before + 1,
    'Marked stale metadata fallback',
  );
  var largeCalls = 0;
  final large = HuggingFaceModelCatalogue(
    fetch: (_) async {
      largeCalls++;
      return const CatalogueResponse([
        {'id': 'owner/model'},
      ], payloadBytes: 600000);
    },
  );
  await large.search('large');
  await large.search('large');
  check(
    largeCalls == 2,
    'Large parsed catalogues do not accumulate in phone cache',
  );
  stdout.writeln(
    'Model catalogue: $passed passed (fixture transport, no live model download).',
  );
}
