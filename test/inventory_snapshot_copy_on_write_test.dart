import 'package:aaris_pharmacy/data/inventory_database.dart';
import 'package:aaris_pharmacy/domain/medicine.dart';
import 'package:flutter_test/flutter_test.dart';

Medicine _stock(
  String id, {
  int quantity = 10,
  int unitPricePaise = 200,
}) =>
    Medicine.fromJson(<String, dynamic>{
      'id': id,
      'name': 'Medicine $id',
      'expiry': '2027-12-31',
      'quantity': quantity,
      'unitPricePaise': unitPricePaise,
      'form': 'Tablet',
    });

InventoryMutation _mutation({
  required int revision,
  required String label,
  List<Medicine> upserts = const <Medicine>[],
  WarningSettings? settings,
}) =>
    InventoryMutation(
      expectedRevision: revision,
      label: label,
      upserts: upserts,
      settings: settings,
      operationTime: DateTime.utc(2026, 9, 20, 10),
    );

void main() {
  test('settings-only transition reuses untouched immutable collections', () {
    final before = InventorySnapshot(
      records: <String, Medicine>{'stock': _stock('stock')},
    );
    final mutation = _mutation(
      revision: before.revision,
      label: 'Change warning window',
      settings: const WarningSettings(shortDays: 5, months: 2),
    );

    final after = nextSnapshot(before, mutation, makeEvent(before, mutation));

    expect(after.settings.shortDays, 5);
    expect(identical(after.settings, before.settings), isFalse);
    expect(identical(after.records, before.records), isTrue);
    expect(identical(after.suppliers, before.suppliers), isTrue);
    expect(identical(after.sales, before.sales), isTrue);
    expect(identical(after.receipts, before.receipts), isTrue);
    expect(identical(after.events, before.events), isFalse);
  });

  test('medicine transition copies records but reuses unrelated collections', () {
    final original = _stock('stock');
    final before = InventorySnapshot(
      records: <String, Medicine>{original.id: original},
    );
    final mutation = _mutation(
      revision: before.revision,
      label: 'Adjust stock',
      upserts: <Medicine>[original.patch(<String, dynamic>{'quantity': 9})],
    );

    final after = nextSnapshot(before, mutation, makeEvent(before, mutation));

    expect(after.records['stock']!.quantity, 9);
    expect(identical(after.settings, before.settings), isTrue);
    expect(identical(after.records, before.records), isFalse);
    expect(identical(after.suppliers, before.suppliers), isTrue);
    expect(identical(after.sales, before.sales), isTrue);
    expect(identical(after.receipts, before.receipts), isTrue);
  });

  test('medicine transitions still enforce aggregate exact-money safety', () {
    final first = _stock(
      'first',
      quantity: 100000000,
      unitPricePaise: 50000000,
    );
    final second = _stock(
      'second',
      quantity: 100000000,
      unitPricePaise: 50000000,
    );
    final before = InventorySnapshot(
      records: <String, Medicine>{first.id: first},
    );
    final mutation = _mutation(
      revision: before.revision,
      label: 'Add large stock',
      upserts: <Medicine>[second],
    );
    final event = makeEvent(before, mutation);

    expect(
      () => nextSnapshot(before, mutation, event),
      throwsFormatException,
    );
  });
}
