import 'package:flutter_test/flutter_test.dart';

import '../lib/domain/inventory.dart';
import '../lib/domain/search.dart';
import 'domain_contract.dart';

void main() {
  group('Aaris offline search evidence engine V5', () {
    test('reconstructs a brand split into single OCR characters', () {
      final engine = MedicineSearch([
        stock(
          'decoy',
          name: 'Crocin',
          salt: 'Paracetamol',
          strength: '650mg',
          form: 'Tablet',
          expiry: '2027-12-31',
        ),
        stock(
          'dolo',
          name: 'Dolo',
          salt: 'Paracetamol',
          strength: '650mg',
          form: 'Tablet',
          expiry: '2027-12-31',
        ),
      ]);

      final hits = engine.search(
        'D O L O 650mg tablet',
        SearchScope.all,
        contractSettings,
        contractToday,
      );

      expect(hits, isNotEmpty);
      expect(hits.first.id, 'dolo');
      expect(hits.first.score, greaterThanOrEqualTo(.85));
    });

    test('reconstructs OCR-spaced numeric strength only beside a unit', () {
      final engine = MedicineSearch([
        stock(
          'dolo-500',
          name: 'Dolo',
          salt: 'Paracetamol',
          strength: '500mg',
          form: 'Tablet',
          expiry: '2027-12-31',
        ),
        stock(
          'dolo-650',
          name: 'Dolo',
          salt: 'Paracetamol',
          strength: '650mg',
          form: 'Tablet',
          expiry: '2027-12-31',
        ),
      ]);

      final hits = engine.search(
        'D O L O 6 5 0 mg tablet',
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

    test('information-gain planning keeps a rare useful clue in a noisy query', () {
      final engine = MedicineSearch([
        stock(
          'cefikid',
          name: 'CefiKid',
          salt: 'Cefixime',
          strength: '100mg',
          form: 'Tablet',
          expiry: '2027-12-31',
        ),
        stock(
          'other',
          name: 'OtherMed',
          salt: 'Paracetamol',
          strength: '100mg',
          form: 'Tablet',
          expiry: '2027-12-31',
        ),
      ]);

      final hits = engine.search(
        'aa bb cc dd ee ff gg hh ii jj kk ll mm nn oo pp qq rr ss tt uu vv cefixime',
        SearchScope.all,
        contractSettings,
        contractToday,
      );

      expect(hits, isNotEmpty);
      expect(hits.first.id, 'cefikid');
    });

    test('repeated OCR words do not become independent evidence', () {
      final engine = MedicineSearch([
        stock(
          'right',
          name: 'Montek LC',
          salt: 'Montelukast Levocetirizine',
          strength: '10mg',
          form: 'Tablet',
          expiry: '2027-12-31',
        ),
        stock(
          'decoy',
          name: 'Montek LC',
          salt: 'Desloratadine',
          strength: '10mg',
          form: 'Tablet',
          expiry: '2027-12-31',
        ),
      ]);

      final hits = engine.search(
        'Montek Montek Montek Levocetirizine 10mg tablet',
        SearchScope.all,
        contractSettings,
        contractToday,
      );

      expect(hits, isNotEmpty);
      expect(hits.first.id, 'right');
      final decoy = hits.where((hit) => hit.id == 'decoy').toList();
      if (decoy.isNotEmpty) {
        expect(hits.first.score, greaterThan(decoy.single.score));
      }
    });
  });
}
