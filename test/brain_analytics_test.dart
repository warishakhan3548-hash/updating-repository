import 'package:aaris_pharmacy/domain/app_brain.dart';
import 'package:aaris_pharmacy/domain/brain_analytics.dart';
import 'package:aaris_pharmacy/domain/medicine.dart';
import 'package:aaris_pharmacy/domain/tracking.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final today = DateTime.utc(2026, 9, 10);

  group('Aaris Brain live analytics parser', () {
    test('routes today sales to a read-only local analytics brief', () {
      final intent = parseAppBrainIntent('aaj ki bikri kitni');
      expect(intent.action, AppBrainAction.analyticsBrief);
      expect(intent.mutatesInventory, isFalse);
      expect(intent.analyticsRequest, isNotNull);
      expect(
        intent.analyticsRequest!.rangeKind,
        BrainAnalyticsRangeKind.today,
      );
      expect(
        intent.analyticsRequest!.focus,
        BrainAnalyticsFocus.salesSummary,
      );
    });

    test('understands bounded English and Devanagari day windows', () {
      final english = parseBrainAnalyticsRequest('last 7 days sales report');
      expect(english, isNotNull);
      expect(english!.rangeKind, BrainAnalyticsRangeKind.lastDays);
      expect(english.days, 7);

      final hindi = parseBrainAnalyticsRequest('पिछले ३० दिन बिक्री रिपोर्ट');
      expect(hindi, isNotNull);
      expect(hindi!.rangeKind, BrainAnalyticsRangeKind.lastDays);
      expect(hindi.days, 30);
    });

    test('resolves week-to-date and month-to-date as civil ranges', () {
      final week = parseBrainAnalyticsRequest('fast moving this week')!;
      final weekRange = week.resolveRange(today);
      expect(dateText(weekRange.start), '2026-09-07');
      expect(dateText(weekRange.end), '2026-09-10');

      final month = parseBrainAnalyticsRequest('slow moving this month')!;
      final monthRange = month.resolveRange(today);
      expect(dateText(monthRange.start), '2026-09-01');
      expect(dateText(monthRange.end), '2026-09-10');
    });

    test('does not reinterpret a sale mutation as analytics', () {
      expect(parseBrainAnalyticsRequest('Dolo 650 5 units sell'), isNull);
      final intent = parseAppBrainIntent('Dolo 650 5 units sell');
      expect(intent.action, AppBrainAction.recordSale);
      expect(intent.quantity, 5);
    });

    test('rejects conflicting explicit analytics windows', () {
      expect(
        parseBrainAnalyticsRequest('last 7 days and last 30 days sales report'),
        isNull,
      );
    });
  });

  group('Aaris Brain deterministic analytics brief', () {
    test('summarizes only recorded ledger facts with exact money', () {
      final medicine = Medicine(
        id: 'm1',
        name: 'Dolo',
        salt: 'Paracetamol',
        strength: '650 mg',
        form: 'Tablet',
        quantity: 20,
      );
      final stats = TrackingStats(
        medicines: [medicine],
        sales: [
          SaleEvent(
            id: 's1',
            stockId: medicine.id,
            medicineName: medicine.name,
            salt: medicine.salt,
            strength: medicine.strength,
            form: medicine.form,
            quantity: 3,
            occurredAt: DateTime.utc(2026, 9, 10, 9),
            totalAmountPaise: 3000,
          ),
        ],
        range: TrackingRange(start: today, end: today),
        today: today,
      );
      const request = BrainAnalyticsRequest(
        focus: BrainAnalyticsFocus.salesSummary,
        rangeKind: BrainAnalyticsRangeKind.today,
        days: 1,
      );

      final brief = buildBrainAnalyticsBrief(
        request: request,
        stats: stats,
        today: today,
      );
      expect(brief, contains('1 recorded sale event'));
      expect(brief, contains('3 units sold'));
      expect(brief, contains('₹30.00'));
      expect(brief, contains('Dolo · 650 mg'));
    });

    test('never invents revenue when sale amount is absent', () {
      final medicine = Medicine(
        id: 'm2',
        name: 'Crocin',
        form: 'Tablet',
        quantity: 5,
      );
      final stats = TrackingStats(
        medicines: [medicine],
        sales: [
          SaleEvent(
            id: 's2',
            stockId: medicine.id,
            medicineName: medicine.name,
            form: medicine.form,
            quantity: 1,
            occurredAt: today,
          ),
        ],
        range: TrackingRange(start: today, end: today),
        today: today,
      );
      const request = BrainAnalyticsRequest(
        focus: BrainAnalyticsFocus.salesSummary,
        rangeKind: BrainAnalyticsRangeKind.today,
      );

      final brief = buildBrainAnalyticsBrief(
        request: request,
        stats: stats,
        today: today,
      );
      expect(brief, contains('sale amount not recorded'));
    });
  });

  group('purchase-order unit-cost evidence', () {
    TrackingStats statsFor(List<Medicine> medicines) => TrackingStats(
      medicines: medicines,
      sales: const <SaleEvent>[],
      range: TrackingRange.lastDays(today, 30),
      today: today,
    );

    Medicine stock(String id, int? price) => Medicine(
      id: id,
      name: 'Aaris Test',
      strength: '10 mg',
      form: 'Tablet',
      quantity: 0,
      unitPricePaise: price,
    );

    test('conflicting active batch prices are never auto-filled', () {
      final stats = statsFor([stock('a', 1000), stock('b', 1200)]);
      expect(stats.reorder, hasLength(1));
      expect(stats.reorder.single.unitPricePaise, isNull);
    });

    test('one consensus active price remains eligible for auto-fill', () {
      final stats = statsFor([stock('a', 1000), stock('b', 1000)]);
      expect(stats.reorder, hasLength(1));
      expect(stats.reorder.single.unitPricePaise, 1000);
    });
  });
}
