import 'package:flutter_test/flutter_test.dart';

import 'package:aaris_pharmacy/domain/medicine_discovery.dart';
import 'package:aaris_pharmacy/services/medicine_catalog_service.dart';

void main() {
  test('openFDA mapping prefills identity fields only', () {
    final hits = OpenFdaNdcProvider.parseResults(
      [
        {
          'brand_name': 'Dolo',
          'generic_name': 'Paracetamol',
          'labeler_name': 'Micro Labs',
          'dosage_form': 'TABLET',
          'product_ndc': '12345-678',
          'active_ingredients': [
            {'name': 'PARACETAMOL', 'strength': '650 mg/1'},
          ],
        },
      ],
      queryText: 'Dolo 650',
      barcode: '8900000000000',
    );

    expect(hits, hasLength(1));
    final seed = hits.single.seed;
    expect(seed.name, 'Dolo');
    expect(seed.brand, 'Dolo');
    expect(seed.salt, 'PARACETAMOL');
    expect(seed.strength, '650 mg/1');
    expect(seed.form, 'Tablet');
    expect(seed.manufacturer, 'Micro Labs');
    expect(seed.barcode, isEmpty);
    expect(seed.source, 'openFDA NDC');
  });

  test('exact catalog barcode is carried into the review draft', () {
    final hits = OpenFdaNdcProvider.parseResults(
      [
        {
          'brand_name': 'ExampleMed',
          'generic_name': 'Example ingredient',
          'dosage_form': 'CAPSULE',
          'active_ingredients': [
            {'name': 'EXAMPLE INGREDIENT', 'strength': '20 mg/1'},
          ],
        },
      ],
      queryText: 'ExampleMed 20',
      barcode: '0123456789012',
      barcodeExact: true,
    );

    expect(hits.single.seed.barcode, '0123456789012');
    expect(hits.single.score, 1);
  });

  test('RxNorm concept is split into brand salt strength and form', () {
    final hits = RxNormProvider.parseResults([
      {
        'rxcui': '123',
        'rank': '1',
        'score': '12.5',
        'name': 'paracetamol 650 MG Oral Tablet [Dolo]',
      },
    ], queryText: 'Dolo 650 tablet');

    expect(hits, hasLength(1));
    final seed = hits.single.seed;
    expect(seed.name, 'Dolo');
    expect(seed.brand, 'Dolo');
    expect(seed.salt.toLowerCase(), 'paracetamol');
    expect(seed.strength.toLowerCase(), '650 mg');
    expect(seed.form, 'Tablet');
    expect(seed.source, 'RxNorm');
  });

  test(
    'catalog service deduplicates identity and keeps stronger result',
    () async {
      final weak = _FakeProvider([
        const MedicineCatalogCandidate(
          seed: MedicineDraftSeed(
            name: 'Dolo',
            brand: 'Dolo',
            salt: 'Paracetamol',
            strength: '650 mg',
            form: 'Tablet',
          ),
          score: .72,
          provider: 'weak',
        ),
      ]);
      final strong = _FakeProvider([
        const MedicineCatalogCandidate(
          seed: MedicineDraftSeed(
            name: 'Dolo',
            brand: 'Dolo',
            salt: 'Paracetamol',
            strength: '650 mg',
            form: 'Tablet',
          ),
          score: .94,
          provider: 'strong',
        ),
      ]);
      final service = MedicineCatalogService(providers: [weak, strong]);
      addTearDown(service.close);

      final results = await service.search(text: 'Dolo 650');
      expect(results, hasLength(1));
      expect(results.single.provider, 'strong');
      expect(results.single.score, .94);
    },
  );

  test('catalog service coalesces and caches repeated scan lookups', () async {
    final provider = _FakeProvider([
      const MedicineCatalogCandidate(
        seed: MedicineDraftSeed(name: 'Dolo', strength: '650 mg'),
        score: .94,
        provider: 'cache-test',
      ),
    ]);
    final service = MedicineCatalogService(providers: [provider]);
    addTearDown(service.close);

    final first = service.search(text: 'Dolo 650');
    final second = service.search(text: 'Dolo 650');
    await Future.wait([first, second]);
    await service.search(text: 'Dolo 650');

    expect(provider.calls, 1);
  });
}

class _FakeProvider implements MedicineCatalogProvider {
  _FakeProvider(this.results);

  final List<MedicineCatalogCandidate> results;
  int calls = 0;

  @override
  Future<List<MedicineCatalogCandidate>> search({
    required String barcode,
    required String text,
    required int limit,
  }) async {
    calls++;
    return results;
  }
}
