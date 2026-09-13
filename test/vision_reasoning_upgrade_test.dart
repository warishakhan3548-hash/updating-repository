import 'package:flutter_test/flutter_test.dart';

import '../lib/domain/medicine_scan_guidance.dart';
import '../lib/domain/medicine_understanding.dart';
import '../lib/services/scan_service.dart';

ExtractedMedicineField field(
  String value, {
  double confidence = .92,
  bool conflicted = false,
}) =>
    ExtractedMedicineField(
      value: value,
      confidence: confidence,
      support: value.isEmpty ? 0 : 1,
      conflicted: conflicted,
    );

MedicineScanDraft draft(
  Map<String, ExtractedMedicineField> fields, {
  double confidence = .88,
}) =>
    MedicineScanDraft(
      fields: fields,
      rawText: fields.values.map((value) => value.value).join('\n'),
      searchKeywords: '',
      frameSequences: const [1],
      overallConfidence: confidence,
    );

void main() {
  group('vision evidence calibration', () {
    test('preserves historical capture quality when OCR confidence is absent', () {
      expect(visionEvidenceQuality(.72, null), closeTo(.72, 1e-9));
      expect(visionEvidenceQuality(.72, 0), closeTo(.72, 1e-9));
    });

    test('a sharp image cannot hide very uncertain OCR', () {
      final weakOcr = visionEvidenceQuality(.95, .20);
      final strong = visionEvidenceQuality(.92, .90);
      expect(weakOcr, lessThan(.50));
      expect(strong, greaterThan(.85));
      expect(strong, greaterThan(weakOcr));
    });
  });

  group('streaming barcode consensus', () {
    test('requires the same code twice before accepting it', () {
      final consensus = MedicineBarcodeConsensus();
      expect(consensus.accept(const ['09504000059118']), isEmpty);
      expect(
        consensus.accept(const ['09504000059118']),
        const ['09504000059118'],
      );
    });

    test('a conflicting code resets the streak', () {
      final consensus = MedicineBarcodeConsensus();
      expect(consensus.accept(const ['09504000059118']), isEmpty);
      expect(consensus.accept(const ['8901234567890']), isEmpty);
      expect(
        consensus.accept(const ['8901234567890']),
        const ['8901234567890'],
      );
    });
  });

  group('next best medicine scan', () {
    test('asks for the front when identity is missing', () {
      final advice = nextBestMedicineScanAdvice(
        draft({
          'strength': field('500 mg'),
          'form': field('Tablet'),
        }, confidence: .55),
      );
      expect(advice?.focus, MedicineScanFocus.frontIdentity);
    });

    test('strength conflict outranks optional missing fields', () {
      final advice = nextBestMedicineScanAdvice(
        draft({
          'name': field('Dolo 650'),
          'strength': field('650 mg', confidence: .70, conflicted: true),
          'salt': field('Paracetamol'),
          'form': field('Tablet'),
        }, confidence: .70),
      );
      expect(advice?.focus, MedicineScanFocus.strength);
    });

    test('DataMatrix is highest information gain when lot facts are missing', () {
      final advice = nextBestMedicineScanAdvice(
        draft({
          'name': field('Dolo 650'),
          'brand': field('Dolo'),
          'strength': field('650 mg'),
          'salt': field('Paracetamol'),
          'form': field('Tablet'),
        }, confidence: .84),
      );
      expect(advice?.focus, MedicineScanFocus.dataMatrix);
      expect(advice?.message, contains('DataMatrix'));
    });

    test('does not nag for an already coherent pack', () {
      final advice = nextBestMedicineScanAdvice(
        draft({
          'name': field('Dolo 650'),
          'brand': field('Dolo'),
          'salt': field('Paracetamol'),
          'strength': field('650 mg'),
          'form': field('Tablet'),
          'barcode': field('09504000059118'),
          'expiry': field('2027-08'),
          'batchNumber': field('A12'),
        }, confidence: .94),
      );
      expect(advice, isNull);
    });
  });
}
