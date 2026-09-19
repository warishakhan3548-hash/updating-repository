// Focused pure Dart contracts. No Flutter runner, platform services or network.
import 'dart:io';
import 'dart:math' as math;

import '../lib/domain/attention.dart';
import '../lib/domain/daily_demand.dart';
import '../lib/domain/medicine.dart';
import '../lib/domain/operations_plan.dart';
import '../lib/domain/stock_guidance.dart';
import '../lib/domain/stock_projection.dart';
import '../lib/domain/stock_risk.dart';
import '../lib/domain/tracking.dart';

var passed = 0;
void check(bool condition, String label) {
  if (!condition) throw StateError(label);
  passed++;
}

bool close(double a, double b) => (a - b).abs() < 1e-7;
final today = DateTime.utc(2026, 9, 15);
Medicine stock({
  String id = 'a',
  String name = 'Cefixime',
  String salt = '',
  int? quantity = 5,
  String? expiry = '2027-12-31',
  String? mfg,
  bool sold = false,
  int? soldQuantity,
  int? price,
}) => Medicine.fromJson({
  'id': id,
  'name': name,
  'salt': salt,
  'strength': '200 mg',
  'form': 'Tablet',
  'quantity': quantity,
  'expiry': expiry,
  'mfg': mfg,
  'address': 'Rack 1',
  'batchNumber': id,
  'sold': sold,
  'soldQuantity': soldQuantity,
  if (sold) 'soldAt': '2026-09-14T12:00:00',
  'unitPricePaise': price,
});
SaleEvent sale(
  int age,
  int units, {
  String id = '',
  String stockId = 'a',
  String name = 'Cefixime',
  String salt = '',
  DateTime? date,
}) => SaleEvent(
  id: id.isEmpty ? 'sale-$age-$units' : id,
  stockId: stockId,
  medicineName: name,
  salt: salt,
  strength: '200 mg',
  form: 'Tablet',
  quantity: units,
  occurredAt: date ?? today.subtract(Duration(days: age)),
);
List<SaleEvent> steady(int units, {int days = 30}) => [
  for (var age = 1; age <= days; age++) sale(age, units),
];
TrackingStats stats(
  List<Medicine> rows,
  List<SaleEvent> sales, {
  TrackingRange? range,
}) => TrackingStats(
  medicines: rows,
  sales: sales,
  today: today,
  range: range ?? TrackingRange.lastDays(today, 30),
);
DailyDemandProfile profile(List<SaleEvent> sales, {List<Medicine>? rows}) =>
    dailyDemandByProduct(
      medicines: rows ?? [stock()],
      sales: sales,
      today: today,
    )[stock().identity]!;

void main() {
  try {
    final daily = profile(steady(2));
    check(
      daily.days.length == 30 &&
          daily.days.first.day == DateTime.utc(2026, 8, 16),
      'Thirty completed days have exact civil boundaries',
    );
    check(
      daily.todayUnits == 0 &&
          daily.yesterdayUnits == 2 &&
          daily.unitsLast30Days == 58,
      'Partial today and rolling thirty-day count are distinct',
    );
    check(
      daily.recentWeekUnits == 14 && daily.previousWeekUnits == 14,
      'Week comparisons use seven completed days each',
    );
    check(
      close(daily.planningUnitsPerDay, 2),
      'Constant demand stays constant',
    );
    check(
      daily.confidence >= .9 && !daily.reviewRequired,
      'Thirty daily observations support an estimate',
    );
    check(
      close(daily.bufferForDays(7), 0),
      'No invented variability for constant sales',
    );
    check(daily.trend == DemandTrend.steady, 'Constant pace is stable');
    final split = profile([
      for (var age = 1; age <= 30; age++) ...[
        sale(age, 1, id: 'x-$age'),
        sale(age, 1, id: 'y-$age'),
      ],
    ]);
    check(
      close(split.planningUnitsPerDay, daily.planningUnitsPerDay) &&
          split.confidence == daily.confidence,
      'Receipt splitting cannot change demand or confidence',
    );
    final sameDay = profile([
      for (var i = 0; i < 50; i++) sale(1, 1, id: '$i'),
    ]);
    check(
      sameDay.sellingDays == 1 &&
          sameDay.reviewRequired &&
          sameDay.confidence < .75,
      'Fifty receipts on one day remain one day of evidence',
    );
    check(
      PharmacyStockRiskReport.build(
        medicines: [stock(quantity: 500, expiry: '2026-09-20')],
        sales: [for (var i = 0; i < 50; i++) sale(1, 1, id: '$i')],
        today: today,
      ).isEmpty,
      'One day cannot create an expiry-waste forecast',
    );
    final reversed = profile(steady(2).reversed.toList());
    check(
      close(reversed.planningUnitsPerDay, daily.planningUnitsPerDay),
      'Input ordering cannot change daily estimates',
    );
    final partial = profile([...steady(2), sale(0, 1)]);
    check(
      close(partial.planningUnitsPerDay, 2) &&
          partial.todayUnits == 1 &&
          partial.unitsLast30Days == 59,
      'Today updates totals without lowering the completed-day rate',
    );
    check(
      close(partial.demandForDays(30), 59),
      'Already recorded demand today is not charged twice',
    );
    check(
      profile([sale(0, 100)]).hasEstimate == false,
      'Today alone is insufficient completed history',
    );
    check(
      profile([sale(31, 100)]).unitsLast30Days == 0,
      'Old sales do not enter the current window',
    );
    final future = profile([...steady(2), sale(-1, 500)]);
    check(
      future.historyNeedsReview &&
          !future.hasEstimate &&
          future.unitsLast30Days == 58,
      'Future sales are excluded and flagged',
    );
    final lifecycle = profile(
      [sale(1, 100), sale(2, 100)],
      rows: [stock(mfg: '2026-09-15')],
    );
    check(
      lifecycle.historyNeedsReview &&
          !lifecycle.hasEstimate &&
          lifecycle.unitsLast30Days == 200,
      'Impossible chronology remains visible but cannot forecast',
    );
    final conflict = profile(
      steady(2)
          .map(
            (s) => sale(
              today.difference(s.occurredAt).inDays,
              2,
              salt: 'Different salt',
            ),
          )
          .toList(),
      rows: [stock(salt: 'Current salt')],
    );
    check(
      conflict.identityConflict && !conflict.hasEstimate,
      'Known composition conflict disables forecasting',
    );
    final renamed = stats([stock(name: 'Corrected', quantity: 0)], steady(2));
    check(
      renamed.reorder.single.suggestedQuantity == null &&
          renamed.movements[stock().identity]!.unitsSold == 58,
      'Identity edits preserve old history without manufacturing new demand',
    );

    final rising = profile([
      for (var age = 1; age <= 30; age++) sale(age, age <= 7 ? 4 : 1),
    ]);
    final falling = profile([
      for (var age = 1; age <= 30; age++) sale(age, age <= 7 ? 1 : 4),
    ]);
    check(
      rising.trend == DemandTrend.rising && rising.planningUnitsPerDay > 2.5,
      'Sustained recent growth affects planning',
    );
    check(
      falling.trend == DemandTrend.falling && falling.planningUnitsPerDay < 2.5,
      'Sustained slowing reduces planning',
    );
    final bulk = profile([
      for (var age = 1; age <= 30; age++) sale(age, age == 1 ? 500 : 2),
    ]);
    check(
      bulk.variableSales && bulk.reviewRequired && bulk.unitsLast30Days == 556,
      'Bulk sales stay in raw counts but cannot silently raise confidence',
    );
    final stopped = profile([for (var age = 8; age <= 30; age++) sale(age, 2)]);
    check(
      stopped.reviewRequired &&
          demandTrendLabel(stopped).contains('बिक्री दर्ज नहीं'),
      'No recent logged sales asks for review, not assumed zero demand',
    );
    final newHistory = profile(steady(2, days: 3));
    check(
      newHistory.observedDays == 7 &&
          newHistory.historySpanDays == 3 &&
          newHistory.reviewRequired,
      'New history is not diluted to a month or labelled mature',
    );

    final unknownDemand = stats([stock(quantity: 0)], []).reorder.single;
    check(
      unknownDemand.suggestedQuantity == null && unknownDemand.reviewRequired,
      'No fallback ten-unit order without sales',
    );
    final oldSold = stats([
      stock(quantity: 0, sold: true, soldQuantity: 5000),
    ], []).reorder.single;
    check(
      oldSold.suggestedQuantity == null,
      'Historical batch size is not future demand',
    );
    final twice = stats([stock(quantity: 5)], steady(2)).reorder.single;
    final once = stats([stock(quantity: 5)], steady(1)).reorder.single;
    check(
      twice.suggestedQuantity == 55 && once.suggestedQuantity == 25,
      'Order quantity follows pace and current stock',
    );
    check(
      twice.reviewRequired == false && twice.coverageDays == 2.5,
      'Supported stock coverage is available',
    );
    final soldToday = stats(
      [stock(quantity: 3)],
      [...steady(2), sale(0, 2)],
    ).reorder.single;
    check(
      soldToday.suggestedQuantity == twice.suggestedQuantity,
      'Typical sales today reduce stock and remaining demand exactly once',
    );
    final shortRange = stats(
      [stock(quantity: 5)],
      steady(2),
      range: TrackingRange.lastDays(today, 7),
    );
    check(
      shortRange.unitsSold == 12 &&
          shortRange.reorder.single.suggestedQuantity == 55,
      'Historical analytics range does not redefine current order demand',
    );
    final oldRange = stats(
      [stock(quantity: 5)],
      steady(2),
      range: TrackingRange(
        start: DateTime.utc(2026, 1, 1),
        end: DateTime.utc(2026, 1, 7),
      ),
    );
    check(
      oldRange.unitsSold == 0 &&
          oldRange.reorder.single.suggestedQuantity == 55,
      'An old sales report cannot erase current planning evidence',
    );
    final unknownStock = stats([stock(quantity: null)], steady(2));
    check(
      unknownStock.reorder.isEmpty &&
          unknownStock.movements.values.single.coverageDays == null,
      'Unknown stock is not zero stock or numerical coverage',
    );
    final unknownExpiry = stats([
      stock(quantity: 5, expiry: null),
    ], steady(2)).reorder.single;
    check(
      unknownExpiry.suggestedQuantity == null && unknownExpiry.reviewRequired,
      'Missing expiry blocks numeric purchasing',
    );
    final exp = stats([
      stock(quantity: 50, expiry: '2026-09-14'),
    ], steady(2)).reorder.single;
    check(
      exp.currentQuantity == 0 && exp.suggestedQuantity == 60,
      'Expired units are unavailable stock',
    );
    final manufacture = stats([
      stock(quantity: 10, mfg: '2026-09-16'),
    ], steady(2)).reorder.single;
    check(
      manufacture.suggestedQuantity == null && manufacture.reviewRequired,
      'Future manufacture dates cannot support automation',
    );
    final costly = stats([
      stock(quantity: 2, price: 500),
      stock(id: 'b', quantity: 2, price: 900),
    ], steady(2)).reorder.single;
    check(
      costly.unitPricePaise == null,
      'Conflicting purchase costs remain manual',
    );
    final huge = stats([stock(quantity: 0)], steady(100000000)).reorder.single;
    check(
      huge.suggestedQuantity == 100000000 && huge.reviewRequired,
      'Order limit requires review instead of an unsafe silent truncation',
    );

    final early = stock(quantity: 20, expiry: '2026-09-18');
    final late = stock(id: 'b', quantity: 5);
    final projected = StockDemandProjection.build(
      medicines: [early, late],
      today: today,
      demand: daily,
    )!;
    check(
      close(projected.wasteWithinDays(7), 12),
      'Only surplus after expected in-date sales counts as waste',
    );
    check(
      projected.expiringWithinDays(7) == 20,
      'Expiring units and expected wasted units are distinct',
    );
    check(
      close(projected.coverageDays, 6.5),
      'Coverage excludes expected expired leftovers',
    );
    final replacement = stats([early, late], steady(2)).reorder.single;
    check(
      replacement.suggestedQuantity == 47 &&
          replacement.projectedExpiryWaste == 12,
      'Partial expiry pressure triggers a net replacement, not the whole batch',
    );
    final risk = PharmacyStockRiskReport.build(
      medicines: [early, late],
      sales: steady(2),
      today: today,
    ).expiryWaste.single;
    check(
      risk.atRiskUnits == 12 &&
          close(risk.planningUnitsPerDay, replacement.unitsPerDay),
      'Buying and expiry warnings share the exact demand rate',
    );
    final todayBatch = stock(quantity: 8, expiry: '2026-09-15');
    final todayRisk = PharmacyStockRiskReport.build(
      medicines: [todayBatch],
      sales: [...steady(2), sale(0, 2)],
      today: today,
    ).expiryWaste.single;
    check(
      todayRisk.atRiskUnits == 8,
      'Today-expiring stock gets no already-consumed daily demand',
    );
    final twoBatches = [
      stock(quantity: 15, expiry: '2026-09-20'),
      stock(id: 'b', quantity: 40, expiry: '2026-09-30'),
    ];
    final twoRisk = PharmacyStockRiskReport.build(
      medicines: twoBatches,
      sales: steady(1),
      today: today,
    ).expiryWaste;
    check(
      twoRisk.first.atRiskUnits == 9 && twoRisk.last.atRiskUnits == 30,
      'Early waste cannot absorb demand belonging to later days',
    );
    final boundary = StockDemandProjection.build(
      medicines: [stock(quantity: 100, expiry: '2026-09-22')],
      today: today,
      demand: daily,
    )!;
    check(
      boundary.wasteWithinDays(7) == 0 && boundary.wasteWithinDays(8) > 0,
      'Seven-day window has no off-by-one expiry inclusion',
    );
    final noWaste = PharmacyStockRiskReport.build(
      medicines: [stock(quantity: 4, expiry: '2026-09-18')],
      sales: steady(2),
      today: today,
    );
    check(
      noWaste.isEmpty,
      'Enough recorded demand suppresses a false waste warning',
    );

    // Reference simulation consumes actual integral daily units and expires
    // leftovers at the end of each civil day. It is independent of the cumulative
    // allocation in production and catches FEFO ordering/expiry edge cases.
    final random = math.Random(9152026);
    for (var trial = 0; trial < 80; trial++) {
      final rate = random.nextInt(5) + 1;
      final rows = [
        for (var i = 0; i < 4; i++)
          stock(
            id: 'batch$i',
            quantity: random.nextInt(25) + 1,
            expiry: dateText(today.add(Duration(days: random.nextInt(12)))),
          ),
      ];
      final d = profile(steady(rate));
      final p = StockDemandProjection.build(
        medicines: rows.reversed,
        today: today,
        demand: d,
      )!;
      final left = {for (final row in rows) row.id: row.quantity!};
      final waste = <String, int>{};
      final sorted = [...rows]
        ..sort((a, b) {
          final date = a.expiry!.compareTo(b.expiry!);
          return date != 0 ? date : a.id.compareTo(b.id);
        });
      for (var offset = 0; offset < 12; offset++) {
        var remaining = rate;
        for (final row in sorted) {
          if (row.daysLeft(today)! < offset) continue;
          final take = math.min(left[row.id]!, remaining);
          left[row.id] = left[row.id]! - take;
          remaining -= take;
        }
        for (final row in sorted.where(
          (row) => row.daysLeft(today) == offset,
        )) {
          waste[row.id] = left[row.id]!;
          left[row.id] = 0;
        }
      }
      check(
        p.batches.every((b) => b.atRiskUnits == waste[b.stock.id]),
        'FEFO reference simulation $trial',
      );
      check(
        p.batches.every(
              (b) => b.unsoldUnits >= 0 && b.unsoldUnits <= b.stock.quantity!,
            ) &&
            p.coverageDays.isFinite,
        'Projection conservation $trial',
      );
    }

    final report = PharmacyAttentionReport.build(
      medicines: [early, late],
      settings: const WarningSettings(),
      today: today,
      reorder: [replacement],
      sales: steady(2),
    );
    final plan = PharmacyOperationsPlan.build(
      items: report.items,
      medicines: [early, late],
    );
    final wasteStep = plan.steps.firstWhere(
      (s) => s.item.kind == AttentionKind.expiryWastePressure,
    );
    final guide = StockGuidance.fromStep(
      wasteStep,
      records: {early.id: early, late.id: late},
      orders: {early.identity: replacement},
      today: today,
    );
    check(
      guide.reason.contains('12 यूनिट') && guide.reason.contains('3 दिन'),
      'Concise card exposes actual batch risk without parsing paragraphs',
    );
    final missingReport = PharmacyAttentionReport.build(
      medicines: [stock(quantity: 5, expiry: null)],
      settings: const WarningSettings(),
      today: today,
      reorder: [unknownExpiry],
      sales: steady(2),
    );
    final missingPlan = PharmacyOperationsPlan.build(
      items: missingReport.items,
      medicines: [stock(quantity: 5, expiry: null)],
    );
    check(
      missingPlan.steps.where((s) => s.item.isReorder).every((s) => s.blocked),
      'Forecast changes cannot bypass fact-repair prerequisites',
    );
    final emptyReport = PharmacyAttentionReport.build(
      medicines: [stock(quantity: 0)],
      settings: const WarningSettings(),
      today: today,
      reorder: [unknownDemand],
    );
    check(
      emptyReport.items.every(
        (item) => !item.detail.contains('suggested null'),
      ),
      'Unknown quantity never leaks as null in UI/report copy',
    );
    final leap = DailyDemandAccumulator(DateTime.utc(2024, 3, 1))
      ..add(DateTime(2024, 2, 29, 23, 59), 3);
    check(
      leap.build().yesterdayUnits == 3,
      'Leap-day late sale stays in its recorded civil day',
    );
    stdout.writeln('Daily stock advice: $passed passed.');
    stdout.writeln(
      'Example: stable 2/day, 5 usable units -> ${twice.suggestedQuantity} units; partial expiry example -> ${replacement.suggestedQuantity} units, ${risk.atRiskUnits} at risk.',
    );
  } catch (error, stack) {
    stderr.writeln('$error\n$stack');
    exitCode = 1;
  }
}
