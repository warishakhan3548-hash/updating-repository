import 'package:flutter_test/flutter_test.dart';

import 'package:aaris_pharmacy/domain/medicine_confusion_firewall.dart';
import 'package:aaris_pharmacy/domain/medicine_resolution_v2.dart';
import 'package:aaris_pharmacy/domain/medicine_understanding.dart';
import 'package:aaris_pharmacy/domain/regulatory_medicine_code.dart';
import 'package:aaris_pharmacy/domain/spatial_traceability.dart';

ExtractedMedicineField _field(String value, {double confidence = .94}) =>
    ExtractedMedicineField(
      value: value,
      confidence: confidence,
      support: 2,
    );

void main() {
  group('Aaris Offline V9 Level 6', () {
    test('LASA firewall recognizes dangerous middle-segment drug names', () {
      final result = assessMedicineConfusion(
        const MedicineConfusionIdentity(
          name: 'Vinblastine',
          salt: 'Vinblastine sulfate',
          strength: '1 mg',
          form: 'Injection',
        ),
        const MedicineConfusionIdentity(
          name: 'Vincristine',
          salt: 'Vincristine sulfate',
          strength: '1 mg',
          form: 'Injection',
        ),
      );

      expect(result.highRisk, isTrue);
      expect(result.commonPrefix, greaterThanOrEqualTo(3));
      expect(result.commonSuffix, greaterThanOrEqualTo(4));
      expect(result.criticalFields, contains('salt'));
    });

    test('similar names are not dangerous when critical identity is same', () {
      final result = assessMedicineConfusion(
        const MedicineConfusionIdentity(
          name: 'Dolo',
          salt: 'Paracetamol',
          strength: '650 mg',
          form: 'Tablet',
        ),
        const MedicineConfusionIdentity(
          name: 'Dolo 650',
          salt: 'Paracetamol',
          strength: '650 mg',
          form: 'Tablet',
        ),
      );

      expect(result.highRisk, isFalse);
      expect(result.criticalFields, isEmpty);
    });

    test('GS1 Digital Link becomes verified offline traceability', () {
      final result = parseRegulatoryMedicineCode(
        'https://id.gs1.org/01/08901234567890/10/LOT7/17/280731?21=SER9',
      );

      expect(result, isNotNull);
      expect(result!.kind, RegulatoryMedicineCodeKind.gs1DigitalLink);
      expect(result.gtin, '08901234567890');
      expect(result.batchLot, 'LOT7');
      expect(result.expiryYyMmDd, '280731');
      expect(result.serial, 'SER9');
    });

    test('strict labelled medicine QR recovers traceability without cloud', () {
      final result = parseRegulatoryMedicineCode(
        'GTIN: 08901234567890; BATCH: LOT7; MFG: 08/2026; EXP: 07/2028',
      );

      expect(result, isNotNull);
      expect(result!.kind, RegulatoryMedicineCodeKind.labelledPayload);
      expect(result.gtin, '08901234567890');
      expect(result.batchLot, 'LOT7');
      expect(result.manufacturingYyMmDd, '260800');
      expect(result.expiryYyMmDd, '280700');
    });

    test('ordinary marketing URL is never promoted to medicine identity', () {
      expect(
        parseRegulatoryMedicineCode('https://example.invalid/promo/dolo'),
        isNull,
      );
    });

    test('spatial graph binds MFG EXP and batch to nearby printed values', () {
      const frame = MedicineFrameEvidence(
        sequence: 0,
        quality: .95,
        text: 'TESTMED\nMFG\n08/2026\nEXP\n07/2028\nBATCH\nAB12',
        layoutLines: <MedicineTextLineEvidence>[
          MedicineTextLineEvidence(
            text: 'MFG',
            left: 10,
            top: 100,
            width: 45,
            height: 20,
          ),
          MedicineTextLineEvidence(
            text: '08/2026',
            left: 70,
            top: 100,
            width: 80,
            height: 20,
          ),
          MedicineTextLineEvidence(
            text: 'EXP',
            left: 10,
            top: 140,
            width: 45,
            height: 20,
          ),
          MedicineTextLineEvidence(
            text: '07/2028',
            left: 70,
            top: 140,
            width: 80,
            height: 20,
          ),
          MedicineTextLineEvidence(
            text: 'BATCH',
            left: 10,
            top: 180,
            width: 55,
            height: 20,
          ),
          MedicineTextLineEvidence(
            text: 'AB12',
            left: 75,
            top: 180,
            width: 60,
            height: 20,
          ),
        ],
      );

      final hints = inferSpatialTraceability(const <MedicineFrameEvidence>[frame]);
      expect(hints.mfg?.value, '2026-08');
      expect(hints.expiry?.value, '2028-07');
      expect(hints.batch?.value, 'AB12');
      expect(hints.mfg?.conflicted, isFalse);
      expect(hints.expiry?.conflicted, isFalse);
    });

    test('LASA pair cannot auto-fill missing discriminating salt', () {
      const winner = CanonicalMedicineProduct(
        productId: 'rx:vincristine:1mg:inj',
        revision: 1,
        name: 'Vincristine',
        brand: 'Vincristine',
        salt: 'Vincristine sulfate',
        strength: '1 mg',
        form: 'Injection',
        verified: true,
      );
      const confusable = CanonicalMedicineProduct(
        productId: 'rx:vinblastine:1mg:inj',
        revision: 1,
        name: 'Vinblastine',
        brand: 'Vinblastine',
        salt: 'Vinblastine sulfate',
        strength: '1 mg',
        form: 'Injection',
        verified: true,
      );
      final draft = MedicineScanDraft(
        fields: <String, ExtractedMedicineField>{
          'name': _field('Vincristine', confidence: .97),
          'brand': _field('Vincristine', confidence: .97),
          'strength': _field('1 mg', confidence: .94),
          'form': _field('Injection', confidence: .94),
        },
        rawText: 'VINCRISTINE\n1 mg\nINJECTION',
        searchKeywords: 'vincristine 1 mg injection',
        frameSequences: const <int>[0],
        overallConfidence: .94,
      );
      final resolved = MedicineProductResolverV2(
        localKnowledge: const <MedicineKnowledgeEntry>[],
        catalogue: const <CanonicalMedicineProduct>[winner, confusable],
      ).reconcile(
        MedicineUnderstandingResult(drafts: <MedicineScanDraft>[draft]),
        const <MedicineFrameEvidence>[
          MedicineFrameEvidence(
            sequence: 0,
            quality: .95,
            text: 'VINCRISTINE\n1 mg\nINJECTION',
          ),
        ],
      );

      expect(resolved.drafts.single.salt, isEmpty);
      expect(resolved.drafts.single.overallConfidence, lessThan(.78));
    });
  });
}
