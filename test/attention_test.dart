import 'package:aaris_pharmacy/domain/attention.dart';
import 'package:aaris_pharmacy/domain/medicine.dart';
import 'package:aaris_pharmacy/domain/tracking.dart';
import 'package:flutter_test/flutter_test.dart';

import 'domain_contract.dart';

void main() {
  group('deterministic pharmacist attention engine', () {
    test('prioritizes expiry, stock mismatch, data gaps and reorder facts', () {
      final report = PharmacyAttentionReport.build(
        medicines: [
          stock('expired', name: 'ExpiredMed', expiry: '2026-09-05'),
          stock('short', name: 'ShortMed', expiry: '2026-09-09'),
          stock('zero', name: 'ZeroMed', expiry: '2027-01', quantity: 0),
          stock('unknown-exp', name: 'NoExpiry', expiry: ''),
          stock(
            'unknown-qty',
            name: 'NoQuantity',
            expiry: '2027-01',
            quantity: null,
          ),
        ],
        settings: const WarningSettings(),
        today: contractToday,
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
          stock('a', name: 'Dolo', strength: '650mg', barcode: '111'),
          stock('b', name: 'Dolo', strength: '650mg', barcode: '111'),
        ],
        settings: const WarningSettings(),
        today: contractToday,
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
          stock('a', name: 'Dolo', strength: '650mg', barcode: '111'),
          stock('b', name: 'Crocin', strength: '500mg', barcode: '111'),
        ],
        settings: const WarningSettings(),
        today: contractToday,
        reorder: const [],
      );
      final barcodeItems = conflict.items.where(
        (item) => item.kind == AttentionKind.barcodeConflict,
      );
      expect(barcodeItems, hasLength(1));
      expect(barcodeItems.single.stockIds.toSet(), {'a', 'b'});
      expect(barcodeItems.single.severity, AttentionSeverity.high);
    });

    test('never reports archived stock as an active operational issue', () {
      final archived = stock('archived', name: 'Old', expiry: '2026-01').patch({
        'archived': true,
      });
      final report = PharmacyAttentionReport.build(
        medicines: [archived],
        settings: const WarningSettings(),
        today: contractToday,
        reorder: const [],
      );
      expect(report.isEmpty, isTrue);
    });
  });
}
