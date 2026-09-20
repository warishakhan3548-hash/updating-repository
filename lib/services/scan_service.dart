import 'dart:async';
import 'dart:collection';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_barcode_scanning/google_mlkit_barcode_scanning.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

import '../domain/capture_quality.dart';
import '../domain/medicine_machine_code_safety.dart';
import '../domain/medicine_evidence_normalization.dart';
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

/// Process-wide arbitration for the native OCR/barcode engines.
///
/// Durable intake can keep processing while the user opens the live scanner.
/// Without one owner, separate [MedicineVisionService] instances can drive ML
/// Kit concurrently and compete for CPU, memory and native recognizer state.
/// Interactive camera work gets the next lease; background photo/video intake
/// yields after every frame, so it remains resumable without making taps wait
/// behind an entire queued video.
enum MedicineVisionWorkPriority { interactive, background }

class _MedicineVisionWorkScheduler {
  bool _active = false;
  final Queue<Completer<void>> _interactive = Queue<Completer<void>>();
  final Queue<Completer<void>> _background = Queue<Completer<void>>();

  Future<T> run<T>(
    MedicineVisionWorkPriority priority,
    Future<T> Function() operation,
  ) async {
    final turn = Completer<void>();
    if (_active) {
      final queue = priority == MedicineVisionWorkPriority.interactive
          ? _interactive
          : _background;
      queue.addLast(turn);
    } else {
      _active = true;
      turn.complete();
    }

    await turn.future;
    try {
      return await operation();
    } finally {
      _release();
    }
  }

  void _release() {
    Completer<void>? next;
    if (_interactive.isNotEmpty) {
      next = _interactive.removeFirst();
    } else if (_background.isNotEmpty) {
      next = _background.removeFirst();
    }
    if (next == null) {
      _active = false;
      return;
    }
    next.complete();
  }
}

final _medicineVisionWorkScheduler = _MedicineVisionWorkScheduler();

@visibleForTesting
Future<T> runMedicineVisionWorkForTesting<T>(
  MedicineVisionWorkPriority priority,
  Future<T> Function() operation,
) => _medicineVisionWorkScheduler.run(priority, operation);

class MedicineVisionService {
  static const _channel = MethodChannel('com.aaris.pharmacy/documents');
  static const _detectorTimeout = Duration(seconds: 12);
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
  final Set<String> _quarantinedDetectors = <String>{};
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
    MedicineVisionWorkPriority priority = MedicineVisionWorkPriority.background,
  }) => analyze(
    InputImage.fromFilePath(path),
    source: source,
    sequence: sequence,
    timestampMs: timestampMs,
    quality: quality,
    qualityPath: path,
    priority: priority,
  );

  Future<ScanEvidence> analyze(
    InputImage input, {
    String source = '',
    int sequence = 0,
    int? timestampMs,
    double? quality,
    String? qualityPath,
    MedicineVisionWorkPriority priority = MedicineVisionWorkPriority.background,
  }) async {
    // Admit work to this instance synchronously before the first await.
    // close() therefore cannot race past a request that is queued for the
    // process-wide recognizer lease.
    if (_closing || _closed) throw StateError('Medicine scanner is closed.');
    if (_inFlight != 0) {
      throw StateError('Medicine scanner is already processing a frame.');
    }
    _inFlight++;
    try {
      return await _medicineVisionWorkScheduler.run(priority, () async {
        if (_closing || _closed) {
          throw StateError('Medicine scanner is closed.');
        }
        Object? latin;
        Object? hindi;
        Object? barcodeResult;
        var measuredQuality = CaptureQuality.safeScore(quality);
        final errors = <Object>[];
        await Future.wait<void>([
          if (quality == null && qualityPath != null)
            _fileQuality(qualityPath).then((value) => measuredQuality = value),
          _runDetector<RecognizedText>(
            key: 'latin',
            work: () => _latin.processImage(input),
            close: _latin.close,
            errors: errors,
          ).then<void>((value) => latin = value),
          _runDetector<RecognizedText>(
            key: 'devanagari',
            work: () => _hindi.processImage(input),
            close: _hindi.close,
            errors: errors,
          ).then<void>((value) => hindi = value),
          _runDetector<List<Barcode>>(
            key: 'barcode',
            work: () => _barcodes.processImage(input),
            close: _barcodes.close,
            errors: errors,
          ).then<void>((value) => barcodeResult = value),
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
        return normalizeMedicineFrameEvidence(ScanEvidence(
          barcode: barcodes.isEmpty ? '' : barcodes.first,
          barcodes: barcodes,
          layoutLines: layoutLines,
          text: lines.join('\n'),
          source: evidenceSource,
          sequence: sequence,
          timestampMs: timestampMs,
          quality: measuredQuality,
        ));
      });
    } finally {
      _inFlight--;
      if (_inFlight == 0) {
        final drained = _drained;
        _drained = null;
        if (drained != null && !drained.isCompleted) drained.complete();
      }
    }
  }

  Future<T?> _runDetector<T>({
    required String key,
    required Future<T> Function() work,
    required Future<void> Function() close,
    required List<Object> errors,
  }) async {
    // A timed-out plugin operation cannot be cancelled safely. Never issue a
    // second request to that recognizer while native work may still be alive.
    if (_quarantinedDetectors.contains(key)) return null;
    late final Future<T> operation;
    try {
      operation = work();
    } catch (error) {
      errors.add(error);
      return null;
    }
    try {
      return await operation.timeout(_detectorTimeout);
    } on TimeoutException {
      errors.add(
        TimeoutException(
          '$key medicine detector did not respond in time.',
          _detectorTimeout,
        ),
      );
      _quarantinedDetectors.add(key);
      unawaited(_retireQuarantinedDetector(operation, close));
      return null;
    } catch (error) {
      errors.add(error);
      return null;
    }
  }

  Future<void> _retireQuarantinedDetector<T>(
    Future<T> operation,
    Future<void> Function() close,
  ) async {
    try {
      await operation;
    } catch (_) {
      // The original detector failure is already represented in analyze().
    }
    try {
      await close();
    } catch (_) {
      // Late native cleanup must never surface as an unhandled async error.
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
      await Future.wait([
        if (!_quarantinedDetectors.contains('latin')) _latin.close(),
        if (!_quarantinedDetectors.contains('devanagari')) _hindi.close(),
        if (!_quarantinedDetectors.contains('barcode')) _barcodes.close(),
      ]);
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
      // Apply the exact same semantic-preserving normalization to geometry
      // evidence as to flattened OCR text. Date adjacency, prominent product
      // headings and strength parsing must not disagree merely because one path
      // saw full-width/script digits while the other saw canonical ASCII.
      final text = normalizeMedicineOcrLine(line.text);
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
  final positions = <String, List<int>>{};
  for (final item in raw.take(500)) {
    final key = medicineOcrLineKey(item.evidence.text);
    if (key.length < 2) continue;

    // Text identity is not physical identity. The same printed value can appear
    // more than once on a carton/foil (for example repeated EXP/MFG panels).
    // Collapse only Latin/Devanagari recognizer duplicates that overlap the same
    // physical region; preserve identical text at distinct coordinates so the
    // spatial resolver can still bind the correct label/value pair.
    final candidates = positions.putIfAbsent(key, () => <int>[]);
    int? duplicateIndex;
    for (final index in candidates) {
      if (_sameLayoutRegion(values[index].evidence, item.evidence)) {
        duplicateIndex = index;
        break;
      }
    }
    if (duplicateIndex == null) {
      candidates.add(values.length);
      values.add(item);
      continue;
    }

    final current = values[duplicateIndex];
    if (_layoutPreference(item) > _layoutPreference(current)) {
      values[duplicateIndex] = item;
    }
  }
  return values
      .take(240)
      .map((value) => value.evidence)
      .toList(growable: false);
}

bool _sameLayoutRegion(
  MedicineTextLineEvidence first,
  MedicineTextLineEvidence second,
) {
  final firstRight = first.left + first.width;
  final secondRight = second.left + second.width;
  final firstBottom = first.top + first.height;
  final secondBottom = second.top + second.height;
  final overlapX = max(
    0.0,
    min(firstRight, secondRight) - max(first.left, second.left),
  );
  final overlapY = max(
    0.0,
    min(firstBottom, secondBottom) - max(first.top, second.top),
  );
  final horizontal = overlapX / max(1.0, min(first.width, second.width));
  final vertical = overlapY / max(1.0, min(first.height, second.height));
  if (horizontal >= .55 && vertical >= .55) return true;

  // Detector boxes for two scripts can be shifted slightly while representing
  // the same glyph row. A tight center-distance fallback handles that jitter
  // without merging repeated text printed elsewhere on the package.
  final firstCenterX = first.left + first.width / 2;
  final secondCenterX = second.left + second.width / 2;
  final firstCenterY = first.top + first.height / 2;
  final secondCenterY = second.top + second.height / 2;
  return (firstCenterX - secondCenterX).abs() <=
          max(first.width, second.width) * .18 &&
      (firstCenterY - secondCenterY).abs() <=
          max(first.height, second.height) * .45;
}

double _layoutPreference(_OcrLayoutLine item) {
  final evidence = item.evidence;
  final lexical = medicineOcrLineQuality(evidence.text);
  final size = min(evidence.height / 1000, .08);
  final detector = item.confidence == null ? 0.0 : item.confidence! * .32;
  return lexical + size + detector;
}
