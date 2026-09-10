import 'package:flutter_test/flutter_test.dart';

import '../lib/data/inventory_database.dart';

void main() {
  test('recent exactly-once receipt window stays bounded and keeps newest intent', () async {
    // InventorySnapshot preserves Set iteration order. Model a persisted load,
    // which is newest-first, so the final element is the oldest receipt.
    final receipts = <String>{
      for (var i = maxRecentOperationReceipts - 1; i >= 0; i--) 'receipt-$i',
    };
    final storage = MemoryInventoryStorage(
      InventorySnapshot(receipts: receipts),
    );

    final after = await storage.commit(
      InventoryMutation(
        expectedRevision: 0,
        label: 'Reviewed operation receipt retention test',
        upserts: const [],
        requestId: 'receipt-current',
      ),
    );

    expect(after.receipts, hasLength(maxRecentOperationReceipts));
    expect(after.receipts, contains('receipt-current'));
    expect(after.receipts, isNot(contains('receipt-0')));
    expect(after.receipts, contains('receipt-1'));
  });

  test(
    'retained receipt replay remains a no-op before revision validation',
    () async {
      final storage = MemoryInventoryStorage();
      final mutation = InventoryMutation(
        expectedRevision: 0,
        label: 'Exactly once receipt',
        upserts: const [],
        requestId: 'stable-request',
      );

      final first = await storage.commit(mutation);
      final replay = await storage.commit(mutation);

      expect(first.revision, 1);
      expect(replay.revision, 1);
      expect(replay.events, hasLength(1));
    },
  );
}
