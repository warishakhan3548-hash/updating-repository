// Focused lifecycle checks; no device, GGUF inference or accuracy benchmark.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../lib/domain/local_scan_request.dart';
import '../lib/domain/medicine_intake.dart';
import '../lib/domain/medicine_understanding.dart';
import '../lib/services/local_ai_runtime.dart';
import 'check_local_chat_response.dart' as fixture;

Future<void> main() async {
  var passed = 0;
  void check(bool value, String message) {
    if (!value) throw StateError(message);
    passed++;
  }

  Future<Object?> failure(Future<Object?> work) =>
      work.then<Object?>((_) => null, onError: (Object error) => error);
  Object? thrown(void Function() work) {
    try {
      work();
      return null;
    } catch (error) {
      return error;
    }
  }

  const draft = MedicineScanDraft(
    fields: {},
    rawText: 'Cefixime Tablets 200 mg EXP 05/2028',
    searchKeywords: 'Cefixime',
    frameSequences: [0],
  );
  MedicineIntakeJob job({String status = 'reasoning', bool hasDraft = true}) =>
      MedicineIntakeJob(
        id: 'a' * 32,
        kind: 'evidence',
        title: 'Capture',
        status: status,
        drafts: hasDraft ? [draft] : [],
      );

  final pending = job();
  check(pending.canReview, 'A saved draft is reviewable while AI is pending');
  final originalJson = jsonEncode(pending.drafts.single.toMessage());
  check(pending.finishOptionalReview(), 'Next ends optional review');
  check(pending.ready && pending.canReview, 'Next makes a usable review state');
  check(pending.aiIndex == 0, 'Next does not pretend that AI completed');
  check(
    jsonEncode(pending.drafts.single.toMessage()) == originalJson,
    'Next preserves the exact evidence and extracted fields',
  );
  check(
    !pending.finishOptionalReview(),
    'A second Next does not change the job',
  );
  final restored = MedicineIntakeJob.fromJson(
    jsonDecode(jsonEncode(pending.toJson())) as Map<String, dynamic>,
  );
  check(
    restored.ready && restored.canReview,
    'Review state survives persistence',
  );
  check(restored.aiIndex == 0, 'Recovery does not resume skipped AI');

  for (final status in ['queued', 'processing', 'failed', 'review']) {
    final other = job(status: status);
    check(
      !other.finishOptionalReview(),
      '$status is not prematurely completed',
    );
    check(other.status == status, '$status keeps its original worker state');
  }
  final empty = job(hasDraft: false);
  check(!empty.canReview, 'No empty medicine can be previewed');
  check(
    !empty.finishOptionalReview(),
    'An unreadable scan is not marked ready',
  );

  final defaultRequest = LocalScanRequest();
  check(
    defaultRequest.limit == const Duration(seconds: 30),
    '30-second scan budget',
  );
  defaultRequest.close();
  check(
    thrown(() => LocalScanRequest(limit: Duration.zero)) is ArgumentError,
    'Invalid deadline rejected',
  );

  var timedOut = 0;
  var foreignCancelled = 0;
  final queued = job();
  final waiting = LocalScanRequest(
    limit: const Duration(milliseconds: 25),
    onTimeout: () {
      timedOut++;
      queued.finishOptionalReview(message: 'Check the scanned details');
    },
  );
  // No bind: the runtime belongs to a different foreground chat.
  await waiting.whenStopped.timeout(const Duration(seconds: 1));
  check(
    waiting.timedOut && queued.ready,
    'Busy queue falls back without inference',
  );
  check(timedOut == 1 && queued.error.isNotEmpty, 'One fallback notification');
  check(identical(queued.drafts.single, draft), 'Timeout retains original OCR');
  check(
    thrown(() => waiting.bind(Object(), () => foreignCancelled++))
        is TimeoutException,
    'Expired scan cannot acquire a later lease',
  );
  check(
    foreignCancelled == 0,
    'Queued timeout does not cancel foreground chat',
  );
  check(waiting.remaining == Duration.zero, 'Deadline is not reset');
  waiting.cancel();
  waiting.close();
  check(timedOut == 1, 'Repeated close never repeats fallback');

  var cancelledFirst = 0, cancelledSecond = 0;
  final serial = LocalScanRequest();
  final first = Object(), second = Object();
  serial.bind(first, () => cancelledFirst++);
  check(
    thrown(() => serial.bind(second, () => cancelledSecond++)) is StateError,
    'One scope cannot own overlapping operations',
  );
  serial.release(first);
  serial.bind(second, () => cancelledSecond++);
  serial.release(first); // delayed finalizer from a preceding operation
  serial.cancel();
  serial.close();
  check(cancelledFirst == 0, 'Completed earlier operation is never cancelled');
  check(
    cancelledSecond == 1,
    'Stale release cannot detach the active operation',
  );

  var completedLeaseCancelled = 0;
  final released = LocalScanRequest(limit: const Duration(milliseconds: 25));
  final doneLease = Object();
  released.bind(doneLease, () => completedLeaseCancelled++);
  released.release(doneLease);
  await released.whenStopped;
  check(
    completedLeaseCancelled == 0,
    'Timer after release cannot cancel another request',
  );

  final reads = LocalScanRequest();
  final lateRead = Completer<String>();
  final readResult = failure(reads.wait(() => lateRead.future));
  reads.cancel();
  check(
    await readResult is StateError,
    'Stop releases a stalled settings read',
  );
  lateRead.completeError(StateError('late read error'));
  await Future<void>.delayed(Duration.zero);
  var lateCalls = 0;
  check(
    await failure(
      reads.wait(() async {
        lateCalls++;
        return 'stale';
      }),
    ) is StateError,
    'Stopped scope rejects another settings read',
  );
  check(lateCalls == 0, 'No new work begins after Stop');

  final nextJob = job();
  final nextRequest = LocalScanRequest();
  final delayedAnswer = Completer<MedicineScanDraft>();
  final staleResult = failure(() async {
    final candidate = await delayedAnswer.future;
    nextRequest.checkCurrent();
    nextJob.drafts[0] = candidate;
  }());
  nextJob.finishOptionalReview();
  nextRequest.cancel();
  delayedAnswer.complete(
    const MedicineScanDraft(
      fields: {},
      rawText: 'late result',
      searchKeywords: 'late',
      frameSequences: [0],
    ),
  );
  check(await staleResult is StateError, 'Late answer is rejected after Next');
  check(
    nextJob.ready && identical(nextJob.drafts.single, draft),
    'Review snapshot stays stable',
  );

  final runtime = LocalAiRuntime(engine: fixture.ReplyProgressEngine());
  await runtime.load('/controlled/model.gguf');
  final active = LocalScanRequest(limit: const Duration(milliseconds: 35));
  final activeLease = Object();
  var nativeCancels = 0;
  active.bind(activeLease, () {
    nativeCancels++;
    runtime.cancelCurrentRequest();
  });
  final blocked = failure(runtime.generate('scan', 'withheld'));
  await active.whenStopped.timeout(const Duration(seconds: 1));
  check(
    await blocked is StateError,
    'Deadline retires incomplete native generation',
  );
  active.release(activeLease);
  check(
    nativeCancels == 1 && !runtime.busy,
    'One cancellation releases native command',
  );
  await runtime.load('/controlled/model.gguf');
  check(
    await runtime.generate('chat', 'success') == 'Hello',
    'Chat works after scan timeout',
  );
  active.close();
  check(
    await runtime.generate('chat', 'success') == 'Hello',
    'Old scope cannot stop later chat',
  );
  await runtime.close();

  final unfinished = LocalScanRequest();
  var timeoutsAfterSuccess = 0;
  final succeeded = LocalScanRequest(
    limit: const Duration(milliseconds: 10),
    onTimeout: () => timeoutsAfterSuccess++,
  );
  succeeded.close();
  await Future<void>.delayed(const Duration(milliseconds: 20));
  check(
    timeoutsAfterSuccess == 0,
    'Completed review has no later timeout callback',
  );
  unfinished.close();

  stdout.writeln('$passed focused scan review deadline checks passed.');
}
