import 'package:aaris_pharmacy/domain/medicine_ocr_text.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('medicine extraction hardening V42', () {
    test('completed nearby packaging fields no longer poison glued dose recovery', () {
      expect(
        normalizeMedicineOcrLine('PACK OF 10 CALPOL500MG TABLETS'),
        'PACK OF 10 CALPOL 500MG TABLETS',
      );
      expect(
        normalizeMedicineOcrLine('MRP 50 CALPOL500MG TABLETS'),
        'MRP 50 CALPOL 500MG TABLETS',
      );
      expect(
        normalizeMedicineOcrLine('EXP 04/2028 CALPOL500MG TABLETS'),
        'EXP 04/2028 CALPOL 500MG TABLETS',
      );
    });

    test('immediate traceability ownership still blocks machine-code dose repair', () {
      expect(
        normalizeMedicineOcrLine('BATCH NO ABC500MG'),
        'BATCH NO ABC500MG',
      );
      expect(
        normalizeMedicineOcrLine('CODE ABC500MG'),
        'CODE ABC500MG',
      );
      expect(
        normalizeMedicineOcrLine('BATCH NO 125mg5ml'),
        'BATCH NO 125mg5ml',
      );
    });

    test('nearby pack text does not block a fused liquid concentration', () {
      expect(
        normalizeMedicineOcrLine(
          'PACK OF 1 CALPOL PARACETAMOL125mg5ml',
        ),
        'PACK OF 1 CALPOL PARACETAMOL 125 mg/5 ml',
      );
    });

    test('completed price context does not block a real combination row', () {
      expect(
        normalizeMedicineOcrLine(
          'MRP 50 AMOXICILLIN I.P. 500 mg & CLAVULANIC ACID I.P. 125 mg',
        ),
        'MRP 50 AMOXICILLIN I.P. 500 mg + CLAVULANIC ACID I.P. 125 mg',
      );
      expect(
        normalizeMedicineOcrLine('BATCH 500 mg & ABC 125 mg'),
        'BATCH 500 mg & ABC 125 mg',
      );
    });
  });
}
