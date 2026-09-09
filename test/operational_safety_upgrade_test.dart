import 'package:aaris_pharmacy/domain/attention.dart';
import 'package:aaris_pharmacy/domain/medicine.dart';
import 'package:aaris_pharmacy/domain/tracking.dart';
import 'package:flutter_test/flutter_test.dart';

Medicine item({
  required String id,
  required String batch,
  required int? quantity,
  DateTime? mfg,
  DateTime? expiry,
  String barcode = '',
  String location = '',
}) => Medicine(
  id: id,
  name: 'Amox',
  strength: '500 mg',
  form: 'Capsule',
  batchNumber: batch,
  quantity: quantity,
  mfg: mfg,
  expiry: expiry,
  barcode: barcode,
  location: location,
);

void main() {
  final today = DateTime.utc(2026, 9, 9);

  test(
    'attention flags future MFG and probable duplicate physical batch rows',
    () {
      final future = item(
        id: 'future',
        batch: 'F1',
        quantity: 10,
        mfg: DateTime.utc(2026, 10, 1),
        expiry: DateTime.utc(2027, 1, 1),
        barcode: '12345678',
        location: 'Rack 1',
      );
      final duplicateA = item(
        id: 'a',
        batch: 'B1',
        quantity: 4,
        expiry: DateTime.utc(2027, 1, 1),
        barcode: '87654321',
        location: 'Rack 2',
      );
      final duplicateB = item(
        id: 'b',
        batch: 'B1',
        quantity: 4,
        expiry: DateTime.utc(2027, 1, 1),
        barcode: '87654321',
        location: 'Rack 2',
      );

      final report = PharmacyAttentionReport.build(
        medicines: [future, duplicateA, duplicateB],
        settings: const WarningSettings(),
        today: today,
        reorder: const [],
      );

      expect(
        report.items.any(
          (entry) => entry.kind == AttentionKind.futureManufactureDate,
        ),
        isTrue,
      );
      final duplicates = report.items.where(
        (entry) => entry.kind == AttentionKind.possibleDuplicateBatch,
      );
      expect(duplicates, hasLength(1));
      expect(duplicates.single.stockIds.toSet(), {'a', 'b'});
    },
  );

  test(
    'future-MFG-only stock cannot suppress reorder and remains review-gated',
    () {
      final future = item(
        id: 'future',
        batch: 'F1',
        quantity: 20,
        mfg: DateTime.utc(2026, 10, 1),
        expiry: DateTime.utc(2027, 1, 1),
      );
      final sales = [
        SaleEvent(
          id: 'sale-1',
          stockId: future.id,
          medicineName: future.name,
          strength: future.strength,
          form: future.form,
          quantity: 5,
          occurredAt: DateTime.utc(2026, 9, 5),
        ),
      ];
      final stats = TrackingStats(
        medicines: [future],
        sales: sales,
        range: TrackingRange.lastDays(today, 30),
        today: today,
      );

      expect(stats.reorder, hasLength(1));
      final suggestion = stats.reorder.single;
      expect(suggestion.reviewRequired, isTrue);
      expect(suggestion.confidence, lessThan(.75));
      expect(suggestion.reason, contains('Manufacturing date needs review'));
      expect(suggestion.currentQuantity, 0);
    },
  );
}
