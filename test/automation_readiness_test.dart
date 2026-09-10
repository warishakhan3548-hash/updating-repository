import 'package:aaris_pharmacy/domain/attention.dart';
import 'package:aaris_pharmacy/domain/automation_readiness.dart';
import 'package:aaris_pharmacy/domain/medicine.dart';
import 'package:flutter_test/flutter_test.dart';

Medicine _stock(
  String id, {
  String name = 'Dolo',
  String strength = '650mg',
  String form = 'Tablet',
  String expiry = '2026-12',
  String batch = '',
  String barcode = '',
  String location = '',
  int? quantity = 10,
  bool sold = false,
  bool archived = false,
  String? mfg,
}) => Medicine.fromJson({
  'id': id,
  'name': name,
  'strength': strength,
  'form': form,
  'expiry': expiry,
  'mfg': mfg,
  'batchNumber': batch,
  'barcode': barcode,
  'location': location,
  'quantity': sold ? 0 : quantity,
  'sold': sold,
  'archived': archived,
});

final _today = DateTime(2026, 9, 10, 18, 30);

void main() {
  group('automation readiness preflight', () {
    test('groups undated stock before FEFO becomes ambiguous', () {
      final report = PharmacyAutomationReadinessReport.build(
        medicines: [
          _stock('dated', expiry: '2026-10', batch: 'A', quantity: 8),
          _stock('undated', expiry: '', batch: 'B', quantity: 5),
        ],
        today: _today,
      );

      final expiry = report.issues.where(
        (issue) =>
            issue.kind == AutomationReadinessKind.fefoExpiryUncertainty,
      );
      expect(expiry, hasLength(1));
      expect(expiry.single.stockIds, ['undated']);
      expect(expiry.single.detail, contains('after 1 dated FEFO row'));
      expect(expiry.single.detail, contains('no expiry will be invented'));
    });

    test('reports when no candidate has an expiry instead of inventing order', () {
      final report = PharmacyAutomationReadinessReport.build(
        medicines: [
          _stock('a', expiry: '', batch: 'A'),
          _stock('b', expiry: '', batch: 'B'),
        ],
        today: _today,
      );

      final issue = report.issues.singleWhere(
        (item) =>
            item.kind == AutomationReadinessKind.fefoExpiryUncertainty,
      );
      expect(issue.stockIds.toSet(), {'a', 'b'});
      expect(issue.detail, contains('none has a recorded expiry'));
      expect(issue.detail, contains('cannot be proven'));
    });

    test('unknown earliest-lot quantity blocks FEFO immediately', () {
      final report = PharmacyAutomationReadinessReport.build(
        medicines: [
          _stock(
            'unknown-first',
            expiry: '2026-09-20',
            batch: 'EARLY',
            quantity: null,
          ),
          _stock('later', expiry: '2026-10', batch: 'LATE', quantity: 12),
        ],
        today: _today,
      );

      final issue = report.issues.singleWhere(
        (item) =>
            item.kind == AutomationReadinessKind.fefoQuantityBlocker,
      );
      expect(issue.stockIds, ['unknown-first']);
      expect(issue.detail, contains('first reachable FEFO-priority'));
      expect(issue.detail, contains('Batch EARLY'));
      expect(issue.detail, contains('never skip'));
    });

    test('quantifies the known safe prefix before a later unknown quantity', () {
      final report = PharmacyAutomationReadinessReport.build(
        medicines: [
          _stock('early', expiry: '2026-09-20', batch: 'A', quantity: 6),
          _stock(
            'unknown',
            expiry: '2026-10-01',
            batch: 'B',
            quantity: null,
          ),
          _stock('later', expiry: '2026-11', batch: 'C', quantity: 10),
        ],
        today: _today,
      );

      final issue = report.issues.singleWhere(
        (item) =>
            item.kind == AutomationReadinessKind.fefoQuantityBlocker,
      );
      expect(issue.detail, contains('up to 6 known units'));
      expect(issue.stockIds, ['unknown']);
    });

    test('does not create multi-lot blockers from unusable or other products', () {
      final report = PharmacyAutomationReadinessReport.build(
        medicines: [
          _stock('active', expiry: '', quantity: null),
          _stock('sold', expiry: '', quantity: null, sold: true),
          _stock(
            'other-strength',
            strength: '500mg',
            expiry: '',
            quantity: null,
          ),
          _stock(
            'future-mfg',
            expiry: '',
            quantity: null,
            mfg: '2026-10-01',
          ),
        ],
        today: _today,
      );

      expect(report.isEmpty, isTrue);
    });
  });

  group('attention queue integration', () {
    test('consolidates multi-lot expiry gaps into one FEFO work item', () {
      final report = PharmacyAttentionReport.build(
        medicines: [
          _stock('dated', expiry: '2026-10', batch: 'A'),
          _stock('undated', expiry: '', batch: 'B'),
        ],
        settings: const WarningSettings(),
        today: _today,
        reorder: const [],
      );

      final grouped = report.items.where(
        (item) => item.key.startsWith('fefo-expiry:'),
      );
      expect(grouped, hasLength(1));
      expect(grouped.single.kind, AttentionKind.unknownExpiry);
      expect(grouped.single.stockIds, ['undated']);
      expect(
        report.items.where((item) => item.key == 'expiry-unknown:undated'),
        isEmpty,
      );
    });

    test('elevates a multi-lot quantity blocker and suppresses duplicate noise', () {
      final report = PharmacyAttentionReport.build(
        medicines: [
          _stock(
            'unknown-first',
            expiry: '2026-09-20',
            batch: 'A',
            quantity: null,
          ),
          _stock('later', expiry: '2026-10', batch: 'B', quantity: 20),
        ],
        settings: const WarningSettings(),
        today: _today,
        reorder: const [],
      );

      final grouped = report.items.singleWhere(
        (item) => item.key.startsWith('fefo-quantity:'),
      );
      expect(grouped.kind, AttentionKind.unknownQuantity);
      expect(grouped.severity, AttentionSeverity.high);
      expect(grouped.stockIds, ['unknown-first']);
      expect(
        report.items.where(
          (item) => item.key == 'quantity-unknown:unknown-first',
        ),
        isEmpty,
      );
    });

    test('flags probable duplicate lot rows even when batch number is absent', () {
      final report = PharmacyAttentionReport.build(
        medicines: [
          _stock(
            'dup-a',
            expiry: '2027-01',
            barcode: '8901234567890',
            location: 'Shelf 4',
          ),
          _stock(
            'dup-b',
            expiry: '2027-01',
            barcode: '8901234567890',
            location: 'Shelf 4',
          ),
        ],
        settings: const WarningSettings(),
        today: _today,
        reorder: const [],
      );

      final duplicate = report.items.where(
        (item) => item.kind == AttentionKind.possibleDuplicateBatch,
      );
      expect(duplicate, hasLength(1));
      expect(duplicate.single.stockIds.toSet(), {'dup-a', 'dup-b'});
      expect(duplicate.single.detail, contains('no batch number'));
      expect(duplicate.single.severity, AttentionSeverity.medium);
    });

    test('does not flag no-batch rows without a shared physical locator', () {
      final report = PharmacyAttentionReport.build(
        medicines: [
          _stock(
            'a',
            expiry: '2027-01',
            barcode: '8901234567890',
            location: 'Shelf 4',
          ),
          _stock(
            'b',
            expiry: '2027-01',
            barcode: '8901234567890',
            location: 'Shelf 5',
          ),
        ],
        settings: const WarningSettings(),
        today: _today,
        reorder: const [],
      );

      expect(
        report.items.where(
          (item) => item.kind == AttentionKind.possibleDuplicateBatch,
        ),
        isEmpty,
      );
    });
  });
}
