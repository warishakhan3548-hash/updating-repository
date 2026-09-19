import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/services/media_import_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.aaris.pharmacy/documents');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  Map<String, Object?> response = {};
  Map<String, Object?> frame(int timestamp) => {
    'path': '/private/frame_$timestamp.jpg',
    'sequence': timestamp,
    'timestampMs': timestamp,
    'quality': .4,
  };
  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    response = {
      'frames': [frame(20500), frame(21500)],
      'nextStartMs': 40000,
      'durationMs': 180000,
      'unreadableFrames': 2,
    };
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'sampleVideoWindow');
      return response;
    });
  });
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    messenger.setMockMethodCallHandler(channel, null);
  });
  Future<VideoWindow> read() =>
      MediaImportService().sampleVideoWindow('/private/video.mp4', 20000);

  test(
    'ordered samples retain native failures and full-video duration',
    () async {
      response['frames'] = [frame(21500), frame(20500)];
      final result = await read();
      expect(result.frames.map((f) => f.timestampMs), [20500, 21500]);
      expect(result.durationMs, 180000);
      expect(result.unreadableFrames, 2);
      expect(result.complete, isFalse);
    },
  );
  test('older native window without failure count remains supported', () async {
    response.remove('unreadableFrames');
    expect((await read()).unreadableFrames, 0);
  });
  for (final entry in <String, Map<String, Object?>>{
    'nonadvancing cursor': {'nextStartMs': 20000},
    'cursor beyond duration': {'nextStartMs': 180001},
    'invalid duration': {'durationMs': 0},
    'negative decode failures': {'unreadableFrames': -1},
    'non-map frame': {
      'frames': ['dropped silently before'],
    },
  }.entries) {
    test(
      'rejects ${entry.key} instead of checkpointing lost coverage',
      () async {
        response.addAll(entry.value);
        await expectLater(read(), throwsStateError);
      },
    );
  }
  test('duplicate frame sequence cannot replace source evidence', () async {
    response['frames'] = [frame(20500), frame(20500)];
    await expectLater(read(), throwsStateError);
  });
  test('out-of-window evidence is rejected', () async {
    response['frames'] = [frame(19500)];
    await expectLater(read(), throwsStateError);
  });
  test('blank window explicitly preserves the native failure count', () async {
    response['frames'] = [];
    response['unreadableFrames'] = 40;
    final result = await read();
    expect(result.frames, isEmpty);
    expect(result.unreadableFrames, 40);
  });
  test('terminal EOF response is valid without frame replay', () async {
    response['frames'] = [];
    response['durationMs'] = 20000;
    response['nextStartMs'] = 20000;
    expect((await read()).complete, isTrue);
  });
}
