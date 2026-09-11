import 'dart:async';
import 'dart:math';

import 'package:google_mlkit_barcode_scanning/google_mlkit_barcode_scanning.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

import '../domain/gs1_healthcare.dart';
import '../domain/medicine_evidence_focus.dart';
import '../domain/medicine_understanding.dart';
import '../domain/search.dart';

typedef ScanEvidence = MedicineFrameEvidence;

class MedicineVisionService {
  final _latin = TextRecognizer(script: TextRecognitionScript.latin);
  final _hindi = TextRecognizer(script: TextRecognitionScript.devanagiri);
  final _barcodes = BarcodeScanner();
  bool _closing = false, _closed = false;
  int _inFlight = 0;
  Completer<void>? _drained;
  Future<void>? _closeFuture;

  Future<ScanEvidence> analyzeFile(
    String path, {
    String source = '',
    int sequence = 0,
    int? timestampMs,
    double quality = 1,
  }) => analyze(
    InputImage.fromFilePath(path),
    source: source,
    sequence: sequence,
    timestampMs: timestampMs,
    quality: quality,
  );

  Future<ScanEvidence> analyze(
    InputImage input, {
    String source = '',
    int sequence = 0,
    int? timestampMs,
    double quality = 1,
  }) async {
    // Acquire the native-recognizer lease synchronously before the first await.
    // close() therefore cannot race between admission and the in-flight count.
    if (_closing || _closed) throw StateError('Medicine scanner is closed.');
    _inFlight++;
    try {
      Object? latin;
      Object? hindi;
      Object? barcodeResult;
      final errors = <Object>[];
      await Future.wait<void>([
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
      final rawText = _completeOcrText([
        if (latin is RecognizedText) (latin as RecognizedText).text,
        if (hindi is RecognizedText) (hindi as RecognizedText).text,
      ]);
      final layoutLines = _mergeLayoutLines([
        if (latin is RecognizedText)
          ..._layoutEvidence(latin as RecognizedText),
        if (hindi is RecognizedText)
          ..._layoutEvidence(hindi as RecognizedText),
      ]);
      final barcodes = barcodeResult is List<Barcode>
          ? _rankBarcodes(
              (barcodeResult as List<Barcode>)
                  .map((barcode) => barcode.rawValue ?? '')
                  .where((value) => value.trim().isNotEmpty),
            )
          : const <String>[];
      return ScanEvidence(
        barcode: barcodes.isEmpty ? '' : barcodes.first,
        barcodes: barcodes,
        layoutLines: layoutLines,
        text: rawText,
        source: source,
        sequence: sequence,
        timestampMs: timestampMs,
        quality: quality.clamp(0, 1),
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
    final key = searchText(item.text);
    if (key.length < 2) continue;
    final existing = positions[key];
    if (existing == null) {
      positions[key] = values.length;
      values.add(item);
      continue;
    }
    final current = values[existing];
    final itemScore = _lineQuality(item.text) + min(item.height / 1000, .08);
    final currentScore =
        _lineQuality(current.text) + min(current.height / 1000, .08);
    if (itemScore > currentScore) values[existing] = item;
  }
  return values.take(240).toList(growable: false);
}

String _completeOcrText(Iterable<String> documents) {
  final buffer = StringBuffer();
  var remaining = maxPersistedRawOcrCharacters;
  for (final document in documents) {
    for (final raw in document.split(RegExp(r'[\r\n]+'))) {
      final line = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
      if (line.isEmpty) continue;
      final separator = buffer.isEmpty ? '' : '\n';
      if (remaining <= separator.length) return buffer.toString();
      buffer.write(separator);
      remaining -= separator.length;
      final take = line.length < remaining ? line.length : remaining;
      buffer.write(line.substring(0, take));
      remaining -= take;
      if (take < line.length || remaining == 0) return buffer.toString();
    }
  }
  return buffer.toString();
}

double _lineQuality(String value) {
  if (value.isEmpty) return 0;
  var useful = 0, replacement = 0;
  for (final code in value.runes) {
    if ((code >= 48 && code <= 57) ||
        (code >= 65 && code <= 90) ||
        (code >= 97 && code <= 122) ||
        (code >= 0x0900 && code <= 0x097F)) {
      useful++;
    }
    if (code == 0xFFFD || code == 0x7C || code == 0x7B || code == 0x7D) {
      replacement++;
    }
  }
  return useful / value.length - replacement * .08;
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
    final gs1 = parseGs1HealthcareBarcode(raw);
    if (gs1 != null && gs1.gtin.isNotEmpty) values.add(gs1.gtin);
  }
  final ranked = values.toList(growable: false)
    ..sort((a, b) {
      final score = _barcodeScore(b).compareTo(_barcodeScore(a));
      return score != 0 ? score : a.compareTo(b);
    });
  return ranked.take(8).toList(growable: false);
}

int _barcodeScore(String value) {
  if (verifiedGtinKey(value).isNotEmpty) return 4;
  final digits = value.replaceAll(RegExp(r'\D'), '');
  if (digits == value && const {8, 12, 13, 14}.contains(digits.length)) {
    return 3;
  }
  if (digits == value && digits.length >= 6) return 2;
  return 1;
}
