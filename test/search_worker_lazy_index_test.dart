import 'package:flutter_test/flutter_test.dart';

import '../lib/domain/inventory.dart';
import '../lib/domain/medicine.dart';
import '../lib/services/search_worker.dart';

void main() {
  test('empty browse defers fuzzy indexing until a query', () async {
    final worker = SearchWorker();
    addTearDown(worker.close);

    final record = Medicine(
      id: 'browse-first',
      name: 'Example item',
      expiry: DateTime.utc(2027, 1, 1),
      quantity: 10,
    );
    const settings = WarningSettings();
    final today = DateTime.utc(2026, 9, 10);

    final browse = await worker.browseActive(
      [record],
      1,
      SearchScope.all,
      settings,
      today,
      limit: 120,
    );
    expect(browse.single.id, record.id);
    expect(worker.debugIndexBuilds, 0);

    final typed = await worker.search(
      [record],
      1,
      'Example',
      SearchScope.all,
      settings,
      today,
    );
    expect(typed.single.id, record.id);
    expect(worker.debugIndexBuilds, 1);
  });

  test('empty browse transfers only the requested ordered window', () async {
    final worker = SearchWorker();
    addTearDown(worker.close);

    final records = List<Medicine>.generate(
      260,
      (index) => Medicine(
        id: 'browse-$index',
        name: 'Medicine $index',
        expiry: DateTime.utc(2027, 1, 1).add(Duration(days: index)),
        quantity: 10,
      ),
      growable: false,
    );
    const settings = WarningSettings();
    final today = DateTime.utc(2026, 9, 10);

    final first = await worker.browseActive(
      records,
      1,
      SearchScope.all,
      settings,
      today,
      limit: 120,
    );
    final expanded = await worker.browseActive(
      records,
      1,
      SearchScope.all,
      settings,
      today,
      limit: 240,
    );

    expect(first, hasLength(120));
    expect(expanded, hasLength(240));
    expect(
      expanded.take(first.length).map((hit) => hit.id),
      first.map((hit) => hit.id),
    );
    expect(worker.debugIndexBuilds, 0);
  });

  test('removed-stock browse stays bounded without building a fuzzy index', () async {
    final worker = SearchWorker();
    addTearDown(worker.close);

    final records = List<Medicine>.generate(
      260,
      (index) => archiveMedicine(
        Medicine(
          id: 'removed-$index',
          name: 'Removed $index',
          expiry: DateTime.utc(2027, 1, 1),
          quantity: 10,
        ),
        reason: 'Damaged pack',
        at: DateTime.utc(2026, 9, 1).add(Duration(seconds: index)),
      ),
      growable: false,
    );

    final first = await worker.browseArchived(records, 1, limit: 120);
    final expanded = await worker.browseArchived(records, 1, limit: 240);

    expect(first, hasLength(120));
    expect(expanded, hasLength(240));
    expect(
      expanded.take(first.length).map((hit) => hit.id),
      first.map((hit) => hit.id),
    );
    expect(worker.debugIndexBuilds, 0);
  });
}
