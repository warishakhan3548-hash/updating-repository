import 'package:aaris_pharmacy/domain/medicine_understanding.dart';
import 'package:aaris_pharmacy/services/medicine_review_pipeline.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('medicine review evidence normalization', () {
    test('recovers layout-only OCR in physical reading order', () {
      const source = MedicineFrameEvidence(
        sequence: 4,
        quality: .96,
        layoutLines: <MedicineTextLineEvidence>[
          MedicineTextLineEvidence(
            text: '04/2028',
            left: 22,
            top: 140,
            width: 95,
            height: 18,
          ),
          MedicineTextLineEvidence(
            text: 'Amoxicillin Trihydrate I.P. 500 mg',
            left: 18,
            top: 55,
            width: 260,
            height: 18,
          ),
          MedicineTextLineEvidence(
            text: 'EXP',
            left: 18,
            top: 120,
            width: 45,
            height: 18,
          ),
          MedicineTextLineEvidence(
            text: 'NOVA CV',
            left: 18,
            top: 10,
            width: 150,
            height: 25,
          ),
          MedicineTextLineEvidence(
            text: '04/2026',
            left: 22,
            top: 100,
            width: 95,
            height: 18,
          ),
          MedicineTextLineEvidence(
            text: 'COMPOSITION',
            left: 18,
            top: 35,
            width: 130,
            height: 18,
          ),
          MedicineTextLineEvidence(
            text: 'MFG',
            left: 18,
            top: 80,
            width: 45,
            height: 18,
          ),
        ],
      );

      final normalized = normalizeMedicineReviewEvidence(
        const <MedicineFrameEvidence>[source],
      );

      expect(normalized, hasLength(1));
      final text = normalized.single.text;
      expect(text, isNotEmpty);
      expect(text.indexOf('NOVA CV'), lessThan(text.indexOf('COMPOSITION')));
      expect(
        text.indexOf('COMPOSITION'),
        lessThan(text.indexOf('Amoxicillin Trihydrate I.P. 500 mg')),
      );
      expect(text.indexOf('MFG'), lessThan(text.indexOf('04/2026')));
      expect(text.indexOf('EXP'), lessThan(text.indexOf('04/2028')));

      final result = MedicineUnderstandingEngine().understand(normalized);
      expect(result.drafts, hasLength(1));
      final draft = result.drafts.single;
      expect(draft.name.toLowerCase(), contains('nova'));
      expect(draft.salt.toLowerCase(), contains('amoxicillin'));
      expect(draft.strength.toLowerCase(), contains('500 mg'));
      expect(draft.mfg, '2026-04');
      expect(draft.expiry, '2028-04');
    });

    test('never overwrites non-empty raw OCR with layout reconstruction', () {
      const source = MedicineFrameEvidence(
        text: 'RAW OCR IS AUTHORITATIVE',
        layoutLines: <MedicineTextLineEvidence>[
          MedicineTextLineEvidence(
            text: 'DIFFERENT LAYOUT TEXT',
            left: 0,
            top: 0,
            width: 100,
            height: 18,
          ),
        ],
      );

      final normalized = normalizeMedicineReviewEvidence(
        const <MedicineFrameEvidence>[source],
      );

      expect(normalized.single, same(source));
      expect(normalized.single.text, 'RAW OCR IS AUTHORITATIVE');
    });

    test('preserves secondary barcode evidence when primary barcode is empty', () {
      const source = MedicineFrameEvidence(
        barcodes: <String>['8901234567890'],
      );

      final normalized = normalizeMedicineReviewEvidence(
        const <MedicineFrameEvidence>[source],
      );

      expect(normalized.single.text, isEmpty);
      expect(normalized.single.allBarcodes, <String>['8901234567890']);
    });
  });
}
