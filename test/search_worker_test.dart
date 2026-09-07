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
}
