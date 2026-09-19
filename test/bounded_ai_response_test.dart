import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import '../lib/services/bounded_ai_response.dart';

void main() {
  test('continuous heartbeat bytes cannot extend the absolute deadline', () async {
    Timer? timer;
    var cancelled = false;
    late StreamController<List<int>> source;
    source = StreamController<List<int>>(
      onListen: () => timer = Timer.periodic(
        const Duration(milliseconds: 5), (_) => source.add([32])),
      onCancel: () { cancelled = true; timer?.cancel(); },
    );
    await expectLater(collectAiResponse(source.stream,
      deadline: const Duration(milliseconds: 60), checkCurrent: () {}),
      throwsA(isA<TimeoutException>()));
    expect(cancelled, isTrue);
  });

  test('oversized unterminated SSE line is stopped before line buffering', () async {
    final lines = utf8.decoder.bind(boundedAiResponse(
      Stream.fromIterable([List.filled(8, 65), List.filled(9, 65)]),
      deadline: const Duration(seconds: 1), maxBytes: 16, checkCurrent: () {},
    )).transform(const LineSplitter());
    await expectLater(lines.toList(), throwsStateError);
  });

  test('UTF-8 bytes split across chunks decode without corruption', () async {
    final encoded = utf8.encode('दवा');
    final result = await collectAiResponse(
      Stream.fromIterable(encoded.map((byte) => [byte])),
      deadline: const Duration(seconds: 1), checkCurrent: () {},
    );
    expect(utf8.decode(result), 'दवा');
  });

  test('a cancelled generation cannot emit its next chunk', () async {
    var current = true;
    Stream<List<int>> source() async* {
      yield [65];
      current = false;
      yield [66];
    }
    await expectLater(collectAiResponse(source(),
      deadline: const Duration(seconds: 1),
      checkCurrent: () { if (!current) throw StateError('Cancelled'); }),
      throwsStateError);
  });
}
