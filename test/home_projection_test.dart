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
  });

  test('home dependency equality ignores all hidden operational facts', () {
    final base = Medicine(
      id: 'projection-input',
      name: 'Projection Input',
      brand: 'Brand',
      manufacturer: 'Maker',
      salt: 'Salt',
      strength: '500mg',
      form: 'Tablet',
      quantity: 10,
      unitPricePaise: 1200,
      location: 'Shelf A',
      expiry: DateTime(2026, 9, 14),
    );

    expect(
      sameHomeProjectionInput(
        base,
        base.patch(<String, dynamic>{
          'quantity': 9,
          'unitPricePaise': 1500,
          'barcode': '8901234567890',
          'notes': 'Counted today',
          'ocrText': 'updated source text',
        }),
      ),
      isTrue,
    );
    expect(
      sameHomeProjectionInput(
        base,
        base.patch(<String, dynamic>{
          'location': 'Shelf B',
          'brand': 'Other Brand',
          'manufacturer': 'Other Maker',
          'salt': 'Other Salt',
        }),
      ),
      isTrue,
      reason: 'These facts now belong to Today Work/details, not Home counts.',
    );
    expect(
      sameHomeProjectionInput(
        base,
        base.patch(<String, dynamic>{'expiry': '2026-09-13'}),
      ),
      isFalse,
      reason: 'Expiry drives Home warning status and counts.',
    );
  });

}
