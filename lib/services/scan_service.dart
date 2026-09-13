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

const String _ambiguousMedicineCodesMarker =
    '[aaris:ambiguous-medicine-machine-codes]';

/// True only when one immutable image contained more than one independently
/// checksum-valid medicine product identity. Such a frame is still useful OCR
/// evidence, but its machine codes are deliberately quarantined so no resolver
/// can exact-lock an arbitrary product from a multi-pack image.
bool scanEvidenceHasAmbiguousMedicineCodes(MedicineFrameEvidence evidence) =>
    evidence.source.contains(_ambiguousMedicineCodesMarker);

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
          ? '${source.trim()} $_ambiguousMedicineCodesMarker'.trim()
          : source;

      // Keep physical camera quality semantically pure. Detector confidence is
      // used only to choose among duplicate OCR layout lines. Downstream capture,
      // date and evidence-graph logic therefore continues to read `quality` as
      // focus/contrast/exposure, never as a model correctness probability.
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
      yield _OcrLayoutLine(
        evidence: MedicineTextLineEvidence(
          text: text,
          left: box.left,
          top: box.top,
          width: box.width,
          height: box.height,
        ),
        // ML Kit may use zero as an unavailable-confidence sentinel. The domain
        // helper converts it to null so older detector paths remain neutral.
        confidence: usableMedicineOcrConfidence(line.confidence),
      );
    }
  }
}

List<MedicineTextLineEvidence> _mergeLayoutLines(
  Iterable<_OcrLayoutLine> raw,
) {
  final values = <_OcrLayoutLine>[];
  final positions = <String, int>{};
  for (final item in raw.take(500)) {
    final key = medicineOcrLineKey(item.evidence.text);
    if (key.length < 2) continue;
    final existing = positions[key];
    if (existing == null) {
      positions[key] = values.length;
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

double _layoutPreference(_OcrLayoutLine item) {
  final evidence = item.evidence;
  final lexical = medicineOcrLineQuality(evidence.text);
  final size = min(evidence.height / 1000, .08);
  final detector = item.confidence == null ? 0.0 : item.confidence! * .32;
  return lexical + size + detector;
}
