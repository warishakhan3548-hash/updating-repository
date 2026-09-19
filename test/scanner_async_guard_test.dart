import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import '../lib/ui/scanner_screen.dart';

void main() {
  test('detached retired reader blocks a new capture until it drains', () {
    expect(
      scannerCaptureBlockedByDetachedReader(
        readerBusy: true,
        hasTrackedFrame: false,
      ),
      isTrue,
    );
    expect(
      scannerCaptureBlockedByDetachedReader(
        readerBusy: true,
        hasTrackedFrame: true,
      ),
      isFalse,
    );
    expect(
      scannerCaptureBlockedByDetachedReader(
        readerBusy: false,
        hasTrackedFrame: false,
      ),
      isFalse,
    );
  });

  test('scanner wait deadline does not cancel the active OCR lease', () async {
    final active = Completer<bool>();

    final completed = await scannerWorkCompletedWithin(
      active.future,
      timeout: const Duration(milliseconds: 15),
    );

    expect(completed, isFalse);
    expect(active.isCompleted, isFalse);

    active.complete(true);
    await expectLater(active.future, completion(isTrue));
  });

  test('scanner wait accepts idle and already completed work', () async {
    expect(
      await scannerWorkCompletedWithin<void>(
        null,
        timeout: const Duration(milliseconds: 15),
      ),
      isTrue,
    );
    expect(
      await scannerWorkCompletedWithin(
        Future<bool>.value(true),
        timeout: const Duration(milliseconds: 15),
      ),
      isTrue,
    );
  });

  test('scanner wait treats settled failures as drained', () async {
    expect(
      await scannerWorkCompletedWithin<void>(
        Future<void>.error(StateError('reader failed')),
        timeout: const Duration(milliseconds: 15),
      ),
      isTrue,
    );
    expect(
      await scannerWorkGroupCompletedWithin(
        <Future<dynamic>?>[
          Future<void>.error(StateError('capture failed')),
          Future<bool>.value(false),
        ],
        timeout: const Duration(milliseconds: 15),
      ),
      isTrue,
    );
  });


  test('scanner wait distinguishes native timeout failures from UI deadline', () async {
    expect(
      await scannerWorkCompletedWithin<void>(
        Future<void>.error(TimeoutException('native reader timed out')),
        timeout: const Duration(milliseconds: 15),
      ),
      isTrue,
    );
    expect(
      await scannerWorkGroupCompletedWithin(
        <Future<dynamic>?>[
          Future<void>.error(TimeoutException('native capture timed out')),
          Future<bool>.value(false),
        ],
        timeout: const Duration(milliseconds: 15),
      ),
      isTrue,
    );
  });

  test('scanner grouped drain treats no active work as complete', () async {
    expect(
      await scannerWorkGroupCompletedWithin(
        const <Future<dynamic>?>[],
        timeout: const Duration(milliseconds: 15),
      ),
      isTrue,
    );
  });

  test('scanner lifecycle drains share one deadline without cancelling work', () async {
    final capture = Completer<void>();
    final frame = Completer<bool>();

    expect(
      await scannerWorkGroupCompletedWithin(
        <Future<dynamic>?>[capture.future, frame.future],
        timeout: const Duration(milliseconds: 15),
      ),
      isFalse,
    );
    expect(capture.isCompleted, isFalse);
    expect(frame.isCompleted, isFalse);

    capture.complete();
    frame.complete(true);
    await capture.future;
    await expectLater(frame.future, completion(isTrue));
    expect(
      await scannerWorkGroupCompletedWithin(
        <Future<dynamic>?>[null, capture.future, frame.future],
        timeout: const Duration(milliseconds: 15),
      ),
      isTrue,
    );
  });
}
