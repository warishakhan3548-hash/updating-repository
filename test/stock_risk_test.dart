import 'package:aaris_pharmacy/domain/medicine.dart';
import 'package:aaris_pharmacy/domain/stock_risk.dart';
import 'package:aaris_pharmacy/domain/tracking.dart';
import 'package:flutter_test/flutter_test.dart';

Medicine stock(
  String id, {
  String name = 'Dolo',
  String strength = '650 mg',
  String form = 'Tablet',
  String salt = '',
  int? quantity = 40,
  String? expiry = '2026-09-20',
  String batch = 'B1',
}) => Medicine.fromJson({
  'id': id,
  'name': name,
  'strength': strength,
  'form': form,
  'salt': salt,
  'quantity': quantity,
  if (expiry != null) 'expiry': expiry,
  'batchNumber': batch,
  'revision': 1,
});

SaleEvent sale(
  String id,
  int quantity,
  DateTime occurredAt, {
  String stockId = 'a',
  String name = 'Dolo',
  String strength = '650 mg',
  String form = 'Tablet',
  String salt = '',
}) => SaleEvent(
  id: id,
  stockId: stockId,
  medicineName: name,
  strength: strength,
  form: form,
  salt: salt,
  quantity: quantity,
  occurredAt: occurredAt,
);

void main() {
  final today = DateTime(2026, 9, 10, 12);

  test(
    'predicts FEFO expiry waste only from repeated recorded sales evidence',
    () {
      final report = PharmacyStockRiskReport.build(
        medicines: [stock('a', quantity: 50)],
        sales: [
          sale('s1', 2, DateTime(2026, 9, 5)),
          sale('s2', 2, DateTime(2026, 9, 8)),
        ],
        today: today,
        maxHorizonDays: 60,
      );

      final risk = report.expiryWaste.single;
      expect(risk.stockId, 'a');
      expect(risk.batchQuantity, 50);
      expect(risk.atRiskUnits, greaterThan(30));
      expect(risk.daysUntilExpiry, 10);
      expect(risk.saleEvents, 2);
      expect(risk.planningUnitsPerDay, greaterThan(0));
    },
  );

  test('one sale never becomes a confident expiry forecast', () {
    final report = PharmacyStockRiskReport.build(
      medicines: [stock('a', quantity: 50)],
      sales: [sale('s1', 1, DateTime(2026, 9, 8))],
      today: today,
    );
    expect(report.expiryWaste, isEmpty);
  });

  test('fast recent movement suppresses false waste pressure', () {
    final report = PharmacyStockRiskReport.build(
      medicines: [stock('a', quantity: 20)],
      sales: [
        sale('s1', 8, DateTime(2026, 9, 5)),
        sale('s2', 8, DateTime(2026, 9, 7)),
        sale('s3', 8, DateTime(2026, 9, 9)),
      ],
      today: today,
    );
    expect(report.expiryWaste, isEmpty);
  });

  test('unknown quantity or expiry blocks FEFO waste prediction', () {
    final evidence = [
      sale('s1', 1, DateTime(2026, 9, 5)),
      sale('s2', 1, DateTime(2026, 9, 8)),
    ];
    expect(
      PharmacyStockRiskReport.build(
        medicines: [stock('a', quantity: null)],
        sales: evidence,
        today: today,
      ).expiryWaste,
      isEmpty,
    );
    expect(
      PharmacyStockRiskReport.build(
        medicines: [stock('a', expiry: null)],
        sales: evidence,
        today: today,
      ).expiryWaste,
      isEmpty,
    );
  });

  test('early expired surplus never consumes later-period FEFO demand', () {
    final report = PharmacyStockRiskReport.build(
      medicines: [
        stock('a', quantity: 15, expiry: '2026-09-15', batch: 'EARLY'),
        stock('b', quantity: 40, expiry: '2026-09-25', batch: 'LATER'),
      ],
      sales: [
        sale('s1', 2, DateTime(2026, 9, 5)),
        sale('s2', 2, DateTime(2026, 9, 8)),
      ],
      today: today,
    );

    final byId = {for (final risk in report.expiryWaste) risk.stockId: risk};
    expect(byId.keys, containsAll(<String>['a', 'b']));
    expect(byId['a']!.atRiskUnits, 11);
    expect(byId['b']!.atRiskUnits, 34);
  });

  test('live identity edits never relabel historical sale evidence', () {
    final report = PharmacyStockRiskReport.build(
      medicines: [
        stock('a', name: 'Paracetamol', strength: '500 mg', quantity: 50),
      ],
      sales: [
        sale('s1', 2, DateTime(2026, 9, 5), name: 'Dolo', strength: '650 mg'),
        sale('s2', 2, DateTime(2026, 9, 8), name: 'Dolo', strength: '650 mg'),
      ],
      today: today,
    );

    expect(
      report.expiryWaste,
      isEmpty,
      reason: 'SaleEvent is an immutable product snapshot; correcting the current stock identity must not manufacture demand for the new identity.',
    );
  });

  test('conflicting known salt evidence fails closed', () {
    final report = PharmacyStockRiskReport.build(
      medicines: [stock('a', quantity: 50, salt: 'Paracetamol')],
      sales: [
        sale('s1', 2, DateTime(2026, 9, 5), salt: 'Paracetamol + Caffeine'),
        sale('s2', 2, DateTime(2026, 9, 8), salt: 'Paracetamol + Caffeine'),
      ],
      today: today,
    );

    expect(
      report.expiryWaste,
      isEmpty,
      reason: 'Known conflicting composition facts must be reviewed instead of being aggregated into an operational demand forecast.',
    );
  });
}
