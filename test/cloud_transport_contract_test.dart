import 'dart:async';
import 'dart:convert';

import 'package:aaris_pharmacy/domain/ai_protocol.dart';
import 'package:aaris_pharmacy/domain/local_ai_protocol.dart';
import 'package:aaris_pharmacy/domain/medicine_understanding.dart';
import 'package:aaris_pharmacy/services/ai_service.dart';
import 'package:aaris_pharmacy/services/cloud_scan_ai_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _compatible = AiConfiguration(
  provider: 'OpenAI-compatible',
  model: 'test-model',
  endpoint: 'https://provider.example/v1/chat/completions',
  key: 'test-key',
);
const _gemini = AiConfiguration(model: 'gemini-test', key: 'test-key');
const _draft = MedicineScanDraft(
  fields: {},
  rawText: 'Paracetamol IP 650 mg\nMFG 05042025\nEXP 06042028',
  searchKeywords: '',
  frameSequences: [0],
);

http.Response _answer(AiConfiguration config, String text) => http.Response(
  jsonEncode(
    config.provider == 'Gemini'
        ? {
            'candidates': [
              {
                'content': {
                  'parts': [
                    {'text': text},
                  ],
                },
              },
            ],
          }
        : {
            'choices': [
              {
                'message': {'content': text},
              },
            ],
          },
  ),
  200,
  headers: {'content-type': 'application/json'},
);

Future<String> _ask(
  AiService service,
  AiConfiguration config, {
  void Function()? onStreamReset,
}) => service.ask(
  config,
  () => PharmacyExport(
    revision: 3,
    records: const [],
    today: DateTime.utc(2026, 9, 12),
  ),
  'Hello',
  conversation: 'Owner: old question\nAssistant: old answer\nOwner: Hello',
  localContext: LocalInventoryContext(
    records: const [],
    sales: const [],
    revision: 3,
    today: DateTime.utc(2026, 9, 12),
  ),
  onStreamReset: onStreamReset,
);

class _ClosingClient extends MockClient {
  _ClosingClient(
    Future<http.Response> Function(http.Request) handler,
    this.onClose,
  ) : super(handler);
  final void Function() onClose;
  @override
  void close() {
    super.close();
    onClose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final config in [
    _compatible.copyWith(jsonModeEnabled: true),
    _gemini,
  ]) {
    test(
      '${config.provider} chat sends to the explicit endpoint without starting local inference',
      () async {
        var calls = 0;
        final service = AiService(
          clientFactory: () => MockClient((request) async {
            calls++;
            expect(request.followRedirects, isFalse);
            expect(
              request.headers[config.provider == 'Gemini'
                  ? 'x-goog-api-key'
                  : 'Authorization'],
              config.provider == 'Gemini' ? 'test-key' : 'Bearer test-key',
            );
            expect(request.url.host, config.uri.host);
            expect(request.url.toString(), isNot(contains('test-key')));
            if (config.provider == 'Gemini') {
              expect(request.url.path, endsWith(':streamGenerateContent'));
            }
            final body = jsonDecode(request.body) as Map;
            // A stored structured-scan preference must not force chat into JSON.
            expect(config.useJsonMode, isTrue);
            expect(body.containsKey('response_format'), isFalse);
            expect(
              (body['generationConfig'] as Map?)?.containsKey(
                    'responseMimeType',
                  ) ??
                  false,
              isFalse,
            );
            final system = config.provider == 'Gemini'
                ? body['system_instruction']['parts'][0]['text'] as String
                : body['messages'][0]['content'] as String;
            expect(system, contains('CONVERSATION IS THE DEFAULT'));
            expect(system, contains('general knowledge'));
            final input = config.provider == 'Gemini'
                ? body['contents'][0]['parts'][0]['text'] as String
                : body['messages'][1]['content'] as String;
            expect(input, contains('OWNER REQUEST:\nHello'));
            expect(input, isNot(contains('Owner: Hello')));
            return _answer(config, 'Hello! How can I help?');
          }),
        );
        expect(await _ask(service, config), 'Hello! How can I help?');
        expect(calls, 1);
      },
    );

    test('${config.provider} scan sends only bounded OCR evidence', () async {
      var calls = 0;
      final service = CloudScanAiService(
        clientFactory: () => MockClient((request) async {
          calls++;
          expect(request.url, config.uri);
          expect(request.followRedirects, isFalse);
          expect(
            request.headers[config.provider == 'Gemini'
                ? 'x-goog-api-key'
                : 'Authorization'],
            config.provider == 'Gemini' ? 'test-key' : 'Bearer test-key',
          );
          expect(request.body, contains('Paracetamol'));
          expect(request.body, isNot(contains('INVENTORY FACTS')));
          final body = jsonDecode(request.body) as Map;
          if (config.provider == 'Gemini') {
            expect(
              body['generationConfig']['responseMimeType'],
              'application/json',
            );
          } else {
            expect(body['response_format']['type'], 'json_object');
          }
          return _answer(config, '{"fields":{},"ingredients":[]}');
        }),
      );
      final result = await service.refine(config, _draft);
      expect(result.rawText, _draft.rawText);
      expect(service.busy, isFalse);
      expect(calls, 1);
    });
  }

  test('cloud chat emits deterministic minimal-add turn policy after owner override', () async {
    var calls = 0;
    final service = AiService(
      clientFactory: () => MockClient((request) async {
        calls++;
        final body = jsonDecode(request.body) as Map;
        final input = body['messages'][1]['content'] as String;
        expect(input, contains('AARIS TURN POLICY'));
        expect(input, contains('Do not ask again for optional fields'));
        expect(input, contains('Omitted quantity means unknown, never zero'));
        expect(
          input,
          contains('OWNER REQUEST:\nArey jodo aur mujhey kuchh nahi pata'),
        );
        return _answer(_compatible, '{"reply":"Prepared","actions":[]}');
      }),
    );

    final result = await service.ask(
      _compatible,
      () => PharmacyExport(
        revision: 3,
        records: const [],
        today: DateTime.utc(2026, 9, 20),
      ),
      'Arey jodo aur mujhey kuchh nahi pata',
      conversation:
          'Owner: Cefixime 200mg add kar do\n'
          'Assistant: Quantity aur form bata do.',
      localContext: LocalInventoryContext(
        records: const [],
        sales: const [],
        revision: 3,
        today: DateTime.utc(2026, 9, 20),
      ),
    );

    expect(result, contains('Prepared'));
    expect(calls, 1);
  });

  test(
    'chat tolerates a compatible provider that rejects only streaming',
    () async {
      var calls = 0;
      final service = AiService(
        clientFactory: () => MockClient((request) async {
          final body = jsonDecode(request.body) as Map;
          if (calls++ == 0) {
            expect(body['stream'], isTrue);
            return http.Response(
              '{"error":{"message":"stream is not supported"}}',
              400,
            );
          }
          expect(body.containsKey('stream'), isFalse);
          return _answer(_compatible, '{"reply":"buffered","actions":[]}');
        }),
      );
      expect(await _ask(service, _compatible), contains('buffered'));
      expect(calls, 2);
    },
  );

  test(
    'chat owns the turn during retry backoff and cancellation drains it',
    () async {
      var calls = 0;
      final retry = Completer<void>();
      final service = AiService(
        clientFactory: () => MockClient((_) async {
          calls++;
          return http.Response(
            '{"error":{"message":"temporarily unavailable"}}',
            503,
          );
        }),
      );
      final first = _ask(
        service,
        _compatible,
        onStreamReset: () => retry.complete(),
      );
      await retry.future;
      await expectLater(_ask(service, _compatible), throwsStateError);
      final cancelled = expectLater(first, throwsStateError);
      service.cancel();
      await cancelled;
      expect(
        calls,
        1,
        reason: 'Cancelled backoff must never open another transport',
      );
    },
  );

  test(
    'scan owns the turn while its first socket is closed for backoff',
    () async {
      var calls = 0;
      final closed = Completer<void>();
      final service = CloudScanAiService(
        clientFactory: () => _ClosingClient(
          (_) async {
            calls++;
            return http.Response('{"error":{"message":"busy"}}', 503);
          },
          () {
            if (!closed.isCompleted) closed.complete();
          },
        ),
      );
      final first = service.refine(_compatible, _draft);
      await closed.future;
      expect(service.busy, isTrue);
      await expectLater(service.refine(_compatible, _draft), throwsStateError);
      final cancelled = expectLater(first, throwsStateError);
      service.cancel();
      await cancelled;
      expect(service.busy, isFalse);
      expect(calls, 1);
    },
  );

  test(
    'transient scan failure retries once, then a later scan still works',
    () async {
      var calls = 0;
      final service = CloudScanAiService(
        clientFactory: () => MockClient((_) async {
          if (calls++ == 0) return http.Response('{}', 503);
          return _answer(_compatible, '{"fields":{}}');
        }),
      );
      await service.refine(_compatible, _draft);
      expect(calls, 2);
      await service.refine(_compatible, _draft);
      expect(calls, 3);
    },
  );

  test('authentication errors fail fast and release scan ownership', () async {
    var calls = 0;
    final service = CloudScanAiService(
      clientFactory: () => MockClient((_) async {
        calls++;
        return http.Response('{"error":{"message":"invalid key"}}', 401);
      }),
    );
    await expectLater(service.refine(_compatible, _draft), throwsStateError);
    expect(calls, 1);
    expect(service.busy, isFalse);
  });

  test('invalid endpoint sends nothing and releases scan ownership', () async {
    var calls = 0;
    final service = CloudScanAiService(
      clientFactory: () {
        calls++;
        return MockClient((_) async => http.Response('{}', 200));
      },
    );
    await expectLater(
      service.refine(
        _compatible.copyWith(
          endpoint: 'http://provider.example/v1/chat/completions',
        ),
        _draft,
      ),
      throwsFormatException,
    );
    expect(calls, 0);
    expect(service.busy, isFalse);
  });
}
