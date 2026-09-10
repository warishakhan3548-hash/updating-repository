import 'automation_readiness.dart';
import 'inventory.dart';
import 'inventory_integrity.dart';
import 'medicine.dart';
import 'stock_risk.dart';
import 'tracking.dart';

enum AttentionSeverity { critical, high, medium, low }

enum AttentionKind {
  expiredStock,
  shortExpiry,
  expiryWastePressure,
  zeroQuantityMismatch,
  barcodeConflict,
  conflictingLotFacts,
  staleSoldMetadata,
  soldAuditGap,
  urgentReorder,
  reorderReview,
  unknownExpiry,
  unknownQuantity,
  futureManufactureDate,
  possibleDuplicateBatch,
}

class AttentionItem {
  const AttentionItem({
    required this.key,
    required this.kind,
    required this.severity,
    required this.title,
    required this.detail,
    this.stockIds = const [],
    this.productKey,
  });

  final String key;
  final AttentionKind kind;
  final AttentionSeverity severity;
  final String title;
  final String detail;
  final List<String> stockIds;
  final String? productKey;

  bool get isReorder =>
      kind == AttentionKind.urgentReorder ||
      kind == AttentionKind.reorderReview;
}

class PharmacyAttentionReport {
  PharmacyAttentionReport._(List<AttentionItem> source)
    : items = List.unmodifiable(source) {
    for (final item in items) {
      counts[item.severity] = (counts[item.severity] ?? 0) + 1;
    }
  }

  factory PharmacyAttentionReport.build({
    required Iterable<Medicine> medicines,
    required WarningSettings settings,
    required DateTime today,
    required Iterable<ReorderSuggestion> reorder,
    Iterable<SaleEvent> sales = const <SaleEvent>[],
  }) {
    final day = civilDay(today);
    final active = medicines.where((medicine) => !medicine.archived).toList();
    final items = <AttentionItem>[];

    // Run cross-row integrity analysis before ordinary per-row warnings. These
    // checks detect contradictions that a valid individual Medicine object
    // cannot see by itself (for example one physical batch saved with two EXP
    // dates). The result is read-only and local; no integrity finding mutates
    // stock without an explicit pharmacist review.
    final integrity = InventoryIntegrityReport.build(
      medicines: active,
      today: day,
    );
    for (final issue in integrity.issues) {
      items.add(
        AttentionItem(
          key: issue.key,
          kind: _integrityKind(issue.kind),
          severity: _integritySeverity(issue.severity),
          title: issue.title,
          detail: issue.detail,
          stockIds: issue.stockIds,
        ),
      );
    }

    // Preflight the exact FEFO candidate ordering used by the sale engine. This
    // turns missing expiry/quantity from a surprise at checkout into an early,
    // grouped work item. Single-row gaps still use the normal per-record warning;
    // multi-lot gaps are consolidated so the attention queue stays actionable.
    final readiness = PharmacyAutomationReadinessReport.build(
      medicines: active,
      today: day,
    );
    final groupedUnknownExpiryIds = <String>{};
    final groupedUnknownQuantityIds = <String>{};
    for (final issue in readiness.issues) {
      switch (issue.kind) {
        case AutomationReadinessKind.fefoExpiryUncertainty:
          groupedUnknownExpiryIds.addAll(issue.stockIds);
          items.add(
            AttentionItem(
              key: issue.key,
              kind: AttentionKind.unknownExpiry,
              severity: AttentionSeverity.medium,
              title: issue.title,
              detail: issue.detail,
              stockIds: issue.stockIds,
              productKey: issue.productKey,
            ),
          );
        case AutomationReadinessKind.fefoQuantityBlocker:
          groupedUnknownQuantityIds.addAll(issue.stockIds);
          items.add(
            AttentionItem(
              key: issue.key,
              kind: AttentionKind.unknownQuantity,
              severity: AttentionSeverity.high,
              title: issue.title,
              detail: issue.detail,
              stockIds: issue.stockIds,
              productKey: issue.productKey,
            ),
          );
      }
    }

    for (final medicine in active) {
      if (medicine.sold) continue;
      if (medicine.mfg != null && civilDay(medicine.mfg!).isAfter(day)) {
        final startsIn = civilDay(medicine.mfg!).difference(day).inDays;
        items.add(
          AttentionItem(
            key: 'future-mfg:${medicine.id}',
            kind: AttentionKind.futureManufactureDate,
            severity: AttentionSeverity.high,
            title: '${medicine.title} · manufacturing date is in the future',
            detail:
                '${_stockCue(medicine)} · recorded MFG is $startsIn day${startsIn == 1 ? '' : 's'} ahead. Verify the physical pack/date; Aaris excludes this row from FEFO and current-stock reorder coverage until the date is valid.',
            stockIds: [medicine.id],
          ),
        );
      }
      final status = statusOf(medicine, settings, day).status;
      final cue = _stockCue(medicine);

      if (status == StockStatus.expired) {
        final days = medicine.daysLeft(day)?.abs();
        items.add(
          AttentionItem(
            key: 'expired:${medicine.id}',
            kind: AttentionKind.expiredStock,
            severity: AttentionSeverity.critical,
            title: '${medicine.title} · expired',
            detail: days == null
                ? '$cue · remove/review this stock in the expiry workflow.'
                : '$cue · expired $days day${days == 1 ? '' : 's'} ago; keep it out of current dispensing.',
            stockIds: [medicine.id],
          ),
        );
        continue;
      }

      if (medicine.quantity == 0) {
        items.add(
          AttentionItem(
            key: 'zero:${medicine.id}',
            kind: AttentionKind.zeroQuantityMismatch,
            severity: AttentionSeverity.high,
            title: '${medicine.title} · 0 units but not SOLD',
            detail:
                '$cue · confirm whether this entry is truly out of stock, or correct its quantity. Aaris will not infer SOLD from zero alone.',
            stockIds: [medicine.id],
          ),
        );
      }

      if (status == StockStatus.shortExpiry) {
        final days = medicine.daysLeft(day) ?? 0;
        items.add(
          AttentionItem(
            key: 'short:${medicine.id}',
            kind: AttentionKind.shortExpiry,
            severity: AttentionSeverity.high,
            title: '${medicine.title} · $days day${days == 1 ? '' : 's'} left',
            detail: '$cue · review FEFO placement before later-expiry stock.',
            stockIds: [medicine.id],
          ),
        );
      }

      if (medicine.expiry == null &&
          !groupedUnknownExpiryIds.contains(medicine.id)) {
        items.add(
          AttentionItem(
            key: 'expiry-unknown:${medicine.id}',
            kind: AttentionKind.unknownExpiry,
            severity: AttentionSeverity.medium,
            title: '${medicine.title} · expiry not recorded',
            detail:
                '$cue · optional fact is missing, so expiry warnings and FEFO confidence are limited until the physical pack is checked.',
            stockIds: [medicine.id],
          ),
        );
      }
      if (medicine.quantity == null &&
          !groupedUnknownQuantityIds.contains(medicine.id)) {
        items.add(
          AttentionItem(
            key: 'quantity-unknown:${medicine.id}',
            kind: AttentionKind.unknownQuantity,
            severity: AttentionSeverity.medium,
            title: '${medicine.title} · quantity not recorded',
            detail:
                '$cue · reorder coverage cannot be calculated honestly until quantity is known.',
            stockIds: [medicine.id],
          ),
        );
      }
    }

    final barcodeGroups = <String, List<Medicine>>{};
    for (final medicine in active) {
      final barcode = medicine.barcode.trim();
      if (barcode.isEmpty) continue;
      barcodeGroups.putIfAbsent(barcode, () => []).add(medicine);
    }
    for (final entry in barcodeGroups.entries) {
      final identities = entry.value
          .map((medicine) => medicine.identity)
          .toSet();
      if (identities.length < 2) continue;
      final titles = entry.value
          .map((medicine) => medicine.title)
          .toSet()
          .take(3);
      items.add(
        AttentionItem(
          key: 'barcode:${entry.key}',
          kind: AttentionKind.barcodeConflict,
          severity: AttentionSeverity.high,
          title: 'Barcode ${entry.key} needs identity review',
          detail:
              '${titles.join(' · ')} share one barcode but do not share one medicine identity. Scanner auto-selection must remain blocked until reviewed.',
          stockIds: entry.value
              .map((medicine) => medicine.id)
              .toList(growable: false),
        ),
      );
    }

    final duplicateGroups = <String, List<Medicine>>{};
    for (final medicine in active.where((medicine) => !medicine.sold)) {
      final batch = normalize(medicine.batchNumber);
      final barcode = normalize(medicine.barcode);
      final address = normalize(medicine.address);

      String? key;
      if (batch.isNotEmpty) {
        // Batch alone can legitimately repeat across locations. Require another
        // physical locator before raising a probable-duplicate review item.
        if (barcode.isNotEmpty || address.isNotEmpty) {
          key = '${medicine.identity}|batch:$batch|barcode:$barcode|address:$address';
        }
      } else if (barcode.isNotEmpty && address.isNotEmpty) {
        // A batch number is optional. Two rows at the same saved physical
        // location can still be probable duplicates when product barcode plus a
        // pack date also agree. This remains a review-only signal: retail
        // barcodes and expiry months are not globally unique lot identifiers.
        final expiry = medicine.expiry == null ? '' : dateText(medicine.expiry!);
        final mfg = medicine.mfg == null ? '' : dateText(medicine.mfg!);
        if (expiry.isNotEmpty || mfg.isNotEmpty) {
          key =
              '${medicine.identity}|no-batch|barcode:$barcode|expiry:$expiry|mfg:$mfg|address:$address';
        }
      }
      if (key == null) continue;
      duplicateGroups.putIfAbsent(key, () => []).add(medicine);
    }
    for (final group in duplicateGroups.values.where(
      (group) => group.length > 1,
    )) {
      final first = group.first;
      items.add(
        AttentionItem(
          key:
              'duplicate-batch:${group.map((medicine) => medicine.id).join(':')}',
          kind: AttentionKind.possibleDuplicateBatch,
          severity: AttentionSeverity.medium,
          title: '${first.title} · possible duplicate stock entries',
          detail: first.batchNumber.trim().isNotEmpty
              ? '${group.length} active rows share the same medicine identity, batch and barcode/location. Verify the physical stock before totals or reorder decisions; Aaris will never merge or delete them automatically.'
              : '${group.length} active rows have no batch number but share the same medicine identity, barcode, saved location and pack date. They may be legitimate separate stock, so Aaris only flags them for physical review and will never merge or delete them automatically.',
          stockIds: group
              .map((medicine) => medicine.id)
              .toList(growable: false),
        ),
      );
    }

    final stockRisk = PharmacyStockRiskReport.build(
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

    for (final suggestion in reorder) {
      final urgent = suggestion.priority == ReorderPriority.urgent;
      items.add(
        AttentionItem(
          key: 'reorder:${suggestion.productKey}',
          kind: urgent
              ? AttentionKind.urgentReorder
              : AttentionKind.reorderReview,
          severity: urgent ? AttentionSeverity.high : AttentionSeverity.medium,
          title:
              '${suggestion.title} · ${urgent ? 'urgent reorder' : 'reorder review'}',
          detail:
              '${suggestion.reason} · suggested ${suggestion.suggestedQuantity} · ${suggestion.confidenceLabel}${suggestion.reviewRequired ? ' · pharmacist review required' : ''}.',
          stockIds: suggestion.stockIds,
          productKey: suggestion.productKey,
        ),
      );
    }

    items.sort((a, b) {
      final severity = a.severity.index.compareTo(b.severity.index);
      if (severity != 0) return severity;
      final kind = a.kind.index.compareTo(b.kind.index);
      if (kind != 0) return kind;
      return a.title.compareTo(b.title);
    });
    return PharmacyAttentionReport._(items);
  }

  final List<AttentionItem> items;
  final Map<AttentionSeverity, int> counts = {};

  int count(AttentionSeverity severity) => counts[severity] ?? 0;
  bool get isEmpty => items.isEmpty;
  int get critical => count(AttentionSeverity.critical);
  int get high => count(AttentionSeverity.high);
  int get medium => count(AttentionSeverity.medium);
  int get low => count(AttentionSeverity.low);

  List<AttentionItem> get top => items.take(5).toList(growable: false);
}

AttentionKind _integrityKind(InventoryIntegrityKind kind) => switch (kind) {
  InventoryIntegrityKind.conflictingLotFacts =>
    AttentionKind.conflictingLotFacts,
  InventoryIntegrityKind.soldAuditGap => AttentionKind.soldAuditGap,
  InventoryIntegrityKind.staleSoldMetadata => AttentionKind.staleSoldMetadata,
};

AttentionSeverity _integritySeverity(InventoryIntegritySeverity severity) =>
    switch (severity) {
      InventoryIntegritySeverity.high => AttentionSeverity.high,
      InventoryIntegritySeverity.medium => AttentionSeverity.medium,
      InventoryIntegritySeverity.low => AttentionSeverity.low,
    };

String _stockCue(Medicine medicine) {
  final parts = <String>[
    if (medicine.batchNumber.trim().isNotEmpty)
      'Batch ${medicine.batchNumber.trim()}',
    if (medicine.address.trim().isNotEmpty) medicine.address.trim(),
    if (medicine.quantity != null) '${medicine.quantity} units',
  ];
  return parts.isEmpty ? 'Exact stock entry' : parts.join(' · ');
}
