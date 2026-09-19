// Pure Dart checks of user-facing actions against real stock-planning decisions.
import 'dart:io';

import '../lib/domain/attention.dart';
import '../lib/domain/medicine.dart';
import '../lib/domain/operations_plan.dart';
import '../lib/domain/stock_guidance.dart';
import '../lib/domain/tracking.dart';

var passed = 0;
void check(bool value, String label) {
  if (!value) throw StateError(label);
  passed++;
}

final today = DateTime(2026, 9, 15);
Medicine stock({
  int? quantity = 2,
  String? expiry = '2027-01',
  String name = 'Cefixime',
  String id = 'a',
  String salt = '',
}) => Medicine.fromJson({
  'id': id,
  'name': name,
  'strength': '200 mg',
  'form': 'Tablet',
  'quantity': quantity,
  'expiry': expiry,
  'address': 'Rack 1',
  'salt': salt,
});
ReorderSuggestion order(
  Medicine record, {
  bool review = false,
  int? quantity = 2,
}) => ReorderSuggestion(
  productKey: record.identity,
  name: record.name,
  salt: record.salt,
  strength: record.strength,
  form: record.form,
  priority: ReorderPriority.soon,
  reason: 'Technical internal reason',
  suggestedQuantity: 10,
  unitsSold: 30,
  unitsPerDay: 1,
  stockIds: [record.id],
  currentQuantity: quantity,
  reviewRequired: review,
  confidence: review ? .4 : .95,
);
AttentionItem item(Medicine record, AttentionKind kind) => AttentionItem(
  key: '${kind.name}:${record.id}',
  kind: kind,
  severity: kind == AttentionKind.expiredStock
      ? AttentionSeverity.critical
      : AttentionSeverity.medium,
  title: '${record.title} · internal report title',
  detail: 'Long internal details',
  stockIds: [record.id],
  productKey: record.identity,
);
StockGuidance guide(
  Medicine record,
  AttentionKind kind, {
  bool review = false,
  AttentionKind? blocker,
}) {
  final reportItem = item(record, kind);
  final plan = PharmacyOperationsPlan.build(
    items: [reportItem, if (blocker != null) item(record, blocker)],
    medicines: [record],
  );
  return StockGuidance.fromStep(
    plan.steps.singleWhere((step) => step.item.key == reportItem.key),
    records: {record.id: record},
    orders: {record.identity: order(record, review: review)},
    today: today,
  );
}

void main() {
  try {
    final record = stock();
    final missing = guide(stock(expiry: null), AttentionKind.unknownExpiry);
    check(
      missing.title == record.title,
      'Keep medicine and strength, omit report suffix',
    );
    check(missing.action == 'Expiry जोड़ें', 'Expiry has a direct action');
    check(missing.reason.contains('2 यूनिट'), 'Known stock remains visible');
    check(
      !missing.reason.contains('FEFO'),
      'No technical copy leaks into the task',
    );
    final unknown = guide(stock(quantity: null), AttentionKind.unknownQuantity);
    check(unknown.action == 'स्टॉक गिनें', 'Ask for physical count');
    check(!unknown.reason.contains('0 यूनिट'), 'Unknown does not become zero');
    final confident = guide(record, AttentionKind.reorderReview);
    check(
      confident.action == '10 यूनिट मँगाएँ',
      'Use exact supported order quantity',
    );
    check(
      confident.reason.contains('30 दिन में 30'),
      'Recorded sales period stays explicit',
    );
    check(
      !confident.action.contains('टैबलेट'),
      'Never infer tablets from generic units',
    );
    final uncertain = guide(record, AttentionKind.reorderReview, review: true);
    check(
      !uncertain.action.contains('10'),
      'Review-only estimates are not commands',
    );
    for (final blocker in [
      AttentionKind.unknownExpiry,
      AttentionKind.unknownQuantity,
      AttentionKind.barcodeConflict,
      AttentionKind.possibleDuplicateBatch,
      AttentionKind.soldAuditGap,
    ]) {
      final blocked = guide(
        record,
        AttentionKind.reorderReview,
        blocker: blocker,
      );
      check(
        blocked.blocked && !blocked.action.contains('10'),
        '${blocker.name} blocks quantity advice',
      );
      check(
        blocked.action.startsWith('पहले '),
        'Explain the first prerequisite',
      );
    }
    for (final kind in AttentionKind.values.where(
      (kind) =>
          kind != AttentionKind.urgentReorder &&
          kind != AttentionKind.reorderReview,
    )) {
      final task = guide(record, kind);
      check(
        !task.action.contains('10 यूनिट मँगाएँ'),
        'Order for same product cannot replace ${kind.name}',
      );
      check(task.action.length < 75, '${kind.name} is readable at a glance');
    }
    final expired = guide(stock(expiry: '2026-08'), AttentionKind.expiredStock);
    check(
      expired.critical && expired.action.contains('न बेचें'),
      'Expired remains an explicit stop',
    );
    final lastDay = guide(
      stock(expiry: '2026-09-15'),
      AttentionKind.shortExpiry,
    );
    check(
      lastDay.reason.contains('आज आखिरी दिन'),
      'Zero days is today, not expired',
    );
    final slowStock = stock(quantity: 50);
    List<StockGuidance> movement(
      int saleCount, {
      Medicine? medicine,
      bool blocked = false,
      String saleSalt = '',
    }) {
      final m = medicine ?? slowStock;
      final sales = [
        for (var i = 0; i < saleCount; i++)
          SaleEvent(
            id: 's$i',
            stockId: m.id,
            medicineName: m.name,
            strength: m.strength,
            form: m.form,
            salt: saleSalt,
            quantity: 1,
            occurredAt: today.subtract(Duration(days: i * 3 + 1)),
          ),
      ];
      final tracking = TrackingStats(
        medicines: [m],
        sales: sales,
        range: TrackingRange.lastDays(today, 30),
        today: today,
      );
      return stockMovementGuidance(
        tracking: tracking,
        records: {m.id: m},
        plan: PharmacyOperationsPlan.build(
          items: [if (blocked) item(m, AttentionKind.unknownQuantity)],
          medicines: [m],
        ),
        today: today,
      );
    }

    final quiet = movement(0).single;
    check(
      quiet.reason.contains('0 बिक्री दर्ज'),
      'Missing sales are labelled recorded, not true zero demand',
    );
    check(
      quiet.action != 'अभी और न मँगाएँ',
      'No sales does not justify an automatic pause',
    );
    check(
      movement(1).single.action != 'अभी और न मँगाएँ',
      'One sale is insufficient for pause advice',
    );
    check(
      movement(3).single.action == 'अभी और न मँगाएँ',
      'Sales on three distinct days across a week and 30-day stock support pause',
    );
    check(
      movement(
        3,
        medicine: stock(quantity: 50, salt: 'Paracetamol'),
        saleSalt: 'Ibuprofen',
      ).isEmpty,
      'A corrected medicine cannot inherit another ingredient sales',
    );
    check(
      movement(3, blocked: true).isEmpty,
      'Do not contradict a fact-repair task',
    );
    check(
      movement(3, medicine: stock(quantity: null)).isEmpty,
      'Unknown stock cannot justify pause',
    );
    check(
      movement(3, medicine: stock(expiry: null)).isEmpty,
      'Unknown expiry cannot justify pause',
    );
    check(
      movement(3, medicine: stock(expiry: '2026-08')).isEmpty,
      'Expired stock is not usable coverage',
    );
    // The complete report from the photographed missing-expiry scenario also
    // retains its original safety dependency, rather than only changing labels.
    final photoStock = stock(expiry: null);
    final tracking = TrackingStats(
      medicines: [photoStock],
      sales: [],
      range: TrackingRange.lastDays(today, 30),
      today: today,
    );
    final report = PharmacyAttentionReport.build(
      medicines: [photoStock],
      settings: const WarningSettings(),
      today: today,
      reorder: tracking.reorder,
    );
    final plan = PharmacyOperationsPlan.build(
      items: report.items,
      medicines: [photoStock],
    );
    check(
      plan.steps.any((step) => step.item.kind == AttentionKind.unknownExpiry),
      'Photo scenario retains expiry task',
    );
    check(
      plan.steps
          .where((step) => step.item.isReorder)
          .every((step) => step.blocked),
      'Photo scenario cannot skip expiry review to order',
    );
    stdout.writeln('Stock guidance: $passed passed.');
  } catch (error, stack) {
    stderr.writeln('$error\n$stack');
    exitCode = 1;
  }
}
