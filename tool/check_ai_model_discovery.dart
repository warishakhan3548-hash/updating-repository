// Offline executable contract checks. No Flutter runner, APK, network or keys.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../lib/domain/ai_configuration.dart';
import '../lib/domain/ai_discovered_model.dart';
import '../lib/services/ai_model_discovery_service.dart';
import '../lib/services/ai_provider_adapter.dart';

var checks = 0;
void check(bool result, String label) {
  checks++;
  if (!result) throw StateError(label);
}

Future<void> fails(FutureOr<Object?> Function() action, String label) async {
  var rejected = false;
  try {
    await action();
  } catch (_) {
    rejected = true;
  }
  check(rejected, label);
}

http.Response response(Object value, [int status = 200]) => http.Response(
  jsonEncode(value),
  status,
  headers: {'content-type': 'application/json'},
);

Future<void> main() async {
  const gemini = AiConfiguration(key: 'fake-key');
  const openai = AiConfiguration(provider: 'OpenAI', key: 'fake-key');
  const claude = AiConfiguration(provider: 'Anthropic', key: 'fake-key');
  const custom = AiConfiguration(
    provider: 'Compatible',
    key: 'fake-key',
    endpoint: 'https://gateway.example/proxy/v1',
  );
  check(
    gemini.modelsUri.path == '/v1beta/models',
    'Discovery without a model ID',
  );
  check(custom.modelsUri.path == '/proxy/v1/models', 'Proxy prefix retained');
  check(
    custom.copyWith(model: 'owner/model').uri.path ==
        '/proxy/v1/chat/completions',
    'Namespaced model supported',
  );
  await fails(
    () => custom
        .copyWith(modelsEndpoint: 'https://other.example/models')
        .modelsUri,
    'Cross-origin credential protection',
  );
  await fails(
    () => custom.copyWith(endpoint: 'http://gateway.example/v1').modelsUri,
    'HTTPS enforced',
  );
  await fails(
    () => custom
        .copyWith(endpoint: 'https://user:secret@gateway.example/v1')
        .modelsUri,
    'URL credentials blocked',
  );
  await fails(
    () => custom.copyWith(key: 'secret\r\nInjected').modelsUri,
    'Header injection blocked',
  );
  await fails(
    () => AiConfiguration.fromStored('{"key":"secret'),
    'Corrupt credentials fail safely',
  );
  try {
    AiConfiguration.fromStored('{"key":"secret');
  } catch (error) {
    check(!error.toString().contains('secret'), 'Saved secret not echoed');
  }
  final legacy = AiConfiguration.fromJson({
    'provider': 'Compatible',
    'model': 'm',
    'key': 'fake-key',
    'endpoint': 'https://legacy.example/chat',
    'localBrainEnabled': true,
  });
  check(
    legacy.uri.path == '/chat' && legacy.localBrainEnabled,
    'Legacy exact endpoint and local preference preserved',
  );
  final saved = AiConfiguration.fromStored(
    jsonEncode(
      custom
          .copyWith(model: 'm', autoSelectModel: true, localBrainEnabled: true)
          .toJson(),
    ),
  );
  check(
    saved.model == 'm' &&
        saved.autoSelectModel &&
        saved.localBrainEnabled &&
        saved.key == custom.key,
    'Selection and independent route round trip',
  );
  final versioned = AiConfiguration.fromStored(
    jsonEncode({
      'version': 2,
      'provider': 'OpenAI-compatible',
      'model': 'legacy-model',
      'endpoint': 'https://gateway.example/proxy/custom-chat',
      'key': 'fake-key',
      'streamingEnabled': false,
      'jsonModeEnabled': true,
      'responseTimeoutSeconds': 150,
      'localBrainEnabled': true,
    }),
  );
  final roundTrip = AiConfiguration.fromStored(
    jsonEncode(
      versioned
          .copyWith(
            autoSelectModel: true,
            modelsEndpoint: 'https://gateway.example/proxy/catalog',
          )
          .toJson(),
    ),
  );
  check(
    roundTrip.provider == 'Compatible' &&
        !roundTrip.streamingEnabled &&
        roundTrip.useJsonMode &&
        roundTrip.responseTimeout.inSeconds == 150 &&
        roundTrip.localBrainEnabled &&
        roundTrip.autoSelectModel,
    'Version 2 migration retains all transport and routing preferences',
  );
  check(
    roundTrip.uri.path == '/proxy/custom-chat' &&
        roundTrip.modelsUri.path == '/proxy/catalog',
    'Legacy custom chat and new discovery override remain independent',
  );
  for (final invalid in <Map<String, dynamic>>[
    {'version': 99},
    {'streamingEnabled': 'yes'},
    {'jsonModeEnabled': 'yes'},
    {'localBrainEnabled': 'yes'},
    {'autoSelectModel': 'yes'},
    {'responseTimeoutSeconds': 9},
    {'responseTimeoutSeconds': 181},
    {'modelsEndpoint': 42},
  ]) {
    await fails(
      () => AiConfiguration.fromJson(invalid),
      'Invalid stored capability rejected',
    );
  }
  await fails(
    () => openai.copyWith(model: 'm', responseTimeoutSeconds: 0).uri,
    'Configured deadline validated before inference',
  );

  for (final provider in AiProviderDefinition.values.where(
    (p) => !p.isCustom,
  )) {
    final config = AiConfiguration(
      provider: provider.id,
      key: 'fake-key',
      model: 'future-model',
    );
    check(
      config.modelsUri.scheme == 'https',
      '${provider.id} discovery preset',
    );
    check(
      config.uri.host == config.modelsUri.host,
      '${provider.id} model and chat origin',
    );
    check(
      !config.modelsUri.toString().contains('fake-key'),
      '${provider.id} no key in URL',
    );
  }

  final parsed = AiDiscoveredModel.parse({
    'models': [
      {
        'name': 'models/future-chat',
        'displayName': 'Future',
        'supportedGenerationMethods': ['generateContent'],
      },
      {
        'name': 'models/embed-only',
        'supportedGenerationMethods': ['embedContent'],
      },
      {
        'name': 'models/gemini-future-tts',
        'supportedGenerationMethods': ['generateContent'],
      },
      {
        'name': 'models/future-chat',
        'supportedGenerationMethods': ['generateContent'],
      },
      {
        'name': 'models/bad model',
        'supportedGenerationMethods': ['generateContent'],
      },
    ],
  }, gemini);
  check(
    parsed.length == 1 && parsed.single.id == 'future-chat',
    'Gemini methods, TTS filter, IDs and dedup',
  );
  final mixed = AiDiscoveredModel.parse({
    'data': [
      {'id': 'future-unknown'},
      {'id': 'text-embedding-future'},
      {'id': 'retired', 'active': false},
      {
        'id': 'mistral-ocr',
        'capabilities': {'completion_chat': false},
      },
      {
        'id': 'vision-chat',
        'architecture': {
          'input_modalities': ['text', 'image'],
          'output_modalities': ['text'],
        },
      },
      {
        'id': 'image-generation',
        'architecture': {
          'output_modalities': ['image'],
        },
      },
    ],
  }, openai);
  check(
    mixed.length == 2,
    'Filter non-text and inactive while keeping future candidates',
  );
  check(
    mixed.last.vision == true && mixed.last.textConfirmed,
    'Explicit capabilities retained',
  );
  check(
    !mixed.first.textConfirmed && mixed.first.vision == null,
    'Unknown capabilities stay unknown',
  );
  check(
    AiDiscoveredModel.choose(mixed, 'future-unknown')?.id == 'future-unknown',
    'Refresh keeps selection',
  );

  var pages = 0;
  final paged = AiModelDiscoveryService(
    clientFactory: () => MockClient((request) async {
      check(!request.followRedirects, 'No redirects');
      check(
        request.headers['x-goog-api-key'] == 'fake-key',
        'Gemini header authentication',
      );
      pages++;
      if (pages == 1)
        return response({
          'models': [
            {'name': 'models/one'},
          ],
          'nextPageToken': 'token',
        });
      check(
        request.url.queryParameters['pageToken'] == 'token',
        'Gemini cursor',
      );
      return response({
        'models': [
          {'name': 'models/two'},
          {'name': 'models/one'},
        ],
      });
    }),
  );
  check(
    (await paged.discover(gemini)).length == 2 && pages == 2,
    'All pages merged without duplicates',
  );
  var anthropicPages = 0;
  final anthropic = AiModelDiscoveryService(
    clientFactory: () => MockClient((request) async {
      anthropicPages++;
      check(request.headers['x-api-key'] == 'fake-key', 'Anthropic key header');
      check(
        request.headers['anthropic-version'] == '2023-06-01',
        'Anthropic version',
      );
      if (anthropicPages == 1)
        return response({
          'data': [
            {'id': 'first'},
          ],
          'has_more': true,
          'last_id': 'first',
        });
      check(
        request.url.queryParameters['after_id'] == 'first',
        'Anthropic cursor',
      );
      return response({
        'data': [
          {'id': 'second'},
        ],
        'has_more': false,
      });
    }),
  );
  check((await anthropic.discover(claude)).length == 2, 'Anthropic pagination');
  var attempts = 0;
  final repeating = AiModelDiscoveryService(
    clientFactory: () => MockClient((_) async {
      attempts++;
      return response({
        'data': [
          {'id': 'first'},
        ],
        'has_more': true,
        'last_id': 'repeat',
      });
    }),
  );
  await fails(() => repeating.discover(openai), 'Repeated cursor rejected');
  check(attempts == 2, 'Pagination terminates');
  final tooBig = AiModelDiscoveryService(
    maxBytes: 12,
    clientFactory: () => MockClient(
      (_) async => response({
        'data': [
          {'id': 'too-big'},
        ],
      }),
    ),
  );
  await fails(() => tooBig.discover(openai), 'Response cap enforced');
  for (final status in [401, 403, 404, 429, 302, 500]) {
    var calls = 0;
    final failing = AiModelDiscoveryService(
      clientFactory: () => MockClient((_) async {
        calls++;
        return response({
          'error': {'message': 'echo fake-key'},
        }, status);
      }),
    );
    try {
      await failing.discover(openai);
      throw StateError('Expected rejection');
    } on AiConnectionFailure catch (error) {
      check(
        !error.message.contains('fake-key'),
        'HTTP $status secret redacted',
      );
    }
    check(calls == 1, 'HTTP $status no duplicate request');
  }
  for (final config in [
    gemini.copyWith(model: 'future'),
    openai.copyWith(model: 'future'),
    claude.copyWith(model: 'future'),
  ]) {
    final adapter = AiProviderAdapter.forConfiguration(config);
    final envelope = config.protocol == AiProviderProtocol.gemini
        ? {
            'candidates': [
              {
                'content': {
                  'parts': [
                    {'text': '{"ok":true}'},
                  ],
                },
              },
            ],
          }
        : config.protocol == AiProviderProtocol.anthropicMessages
        ? {
            'content': [
              {'type': 'text', 'text': '{"ok":true}'},
            ],
          }
        : {
            'choices': [
              {
                'message': {'content': '{"ok":true}'},
              },
            ],
          };
    final probe = AiModelDiscoveryService(
      clientFactory: () => MockClient((request) async {
        check(
          request.method == 'POST' && request.url == config.uri,
          '${config.provider} real inference test',
        );
        check(
          !request.body.contains('inventory') &&
              request.body.contains('Connection test'),
          '${config.provider} no inventory in test',
        );
        return response(envelope);
      }),
    );
    await probe.testModel(config);
    check(
      adapter.decode(utf8.encode(jsonEncode(envelope))) == '{"ok":true}',
      '${config.provider} shared adapter response',
    );
  }
  final adapter = AiProviderAdapter.forConfiguration(
    claude.copyWith(model: 'future'),
  );
  check(
    adapter.delta({
      'type': 'content_block_delta',
      'delta': {'type': 'thinking_delta', 'thinking': 'private'},
    }).isEmpty,
    'Reasoning excluded',
  );
  check(
    adapter.delta({
          'type': 'content_block_delta',
          'delta': {'type': 'text_delta', 'text': 'hello'},
        }) ==
        'hello',
    'Claude streaming works',
  );
  check(adapter.terminal({'type': 'message_stop'}), 'Claude stream terminal');

  final delayed = Completer<http.Response>();
  final cancelled = AiModelDiscoveryService(
    clientFactory: () => MockClient((_) => delayed.future),
  );
  final old = cancelled.discover(openai);
  cancelled.cancel();
  delayed.complete(
    response({
      'data': [
        {'id': 'stale'},
      ],
    }),
  );
  await fails(() => old, 'Cancelled response cannot return a catalog');
  final timeout = AiModelDiscoveryService(
    timeout: const Duration(milliseconds: 20),
    clientFactory: () => MockClient((_) => Completer<http.Response>().future),
  );
  await fails(() => timeout.discover(openai), 'Total timeout releases request');
  stdout.writeln('PASS: $checks offline model-discovery and adapter checks.');
}
