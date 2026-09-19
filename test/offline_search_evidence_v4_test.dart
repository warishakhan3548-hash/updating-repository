import 'package:flutter_test/flutter_test.dart';

import '../lib/domain/inventory.dart';
import '../lib/domain/search.dart';
import 'domain_contract.dart';

void main() {
  group('Aaris offline search evidence engine V4', () {
    test('fuses independent identity clues instead of trusting one field', () {
      final engine = MedicineSearch([
        stock(
          'coherent',
          name: 'Montek LC',
          salt: 'Montelukast Levocetirizine',
          strength: '10mg',
          form: 'Tablet',
          expiry: '2027-12-31',
        ),
        stock(
          'name-only-decoy',
          name: 'Montek LC',
          salt: 'Desloratadine',
          strength: '10mg',
          form: 'Tablet',
          expiry: '2027-12-31',
        ),
      ]);

      final hits = engine.search(
        'Montek Levocetirizine 10mg tablet',
        SearchScope.all,
        contractSettings,
        contractToday,
      );

      expect(hits, isNotEmpty);
      expect(hits.first.id, 'coherent');
      final decoy = hits.where((hit) => hit.id == 'name-only-decoy').toList();
      if (decoy.isNotEmpty) {
        expect(hits.first.score, greaterThan(decoy.single.score));
      }
      expect(hits.first.score, greaterThanOrEqualTo(.85));
    });

    test('same name and strength cannot hide a dosage-form contradiction', () {
      final engine = MedicineSearch([
        stock(
          'tablet',
          name: 'CefiKid',
          salt: 'Cefixime',
          strength: '100mg',
          form: 'Tablet',
          expiry: '2027-12-31',
        ),
        stock(
          'syrup',
          name: 'CefiKid',
          salt: 'Cefixime',
          strength: '100mg',
          form: 'Syrup',
          expiry: '2027-12-31',
        ),
      ]);

      final hits = engine.search(
        'CefiKid 100mg syrup',
        SearchScope.all,
        contractSettings,
        contractToday,
      );

      expect(hits, isNotEmpty);
      expect(hits.first.id, 'syrup');
      final wrongForm = hits.where((hit) => hit.id == 'tablet').toList();
      if (wrongForm.isNotEmpty) {
        expect(wrongForm.single.score, lessThan(hits.first.score));
        expect(
          wrongForm.single.reason,
          'Different dosage form — check carefully',
        );
      }
    });

    test('strength contradiction remains stronger than fuzzy identity evidence', () {
      final engine = MedicineSearch([
        stock(
          'right-strength',
          name: 'Dolo',
          salt: 'Paracetamol',
          strength: '650mg',
          form: 'Tablet',
          expiry: '2027-12-31',
        ),
        stock(
          'wrong-strength',
          name: 'Dolo',
          salt: 'Paracetamol',
          strength: '500mg',
          form: 'Tablet',
          expiry: '2027-12-31',
        ),
      ]);

      final hits = engine.search(
        'D0LO paracetamol 650mg tablet',
        SearchScope.all,
        contractSettings,
        contractToday,
      );

      expect(hits, isNotEmpty);
      expect(hits.first.id, 'right-strength');
      final wrongStrength = hits.where((hit) => hit.id == 'wrong-strength').toList();
      if (wrongStrength.isNotEmpty) {
        expect(wrongStrength.single.score, lessThan(hits.first.score));
        expect(
          wrongStrength.single.reason,
          'Different strength — check carefully',
        );
      }
    });
  });
}
