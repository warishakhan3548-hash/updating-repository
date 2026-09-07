import 'package:google_mlkit_barcode_scanning/google_mlkit_barcode_scanning.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

class ScanEvidence {
  const ScanEvidence({this.barcode = '', this.text = '', this.source = ''});

  final String barcode;
  final String text;
  final String source;
}

class MedicineVisionService {
  final _latin = TextRecognizer(script: TextRecognitionScript.latin);
  final _hindi = TextRecognizer(script: TextRecognitionScript.devanagiri);
  final _barcodes = BarcodeScanner();
  bool _closed = false;

  Future<ScanEvidence> analyzeFile(String path, {String source = ''}) =>
      analyze(InputImage.fromFilePath(path), source: source);

  Future<ScanEvidence> analyze(InputImage input, {String source = ''}) async {
    if (_closed) throw StateError('Medicine scanner is closed.');
    final result = await Future.wait<Object>([
      _latin.processImage(input),
      _hindi.processImage(input),
      _barcodes.processImage(input),
    ]);
    final lines = <String>{
      ...((result[0] as RecognizedText).text.split('\n')),
      ...((result[1] as RecognizedText).text.split('\n')),
    }..removeWhere((line) => line.trim().isEmpty);
    final barcodes = (result[2] as List<Barcode>)
        .map((barcode) => barcode.rawValue ?? '')
        .where((value) => value.isNotEmpty);
    return ScanEvidence(
      barcode: barcodes.isEmpty ? '' : barcodes.first,
      text: lines.join('\n'),
      source: source,
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
