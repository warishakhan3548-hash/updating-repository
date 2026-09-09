from pathlib import Path


def replace_once(path: str, old: str, new: str) -> None:
    target = Path(path)
    text = target.read_text()
    count = text.count(old)
    if count != 1:
        raise SystemExit(f'{path}: expected exactly one guarded match, found {count}')
    target.write_text(text.replace(old, new, 1))


replace_once(
    'lib/data/inventory_database.dart',
    """    this.soldValueOverride,\n    this.unknownSoldOverride,\n  });\n""",
    """    this.soldValueOverride,\n    this.unknownSoldOverride,\n    this.operationTime,\n  });\n""",
)

replace_once(
    'lib/data/inventory_database.dart',
    """  final bool undoable;\n  final int? soldValueOverride, unknownSoldOverride;\n}\n""",
    """  final bool undoable;\n  final int? soldValueOverride, unknownSoldOverride;\n  final DateTime? operationTime;\n\n  InventoryMutation withOperationTime(DateTime value) => InventoryMutation(\n    expectedRevision: expectedRevision,\n    label: label,\n    upserts: upserts,\n    upsertSales: upsertSales,\n    removeIds: removeIds,\n    removeSaleIds: removeSaleIds,\n    settings: settings,\n    requestId: requestId,\n    undoEventId: undoEventId,\n    undoable: undoable,\n    soldValueOverride: soldValueOverride,\n    unknownSoldOverride: unknownSoldOverride,\n    operationTime: value,\n  );\n}\n""",
)

replace_once(
    'lib/data/inventory_database.dart',
    """  if (mutation.expectedRevision < 0) {\n    throw const FormatException('Invalid inventory revision.');\n  }\n  final label = mutation.label.trim();\n""",
    """  if (mutation.expectedRevision < 0) {\n    throw const FormatException('Invalid inventory revision.');\n  }\n  final operationTime = mutation.operationTime;\n  if (operationTime != null &&\n      (operationTime.year < 2000 || operationTime.year > 2200)) {\n    throw const FormatException('Invalid inventory operation time.');\n  }\n  final label = mutation.label.trim();\n""",
)

replace_once(
    'lib/data/inventory_database.dart',
    """  checkedMoneySum(before.soldValue, soldValue);\n  return {\n""",
    """  checkedMoneySum(before.soldValue, soldValue);\n  // One immutable operation timestamp drives both the durable audit event and\n  // every date-sensitive persistence guard for this transaction. Controller\n  // writes stamp this from the controller's injected business clock; direct\n  // storage callers fall back to one wall-clock read here.\n  final operationTime = mutation.operationTime ?? DateTime.now();\n  final operationDay = civilDay(operationTime);\n  return {\n""",
)

replace_once(
    'lib/data/inventory_database.dart',
    """    'time': DateTime.now().toIso8601String(),\n    'undoable': mutation.undoable,\n""",
    """    'time': operationTime.toUtc().toIso8601String(),\n    'businessDay': dateText(operationDay),\n    'undoable': mutation.undoable,\n""",
)

replace_once(
    'lib/data/inventory_database.dart',
    """  final records = {...before.records};\n  final sales = {...before.sales};\n""",
    """  final records = {...before.records};\n  final sales = {...before.sales};\n  final eventTimeRaw = event['time'];\n  if (eventTimeRaw is! String) {\n    throw const FormatException('Inventory event time is missing.');\n  }\n  final operationTime = DateTime.tryParse(eventTimeRaw);\n  if (operationTime == null ||\n      operationTime.year < 2000 ||\n      operationTime.year > 2200) {\n    throw const FormatException('Inventory event time is invalid.');\n  }\n  final operationDay = civilDay(operationTime);\n""",
)

replace_once(
    'lib/data/inventory_database.dart',
    """      today: DateTime.now(),\n    );\n""",
    """      today: operationDay,\n    );\n""",
)

replace_once(
    'lib/data/inventory_database.dart',
    """  InventoryStats(records.values, DateTime.now());\n""",
    """  InventoryStats(records.values, operationDay);\n""",
)

replace_once(
    'lib/state/pharmacy_controller.dart',
    """  Future<void> _commit(InventoryMutation mutation) {\n    final result = _writes.then((_) async {\n      if (_disposed) throw StateError('App is closed.');\n      snapshot = await storage.commit(mutation);\n""",
    """  Future<void> _commit(InventoryMutation mutation) {\n    // Stamp once at the authoritative controller boundary. Every downstream\n    // date-sensitive guard and the durable audit event uses this exact instant,\n    // so a transaction cannot observe two different business days around\n    // midnight or diverge from an injected/test business clock.\n    final committedMutation = mutation.withOperationTime(clock());\n    final result = _writes.then((_) async {\n      if (_disposed) throw StateError('App is closed.');\n      snapshot = await storage.commit(committedMutation);\n""",
)

Path('test/authoritative_business_clock_test.dart').write_text("""import 'package:aaris_pharmacy/data/inventory_database.dart';
import 'package:aaris_pharmacy/domain/medicine.dart';
import 'package:aaris_pharmacy/state/pharmacy_controller.dart';
import 'package:flutter_test/flutter_test.dart';

Medicine _futureDatedStock(String id) => Medicine.fromJson({
  'id': id,
  'name': 'Clock Test Medicine',
  'strength': '10mg',
  'form': 'Tablet',
  'mfg': '2027-01-01',
  'expiry': '2028-01',
  'quantity': 10,
  'barcode': 'clock-$id',
  'batchNumber': 'CLOCK-$id',
});

void main() {
  group('authoritative inventory business clock', () {
    test('persistence guards use the reviewed operation day, not wall time', () async {
      final storage = MemoryInventoryStorage();
      final record = _futureDatedStock('direct');
      final operationTime = DateTime.utc(2027, 1, 1, 9, 30);

      final result = await storage.commit(
        InventoryMutation(
          expectedRevision: 0,
          label: 'Add clock-controlled stock',
          upserts: [record],
          operationTime: operationTime,
        ),
      );

      expect(result.revision, 1);
      expect(result.records['direct']?.mfg, DateTime.utc(2027, 1, 1));
      expect(
        result.events.first['time'],
        operationTime.toUtc().toIso8601String(),
      );
      expect(result.events.first['businessDay'], '2027-01-01');
    });

    test('the same future MFG is blocked on the preceding business day', () async {
      final storage = MemoryInventoryStorage();
      final record = _futureDatedStock('blocked');

      await expectLater(
        storage.commit(
          InventoryMutation(
            expectedRevision: 0,
            label: 'Add too-early stock',
            upserts: [record],
            operationTime: DateTime.utc(2026, 12, 31, 23, 59, 59),
          ),
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('manufacturing date in the future'),
          ),
        ),
      );

      expect((await storage.load()).revision, 0);
      expect((await storage.load()).records, isEmpty);
    });

    test('controller clock is propagated to the persistence boundary', () async {
      final operationTime = DateTime.utc(2027, 1, 1, 11, 45);
      final controller = PharmacyController(
        MemoryInventoryStorage(),
        clock: () => operationTime,
        backgroundSearch: false,
      );
      await controller.initialize();
      addTearDown(controller.dispose);

      final record = _futureDatedStock('controller');
      await controller.save(
        record,
        expectedRevision: controller.snapshot.revision,
      );

      expect(controller.snapshot.records['controller']?.mfg, DateTime.utc(2027, 1, 1));
      expect(
        controller.snapshot.events.first['time'],
        operationTime.toIso8601String(),
      );
      expect(controller.snapshot.events.first['businessDay'], '2027-01-01');
    });

    test('operation time validation fails closed before persistence', () async {
      final storage = MemoryInventoryStorage();
      final record = _futureDatedStock('invalid-time');

      await expectLater(
        storage.commit(
          InventoryMutation(
            expectedRevision: 0,
            label: 'Invalid clock',
            upserts: [record],
            operationTime: DateTime.utc(2300, 1, 1),
          ),
        ),
        throwsA(isA<FormatException>()),
      );
      expect((await storage.load()).revision, 0);
    });
  });
}
""")
