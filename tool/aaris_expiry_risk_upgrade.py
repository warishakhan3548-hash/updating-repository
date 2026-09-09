from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def replace_once(path: str, old: str, new: str) -> None:
    target = ROOT / path
    text = target.read_text(encoding='utf-8')
    count = text.count(old)
    if count != 1:
        raise SystemExit(f'{path}: expected one match, found {count}: {old[:140]!r}')
    target.write_text(text.replace(old, new, 1), encoding='utf-8')


def write(path: str, content: str) -> None:
    target = ROOT / path
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(content, encoding='utf-8')


stock_risk = r'''import 'dart:math' as math;

import 'medicine.dart';
import 'tracking.dart';

class ExpiryWasteRisk {
  const ExpiryWasteRisk({
    required this.stockId,
    required this.productKey,
    required this.name,
    required this.strength,
    required this.form,
    required this.batchNumber,
    required this.address,
    required this.expiry,
    required this.daysUntilExpiry,
    required this.batchQuantity,
    required this.atRiskUnits,
    required this.planningUnitsPerDay,
    required this.saleEvents,
    required this.observedDays,
    required this.confidence,
  });

  final String stockId;
  final String productKey;
  final String name;
  final String strength;
  final String form;
  final String batchNumber;
  final String address;
  final DateTime expiry;
  final int daysUntilExpiry;
  final int batchQuantity;
  final int atRiskUnits;
  final double planningUnitsPerDay;
  final int saleEvents;
  final int observedDays;
  final double confidence;

  String get title => '$name${strength.isEmpty ? '' : ' · $strength'}';
  double get atRiskFraction => batchQuantity == 0 ? 0 : atRiskUnits / batchQuantity;

  String get stockCue {
    final parts = <String>[
      if (batchNumber.trim().isNotEmpty) 'Batch ${batchNumber.trim()}',
      if (address.trim().isNotEmpty) address.trim(),
    ];
    return parts.isEmpty ? 'Exact stock row' : parts.join(' · ');
  }

  String get confidenceLabel => confidence >= .9
      ? 'high evidence'
      : confidence >= .75
      ? 'good evidence'
      : 'limited evidence';
}

class PharmacyStockRiskReport {
  PharmacyStockRiskReport._(List<ExpiryWasteRisk> risks)
    : expiryWaste = List.unmodifiable(risks);

  factory PharmacyStockRiskReport.build({
    required Iterable<Medicine> medicines,
    required Iterable<SaleEvent> sales,
    required DateTime today,
    int maxHorizonDays = 60,
  }) {
    if (maxHorizonDays < 1 || maxHorizonDays > 730) {
      throw const FormatException('Expiry risk horizon must be between 1 and 730 days.');
    }

    final day = civilDay(today);
    final allRecords = medicines.toList(growable: false);
    final byId = <String, Medicine>{for (final medicine in allRecords) medicine.id: medicine};
    final groups = <String, List<Medicine>>{};

    for (final medicine in allRecords) {
      if (medicine.archived || medicine.sold || medicine.quantity == 0) continue;
      if (medicine.mfg != null && civilDay(medicine.mfg!).isAfter(day)) continue;
      final days = medicine.daysLeft(day);
      if (days != null && days < 0) continue;
      groups.putIfAbsent(medicine.identity, () => <Medicine>[]).add(medicine);
    }

    final evidence = <String, _VelocityEvidence>{};
    final start30 = day.subtract(const Duration(days: 29));
    final start7 = day.subtract(const Duration(days: 6));
    for (final sale in sales) {
      final saleDay = civilDay(sale.occurredAt);
      if (saleDay.isBefore(start30) || saleDay.isAfter(day)) continue;
      final record = byId[sale.stockId];
      final key = record?.identity ?? sale.productKey;
      final item = evidence.putIfAbsent(key, _VelocityEvidence.new);
      item.units30 += sale.quantity;
      item.events30++;
      if (item.firstDay == null || saleDay.isBefore(item.firstDay!)) {
        item.firstDay = saleDay;
      }
      if (!saleDay.isBefore(start7)) {
        item.units7 += sale.quantity;
        item.events7++;
      }
    }

    final risks = <ExpiryWasteRisk>[];
    for (final entry in groups.entries) {
      final rows = entry.value;

      // Quantity or expiry uncertainty makes a FEFO stock-consumption forecast
      // unsafe. Existing attention checks surface those missing facts instead of
      // this engine inventing a denominator or an expiry order.
      if (rows.any((medicine) => medicine.quantity == null)) continue;
      final positive = rows.where((medicine) => medicine.quantity! > 0).toList();
      if (positive.isEmpty || positive.any((medicine) => medicine.expiry == null)) {
        continue;
      }

      final movement = evidence[entry.key];
      if (movement == null ||
          movement.events30 < 2 ||
          movement.units30 <= 0 ||
          movement.firstDay == null) {
        continue;
      }

      // A newly recorded sales history must not be diluted over a full 30 days.
      // Clamp the observed denominator to 7..30 days, then use the faster of
      // recent-seven-day and observed-period demand. This deliberately biases
      // against false expiry-waste alarms when recent demand is accelerating.
      final observedDays = math.min(
        30,
        math.max(7, day.difference(movement.firstDay!).inDays + 1),
      );
      final periodVelocity = movement.units30 / observedDays;
      final recentVelocity = movement.units7 / 7.0;
      final planningVelocity = math.max(periodVelocity, recentVelocity);
      if (planningVelocity <= 0) continue;

      positive.sort((a, b) {
        final expiry = a.expiry!.compareTo(b.expiry!);
        if (expiry != 0) return expiry;
        final batch = normalize(a.batchNumber).compareTo(normalize(b.batchNumber));
        return batch != 0 ? batch : a.id.compareTo(b.id);
      });

      var cumulativeFefoUnits = 0;
      for (final medicine in positive) {
        final days = medicine.daysLeft(day)!;
        if (days > maxHorizonDays) break;
        final quantity = medicine.quantity!;
        cumulativeFefoUnits += quantity;

        // Expiry is inclusive, so a batch expiring today still has one possible
        // dispensing day. Project only recorded operational demand; never infer
        // any clinical need or future prescription volume.
        final horizonDays = math.max(1, days + 1);
        final expectedFefoDemand = (planningVelocity * horizonDays).ceil();
        final cumulativeExcess = math.max(0, cumulativeFefoUnits - expectedFefoDemand);
        final atRisk = math.min(quantity, cumulativeExcess);
        final minimumSignal = math.max(2, (quantity * .20).ceil());
        if (atRisk < minimumSignal) continue;

        final confidence = movement.events30 >= 6 && observedDays >= 21
            ? .92
            : movement.events30 >= 3
            ? .78
            : .62;
        risks.add(
          ExpiryWasteRisk(
            stockId: medicine.id,
            productKey: medicine.identity,
            name: medicine.name,
            strength: medicine.strength,
            form: medicine.form,
            batchNumber: medicine.batchNumber,
            address: medicine.address,
            expiry: medicine.expiry!,
            daysUntilExpiry: days,
            batchQuantity: quantity,
            atRiskUnits: atRisk,
            planningUnitsPerDay: planningVelocity,
            saleEvents: movement.events30,
            observedDays: observedDays,
            confidence: confidence,
          ),
        );
      }
    }

    risks.sort((a, b) {
      final expiry = a.daysUntilExpiry.compareTo(b.daysUntilExpiry);
      if (expiry != 0) return expiry;
      final units = b.atRiskUnits.compareTo(a.atRiskUnits);
      if (units != 0) return units;
      return a.title.compareTo(b.title);
    });
    return PharmacyStockRiskReport._(risks);
  }

  final List<ExpiryWasteRisk> expiryWaste;
  bool get isEmpty => expiryWaste.isEmpty;
}

class _VelocityEvidence {
  int units30 = 0;
  int events30 = 0;
  int units7 = 0;
  int events7 = 0;
  DateTime? firstDay;
}
'''

stock_risk_test = r'''import 'package:aaris_pharmacy/domain/medicine.dart';
import 'package:aaris_pharmacy/domain/stock_risk.dart';
import 'package:aaris_pharmacy/domain/tracking.dart';
import 'package:flutter_test/flutter_test.dart';

Medicine stock(
  String id, {
  int? quantity = 40,
  String? expiry = '2026-09-20',
  String batch = 'B1',
}) => Medicine.fromJson({
  'id': id,
  'name': 'Dolo',
  'strength': '650 mg',
  'form': 'Tablet',
  'quantity': quantity,
  if (expiry != null) 'expiry': expiry,
  'batchNumber': batch,
  'revision': 1,
});

SaleEvent sale(String id, int quantity, DateTime occurredAt) => SaleEvent(
  id: id,
  stockId: 'a',
  medicineName: 'Dolo',
  strength: '650 mg',
  form: 'Tablet',
  quantity: quantity,
  occurredAt: occurredAt,
);

void main() {
  final today = DateTime(2026, 9, 10, 12);

  test('predicts FEFO expiry waste only from repeated recorded sales evidence', () {
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
  });

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

  test('FEFO cumulative stock can expose a later batch at risk', () {
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

    expect(report.expiryWaste.map((risk) => risk.stockId), contains('b'));
  });
}
'''

risk_doc = r'''# Aaris Expiry-Waste Intelligence — 2026-09-10

Aaris now has a local, deterministic **expiry-waste pressure** engine inside the existing Needs Attention workflow.

## What it does

For each medicine identity, Aaris orders known positive stock by FEFO, combines the cumulative units that must move before each batch expiry, and compares that stock with recorded sales movement. The planning pace uses the faster of the observed-period and recent-seven-day velocity so a new or accelerating sales history is not diluted across an artificial 30-day denominator.

When the saved facts indicate that a meaningful portion of a batch may remain by expiry, the exact batch is surfaced in Needs Attention with its estimated at-risk units, evidence quality, current planning pace and physical stock cue.

## Safety design

- This is operational inventory forecasting, not medical advice.
- It never invents demand, dose, indication or medicine facts.
- It requires at least two recorded sale events for the product.
- A product with any unknown active quantity or expiry is excluded from the forecast; the existing missing-fact warnings remain authoritative instead.
- Recent demand is allowed to increase the planning pace, reducing false waste alarms when movement is accelerating.
- The expiry date is inclusive and FEFO cumulative stock is respected across batches.
- The risk horizon follows the pharmacist's configured month-expiry window.
- The engine is read-only. It cannot edit stock, sell, archive, merge batches or create/cancel purchase orders.

The result is a proactive queue that tells the pharmacist *where expiry loss may be forming* without turning an estimate into an automatic mutation.
'''

write('lib/domain/stock_risk.dart', stock_risk)
write('test/stock_risk_test.dart', stock_risk_test)
write('docs/AARIS_EXPIRY_WASTE_INTELLIGENCE_2026_09_10.md', risk_doc)

replace_once(
    'lib/domain/attention.dart',
    "import 'medicine.dart';\nimport 'tracking.dart';",
    "import 'medicine.dart';\nimport 'stock_risk.dart';\nimport 'tracking.dart';",
)
replace_once(
    'lib/domain/attention.dart',
    "  expiredStock,\n  shortExpiry,\n  zeroQuantityMismatch,",
    "  expiredStock,\n  shortExpiry,\n  expiryWastePressure,\n  zeroQuantityMismatch,",
)
replace_once(
    'lib/domain/attention.dart',
    "    required Iterable<ReorderSuggestion> reorder,\n  }) {",
    "    required Iterable<ReorderSuggestion> reorder,\n    Iterable<SaleEvent> sales = const <SaleEvent>[],\n  }) {",
)
risk_attention = r'''    final stockRisk = PharmacyStockRiskReport.build(
      medicines: active,
      sales: sales,
      today: day,
      maxHorizonDays: settings.monthDays,
    );
    for (final risk in stockRisk.expiryWaste) {
      final shortWindow = risk.daysUntilExpiry <= settings.shortDays;
      items.add(
        AttentionItem(
          key: 'expiry-waste:${risk.stockId}',
          kind: AttentionKind.expiryWastePressure,
          severity: shortWindow
              ? AttentionSeverity.high
              : AttentionSeverity.medium,
          title: '${risk.title} · expiry waste pressure',
          detail:
              '${risk.stockCue} · about ${risk.atRiskUnits} of ${risk.batchQuantity} known units may remain by ${dateText(risk.expiry)} if the recent recorded sales pace continues. Planning pace ${risk.planningUnitsPerDay.toStringAsFixed(1)} units/day from ${risk.saleEvents} sale records (${risk.confidenceLabel}). Review FEFO placement and the next reorder; Aaris will not change stock or ordering automatically.',
          stockIds: List.unmodifiable(<String>[risk.stockId]),
          productKey: risk.productKey,
        ),
      );
    }

'''
replace_once(
    'lib/domain/attention.dart',
    "    for (final suggestion in reorder) {",
    risk_attention + "    for (final suggestion in reorder) {",
)

replace_once(
    'lib/ui/attention_screen.dart',
    "      today: controller.today,\n      reorder: controller.tracking(range).reorder,\n    );",
    "      today: controller.today,\n      reorder: controller.tracking(range).reorder,\n      sales: controller.sales,\n    );",
)
replace_once(
    'lib/ui/attention_screen.dart',
    "    AttentionKind.shortExpiry => Icons.timer_outlined,\n    AttentionKind.zeroQuantityMismatch =>",
    "    AttentionKind.shortExpiry => Icons.timer_outlined,\n    AttentionKind.expiryWastePressure => Icons.trending_down_rounded,\n    AttentionKind.zeroQuantityMismatch =>",
)
replace_once(
    'lib/ui/attention_screen.dart',
    "Aaris checks expiry, stock consistency, batch fact conflicts, barcode identity, audit quality, missing automation facts and deterministic reorder signals from local data.",
    "Aaris checks expiry, FEFO waste pressure, stock consistency, batch fact conflicts, barcode identity, audit quality, missing automation facts and deterministic reorder signals from local data.",
)

replace_once(
    'lib/ui/brain_screen.dart',
    "      today: widget.controller.today,\n      reorder: widget.controller.tracking(range).reorder,\n    );",
    "      today: widget.controller.today,\n      reorder: widget.controller.tracking(range).reorder,\n      sales: widget.controller.sales,\n    );",
)

replace_once(
    'docs/ARCHITECTURE.md',
    "| `domain/tracking.dart` | Privacy-safe sale events, period movement and reorder suggestions |",
    "| `domain/tracking.dart` | Privacy-safe sale events, period movement and reorder suggestions |\n| `domain/stock_risk.dart` | Read-only FEFO expiry-waste pressure from known stock plus recorded sales; uncertainty fails closed |",
)

print('Aaris deterministic expiry-risk intelligence upgrade applied.')
