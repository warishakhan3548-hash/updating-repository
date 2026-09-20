import 'dart:async';
import 'dart:typed_data';

/// Bounds bytes before UTF-8/SSE framing. A provider cannot keep a turn alive
/// with heartbeat chunks or allocate an unlimited unterminated line.
Stream<List<int>> boundedAiResponse(
  Stream<List<int>> source, {
  required Duration deadline,
  required void Function() checkCurrent,
  int maxBytes = 1500000,
}) async* {
  if (deadline <= Duration.zero || maxBytes < 1) {
    throw ArgumentError('Invalid AI response budget.');
  }
  final elapsed = Stopwatch()..start();
  final iterator = StreamIterator<List<int>>(source);
  var count = 0;
  try {
    while (true) {
      checkCurrent();
      final remaining = deadline - elapsed.elapsed;
      if (remaining <= Duration.zero) {
        throw TimeoutException('AI response deadline exceeded.');
      }
      final wait = remaining < const Duration(seconds: 60)
          ? remaining : const Duration(seconds: 60);
      if (!await iterator.moveNext().timeout(wait)) break;
      checkCurrent();
      final chunk = iterator.current;
      if (chunk.length > maxBytes - count) {
        throw StateError('AI response is too large. Ask for fewer changes.');
      }
      count += chunk.length;
      yield chunk;
    }
    checkCurrent();
  } finally {
    elapsed.stop();
    await iterator.cancel();
  }
}

Future<List<int>> collectAiResponse(
  Stream<List<int>> source, {
  required Duration deadline,
  required void Function() checkCurrent,
  int maxBytes = 1500000,
}) async {
  final bytes = BytesBuilder(copy: false);
  await for (final chunk in boundedAiResponse(
    source,
    deadline: deadline,
    checkCurrent: checkCurrent,
    maxBytes: maxBytes,
  )) {
    bytes.add(chunk);
  }
  return bytes.takeBytes();
}
