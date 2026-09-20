import 'dart:async';

import 'package:aaris_pharmacy/domain/ai_configuration.dart';
import 'package:aaris_pharmacy/domain/medicine_understanding.dart';
import 'package:aaris_pharmacy/services/bounded_ai_response.dart';
import 'package:aaris_pharmacy/services/cloud_scan_ai_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _configuration = AiConfiguration(
  provider: 'OpenAI-compatible',
  model: 'test-model',
  endpoint: 'https://provider.example/v1/chat/completions',
  key: 'test-key',
);

const _draft = MedicineScanDraft(
  fields: {},
  rawText: 'Cefixime Tablets 200 mg EXP 05/2028',
  searchKeywords: 'Cefixime',
  frameSequences: [0],
);

void main() {
  test('response deadline is monotonic across sequential stages', () async {
    final deadline = AiResponseDeadline(const Duration(milliseconds: 400));
    await deadline.wait(Future<void>.delayed(const Duration(milliseconds: 240)));

    final watch = Stopwatch()..start();
    await expectLater(
      deadline.wait(Future<void>.delayed(const Duration(milliseconds: 320))),
      throwsA(isA<TimeoutException>()),
    );
    watch.stop();

    expect(deadline.expired, isTrue);
    expect(watch.elapsed, lessThan(const Duration(milliseconds: 260)));
  });

  test('cloud scan deadline includes waiting for response headers', () async {
    var calls = 0;
    final never = Completer<http.Response>();
    final service = CloudScanAiService(
      clientFactory: () => MockClient((_) {
        calls++;
        return never.future;
      }),
      responseTimeout: const Duration(milliseconds: 80),
    );

    final watch = Stopwatch()..start();
    await expectLater(
      service
          .refine(_configuration, _draft)
          .timeout(const Duration(seconds: 1)),
      throwsA(isA<TimeoutException>()),
    );
    watch.stop();

    expect(watch.elapsed, lessThan(const Duration(milliseconds: 500)));
    expect(calls, 1);
    expect(service.busy, isFalse);
  });

  test('transient retry backoff cannot restart the scan deadline', () async {
    var calls = 0;
    final service = CloudScanAiService(
      clientFactory: () => MockClient((_) async {
        calls++;
        return http.Response('{}', 503);
      }),
      responseTimeout: const Duration(milliseconds: 120),
    );

    final watch = Stopwatch()..start();
    await expectLater(
      service
          .refine(_configuration, _draft)
          .timeout(const Duration(seconds: 1)),
      throwsA(isA<TimeoutException>()),
    );
    watch.stop();

    expect(watch.elapsed, lessThan(const Duration(milliseconds: 500)));
    expect(calls, 1);
    expect(service.busy, isFalse);
  });
}
