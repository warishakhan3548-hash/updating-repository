import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../lib/domain/ai_configuration.dart';
import '../lib/domain/medicine_understanding.dart';
import '../lib/services/cloud_scan_ai_service.dart';

const _config = AiConfiguration(
  provider: 'OpenAI-compatible',
  model: 'test-model',
  endpoint: 'https://provider.example/v1/chat/completions',
  key: 'test-key',
);
const _draft = MedicineScanDraft(
  fields: {},
  rawText: 'Brand name: ALPHA\nParacetamol IP 500 mg\nEXP 09/2028',
  searchKeywords: '',
  frameSequences: [0],
);
http.Response _answer(String text) => http.Response(
  jsonEncode({
    'choices': [
      {
        'message': {'content': text},
      },
    ],
  }),
  200,
);

class _StreamingClient extends http.BaseClient {
  _StreamingClient(this.stream);
  final Stream<List<int>> stream;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async =>
      http.StreamedResponse(stream, 200);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('slow-drip response has a total deadline and bounded retries', () async {
    var calls = 0, cancelled = 0;
    final service = CloudScanAiService(
      responseTimeout: const Duration(milliseconds: 70),
      clientFactory: () {
        calls++;
        Timer? timer;
        late StreamController<List<int>> controller;
        controller = StreamController<List<int>>(
          onListen: () => timer = Timer.periodic(
            const Duration(milliseconds: 10),
            (_) => controller.add([32]),
          ),
          onCancel: () {
            cancelled++;
            timer?.cancel();
          },
        );
        return _StreamingClient(controller.stream);
      },
    );
    final elapsed = Stopwatch()..start();
    await expectLater(
      service.refine(_config, _draft),
      throwsA(isA<TimeoutException>()),
    );
    expect(calls, 2);
    expect(cancelled, 2);
    expect(elapsed.elapsed, lessThan(const Duration(seconds: 3)));
    expect(service.busy, isFalse);
    expect(_draft.fields, isEmpty);
  });
  test(
    'oversized response fails without a retry and releases the lease',
    () async {
      var calls = 0;
      final service = CloudScanAiService(
        clientFactory: () {
          calls++;
          return _StreamingClient(Stream.value(List.filled(1500001, 32)));
        },
      );
      await expectLater(service.refine(_config, _draft), throwsStateError);
      expect(calls, 1);
      expect(service.busy, isFalse);
    },
  );
  test(
    'provider output cannot invent a salt missing from this draft',
    () async {
      final service = CloudScanAiService(
        clientFactory: () => MockClient(
          (_) async => _answer(
            '{"fields":{"salt":{"value":"Metformin","quote":"Metformin IP 500 mg"}}}',
          ),
        ),
      );
      await expectLater(service.refine(_config, _draft), throwsFormatException);
      expect(_draft.salt, isEmpty);
      expect(_draft.rawText, contains('Paracetamol'));
      expect(service.busy, isFalse);
    },
  );
  test(
    'HTTP auth failure preserves deterministic draft and allows later retry',
    () async {
      var calls = 0;
      final service = CloudScanAiService(
        clientFactory: () => MockClient(
          (_) async => calls++ == 0
              ? http.Response('{"error":{"message":"bad key"}}', 401)
              : _answer('{"fields":{}}'),
        ),
      );
      await expectLater(service.refine(_config, _draft), throwsStateError);
      final result = await service.refine(_config, _draft);
      expect(result.rawText, _draft.rawText);
      expect(calls, 2);
    },
  );
  test(
    'scan payload remains explicit OCR only with redirects disabled',
    () async {
      final service = CloudScanAiService(
        clientFactory: () => MockClient((request) async {
          expect(request.url, _config.uri);
          expect(request.followRedirects, isFalse);
          expect(request.body, contains('Paracetamol'));
          expect(request.body, isNot(contains('INVENTORY FACTS')));
          return _answer('{"fields":{}}');
        }),
      );
      expect((await service.refine(_config, _draft)).rawText, _draft.rawText);
    },
  );
}
