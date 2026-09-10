import 'medicine.dart';
import 'tracking.dart';

enum SaleHistoryIntegrityKind { futureSaleEvent, lifecycleConflict }

class SaleHistoryIntegrityIssue {
  const SaleHistoryIntegrityIssue({
    required this.key,
    required this.kind,
    required this.title,
    required this.detail,
    required this.stockIds,
    required this.productKey,
  });

  final String key;
  final SaleHistoryIntegrityKind kind;
  final String title;
  final String detail;
  final List<String> stockIds;
  final String productKey;
}

/// Read-only audit of persisted sale history against authoritative stock facts.
///
/// The normal sale persistence firewall prevents new invalid ledger writes, but
/// reviewed backup recovery and legacy databases can legitimately reproduce old
/// states that predate newer guards. This auditor closes that gap without ever
/// rewriting history: it surfaces suspicious persisted events so a pharmacist
/// can verify the exact stock row and recovery source.
///
/// Historical medicine identity snapshots are deliberately NOT compared with the
/// current Medicine identity. A later pharmacist correction may validly rename or
/// reclassify a stock row, while the immutable SaleEvent must keep the identity
/// that was recorded at sale time for honest historical analytics.
class SaleHistoryIntegrityReport {
  SaleHistoryIntegrityReport._(List<SaleHistoryIntegrityIssue> source)
    : issues = List.unmodifiable(source);

  factory SaleHistoryIntegrityReport.build({
    required Iterable<Medicine> medicines,
    required Iterable<SaleEvent> sales,
    required DateTime today,
  }) {
    final day = civilDay(today);
    final activeById = <String, Medicine>{
      for (final medicine in medicines)
        if (!medicine.archived) medicine.id: medicine,
    };
    final future = <String, _SaleIssueGroup>{};
    final lifecycle = <String, _SaleIssueGroup>{};

    for (final sale in sales) {
      final stock = activeById[sale.stockId];
      if (stock == null) {
        // Removed-stock history is intentionally preserved and may be valid.
        // Backup parsing already rejects truly orphaned sale references, so this
        // operational auditor only emits tasks that can route to a current row.
        continue;
      }
      final saleDay = civilDay(sale.occurredAt);
      final key = '${stock.id}|${sale.productKey}';

      if (saleDay.isAfter(day)) {
        future.putIfAbsent(
          key,
          () => _SaleIssueGroup(stock: stock, productKey: sale.productKey),
        )..add(sale);
        continue;
      }

      final beforeMfg =
          stock.mfg != null && saleDay.isBefore(civilDay(stock.mfg!));
      final afterExpiry =
          stock.expiry != null && saleDay.isAfter(civilDay(stock.expiry!));
      if (!beforeMfg && !afterExpiry) continue;

      lifecycle.putIfAbsent(
        key,
        () => _SaleIssueGroup(stock: stock, productKey: sale.productKey),
      )
        ..add(sale)
        ..beforeMfg = lifecycle[key]?.beforeMfg == true || beforeMfg
        ..afterExpiry = lifecycle[key]?.afterExpiry == true || afterExpiry;
    }

    final issues = <SaleHistoryIntegrityIssue>[];
    for (final group in future.values) {
      final count = group.sales.length;
      final first = group.earliest;
      issues.add(
        SaleHistoryIntegrityIssue(
          key: 'sale-future:${group.stock.id}:${group.productKey}',
          kind: SaleHistoryIntegrityKind.futureSaleEvent,
          title: '${group.stock.title} · future-dated sale history',
          detail:
              '$count recorded sale event${count == 1 ? '' : 's'} for this exact stock row ${count == 1 ? 'is' : 'are'} dated after the current business day; earliest is ${dateText(first.occurredAt)}. Aaris will not use a future event as current demand evidence or rewrite immutable sale history automatically. Verify the device/business date and the historical source before relying on this record.',
          stockIds: List.unmodifiable(<String>[group.stock.id]),
          productKey: group.productKey,
        ),
      );
    }

    for (final group in lifecycle.values) {
      final count = group.sales.length;
      final boundaries = <String>[
        if (group.beforeMfg && group.stock.mfg != null)
          'before recorded MFG ${dateText(group.stock.mfg!)}',
        if (group.afterExpiry && group.stock.expiry != null)
          'after recorded EXP ${dateText(group.stock.expiry!)}',
      ];
      issues.add(
        SaleHistoryIntegrityIssue(
          key: 'sale-lifecycle:${group.stock.id}:${group.productKey}',
          kind: SaleHistoryIntegrityKind.lifecycleConflict,
          title: '${group.stock.title} · sale history conflicts with pack dates',
          detail:
              '$count recorded sale event${count == 1 ? '' : 's'} for this exact stock row fall ${boundaries.join(' and ')}. This can happen after legacy restore or a later correction of physical pack dates. Verify the current MFG/EXP and the historical source; Aaris keeps the ledger append-only and will never invent or silently rewrite a sale to make the conflict disappear.',
          stockIds: List.unmodifiable(<String>[group.stock.id]),
          productKey: group.productKey,
        ),
      );
    }

    issues.sort((a, b) {
      final kind = a.kind.index.compareTo(b.kind.index);
      if (kind != 0) return kind;
      final title = a.title.compareTo(b.title);
      return title != 0 ? title : a.key.compareTo(b.key);
    });
    return SaleHistoryIntegrityReport._(issues);
  }

  final List<SaleHistoryIntegrityIssue> issues;
  bool get isEmpty => issues.isEmpty;
}

class _SaleIssueGroup {
  _SaleIssueGroup({required this.stock, required this.productKey});

  final Medicine stock;
  final String productKey;
  final List<SaleEvent> sales = <SaleEvent>[];
  bool beforeMfg = false;
  bool afterExpiry = false;

  void add(SaleEvent sale) => sales.add(sale);

  SaleEvent get earliest {
    var value = sales.first;
    for (final sale in sales.skip(1)) {
      if (sale.occurredAt.isBefore(value.occurredAt)) value = sale;
    }
    return value;
  }
}
