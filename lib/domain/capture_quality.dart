import 'dart:math';
import 'dart:typed_data';

/// Cheap, bounded capture hint, not an OCR/medicine correctness probability.
/// Mirrors the existing native video sampler's luminance-grid metrics. It never
/// invents/enhances pixels or suppresses OCR of an otherwise readable frame.
class CaptureQuality {
  const CaptureQuality({
    required this.sharpness,
    required this.contrast,
    required this.exposure,
    required this.meanLuminance,
    required this.score,
  });
  static const unknownScore = .65;
  final double sharpness, contrast, exposure, meanLuminance, score;

  String get guidance {
    if (meanLuminance < 35) return 'Add light or turn on the torch.';
    if (meanLuminance > 235 && contrast < 20) {
      return 'Tilt the pack to reduce glare.';
    }
    if (sharpness < .12 && contrast < 25) {
      return 'Move closer and hold steady; keep the label in focus.';
    }
    return '';
  }

  static double safeScore(num? value) => value == null || !value.isFinite
      ? unknownScore
      : value.toDouble().clamp(0, 1);

  /// Samples at most 1024 pixels; respects row padding and pixel stride. NV21/Y
  /// only reads the luminance plane, never interleaved chroma. BGRA reads RGB.
  static CaptureQuality? fromPlane({
    required Uint8List bytes,
    required int width,
    required int height,
    required int bytesPerRow,
    int pixelStride = 1,
    bool bgra = false,
  }) {
    final channels = bgra ? 4 : 1;
    if (width < 2 ||
        height < 2 ||
        width > 32768 ||
        height > 32768 ||
        pixelStride < channels ||
        bytesPerRow < (width - 1) * pixelStride + channels ||
        (height - 1) * bytesPerRow + (width - 1) * pixelStride + channels >
            bytes.length) {
      return null;
    }
    final columns = min(32, width), rows = min(32, height);
    final luminance = <double>[];
    for (var y = 0; y < rows; y++) {
      final sy = ((y + .5) * height / rows).floor().clamp(0, height - 1);
      for (var x = 0; x < columns; x++) {
        final sx = ((x + .5) * width / columns).floor().clamp(0, width - 1);
        final i = sy * bytesPerRow + sx * pixelStride;
        luminance.add(
          bgra
              ? (bytes[i + 2] * 299 + bytes[i + 1] * 587 + bytes[i] * 114) /
                    1000
              : bytes[i].toDouble(),
        );
      }
    }
    final mean = luminance.reduce((a, b) => a + b) / luminance.length;
    var variance = 0.0, edges = 0.0;
    var edgeCount = 0;
    for (var i = 0; i < luminance.length; i++) {
      variance += pow(luminance[i] - mean, 2);
      if (i % columns > 0) {
        edges += (luminance[i] - luminance[i - 1]).abs();
        edgeCount++;
      }
      if (i >= columns) {
        edges += (luminance[i] - luminance[i - columns]).abs();
        edgeCount++;
      }
    }
    final contrast = sqrt(variance / luminance.length);
    final sharpness = (edges / max(1, edgeCount) / 28).clamp(0.0, 1.0);
    final exposure = (1 - (mean - 128).abs() / 128).clamp(0.0, 1.0);
    return CaptureQuality(
      sharpness: sharpness,
      contrast: contrast,
      exposure: exposure,
      meanLuminance: mean,
      score:
          (sharpness * .52 +
                  (contrast / 58).clamp(0.0, 1.0) * .28 +
                  exposure * .20)
              .clamp(0.0, 1.0),
    );
  }
}
