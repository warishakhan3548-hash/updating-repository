import 'package:aaris_pharmacy/domain/intake_resolution.dart';
import 'package:aaris_pharmacy/domain/medicine.dart';
import 'package:aaris_pharmacy/domain/medicine_understanding.dart';
import 'package:flutter_test/flutter_test.dart';

ExtractedMedicineField _field(
  String value, {
  double confidence = .95,
  bool conflicted = false,
}) => ExtractedMedicineField(
  value: value,
  confidence: confidence,
  support: 2,
  conflicted: conflicted,
);

MedicineScanDraft _draft({
  String name = 'Dolo',
  String strength = '650mg',
  String form = 'Tablet',
  String salt = 'Paracetamol',
  String brand = '',
  String manufacturer = '',
  String batch = 'B-100',
  String barcode = '8901234567890',
  String expiry = '2027-12',
  String mfg = '2026-01',
  double overall = .95,
  bool batchConflict = false,
  double nameConfidence = .95,
}) => MedicineScanDraft(
  fields: <String, ExtractedMedicineField>{
    if (name.isNotEmpty) 'name': _field(name, confidence: nameConfidence),
    if (strength.isNotEmpty) 'strength': _field(strength),
    if (form.isNotEmpty) 'form': _field(form),
    if (salt.isNotEmpty) 'salt': _field(salt),
    if (brand.isNotEmpty) 'brand': _field(brand),
    if (manufacturer.isNotEmpty) 'manufacturer': _field(manufacturer),
    if (batch.isNotEmpty)
      'batchNumber': _field(batch, conflicted: batchConflict),
    if (barcode.isNotEmpty) 'barcode': _field(barcode),
    if (expiry.isNotEmpty) 'expiry': _field(expiry),
    if (mfg.isNotEmpty) 'mfg': _field(mfg),
  },
  rawText: 'pack text',
  searchKeywords: 'dolo 650',
  frameSequences: const <int>[1],
  expiryMonthOnly: expiry.length == 7,
  mfgMonthOnly: mfg.length == 7,
  overallConfidence: overall,
);

Medicine _medicine(
  String id, {
  String name = 'Dolo',
  String strength = '650mg',
  String form = 'Tablet',
  String salt = 'Paracetamol',
  String brand = '',
  String manufacturer = '',
  String batch = 'B-100',
  String barcode = '8901234567890',
  String expiry = '2027-12',
  String mfg = '2026-01',
  int? quantity = 10,
  bool sold = false,
}) => Medicine.fromJson(<String, dynamic>{
  'id': id,
  'name': name,
  'strength': strength,
  'form': form,
  'salt': salt,
  'brand': brand,
  'manufacturer': manufacturer,
  'batchNumber': batch,
  'barcode': barcode,
  'expiry': expiry,
  'mfg': mfg,
  'quantity': sold ? 0 : quantity,
  'sold': sold,
  if (sold) 'soldAt': '2026-09-01T10:00:00.000',
  if (sold) 'soldQuantity': 10,
});

void main() {
  final today = DateTime(2026, 9, 10);

  group('scan-to-stock intake resolution', () {
    test('trusted barcode batch and dates resolve one exact lot', () {
      final stock = _medicine('lot-a');
      final result = resolveIntakeDraft(
        draft: _draft(),
        records: <Medicine>[stock],
        today: today,
      );

      expect(result.kind, IntakeResolutionKind.exactLot);
      expect(result.exactStockId, stock.id);
      expect(result.candidateStockIds, <String>[stock.id]);
      expect(result.safeToReceive, isTrue);
      expect(result.receiveBlockReason, isEmpty);
    });

    test('same product with a different batch is not merged into existing lot', () {
      final stock = _medicine('lot-a', batch: 'OLD-1', expiry: '2027-10');
      final result = resolveIntakeDraft(
        draft: _draft(batch: 'NEW-2', expiry: '2028-01'),
        records: <Medicine>[stock],
        today: today,
      );

      expect(result.kind, IntakeResolutionKind.sameProduct);
      expect(result.exactStockId, isNull);
      expect(result.safeToReceive, isFalse);
      expect(result.candidateStockIds, contains(stock.id));
    });

    test('same trusted batch with conflicting expiry fails closed', () {
      final stock = _medicine('lot-a', batch: 'B-100', expiry: '2027-10');
      final result = resolveIntakeDraft(
        draft: _draft(batch: 'B-100', expiry: '2028-01'),
        records: <Medicine>[stock],
        today: today,
      );

      expect(result.kind, IntakeResolutionKind.needsReview);
      expect(result.exactStockId, isNull);
      expect(result.safeToReceive, isFalse);
      expect(result.candidateStockIds, <String>[stock.id]);
      expect(result.reason, contains('already exists'));
    });

    test('one barcode saved for different identities fails closed', () {
      final first = _medicine('a');
      final second = _medicine(
        'b',
        name: 'Azithro',
        strength: '500mg',
        salt: 'Azithromycin',
        batch: 'AZ-1',
      );
      final result = resolveIntakeDraft(
        draft: _draft(),
        records: <Medicine>[first, second],
        today: today,
      );

      expect(result.kind, IntakeResolutionKind.ambiguous);
      expect(result.safeToReceive, isFalse);
      expect(result.candidateStockIds.toSet(), <String>{first.id, second.id});
    });

    test('trusted OCR identity conflicting with saved barcode requires review', () {
      final stock = _medicine('a', name: 'Azithro', salt: 'Azithromycin');
      final result = resolveIntakeDraft(
        draft: _draft(name: 'Dolo', salt: 'Paracetamol'),
        records: <Medicine>[stock],
        today: today,
      );

      expect(result.kind, IntakeResolutionKind.needsReview);
      expect(result.safeToReceive, isFalse);
      expect(result.candidateStockIds, <String>[stock.id]);
      expect(result.reason, contains('conflicts'));
    });

    test('duplicate rows matching the same physical lot remain ambiguous', () {
      final first = _medicine('a');
      final second = _medicine('b');
      final result = resolveIntakeDraft(
        draft: _draft(),
        records: <Medicine>[first, second],
        today: today,
      );

      expect(result.kind, IntakeResolutionKind.ambiguous);
      expect(result.exactStockId, isNull);
      expect(result.safeToReceive, isFalse);
    });

    test('low-confidence identity cannot unlock existing-stock automation', () {
      final result = resolveIntakeDraft(
        draft: _draft(
          barcode: '',
          batch: '',
          expiry: '',
          mfg: '',
          strength: '',
          form: '',
          salt: '',
          nameConfidence: .55,
          overall: .55,
        ),
        records: <Medicine>[_medicine('a')],
        today: today,
      );

      expect(result.kind, IntakeResolutionKind.needsReview);
      expect(result.candidateStockIds, isEmpty);
    });

    test('high-confidence unseen medicine stays a reviewed new-stock draft', () {
      final result = resolveIntakeDraft(
        draft: _draft(
          name: 'NewMed',
          strength: '20mg',
          salt: 'New Salt',
          batch: 'N-1',
          barcode: '8909999999999',
        ),
        records: <Medicine>[_medicine('a')],
        today: today,
      );

      expect(result.kind, IntakeResolutionKind.newStock);
      expect(result.safeToReceive, isFalse);
      expect(result.candidateStockIds, isEmpty);
    });

    test('expired exact lot is identified but receiving is blocked', () {
      final stock = _medicine('a', expiry: '2026-08');
      final result = resolveIntakeDraft(
        draft: _draft(expiry: '2026-08'),
        records: <Medicine>[stock],
        today: today,
      );

      expect(result.kind, IntakeResolutionKind.exactLot);
      expect(result.exactStockId, stock.id);
      expect(result.safeToReceive, isFalse);
      expect(result.receiveBlockReason, contains('expired'));
    });

    test('exact lot with unknown current quantity cannot receive blindly', () {
      final stock = _medicine('a', quantity: null);
      final result = resolveIntakeDraft(
        draft: _draft(),
        records: <Medicine>[stock],
        today: today,
      );

      expect(result.kind, IntakeResolutionKind.exactLot);
      expect(result.safeToReceive, isFalse);
      expect(result.receiveBlockReason, contains('quantity is unknown'));
    });

    test('identity plus trusted batch can resolve without a retail barcode', () {
      final stock = _medicine('a', barcode: '');
      final result = resolveIntakeDraft(
        draft: _draft(barcode: ''),
        records: <Medicine>[stock],
        today: today,
      );

      expect(result.kind, IntakeResolutionKind.exactLot);
      expect(result.exactStockId, stock.id);
      expect(result.safeToReceive, isTrue);
    });

    test('conflicted OCR batch cannot be used as an exact-lot anchor', () {
      final stock = _medicine('a', barcode: '', expiry: '');
      final result = resolveIntakeDraft(
        draft: _draft(
          barcode: '',
          batchConflict: true,
          expiry: '',
          mfg: '',
        ),
        records: <Medicine>[stock],
        today: today,
      );

      expect(result.kind, IntakeResolutionKind.sameProduct);
      expect(result.safeToReceive, isFalse);
    });
  });
}
