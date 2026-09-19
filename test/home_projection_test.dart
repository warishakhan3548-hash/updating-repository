import 'package:flutter_test/flutter_test.dart';

import '../lib/domain/home_projection.dart';
import '../lib/domain/medicine.dart';
import 'domain_contract.dart';

void main() {
  test('home projection keeps dashboard counts disjoint in one snapshot', () {
    final archived = Medicine.fromJson({
      ...stock('archived', name: 'Archived medicine').toJson(),
      'archived': true,
      'archivedAt': '2026-09-01T10:00:00Z',
      'archiveReason': 'Correction',
    });
    final records = [
      stock('expired', name: 'Expired', expiry: '2026-09-06'),
      stock('short', name: 'Short', expiry: '2026-09-10'),
      stock('month', name: 'Month', expiry: '2026-10-01'),
      stock('sold', name: 'Sold', sold: true),
      stock('normal', name: 'Normal', expiry: '2027-01-01'),
      // Same product identity as normal: physical rows remain separate while
      // the Home medicine count stays identity-based like InventoryStats.
      stock('normal-2', name: 'Normal', expiry: '2027-02-01'),
      archived,
    ];

    final projection = HomeInventoryProjection.build(
      medicines: records,
      settings: contractSettings,
      today: contractToday,
    );

    expect(projection.activeCount, 6);
    expect(projection.expiredCount, 1);
    expect(projection.shortExpiryCount, 1);
    expect(projection.monthExpiryCount, 1);
    expect(projection.soldCount, 1);
    expect(projection.uniqueMedicines, 5);
    expect(projection.attention.map((medicine) => medicine.id), [
      'expired',
      'short',
      'month',
    ]);
  });

  test('home attention remains bounded and prioritizes expired before warnings', () {
    final records = [
      stock('month-a', name: 'Month A', expiry: '2026-10-01'),
      stock('short-a', name: 'Short A', expiry: '2026-09-12'),
      stock('expired-old', name: 'Expired old', expiry: '2026-08-01'),
      stock('expired-new', name: 'Expired new', expiry: '2026-09-06'),
      stock('short-b', name: 'Short B', expiry: '2026-09-09'),
      stock('month-b', name: 'Month B', expiry: '2026-10-20'),
      stock('month-c', name: 'Month C', expiry: '2026-10-25'),
    ];

    final projection = HomeInventoryProjection.build(
      medicines: records,
      settings: contractSettings,
      today: contractToday,
    );

    expect(projection.attention.length, 4);
    expect(projection.attention[0].id, 'expired-new');
    expect(projection.attention[1].id, 'expired-old');
    expect(
      projection.attention.skip(2).map((medicine) => medicine.id),
      ['short-b', 'short-a'],
    );
  });
}
