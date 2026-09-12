import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class PickedImportSource {
  const PickedImportSource({
    required this.path,
    required this.name,
    required this.mimeType,
  });

  final String path;
  final String name;
  final String mimeType;

  factory PickedImportSource.fromMap(Map<Object?, Object?> map) =>
      PickedImportSource(
        path: map['path'] as String,
        name: map['name'] as String? ?? 'Selected file',
        mimeType: map['mimeType'] as String? ?? '',
      );
}

class VideoFrameSample {
  const VideoFrameSample({
    required this.path,
    required this.sequence,
    required this.timestampMs,
    required this.quality,
  });

  final String path;
  final int sequence;
  final int timestampMs;
  final double quality;

  factory VideoFrameSample.fromMap(
    Map<Object?, Object?> map, {
    required int fallbackSequence,
  }) => VideoFrameSample(
    path: map['path'] as String,
    sequence: map['sequence'] as int? ?? fallbackSequence,
    timestampMs: map['timestampMs'] as int? ?? 0,
    quality: (map['quality'] as num? ?? 1).toDouble().clamp(0, 1),
  );
}

class MediaImportService {
  static const _channel = MethodChannel('com.aaris.pharmacy/documents');
  static const _videoSampleTimeout = Duration(minutes: 2);
  static const _videoWindowTimeout = Duration(seconds: 75);
  static const _cleanupTimeout = Duration(seconds: 12);

  void _requireAndroid() {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      throw UnsupportedError(
        'Gallery photo and video import are available in the Android app.',
      );
    }
  }

  Future<T> _boundedNative<T>(
    Future<T> operation, {
    required Duration timeout,
    required String action,
  }) => operation.timeout(
    timeout,
    onTimeout: () => throw TimeoutException(
      '$action did not finish on the device. The saved intake state was not discarded; retry this step.',
      timeout,
    ),
  );

  Future<PickedImportSource?> pick(String kind) async {
    _requireAndroid();
    if (kind != 'image' && kind != 'video') {
      throw const FormatException('Choose an image or video import.');
    }
    // Do not timeout the system picker: the user may intentionally browse for
    // several minutes. Bounds apply only after native processing has started.
    final raw = await _channel.invokeMethod<Map<Object?, Object?>>(
      'pickImportSource',
      {'kind': kind},
    );
    return raw == null ? null : PickedImportSource.fromMap(raw);
  }

  Future<List<VideoFrameSample>> sampleVideo(
    String path, {
    int maxFrames = 60,
  }) async {
    _requireAndroid();
    final frames = await _boundedNative<List<Object?>?>(
      _channel.invokeListMethod<Object?>('sampleVideo', {
        'path': path,
        'maxFrames': maxFrames.clamp(1, 72),
      }),
      timeout: _videoSampleTimeout,
      action: 'Video sampling',
    );
    if (frames == null) return const <VideoFrameSample>[];
    final result = <VideoFrameSample>[];
    for (var index = 0; index < frames.length; index++) {
      final raw = frames[index];
      // Accept the old native response during hot upgrades, but all current
      // Android builds return ordered metadata maps.
      if (raw is String && raw.isNotEmpty) {
        result.add(
          VideoFrameSample(
            path: raw,
            sequence: index,
            timestampMs: index * 3000,
            quality: 1,
          ),
        );
      } else if (raw is Map && raw['path'] is String) {
        result.add(
          VideoFrameSample.fromMap(
            Map<Object?, Object?>.from(raw),
            fallbackSequence: index,
          ),
        );
      }
    }
    result.sort((a, b) => a.sequence.compareTo(b.sequence));
    return result;
  }

  Future<void> cleanup(Iterable<String> paths) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    final bounded = paths.where((path) => path.isNotEmpty).take(100).toList();
    if (bounded.isEmpty) return;
    try {
      await _channel
          .invokeMethod<int>('deleteImportFiles', {'paths': bounded})
          .timeout(_cleanupTimeout);
    } on TimeoutException {
      // Temp-file cleanup is best effort. A housekeeping timeout must never
      // convert a successful durable queue write into a failed import state.
    } on PlatformException {
      // The private queue/source-of-truth already owns the capture at this point.
    } on MissingPluginException {
      // Hot-upgrade/native-version mismatch: preserve the intake result.
    }
  }

  Future<VideoWindow> sampleVideoWindow(String path, int startMs) async {
    _requireAndroid();
    final raw = await _boundedNative<Map<Object?, Object?>?>(
      _channel.invokeMapMethod<Object?, Object?>('sampleVideoWindow', {
        'path': path,
        'startMs': startMs,
      }),
      timeout: _videoWindowTimeout,
      action: 'Video intake window',
    );
    if (raw == null ||
        raw['frames'] is! List ||
        raw['nextStartMs'] is! int ||
        raw['durationMs'] is! int) {
      throw StateError('Invalid video window response.');
    }
    return VideoWindow(
      frames: [
        for (final frame in (raw['frames'] as List).whereType<Map>())
          VideoFrameSample.fromMap(
            Map<Object?, Object?>.from(frame),
            fallbackSequence: startMs,
          ),
      ],
      nextStartMs: raw['nextStartMs'] as int,
      durationMs: raw['durationMs'] as int,
    );
  }

  Future<void> cleanupCameraCapture(String path) async {
    if (path.isEmpty ||
        kIsWeb ||
        defaultTargetPlatform != TargetPlatform.android) {
      return;
    }
    try {
      await _channel
          .invokeMethod<bool>('deleteCameraCapture', {'path': path})
          .timeout(_cleanupTimeout);
    } on TimeoutException {
      // Best-effort housekeeping; do not break an already completed capture.
    } on PlatformException {
      // See cleanup().
    } on MissingPluginException {
      // See cleanup().
    }
  }
}

class VideoWindow {
  const VideoWindow({
    required this.frames,
    required this.nextStartMs,
    required this.durationMs,
  });
  final List<VideoFrameSample> frames;
  final int nextStartMs, durationMs;
  bool get complete => nextStartMs >= durationMs;
}
