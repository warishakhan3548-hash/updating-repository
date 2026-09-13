import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_barcode_scanning/google_mlkit_barcode_scanning.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

import '../domain/capture_quality.dart';
import '../domain/medicine_machine_code_safety.dart';
import '../domain/medicine_ocr_reliability.dart';
import '../domain/medicine_ocr_text.dart';
import '../domain/medicine_understanding.dart';

typedef ScanEvidence = MedicineFrameEvidence;

/// True only when one immutable image contained more than one independently
/// checksum-valid medicine product identity. Such a frame is still useful OCR
/// evidence, but its machine codes are deliberately quarantined so no resolver
/// can exact-lock an arbitrary product from a multi-pack image.
bool scanEvidenceHasAmbiguousMedicineCodes(MedicineFrameEvidence evidence) =>
    medicineMachineCodeSourceIsAmbiguous(evidence.source);

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

      final lines = mergeMedicineOcrLines([
        if (latin is RecognizedText)
          ...(latin as RecognizedText).text.split('\n'),
        if (hindi is RecognizedText)
          ...(hindi as RecognizedText).text.split('\n'),
      ]);
      final layoutLines = _mergeLayoutLines([
        if (latin is RecognizedText)
          ..._layoutEvidence(latin as RecognizedText),
        if (hindi is RecognizedText)
          ..._layoutEvidence(hindi as RecognizedText),
      ]);
      final decodedBarcodes = barcodeResult is List<Barcode>
          ? (barcodeResult as List<Barcode>)
                .map((barcode) => barcode.rawValue ?? '')
                .where((value) => value.trim().isNotEmpty)
          : const <String>[];
      final barcodeSelection = selectSafeMedicineMachineCodes(decodedBarcodes);
      final barcodes = barcodeSelection.payloads;
      final evidenceSource = barcodeSelection.ambiguousTrustedProductCodes
          ? '${source.trim()} $ambiguousMedicineMachineCodesMarker'.trim()
          : source;

      // Keep physical camera quality semantically pure. Detector confidence is
      // used only to choose trustworthy OCR geometry and duplicate layout lines.
      // Raw OCR text remains untouched, so a low-confidence line can still be
      // reviewed without being promoted into a high-confidence spatial fact.
      return ScanEvidence(
        barcode: barcodes.isEmpty ? '' : barcodes.first,
        barcodes: barcodes,
        layoutLines: layoutLines,
        text: lines.join('\n'),
        source: evidenceSource,
        sequence: sequence,
        timestampMs: timestampMs,
        quality: measuredQuality,
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

class _OcrLayoutLine {
  const _OcrLayoutLine({required this.evidence, required this.confidence});

  final MedicineTextLineEvidence evidence;
  final double? confidence;
}

Iterable<_OcrLayoutLine> _layoutEvidence(RecognizedText result) sync* {
  for (final block in result.blocks) {
    for (final line in block.lines) {
      final text = line.text.replaceAll(RegExp(r'\s+'), ' ').trim();
      final box = line.boundingBox;
      if (text.isEmpty || box.width <= 0 || box.height <= 0) continue;
      final confidence = usableMedicineOcrConfidence(line.confidence);

      // Geometry can create very strong MFG/EXP/BATCH bindings downstream.
      // Known extremely weak OCR must therefore stay out of the geometry lane;
      // the raw recognizer text is still retained above for ordinary review and
      // deterministic parsing, so this never destroys the captured evidence.
      if (confidence != null && confidence < .32) continue;

      yield _OcrLayoutLine(
        evidence: MedicineTextLineEvidence(
          text: text,
          left: box.left,
          top: box.top,
          width: box.width,
          height: box.height,
        ),
        confidence: confidence,
      );
    }
  }
}

List<MedicineTextLineEvidence> _mergeLayoutLines(
  Iterable<_OcrLayoutLine> raw,
) {
  final values = <_OcrLayoutLine>[];
  final positions = <String, List<int>>{};
  for (final item in raw.take(500)) {
    final key = medicineOcrLineKey(item.evidence.text);
    if (key.length < 2) continue;

    // Latin and Devanagari recognizers can report the same visual line twice.
    // Deduplicate only when the text AND its physical region agree. Repeated
    // labels such as EXP/BATCH at different positions are intentionally kept so
    // spatial traceability can bind each label to its own nearby value.
    final candidates = positions[key] ?? const <int>[];
    int? existing;
    for (final index in candidates) {
      if (_sameLayoutObservation(values[index].evidence, item.evidence)) {
        existing = index;
        break;
      }
    }
    if (existing == null) {
      positions.putIfAbsent(key, () => <int>[]).add(values.length);
      values.add(item);
      continue;
    }

    final current = values[existing];
    if (_layoutPreference(item) > _layoutPreference(current)) {
      values[existing] = item;
    }
  }
  return values
      .take(240)
      .map((value) => value.evidence)
      .toList(growable: false);
}

bool _sameLayoutObservation(
  MedicineTextLineEvidence left,
  MedicineTextLineEvidence right,
) {
  final leftRight = left.left + left.width;
  final rightRight = right.left + right.width;
  final leftBottom = left.top + left.height;
  final rightBottom = right.top + right.height;
  final overlapX = max(0.0, min(leftRight, rightRight) - max(left.left, right.left));
  final overlapY = max(0.0, min(leftBottom, rightBottom) - max(left.top, right.top));
  final overlapRatioX = overlapX / max(1.0, min(left.width, right.width));
  final overlapRatioY = overlapY / max(1.0, min(left.height, right.height));
  if (overlapRatioX >= .55 && overlapRatioY >= .50) return true;

  final height = max(1.0, max(left.height, right.height));
  final leftCenterX = left.left + left.width / 2;
  final rightCenterX = right.left + right.width / 2;
  final leftCenterY = left.top + left.height / 2;
  final rightCenterY = right.top + right.height / 2;
  final horizontalScale = max(height, max(left.width, right.width));
  return (leftCenterY - rightCenterY).abs() / height <= .42 &&
      (leftCenterX - rightCenterX).abs() / horizontalScale <= .32;
}

double _layoutPreference(_OcrLayoutLine item) {
  final evidence = item.evidence;
  final lexical = medicineOcrLineQuality(evidence.text);
  final size = min(evidence.height / 1000, .08);
  final detector = item.confidence == null ? 0.0 : item.confidence! * .32;
  return lexical + size + detector;
}
