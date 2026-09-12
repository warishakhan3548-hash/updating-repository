import 'package:aaris_pharmacy/domain/attention.dart';
import 'package:aaris_pharmacy/domain/medicine.dart';
import 'package:aaris_pharmacy/domain/tracking.dart';
import 'package:flutter_test/flutter_test.dart';

Medicine _stock(
  String id, {
  String name = 'Paracetamol',
  String strength = '500mg',
  String expiry = '2026-09-10',
  String barcode = '',
  String batchNumber = '',
  String notes = '',
  String salt = '',
  String brand = '',
  String manufacturer = '',
  int? quantity = 10,
  int? price = 200,
  String form = 'Tablet',
  bool sold = false,
  String? soldAt,
  int? soldQuantity,
  int? soldUnitPricePaise,
}) => Medicine.fromJson({
  'id': id,
  'name': name,
  'strength': strength,
  'expiry': expiry,
  'barcode': barcode,
  'batchNumber': batchNumber,
  'notes': notes,
  'salt': salt,
  'brand': brand,
  'manufacturer': manufacturer,
  'quantity': sold ? 0 : quantity,
  'unitPricePaise': price,
  'form': form,
  'sold': sold,
  'soldAt': soldAt,
  'soldQuantity': soldQuantity,
  'soldUnitPricePaise': soldUnitPricePaise,
});

final _today = DateTime(2026, 9, 7, 23, 59);

void main() {
  group('deterministic pharmacist attention engine', () {
    test('prioritizes expiry, stock mismatch, data gaps and reorder facts', () {
      final report = PharmacyAttentionReport.build(
        medicines: [
          _stock('expired', name: 'ExpiredMed', expiry: '2026-09-05'),
          _stock('short', name: 'ShortMed', expiry: '2026-09-09'),
          _stock('zero', name: 'ZeroMed', expiry: '2027-01', quantity: 0),
          _stock('unknown-exp', name: 'NoExpiry', expiry: ''),
          _stock(
            'unknown-qty',
            name: 'NoQuantity',
            expiry: '2027-01',
            quantity: null,
          ),
        ],
        settings: const WarningSettings(),
        today: _today,
        reorder: const [
          ReorderSuggestion(
            productKey: 'urgent-product',
            name: 'UrgentMed',
            salt: '',
            strength: '10mg',
            form: 'Tablet',
            priority: ReorderPriority.urgent,
            reason: 'Out of stock',
            suggestedQuantity: 10,
            unitsSold: 4,
            unitsPerDay: .4,
            stockIds: ['urgent-stock'],
            confidence: .95,
            reviewRequired: false,
          ),
        ],
      );

      expect(report.items.first.kind, AttentionKind.expiredStock);
      expect(report.critical, 1);
      expect(
        report.items.map((item) => item.kind),
        contains(AttentionKind.shortExpiry),
      );
      expect(
        report.items.map((item) => item.kind),
        contains(AttentionKind.zeroQuantityMismatch),
      );
      expect(
        report.items.map((item) => item.kind),
        contains(AttentionKind.unknownExpiry),
      );
      expect(
        report.items.map((item) => item.kind),
        contains(AttentionKind.unknownQuantity),
      );
      expect(
        report.items.map((item) => item.kind),
        contains(AttentionKind.urgentReorder),
      );
    });

    test('flags a barcode only when active records disagree on identity', () {
      final sameIdentity = PharmacyAttentionReport.build(
        medicines: [
          _stock('a', name: 'Dolo', strength: '650mg', barcode: '111'),
          _stock('b', name: 'Dolo', strength: '650mg', barcode: '111'),
        ],
        settings: const WarningSettings(),
        today: _today,
        reorder: const [],
      );
      expect(
        sameIdentity.items.where(
          (item) => item.kind == AttentionKind.barcodeConflict,
        ),
        isEmpty,
      );

      final conflict = PharmacyAttentionReport.build(
        medicines: [
          _stock('a', name: 'Dolo', strength: '650mg', barcode: '111'),
          _stock('b', name: 'Crocin', strength: '500mg', barcode: '111'),
        ],
        settings: const WarningSettings(),
        today: _today,
        reorder: const [],
      );
      final barcodeItems = conflict.items.where(
        (item) => item.kind == AttentionKind.barcodeConflict,
      );
      expect(barcodeItems, hasLength(1));
      expect(barcodeItems.single.stockIds.toSet(), {'a', 'b'});
      expect(barcodeItems.single.severity, AttentionSeverity.high);
    });

    test('detects contradictory saved facts for one strongly anchored lot', () {
      final report = PharmacyAttentionReport.build(
        medicines: [
          _stock(
            'lot-a',
            name: 'Dolo',
            strength: '650mg',
            barcode: '890123',
            batchNumber: 'B-17',
            expiry: '2027-01',
          ),
          _stock(
            'lot-b',
            name: 'Dolo',
            strength: '650mg',
            barcode: '890123',
            batchNumber: 'B-17',
            expiry: '2027-02',
          ),
        ],
        settings: const WarningSettings(),
        today: _today,
        reorder: const [],
      );

      final conflicts = report.items.where(
        (item) => item.kind == AttentionKind.conflictingLotFacts,
      );
      expect(conflicts, hasLength(1));
      expect(conflicts.single.severity, AttentionSeverity.high);
      expect(conflicts.single.stockIds.toSet(), {'lot-a', 'lot-b'});
      expect(conflicts.single.detail, contains('expiry'));
    });

    test(
      'does not treat a bare reused batch number as the same physical lot',
      () {
        final report = PharmacyAttentionReport.build(
          medicines: [
            _stock(
              'weak-a',
              name: 'Paracetamol',
              batchNumber: 'COMMON-1',
              expiry: '2027-01',
            ),
            _stock(
              'weak-b',
              name: 'Paracetamol',
              batchNumber: 'COMMON-1',
              expiry: '2027-02',
            ),
          ],
          settings: const WarningSettings(),
          today: _today,
          reorder: const [],
        );

        expect(
          report.items.where(
            (item) => item.kind == AttentionKind.conflictingLotFacts,
          ),
          isEmpty,
        );
      },
    );

    test('surfaces stale active SOLD metadata instead of trusting it', () {
      final report = PharmacyAttentionReport.build(
        medicines: [
          _stock(
            'stale',
            name: 'ActiveMed',
            expiry: '2027-02',
            soldAt: '2026-08-01T10:00:00.000',
            soldQuantity: 12,
            soldUnitPricePaise: 450,
          ),
        ],
        settings: const WarningSettings(),
        today: _today,
        reorder: const [],
      );

      final issues = report.items.where(
        (item) => item.kind == AttentionKind.staleSoldMetadata,
      );
      expect(issues, hasLength(1));
      expect(issues.single.severity, AttentionSeverity.high);
      expect(issues.single.stockIds, ['stale']);
    });

    test('surfaces incomplete or future SOLD audit facts without mutation', () {
      final incomplete = PharmacyAttentionReport.build(
        medicines: [
          _stock('sold-missing', expiry: '2027-01', sold: true),
          _stock(
            'sold-future',
            expiry: '2027-01',
            sold: true,
            soldAt: '2026-10-01T09:00:00.000',
            soldQuantity: 8,
          ),
        ],
        settings: const WarningSettings(),
        today: _today,
        reorder: const [],
      );

      final issues = incomplete.items.where(
        (item) => item.kind == AttentionKind.soldAuditGap,
      );
      expect(issues, hasLength(2));
      expect(
        issues.where((item) => item.severity == AttentionSeverity.high),
        hasLength(1),
      );
      expect(
        issues.where((item) => item.severity == AttentionSeverity.medium),
        hasLength(1),
      );
    });

    test('never reports archived stock as an active operational issue', () {
      final archived = _stock(
        'archived',
        name: 'Old',
        expiry: '2026-01',
      ).patch({'archived': true});
      final report = PharmacyAttentionReport.build(
        medicines: [archived],
        settings: const WarningSettings(),
        today: _today,
        reorder: const [],
      );
      expect(report.isEmpty, isTrue);
    });
  });
}
