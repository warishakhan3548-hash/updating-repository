#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


def write(path: str, text: str) -> None:
    target = ROOT / path
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(text, encoding="utf-8")


def replace_once(path: str, old: str, new: str) -> None:
    text = read(path)
    count = text.count(old)
    if count != 1:
        raise RuntimeError(f"{path}: expected one target, found {count}")
    write(path, text.replace(old, new, 1))


replace_once(
    "lib/data/inventory_database.dart",
    "import '../domain/tracking.dart';\n\nclass InventorySnapshot {",
    "import '../domain/tracking.dart';\n\n"
    "// Idempotency receipts are intentionally bounded. Every reviewed operation also\n"
    "// carries the inventory revision it was reviewed against, so a callback older\n"
    "// than this recent window still fails closed at the revision gate rather than\n"
    "// being replayed. Keeping the window bounded prevents an always-on pharmacy\n"
    "// from turning every historical sale into permanent O(n) snapshot-copy cost.\n"
    "const int maxRecentOperationReceipts = 4096;\n\n"
    "class InventorySnapshot {",
)

replace_once(
    "lib/data/inventory_database.dart",
    """    receipts: {\n      ...before.receipts,\n      if (mutation.requestId != null) mutation.requestId!,\n    },\n""",
    """    receipts: <String>{\n      if (mutation.requestId != null) mutation.requestId!,\n      ...before.receipts,\n    }.take(maxRecentOperationReceipts).toSet(),\n""",
)

replace_once(
    "lib/data/inventory_database.dart",
    """    final receipts = await db.query('receipts');\n""",
    """    final receipts = await db.query(\n      'receipts',\n      orderBy: 'rowid DESC',\n      limit: maxRecentOperationReceipts,\n    );\n""",
)

replace_once(
    "lib/data/inventory_database.dart",
    """      if (mutation.requestId != null)\n        await tx.insert('receipts', {'request_id': mutation.requestId});\n      await tx.insert('events', {\n""",
    """      if (mutation.requestId != null) {\n        await tx.insert('receipts', {'request_id': mutation.requestId});\n        await tx.rawDelete(\n          'DELETE FROM receipts WHERE rowid NOT IN '\n          '(SELECT rowid FROM receipts ORDER BY rowid DESC LIMIT $maxRecentOperationReceipts)',\n        );\n      }\n      await tx.insert('events', {\n""",
)

write(
    "test/operation_receipt_retention_test.dart",
    r"""import 'package:flutter_test/flutter_test.dart';

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

  test('retained receipt replay remains a no-op before revision validation', () async {
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
  });
}
""",
)

progress = read("docs/PROGRESS.md")
needle = "- Pharmacist-reviewed FEFO sales, stock corrections/receipts, stock relocation, protected bulk removal and removed-stock restore now carry durable exactly-once request receipts. Duplicate callbacks/retries cannot repeat the physical stock or sale effect; a fresh review intentionally mints a fresh request.\n"
replacement = needle + "- Exactly-once receipt memory is capped to the newest 4096 operation intents and SQLite prunes the same recent window. Older callbacks still fail closed through their stale reviewed revision, preventing long-running pharmacies from accumulating permanent O(n) receipt-copy overhead.\n"
if replacement not in progress:
    if needle not in progress:
        raise RuntimeError("docs/PROGRESS.md: receipt bullet missing")
    progress = progress.replace(needle, replacement, 1)
    write("docs/PROGRESS.md", progress)

print("Bounded exactly-once receipt retention applied")
