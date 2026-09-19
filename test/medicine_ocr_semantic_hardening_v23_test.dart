import 'package:aaris_pharmacy/domain/medicine_date_intelligence.dart';
import 'package:aaris_pharmacy/domain/medicine_date_parser.dart';
import 'package:aaris_pharmacy/domain/medicine_ocr_text.dart';
import 'package:aaris_pharmacy/domain/medicine_understanding.dart';
import 'package:flutter_test/flutter_test.dart';

MedicineTextLineEvidence _line(
  String text, {
  required double left,
  required double top,
  double width = 70,
  double height = 12,
}) => MedicineTextLineEvidence(
  text: text,
  left: left,
  top: top,
  width: width,
  height: height,
);

void main() {
  group('medicine OCR semantic hardening V23', () {
    test('equivalent decimal scripts dedupe without rewriting audit text', () {
      expect(
        mergeMedicineOcrLines(<String>[
          'EXP 04/2028',
          'EXP ०४/२०२८',
          'EXP ٠٤/٢٠٢٨',
          'EXP ۰۴/۲۰۲۸',
          'EXP ０４／２０２８',
        ]),
        <String>['EXP 04/2028'],
      );
    });

    test('date parser repairs full-width digits and Unicode separators', () {
      expect(parseMedicineDateText('EXP ０４／２０２８')?.value, '2028-04');
      expect(parseMedicineDateText('MFG ０４–２０２６')?.value, '2026-04');
    });

    test('date-of-expiry and BBE labels are authoritative expiry roles', () {
      expect(medicineExpiryLabel.hasMatch('DATE OF EXPIRY 04/2028'), isTrue);
      expect(medicineExpiryLabel.hasMatch('BBE 04/2028'), isTrue);
      final result = inferMedicineDateIntelligence(
        frames: const <MedicineFrameEvidence>[
          MedicineFrameEvidence(
            text: 'MFG 04/2026\nDATE OF EXPIRY 04/2028',
            quality: .98,
          ),
        ],
        referenceDate: DateTime.utc(2026, 9, 14),
      );
      expect(result.manufacturing?.date.value, '2026-04');
      expect(result.expiry?.date.value, '2028-04');
      expect(result.conflicted, isFalse);
    });

    test('MFG BY and MFG AT are manufacturer metadata, never date labels', () {
      expect(medicineManufacturingLabel.hasMatch('MFG. BY ACME PHARMA'), isFalse);
      expect(medicineManufacturingLabel.hasMatch('MFG . AT PLANT 2'), isFalse);
      expect(medicineNonDateLabel.hasMatch('MFG. BY ACME PHARMA'), isTrue);
      expect(medicineNonDateLabel.hasMatch('MFG . AT PLANT 2'), isTrue);
      final result = inferMedicineDateIntelligence(
        frames: const <MedicineFrameEvidence>[
          MedicineFrameEvidence(
            text: 'MFG. BY ACME PHARMA\n04/2026\nEXP 04/2028',
            quality: .98,
          ),
        ],
        referenceDate: DateTime.utc(2026, 9, 14),
      );
      expect(result.manufacturing, isNull);
      expect(result.expiry?.date.value, '2028-04');
    });

    test('fragmented same-row layout overrides unsafe flattened raw order', () {
      final result = inferMedicineDateIntelligence(
        frames: <MedicineFrameEvidence>[
          MedicineFrameEvidence(
            text: 'MFG\nEXP\n04/2026\n04/2028',
            quality: .98,
            layoutLines: <MedicineTextLineEvidence>[
              _line('MFG', left: 0, top: 0),
              _line('04/2026', left: 55, top: 0),
              _line('EXP', left: 150, top: 0),
              _line('04/2028', left: 205, top: 0),
            ],
          ),
        ],
        referenceDate: DateTime.utc(2026, 9, 14),
      );
      expect(result.manufacturing?.date.value, '2026-04');
      expect(result.expiry?.date.value, '2028-04');
      expect(result.conflicted, isFalse);
    });

    test('two-column header rows cannot invert MFG and EXP by raw adjacency', () {
      final result = inferMedicineDateIntelligence(
        frames: <MedicineFrameEvidence>[
          MedicineFrameEvidence(
            text: 'MFG\nEXP\n04/2026\n04/2028',
            quality: .98,
            layoutLines: <MedicineTextLineEvidence>[
              _line('MFG', left: 0, top: 0),
              _line('EXP', left: 150, top: 0),
              _line('04/2026', left: 0, top: 24),
              _line('04/2028', left: 150, top: 24),
            ],
          ),
        ],
        referenceDate: DateTime.utc(2026, 9, 14),
      );
      expect(result.manufacturing?.date.value, '2026-04');
      expect(result.expiry?.date.value, '2028-04');
      expect(result.conflicted, isFalse);
    });
  });
}
