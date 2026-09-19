import 'package:flutter_test/flutter_test.dart';

import '../lib/domain/inventory.dart';
import '../lib/domain/search.dart';
import '../lib/services/search_worker.dart';
import 'domain_contract.dart';

void main() {
  test('stock-only revisions reuse the expensive background search index', () async {
    final worker = SearchWorker();
    addTearDown(worker.close);

    final original = stock(
      'drotaverine',
      name: 'Drotaverine',
      strength: '80mg',
      quantity: 10,
      price: 200,
    );
    final first = await worker.search(
      [original],
      1,
      'DOTIN 80mg',
      SearchScope.all,
      contractSettings,
      contractToday,
    );
    expect(first.single.id, original.id);
    expect(worker.debugIndexBuilds, 1);

    final quantityOnly = original.patch({'quantity': 7});
    final afterSale = await worker.search(
      [quantityOnly],
      2,
      'DOTIN 80mg',
      SearchScope.all,
      contractSettings,
      contractToday,
    );
    expect(afterSale.single.id, original.id);
    expect(worker.debugIndexBuilds, 1);

    final priceOnly = quantityOnly.patch({'unitPricePaise': 350});
    await worker.search(
      [priceOnly],
      3,
      'Drotaverine 80mg',
      SearchScope.all,
      contractSettings,
      contractToday,
    );
    expect(worker.debugIndexBuilds, 1);

    final searchableEdit = priceOnly.patch({'notes': 'Emergency shelf'});
    final noteHit = await worker.search(
      [searchableEdit],
      4,
      'Emergency shelf',
      SearchScope.all,
      contractSettings,
      contractToday,
    );
    expect(noteHit.single.id, original.id);
    expect(worker.debugIndexBuilds, 2);
  });

  test('status changes rebuild the index so scoped results stay authoritative', () async {
    final worker = SearchWorker();
    addTearDown(worker.close);

    final active = stock(
      'sold-later',
      name: 'Cefixime',
      expiry: '2027-01-01',
      quantity: 4,
    );
    await worker.search(
      [active],
      10,
      'Cefixime',
      SearchScope.all,
      contractSettings,
      contractToday,
    );
    expect(worker.debugIndexBuilds, 1);

    final sold = active.patch({'sold': true, 'quantity': 0});
    final soldHits = await worker.search(
      [sold],
      11,
      'Cefixime',
      SearchScope.sold,
      contractSettings,
      contractToday,
    );
    expect(soldHits.single.id, active.id);
    expect(worker.debugIndexBuilds, 2);
  });

  test('removed-stock timestamp changes invalidate stale worker ordering', () async {
    final worker = SearchWorker();
    addTearDown(worker.close);

    final older = stock('removed-older', name: 'Drotaverine').patch({
      'archived': true,
      'archivedAt': DateTime.utc(2026, 9, 1).toIso8601String(),
      'archiveReason': 'Removed for return',
    });
    final newer = stock('removed-newer', name: 'Drotaverine').patch({
      'archived': true,
      'archivedAt': DateTime.utc(2026, 9, 2).toIso8601String(),
      'archiveReason': 'Removed for return',
    });

    final first = await worker.browseArchived(
      [older, newer],
      20,
      limit: 100000,
    );
    expect(first.map((hit) => hit.id), [newer.id, older.id]);

    final reArchivedLater = older.patch({
      'archivedAt': DateTime.utc(2026, 9, 3).toIso8601String(),
    });
    final refreshed = await worker.browseArchived(
      [reArchivedLater, newer],
      21,
      limit: 100000,
    );

    expect(refreshed.map((hit) => hit.id), [reArchivedLater.id, newer.id]);
  });

  test('shared search projection ignores stock-only facts but catches search edits', () {
    final original = stock(
      'projection',
      name: 'Drotaverine',
      strength: '80mg',
      quantity: 10,
      price: 200,
    );

    expect(
      sameSearchProjection(
        original,
        original.patch({'quantity': 7, 'unitPricePaise': 350}),
      ),
      isTrue,
    );
    expect(
      sameSearchProjection(
        original,
        original.patch({'location': 'Shelf B'}),
      ),
      isFalse,
    );
  });

}
