import 'package:google_mlkit_barcode_scanning/google_mlkit_barcode_scanning.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

import '../domain/medicine_understanding.dart';
import '../domain/search.dart';

typedef ScanEvidence = MedicineFrameEvidence;

class MedicineVisionService {
  final _latin = TextRecognizer(script: TextRecognitionScript.latin);
  final _hindi = TextRecognizer(script: TextRecognitionScript.devanagiri);
  final _barcodes = BarcodeScanner();
  bool _closed = false;

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
    if (_closed) throw StateError('Medicine scanner is closed.');
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
    final lines = _mergeLines([
      if (latin is RecognizedText)
        ...(latin as RecognizedText).text.split('\n'),
      if (hindi is RecognizedText)
        ...(hindi as RecognizedText).text.split('\n'),
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
      text: lines.join('\n'),
      source: source,
      sequence: sequence,
      timestampMs: timestampMs,
      quality: quality.clamp(0, 1),
    );
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _latin.close();
    await _hindi.close();
    await _barcodes.close();
  }
}

List<String> _mergeLines(Iterable<String> raw) {
  final values = <String>[];
  final normalized = <String>[];
  for (final item in raw.take(500)) {
    final value = item.replaceAll(RegExp(r'\s+'), ' ').trim();
    final key = searchText(value);
    if (key.length < 2) continue;
    var duplicate = -1;
    for (var index = 0; index < normalized.length; index++) {
      if (key == normalized[index] ||
          (key.length >= 6 &&
              normalized[index].length >= 6 &&
              orderedSimilarity(key, normalized[index]) >= .96)) {
        duplicate = index;
        break;
      }
    }
    if (duplicate < 0) {
      values.add(value);
      normalized.add(key);
    } else if (_lineQuality(value) > _lineQuality(values[duplicate])) {
      values[duplicate] = value;
      normalized[duplicate] = key;
    }
  }
  return values;
}

double _lineQuality(String value) {
  if (value.isEmpty) return 0;
  final useful = value.runes.where((code) {
    final character = String.fromCharCode(code);
    return RegExp(r'[A-Za-z0-9\u0900-\u097f]').hasMatch(character);
  }).length;
  final replacement = RegExp(r'[�|{}]').allMatches(value).length;
  return useful / value.length - replacement * .08;
}

List<String> _rankBarcodes(Iterable<String> input) {
  final values = input.map((value) => value.trim()).toSet().toList();
  values.sort((a, b) {
    final score = _barcodeScore(b).compareTo(_barcodeScore(a));
    return score != 0 ? score : a.compareTo(b);
  });
  return values.take(8).toList(growable: false);
}

int _barcodeScore(String value) {
  final digits = value.replaceAll(RegExp(r'\D'), '');
  if (digits == value && const {8, 12, 13, 14}.contains(digits.length)) {
    return _validGtin(digits) ? 4 : 3;
  }
  if (digits == value && digits.length >= 6) return 2;
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
