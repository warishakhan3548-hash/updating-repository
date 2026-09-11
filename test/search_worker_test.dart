import 'package:flutter_test/flutter_test.dart';

import '../lib/services/search_worker.dart';
import '../lib/domain/inventory.dart';
import 'domain_contract.dart';

void main() {
  test(
    'persistent worker scopes results and replaces its index after edits',
    () async {
      final worker = SearchWorker();
      addTearDown(worker.close);
      final data = [
        stock('old', name: 'Drotaverine', strength: '80mg'),
        stock('expired', expiry: '2026-01-01'),
      ];
      final first = await worker.search(
        data,
        1,
        'DOTIN',
        SearchScope.all,
        contractSettings,
        contractToday,
      );
      expect(first.first.id, 'old');
      final expired = await worker.search(
        data,
        1,
        'Paracetamol',
        SearchScope.expired,
        contractSettings,
        contractToday,
      );
      expect(expired.single.id, 'expired');
      final updated = await worker.search(
        [stock('new', name: 'Cefixime')],
        2,
        '',
        SearchScope.all,
        contractSettings,
        contractToday,
      );
      expect(updated.single.id, 'new');
    },
  );

  test('OCR-confusable typo recovery preserves the requested scope', () async {
    final worker = SearchWorker();
    addTearDown(worker.close);
    final data = [
      stock(
        'active-dolo',
        name: 'Dolo',
        strength: '650mg',
        expiry: '2027-01-01',
      ),
      stock(
        'expired-dolo',
        name: 'Dolo',
        strength: '650mg',
        expiry: '2026-01-01',
      ),
    ];

    final hits = await worker.search(
      data,
      1,
      'D0LO 650mg',
      SearchScope.expired,
      contractSettings,
      contractToday,
    );

    expect(hits, isNotEmpty);
    expect(hits.first.id, 'expired-dolo');
    expect(hits.every((hit) => hit.id != 'active-dolo'), isTrue);
  });

  test('typo candidate recovery never overrides a strength contradiction', () async {
    final worker = SearchWorker();
    addTearDown(worker.close);
    final data = [
      stock(
        'dolo-650',
        name: 'Dolo',
        strength: '650mg',
        expiry: '2027-01-01',
      ),
      stock(
        'dolo-500',
        name: 'Dolo',
        strength: '500mg',
        expiry: '2027-01-01',
      ),
    ];

    final hits = await worker.search(
      data,
      1,
      'D0LO 650mg',
      SearchScope.all,
      contractSettings,
      contractToday,
    );

    expect(hits, isNotEmpty);
    expect(hits.first.id, 'dolo-650');
    final wrongStrength = hits.where((hit) => hit.id == 'dolo-500').toList();
    if (wrongStrength.isNotEmpty) {
      expect(wrongStrength.single.score, lessThan(hits.first.score));
      expect(
        wrongStrength.single.reason,
        'Different strength — check carefully',
      );
    }
  });
}
