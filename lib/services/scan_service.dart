import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_barcode_scanning/google_mlkit_barcode_scanning.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

import '../domain/medicine_understanding.dart';
import '../domain/capture_quality.dart';
import '../domain/medicine_ocr_text.dart';
import '../domain/regulatory_medicine_code.dart';

typedef ScanEvidence = MedicineFrameEvidence;

/// Conservative fusion of physical capture quality with native OCR confidence.
/// This is an evidence-reliability hint, not a calibrated correctness
/// probability. The geometric/weakest-dimension blend prevents a sharp photo
/// from hiding very uncertain OCR (and vice versa). If ML Kit confidence is not
/// available, historical capture-quality behavior is preserved exactly.
double visionEvidenceQuality(double captureQuality, double? ocrConfidence) {
  final capture = CaptureQuality.safeScore(captureQuality);
  if (ocrConfidence == null ||
      !ocrConfidence.isFinite ||
      ocrConfidence <= 0) {
    return capture;
  }
  final ocr = ocrConfidence.clamp(0, 1).toDouble();
  final geometric = sqrt(max(.0001, capture) * max(.0001, ocr));
  final weakest = min(capture, ocr);
  return (geometric * .78 + weakest * .22).clamp(.12, 1).toDouble();
}

/// Streaming barcode hysteresis. One isolated camera/video decode remains a
/// clue, but it does not enter medicine evidence until the same canonical value
/// is observed again. This follows ML Kit's recommendation to require a
/// consecutive series before trusting streaming barcode output. Still photos do
/// not use this gate.
class MedicineBarcodeConsensus {
  String _key = '';
  int _streak = 0;

  void reset() {
    _key = '';
    _streak = 0;
  }

  List<String> accept(List<String> rankedBarcodes) {
    if (rankedBarcodes.isEmpty) {
      reset();
      return const <String>[];
    }
    final firstKey = _barcodeConsensusKey(rankedBarcodes.first);
    if (firstKey.isEmpty) {
      reset();
      return const <String>[];
    }
    if (firstKey == _key) {
      _streak++;
    } else {
      _key = firstKey;
      _streak = 1;
    }
    if (_streak < 2) return const <String>[];
    return rankedBarcodes
        .where((value) => _barcodeConsensusKey(value) == firstKey)
        .take(8)
        .toList(growable: false);
  }
}

class MedicineVisionService {
  static const _channel = MethodChannel('com.aaris.pharmacy/documents');
  final _latin = TextRecognizer(script: TextRecognitionScript.latin);
  final _hindi = TextRecognizer(script: TextRecognitionScript.devanagiri);
  final _barcodes = BarcodeScanner(
    formats: const <BarcodeFormat>[
      BarcodeFormat.dataMatrix,
      BarcodeFormat.qrCode,
      BarcodeFormat.ean13,
      BarcodeFormat.ean8,
      BarcodeFormat.code128,
      BarcodeFormat.upca,
      BarcodeFormat.upce,
      BarcodeFormat.itf,
    ],
  );
  final _barcodeConsensus = MedicineBarcodeConsensus();
  bool _closing = false, _closed = false;
  int _inFlight = 0;
  Completer<void>? _drained;
  Future<void>? _closeFuture;

  Future<ScanEvidence> analyzeFile(
    String path, {
    String source = '',
    int sequence = 0,
    int? timestampMs,
    double? quality,
  }) => analyze(
    InputImage.fromFilePath(path),
    source: source,
    sequence: sequence,
    timestampMs: timestampMs,
    quality: quality,
    qualityPath: path,
  );

  Future<ScanEvidence> analyze(
    InputImage input, {
    String source = '',
    int sequence = 0,
    int? timestampMs,
    double? quality,
    String? qualityPath,
  }) async {
    // Acquire the native-recognizer lease synchronously before the first await.
    // close() therefore cannot race between admission and the in-flight count.
    if (_closing || _closed) throw StateError('Medicine scanner is closed.');
    _inFlight++;
    try {
      Object? latin;
      Object? hindi;
      Object? barcodeResult;
      var measuredQuality = CaptureQuality.safeScore(quality);
      final errors = <Object>[];
      await Future.wait<void>([
        if (quality == null && qualityPath != null)
          _fileQuality(qualityPath).then((value) => measuredQuality = value),
        _latin
            .processImage(input)
            .then<void>(
              (value) => latin = value,
              onError: (Object error, StackTrace _) => errors.add(error),
            ),
        _hindi
            .processImage(input)
            .then<void>(
              (value) => hindi = value,
              onError: (Object error, StackTrace _) => errors.add(error),
            ),
        _barcodes
            .processImage(input)
            .then<void>(
              (value) => barcodeResult = value,
              onError: (Object error, StackTrace _) => errors.add(error),
            ),
      ]);
      if (latin == null && hindi == null && barcodeResult == null) {
        throw StateError(
          errors.isEmpty
              ? 'Medicine recognition produced no result.'
              : 'Medicine recognition is temporarily unavailable.',
        );
      }
      final recognized = <RecognizedText>[
        if (latin is RecognizedText) latin as RecognizedText,
        if (hindi is RecognizedText) hindi as RecognizedText,
      ];
      final lines = mergeMedicineOcrLines([
        for (final result in recognized) ...result.text.split('\n'),
      ]);
      final layoutLines = _mergeLayoutLines([
        for (final result in recognized) ..._layoutEvidence(result),
      ]);
      final detectedBarcodes = barcodeResult is List<Barcode>
          ? _rankBarcodes(
              (barcodeResult as List<Barcode>)
                  .map((barcode) => barcode.rawValue ?? '')
                  .where((value) => value.trim().isNotEmpty),
            )
          : const <String>[];
      final temporal =
          timestampMs != null || source.startsWith('Live camera frame');
      final barcodes = temporal
          ? _barcodeConsensus.accept(detectedBarcodes)
          : detectedBarcodes;
      if (!temporal) _barcodeConsensus.reset();
      final evidenceQuality = visionEvidenceQuality(
        measuredQuality,
        _recognizedOcrConfidence(recognized),
      );
      return ScanEvidence(
        barcode: barcodes.isEmpty ? '' : barcodes.first,
        barcodes: barcodes,
        layoutLines: layoutLines,
        text: lines.join('\n'),
        source: source,
        sequence: sequence,
        timestampMs: timestampMs,
        quality: evidenceQuality,
      );
    } finally {
      _inFlight--;
      if (_inFlight == 0) {
        final drained = _drained;
        _drained = null;
        if (drained != null && !drained.isCompleted) drained.complete();
      }
    }
  }

  Future<double> _fileQuality(String path) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return CaptureQuality.unknownScore;
    }
    try {
      final result = await _channel
          .invokeMapMethod<String, dynamic>('measureImageQuality', {
            'path': path,
          })
          .timeout(const Duration(seconds: 2));
      final value = result?['quality'];
      return CaptureQuality.safeScore(value is num ? value : null);
    } catch (_) {
      // A missing platform metric/unsupported photo format must never destroy
      // successful OCR. Unknown quality is neutral, not a perfect capture.
      return CaptureQuality.unknownScore;
    }
  }

  Future<void> close() => _closeFuture ??= _closeWhenDrained();

  Future<void> _closeWhenDrained() async {
    if (_closed) return;
    _closing = true;
    if (_inFlight > 0) {
      _drained ??= Completer<void>();
      await _drained!.future;
    }
    try {
      // Release every native recognizer only after admitted work has drained.
      // Future.wait still gives every recognizer a chance to close if one close
      // operation fails, preventing native resources from leaking on teardown.
      await Future.wait([_latin.close(), _hindi.close(), _barcodes.close()]);
    } finally {
      _closed = true;
    }
  }
}

double? _recognizedOcrConfidence(Iterable<RecognizedText> results) {
  final best = <String, (double, int)>{};
  for (final result in results) {
    for (final block in result.blocks) {
      for (final line in block.lines) {
        final key = medicineOcrLineKey(line.text);
        if (key.length < 2) continue;
        final confidence = _lineConfidence(line);
        if (confidence == null) continue;
        final weight = line.text.trim().length.clamp(1, 64).toInt();
        final previous = best[key];
        if (previous == null || confidence > previous.$1) {
          best[key] = (confidence, weight);
        }
      }
    }
  }
  if (best.isEmpty) return null;
  var weighted = 0.0;
  var total = 0.0;
  for (final value in best.values) {
    final weight = sqrt(value.$2.toDouble()).clamp(1, 8).toDouble();
    weighted += value.$1 * weight;
    total += weight;
  }
  return total <= 0 ? null : (weighted / total).clamp(0, 1).toDouble();
}

double? _lineConfidence(TextLine line) {
  final direct = line.confidence;
  if (direct != null && direct.isFinite && direct > 0) {
    return direct.clamp(0, 1).toDouble();
  }
  var weighted = 0.0;
  var total = 0.0;
  for (final element in line.elements) {
    final confidence = element.confidence;
    if (confidence == null || !confidence.isFinite || confidence <= 0) continue;
    final weight = sqrt(element.text.trim().length.clamp(1, 32).toDouble());
    weighted += confidence.clamp(0, 1).toDouble() * weight;
    total += weight;
  }
  return total <= 0 ? null : (weighted / total).clamp(0, 1).toDouble();
}

Iterable<MedicineTextLineEvidence> _layoutEvidence(
  RecognizedText result,
) sync* {
  for (final block in result.blocks) {
    for (final line in block.lines) {
      final text = line.text.replaceAll(RegExp(r'\s+'), ' ').trim();
      final box = line.boundingBox;
      if (text.isEmpty || box.width <= 0 || box.height <= 0) continue;
      yield MedicineTextLineEvidence(
        text: text,
        left: box.left,
        top: box.top,
        width: box.width,
        height: box.height,
      );
    }
  }
}

List<MedicineTextLineEvidence> _mergeLayoutLines(
  Iterable<MedicineTextLineEvidence> raw,
) {
  final values = <MedicineTextLineEvidence>[];
  final positions = <String, int>{};
  for (final item in raw.take(500)) {
    final key = medicineOcrLineKey(item.text);
    if (key.length < 2) continue;
    final existing = positions[key];
    if (existing == null) {
      positions[key] = values.length;
      values.add(item);
      continue;
    }
    final current = values[existing];
    final itemScore =
        medicineOcrLineQuality(item.text) + min(item.height / 1000, .08);
    final currentScore =
        medicineOcrLineQuality(current.text) + min(current.height / 1000, .08);
    if (itemScore > currentScore) values[existing] = item;
  }
  return values.take(240).toList(growable: false);
}

List<String> _rankBarcodes(Iterable<String> input) {
  final values = <String>{};
  for (final candidate in input.take(24)) {
    final raw = candidate.trim();
    if (raw.isEmpty) continue;
    values.add(raw);

    // GS1 healthcare DataMatrix commonly carries a GTIN plus batch/expiry in one
    // element string. Preserve the complete raw payload for future traceability,
    // but also expose its verified GTIN as a canonical barcode candidate. That
    // lets the existing private inventory knowledge index hit the exact product
    // instead of treating a structured GS1 payload as an unrelated long string.
    final structured = parseRegulatoryMedicineCode(raw);
    if (structured != null && structured.gtin.isNotEmpty) {
      values.add(structured.gtin);
    }
  }
  final ranked = values.toList(growable: false)
    ..sort((a, b) {
      final score = _barcodeScore(b).compareTo(_barcodeScore(a));
      return score != 0 ? score : a.compareTo(b);
    });
  return ranked.take(8).toList(growable: false);
}

String _barcodeConsensusKey(String value) {
  final raw = value.trim();
  if (raw.isEmpty) return '';
  final structured = parseRegulatoryMedicineCode(raw);
  if (structured != null && structured.gtin.isNotEmpty) {
    return 'gtin:${structured.gtin}';
  }
  final digits = raw.replaceAll(RegExp(r'\D'), '');
  if (digits == raw && const {8, 12, 13, 14}.contains(digits.length)) {
    if (_validGtin(digits)) return 'gtin:${digits.padLeft(14, '0')}';
  }
  return 'raw:$raw';
}

int _barcodeScore(String value) {
  final digits = value.replaceAll(RegExp(r'\D'), '');
  if (digits == value && const {8, 12, 13, 14}.contains(digits.length)) {
    return _validGtin(digits) ? 6 : 3;
  }
  final structured = parseRegulatoryMedicineCode(value);
  if (structured != null && structured.gtin.isNotEmpty) return 5;
  if (digits == value && digits.length >= 6) return 3;
  if (structured != null && structured.hasTraceability) return 2;
  return 1;
}

bool _validGtin(String digits) {
  if (!const {8, 12, 13, 14}.contains(digits.length)) return false;
  var sum = 0;
  for (
    var index = digits.length - 2, position = 1;
    index >= 0;
    index--, position++
  ) {
    final digit = int.parse(digits[index]);
    sum += digit * (position.isOdd ? 3 : 1);
  }
  return (10 - sum % 10) % 10 == int.parse(digits[digits.length - 1]);
}
