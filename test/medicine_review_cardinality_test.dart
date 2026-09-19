import 'package:flutter_test/flutter_test.dart';

import '../lib/domain/medicine_review_cardinality.dart';
import '../lib/domain/medicine_understanding.dart';

void main() {
  test('single physical pack collapses noisy sibling OCR drafts safely', () {
    final drafts = <MedicineScanDraft>[
      _draft(
        name: 'Calcium',
        salt: 'Calcium Vitamin D3 Vitamin B12',
        form: 'Syrup',
        confidence: .86,
        sequence: 0,
        rawText: 'CALCIUM\nVITAMIN D3 & VITAMIN B12\nSUSPENSION',
      ),
      _draft(
        name: 'SHAKE WELL BEFORE USE',
        mfg: '2026-05',
        expiry: '2027-10',
        confidence: .72,
        sequence: 1,
        rawText: 'SHAKE WELL BEFORE USE\nMFG 05/2026\nEXP 10/2027',
      ),
    ];

    final normalized = normalizeMedicineReviewDrafts(
      drafts,
      singlePackExpected: true,
    );

    expect(normalized, hasLength(1));
    final result = normalized.single;
    expect(result.name, 'Calcium');
    expect(result.mfg, '2026-05');
    expect(result.expiry, '2027-10');
    expect(result.frameSequences, <int>[0, 1]);
    expect(result.rawText, contains('SHAKE WELL BEFORE USE'));
    expect(result.overallConfidence, lessThan(.78));
  });

  test('multi-medicine source preserves every draft', () {
    final drafts = <MedicineScanDraft>[
      _draft(name: 'Dolo', confidence: .91, sequence: 0),
      _draft(name: 'Azithral', confidence: .90, sequence: 1),
    ];

    final normalized = normalizeMedicineReviewDrafts(
      drafts,
      singlePackExpected: false,
    );

    expect(normalized, hasLength(2));
    expect(normalized[0].name, 'Dolo');
    expect(normalized[1].name, 'Azithral');
  });

  test('contradictory lot facts stay review-required after collapse', () {
    final drafts = <MedicineScanDraft>[
      _draft(
        name: 'Dolo',
        expiry: '2028-07',
        confidence: .92,
        sequence: 0,
      ),
      _draft(
        name: 'Dolo',
        expiry: '2029-01',
        confidence: .88,
        sequence: 1,
      ),
    ];

    final result = normalizeMedicineReviewDrafts(
      drafts,
      singlePackExpected: true,
    ).single;

    expect(result.field('expiry').conflicted, isTrue);
    expect(result.field('expiry').confidence, lessThan(.78));
    expect(result.needsReview, isTrue);
  });

  test('month precision and exact day in same month are compatible', () {
    final drafts = <MedicineScanDraft>[
      _draft(
        name: 'Dolo',
        mfg: '2026-04',
        expiry: '2028-04',
        confidence: .91,
        sequence: 0,
      ),
      _draft(
        name: 'Dolo',
        mfg: '2026-04-05',
        expiry: '2028-04-30',
        confidence: .90,
        sequence: 1,
      ),
    ];

    final result = normalizeMedicineReviewDrafts(
      drafts,
      singlePackExpected: true,
    ).single;

    expect(result.mfg, '2026-04-05');
    expect(result.expiry, '2028-04-30');
    expect(result.field('mfg').conflicted, isFalse);
    expect(result.field('expiry').conflicted, isFalse);
    expect(result.mfgMonthOnly, isFalse);
    expect(result.expiryMonthOnly, isFalse);
  });

  test('two different exact days in the same month remain conflicting', () {
    final drafts = <MedicineScanDraft>[
      _draft(
        name: 'Dolo',
        expiry: '2028-04-05',
        confidence: .92,
        sequence: 0,
      ),
      _draft(
        name: 'Dolo',
        expiry: '2028-04-06',
        confidence: .90,
        sequence: 1,
      ),
    ];

    final result = normalizeMedicineReviewDrafts(
      drafts,
      singlePackExpected: true,
    ).single;

    expect(result.field('expiry').conflicted, isTrue);
    expect(result.field('expiry').confidence, lessThan(.78));
    expect(result.needsReview, isTrue);
  });
}

MedicineScanDraft _draft({
  required String name,
  String salt = '',
  String form = '',
  String mfg = '',
  String expiry = '',
  required double confidence,
  required int sequence,
  String rawText = '',
}) {
  ExtractedMedicineField field(String value, {double? score}) =>
      ExtractedMedicineField(
        value: value,
        confidence: score ?? confidence,
        support: value.isEmpty ? 0 : 1,
      );

  return MedicineScanDraft(
    fields: <String, ExtractedMedicineField>{
      'name': field(name),
      if (salt.isNotEmpty) 'salt': field(salt),
      if (form.isNotEmpty) 'form': field(form),
      if (mfg.isNotEmpty) 'mfg': field(mfg, score: .90),
      if (expiry.isNotEmpty) 'expiry': field(expiry, score: .91),
    },
    rawText: rawText.isEmpty ? name : rawText,
    searchKeywords: <String>[name, salt, form]
        .where((value) => value.isNotEmpty)
        .join(' '),
    frameSequences: <int>[sequence],
    overallConfidence: confidence,
  );
}
