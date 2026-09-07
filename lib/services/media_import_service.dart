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

class MediaImportService {
  static const _channel = MethodChannel('com.aaris.pharmacy/documents');

  void _requireAndroid() {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      throw UnsupportedError(
        'Gallery photo and video import are available in the Android app.',
      );
    }
  }

  Future<PickedImportSource?> pick(String kind) async {
    _requireAndroid();
    if (kind != 'image' && kind != 'video') {
      throw const FormatException('Choose an image or video import.');
    }
    final raw = await _channel.invokeMethod<Map<Object?, Object?>>(
      'pickImportSource',
      {'kind': kind},
    );
    return raw == null ? null : PickedImportSource.fromMap(raw);
  }

  Future<List<String>> sampleVideo(String path, {int maxFrames = 60}) async {
    _requireAndroid();
    final frames = await _channel.invokeListMethod<String>('sampleVideo', {
      'path': path,
      'maxFrames': maxFrames.clamp(1, 72),
    });
    return frames ?? const [];
  }

  Future<void> cleanup(Iterable<String> paths) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    final bounded = paths.where((path) => path.isNotEmpty).take(100).toList();
    if (bounded.isEmpty) return;
    await _channel.invokeMethod<int>('deleteImportFiles', {'paths': bounded});
  }
}
