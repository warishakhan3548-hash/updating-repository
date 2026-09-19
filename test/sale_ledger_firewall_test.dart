import 'package:flutter_test/flutter_test.dart';

import '../lib/data/inventory_database.dart';
import '../lib/domain/medicine.dart';
import '../lib/domain/tracking.dart';

Medicine stock({
  String id = 'stock-1',
  String name = 'Paracetamol',
  String salt = 'Paracetamol',
  String strength = '500mg',
  String form = 'Tablet',
  int? quantity = 10,
  DateTime? mfg,
  DateTime? expiry,
}) => Medicine(
  id: id,
  name: name,
  salt: salt,
  strength: strength,
  form: form,
  quantity: quantity,
  mfg: mfg,
  expiry: expiry ?? DateTime.utc(2027, 12, 31),
  batchNumber: 'B-1',
  location: 'Rack 1',
);

SaleEvent sale({
  String id = 'sale-1',
  String stockId = 'stock-1',
  String name = 'Paracetamol',
  String salt = 'Paracetamol',
  String strength = '500mg',
  String form = 'Tablet',
  int quantity = 4,
  DateTime? occurredAt,
}) => SaleEvent(
  id: id,
  stockId: stockId,
  medicineName: name,
  salt: salt,
  strength: strength,
  form: form,
  quantity: quantity,
  occurredAt: occurredAt ?? DateTime(2026, 9, 9, 12),
);

Future<MemoryInventoryStorage> seeded(Medicine medicine) async {
  final storage = MemoryInventoryStorage(
    InventorySnapshot(records: <String, Medicine>{medicine.id: medicine}),
  );
  await storage.load();
  return storage;
}

void main() {
  test('valid sale atomically reconciles stock and append-only ledger', () async {
    final before = stock(quantity: 10);
    final storage = await seeded(before);

    final after = await storage.commit(
      InventoryMutation(
        expectedRevision: 0,
        label: 'Valid sale',
        upserts: <Medicine>[before.patch(<String, dynamic>{'quantity': 6})],
        upsertSales: <SaleEvent>[sale(quantity: 4)],
      ),
    );

    expect(after.revision, 1);
    expect(after.records['stock-1']!.quantity, 6);
    expect(after.sales['sale-1']!.quantity, 4);
  });

  test('forged sale without matching stock decrement fails closed', () async {
    final before = stock(quantity: 10);
    final storage = await seeded(before);

    await expectLater(
      storage.commit(
        InventoryMutation(
          expectedRevision: 0,
          label: 'Forged movement',
          upserts: <Medicine>[before],
          upsertSales: <SaleEvent>[sale(quantity: 4)],
        ),
      ),
      throwsStateError,
    );

    final state = await storage.load();
    expect(state.revision, 0);
    expect(state.records['stock-1']!.quantity, 10);
    expect(state.sales, isEmpty);
  });

  test('sale audit cannot invent a different medicine identity or salt', () async {
    final before = stock(quantity: 10);
    final storage = await seeded(before);

    await expectLater(
      storage.commit(
        InventoryMutation(
          expectedRevision: 0,
          label: 'Wrong identity',
          upserts: <Medicine>[
            before.patch(<String, dynamic>{'quantity': 9}),
          ],
          upsertSales: <SaleEvent>[
            sale(name: 'Amoxicillin', salt: 'Amoxicillin', quantity: 1),
          ],
        ),
      ),
      throwsStateError,
    );

    expect((await storage.load()).sales, isEmpty);
  });

  test('sale and medicine identity edit cannot be hidden in one transaction', () async {
    final before = stock(quantity: 10);
    final storage = await seeded(before);

    await expectLater(
      storage.commit(
        InventoryMutation(
          expectedRevision: 0,
          label: 'Sale plus identity rewrite',
          upserts: <Medicine>[
            before.patch(<String, dynamic>{
              'name': 'Paracetamol Plus',
              'quantity': 9,
            }),
          ],
          upsertSales: <SaleEvent>[sale(quantity: 1)],
        ),
      ),
      throwsStateError,
    );
  });

  test('unknown stock may record movement but cannot invent remaining stock', () async {
    final before = stock(quantity: null);
    final storage = await seeded(before);

    final accepted = await storage.commit(
      InventoryMutation(
        expectedRevision: 0,
        label: 'Known movement from unknown baseline',
        upserts: <Medicine>[before],
        upsertSales: <SaleEvent>[sale(quantity: 2)],
      ),
    );
    expect(accepted.records['stock-1']!.quantity, isNull);
    expect(accepted.sales.length, 1);

    final live = accepted.records['stock-1']!;
    await expectLater(
      storage.commit(
        InventoryMutation(
          expectedRevision: 1,
          label: 'Invent remaining quantity',
          upserts: <Medicine>[
            live.patch(<String, dynamic>{'quantity': 5}),
          ],
          upsertSales: <SaleEvent>[
            sale(id: 'sale-2', quantity: 1),
          ],
        ),
      ),
      throwsStateError,
    );
  });

  test('ordinary actions cannot delete or rewrite recorded sale history', () async {
    final before = stock(quantity: 10);
    final storage = await seeded(before);
    final firstSale = sale(quantity: 2);
    final state = await storage.commit(
      InventoryMutation(
        expectedRevision: 0,
        label: 'Initial sale',
        upserts: <Medicine>[before.patch(<String, dynamic>{'quantity': 8})],
        upsertSales: <SaleEvent>[firstSale],
      ),
    );

    await expectLater(
      storage.commit(
        InventoryMutation(
          expectedRevision: 1,
          label: 'Erase sale',
          upserts: const <Medicine>[],
          removeSaleIds: const <String>['sale-1'],
        ),
      ),
      throwsStateError,
    );

    await expectLater(
      storage.commit(
        InventoryMutation(
          expectedRevision: 1,
          label: 'Rewrite sale',
          upserts: const <Medicine>[],
          upsertSales: <SaleEvent>[sale(quantity: 3)],
        ),
      ),
      throwsStateError,
    );

    final unchanged = await storage.load();
    expect(unchanged.revision, state.revision);
    expect(unchanged.sales['sale-1']!.quantity, 2);
  });

  test('new sale must reference pre-existing active stock', () async {
    final storage = MemoryInventoryStorage();
    await storage.load();
    final newStock = stock(quantity: 9);

    await expectLater(
      storage.commit(
        InventoryMutation(
          expectedRevision: 0,
          label: 'Create and sell in one hidden operation',
          upserts: <Medicine>[newStock],
          upsertSales: <SaleEvent>[sale(quantity: 1)],
        ),
      ),
      throwsStateError,
    );
  });

  test('historical sale lifecycle is checked against pack facts', () async {
    final before = stock(
      quantity: 10,
      mfg: DateTime.utc(2026, 8, 1),
      expiry: DateTime.utc(2026, 8, 31),
    );
    final storage = await seeded(before);

    final accepted = await storage.commit(
      InventoryMutation(
        expectedRevision: 0,
        label: 'Expiry-day historical sale',
        upserts: <Medicine>[before.patch(<String, dynamic>{'quantity': 9})],
        upsertSales: <SaleEvent>[
          sale(quantity: 1, occurredAt: DateTime(2026, 8, 31, 18)),
        ],
      ),
    );
    expect(accepted.sales.length, 1);

    final live = accepted.records['stock-1']!;
    await expectLater(
      storage.commit(
        InventoryMutation(
          expectedRevision: 1,
          label: 'After-expiry historical sale',
          upserts: <Medicine>[
            live.patch(<String, dynamic>{'quantity': 8}),
          ],
          upsertSales: <SaleEvent>[
            sale(
              id: 'sale-2',
              quantity: 1,
              occurredAt: DateTime(2026, 9, 1),
            ),
          ],
        ),
      ),
      throwsStateError,
    );
  });
}
