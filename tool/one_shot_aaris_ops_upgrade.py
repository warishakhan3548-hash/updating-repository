from pathlib import Path


def replace_once(path: str, old: str, new: str) -> None:
    p = Path(path)
    text = p.read_text()
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{path}: expected exactly one anchor, found {count}")
    p.write_text(text.replace(old, new, 1))


# Deterministic FEFO planning domain. It produces a reviewable plan only.
Path("lib/domain/dispensing_plan.dart").write_text(
    r'''import 'dart:math';

import 'inventory.dart';
import 'medicine.dart';

class FefoAllocation {
  const FefoAllocation({
    required this.stockId,
    required this.quantity,
    required this.availableQuantity,
    required this.batchNumber,
    required this.address,
    required this.expiry,
    required this.expiryMonthOnly,
  });

  final String stockId;
  final int quantity;
  final int availableQuantity;
  final String batchNumber;
  final String address;
  final DateTime? expiry;
  final bool expiryMonthOnly;

  bool get emptiesStock => quantity == availableQuantity;
}

class FefoDispensingPlan {
  const FefoDispensingPlan({
    required this.productKey,
    required this.title,
    required this.requestedQuantity,
    required this.plannedQuantity,
    required this.knownVisibleUnits,
    required this.allocations,
    required this.unknownQuantityStockIds,
  });

  final String productKey;
  final String title;
  final int requestedQuantity;
  final int plannedQuantity;
  final int knownVisibleUnits;
  final List<FefoAllocation> allocations;
  final List<String> unknownQuantityStockIds;

  int get remainingQuantity => requestedQuantity - plannedQuantity;
  bool get blockedByUnknownQuantity => unknownQuantityStockIds.isNotEmpty;
  bool get complete => remainingQuantity == 0 && !blockedByUnknownQuantity;
  bool get requiresExpiryVerification =>
      allocations.any((allocation) => allocation.expiry == null);
}

class ReviewedFefoSale {
  const ReviewedFefoSale({
    required this.baseRevision,
    required this.occurredAt,
    required this.plan,
  });

  final int baseRevision;
  final DateTime occurredAt;
  final FefoDispensingPlan plan;
}

FefoDispensingPlan planFefoDispensing({
  required Iterable<Medicine> records,
  required Medicine requested,
  required int quantity,
  required DateTime date,
}) {
  if (quantity < 1 || quantity > 100000000) {
    throw const FormatException(
      'Dispensing quantity must be a positive whole number.',
    );
  }

  final candidates = dispensingCandidates(records, requested, date);
  final knownVisibleUnits = candidates
      .where((medicine) => medicine.quantity != null)
      .fold<int>(0, (sum, medicine) => sum + medicine.quantity!);
  final allocations = <FefoAllocation>[];
  final blockers = <String>[];
  var remaining = quantity;

  for (final medicine in candidates) {
    if (remaining == 0) break;
    final available = medicine.quantity;
    if (available == null) {
      // An unknown-quantity batch cannot be silently skipped because it may be
      // the true FEFO batch. Stop and require physical verification.
      blockers.add(medicine.id);
      break;
    }
    if (available <= 0) continue;
    final take = min(available, remaining);
    allocations.add(
      FefoAllocation(
        stockId: medicine.id,
        quantity: take,
        availableQuantity: available,
        batchNumber: medicine.batchNumber,
        address: medicine.address,
        expiry: medicine.expiry,
        expiryMonthOnly: medicine.expiryMonthOnly,
      ),
    );
    remaining -= take;
  }

  return FefoDispensingPlan(
    productKey: requested.identity,
    title: requested.title,
    requestedQuantity: quantity,
    plannedQuantity: quantity - remaining,
    knownVisibleUnits: knownVisibleUnits,
    allocations: List.unmodifiable(allocations),
    unknownQuantityStockIds: List.unmodifiable(blockers),
  );
}
'''
)

# Inventory safety: future manufacturing dates are not dispensable.
replace_once(
    "lib/domain/inventory.dart",
    """bool isDispensableOn(Medicine record, DateTime date) =>
    !record.archived && !record.sold && !isExpiredOn(record, date);""",
    """bool isDispensableOn(Medicine record, DateTime date) {
  final day = civilDay(date);
  return !record.archived &&
      !record.sold &&
      !isExpiredOn(record, day) &&
      (record.mfg == null || !day.isBefore(civilDay(record.mfg!)));
}""",
)
replace_once(
    "lib/domain/inventory.dart",
    """/// Stock that may participate in a dispensing decision on [date].
///
/// Quantity is deliberately not part of this predicate: an unknown quantity is
/// still a real stock entry. Callers that need an available batch must separately
/// exclude a known zero quantity.""",
    """/// Stock that may participate in a dispensing decision on [date].
///
/// Quantity is deliberately not part of this predicate: an unknown quantity is
/// still a real stock entry. A recorded manufacturing date in the future is not
/// dispensable and must be verified rather than treated as usable stock. Callers
/// that need an available batch must separately exclude a known zero quantity.""",
)

# Reorder intelligence uses the same authoritative dispensability predicate.
replace_once(
    "lib/domain/tracking.dart",
    "import 'medicine.dart';",
    "import 'inventory.dart';\nimport 'medicine.dart';",
)
replace_once(
    "lib/domain/tracking.dart",
    "    bool usable(Medicine m) => !m.sold && (m.daysLeft(stockDate) ?? 0) >= 0;",
    "    bool usable(Medicine m) => isDispensableOn(m, stockDate);",
)
replace_once(
    "lib/domain/tracking.dart",
    """      final records = current[key] ?? const <Medicine>[];
      final representative =""",
    """      final records = current[key] ?? const <Medicine>[];
      final hasFutureManufacture = records.any(
        (medicine) =>
            !medicine.sold &&
            medicine.mfg != null &&
            civilDay(medicine.mfg!).isAfter(stockDate),
      );
      final representative =""",
)
replace_once(
    "lib/domain/tracking.dart",
    """      final confidence = hasUnknownQuantity
          ? .35
          : hasUnknownExpiry""",
    """      final confidence = hasFutureManufacture
          ? .35
          : hasUnknownQuantity
          ? .35
          : hasUnknownExpiry""",
)
replace_once(
    "lib/domain/tracking.dart",
    "      final reviewRequired = confidence < .75 || movement.recordedSales == 0;",
    """      final reviewRequired =
          hasFutureManufacture || confidence < .75 || movement.recordedSales == 0;""",
)
replace_once(
    "lib/domain/tracking.dart",
    """          reason: expiredOnly
              ? 'Only expired stock remains'""",
    """          reason: hasFutureManufacture && active.isEmpty
              ? 'Manufacturing date needs review before reorder'
              : expiredOnly
              ? 'Only expired stock remains'""",
)

# Proactive attention: future MFG and likely duplicate physical batch rows.
replace_once(
    "lib/domain/attention.dart",
    """  unknownExpiry,
  unknownQuantity,
}""",
    """  unknownExpiry,
  unknownQuantity,
  futureManufactureDate,
  possibleDuplicateBatch,
}""",
)
replace_once(
    "lib/domain/attention.dart",
    """    for (final medicine in active) {
      if (medicine.sold) continue;
      final status = statusOf(medicine, settings, day).status;""",
    """    for (final medicine in active) {
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
      final status = statusOf(medicine, settings, day).status;""",
)
replace_once(
    "lib/domain/attention.dart",
    "    for (final suggestion in reorder) {",
    """    final duplicateGroups = <String, List<Medicine>>{};
    for (final medicine in active.where((medicine) => !medicine.sold)) {
      final batch = normalize(medicine.batchNumber);
      if (batch.isEmpty) continue;
      final barcode = normalize(medicine.barcode);
      final address = normalize(medicine.address);
      // Batch alone can legitimately repeat across locations. Require another
      // physical locator before raising a probable-duplicate review item.
      if (barcode.isEmpty && address.isEmpty) continue;
      final key = '${medicine.identity}|$batch|$barcode|$address';
      duplicateGroups.putIfAbsent(key, () => []).add(medicine);
    }
    for (final group in duplicateGroups.values.where((group) => group.length > 1)) {
      final first = group.first;
      items.add(
        AttentionItem(
          key: 'duplicate-batch:${group.map((medicine) => medicine.id).join(':')}',
          kind: AttentionKind.possibleDuplicateBatch,
          severity: AttentionSeverity.medium,
          title: '${first.title} · possible duplicate batch entries',
          detail:
              '${group.length} active rows share the same medicine identity, batch and barcode/location. Verify the physical stock before totals or reorder decisions; Aaris will never merge or delete them automatically.',
          stockIds: group.map((medicine) => medicine.id).toList(growable: false),
        ),
      );
    }

    for (final suggestion in reorder) {""",
)
replace_once(
    "lib/ui/attention_screen.dart",
    """    AttentionKind.unknownExpiry => Icons.event_note_rounded,
    AttentionKind.unknownQuantity => Icons.numbers_rounded,
  };""",
    """    AttentionKind.unknownExpiry => Icons.event_note_rounded,
    AttentionKind.unknownQuantity => Icons.numbers_rounded,
    AttentionKind.futureManufactureDate => Icons.event_repeat_rounded,
    AttentionKind.possibleDuplicateBatch => Icons.content_copy_rounded,
  };""",
)

# Aaris Brain parses only explicit physical unit quantities.
replace_once(
    "lib/domain/app_brain.dart",
    """    this.query = '',
    this.confidence = 0,""",
    """    this.query = '',
    this.quantity,
    this.confidence = 0,""",
)
replace_once(
    "lib/domain/app_brain.dart",
    """  final String query;
  final double confidence;""",
    """  final String query;
  final int? quantity;
  final double confidence;""",
)
replace_once(
    "lib/domain/app_brain.dart",
    """  if (_containsAny(text, _saleTerms)) {
    return AppBrainIntent(
      action: AppBrainAction.recordSale,
      query: _extractMedicineQuery(raw, _saleTerms),
      confidence: .96,
    );
  }""",
    """  if (_containsAny(text, _saleTerms)) {
    final saleInput = _extractExplicitSaleQuantity(raw);
    return AppBrainIntent(
      action: AppBrainAction.recordSale,
      query: _extractMedicineQuery(saleInput.remainingText, _saleTerms),
      quantity: saleInput.quantity,
      confidence: .96,
    );
  }""",
)
replace_once(
    "lib/domain/app_brain.dart",
    """  if (_containsAny(text, const [
    'what needs attention',
    'needs attention',
    'attention brief',
    'attention summary',
    'risk summary',
    'problem stock',
    'aaj kya dekhna hai',
    'aaj kya karna hai',
    'kya dikkat hai',
    'क्या देखना है',
    'आज क्या करना है',
    'क्या दिक्कत है',
  ])) {""",
    "  if (_containsAny(text, _attentionTerms)) {",
)
replace_once(
    "lib/domain/app_brain.dart",
    """bool _containsAny(String text, List<String> phrases) =>
    phrases.any((phrase) => text.contains(_normalized(phrase)));""",
    """bool _containsAny(String text, List<String> phrases) => phrases.any((phrase) {
  final needle = _normalized(phrase);
  if (needle.isEmpty) return false;
  return text == needle ||
      text.startsWith('$needle ') ||
      text.endsWith(' $needle') ||
      text.contains(' $needle ');
});""",
)
replace_once(
    "lib/domain/app_brain.dart",
    "String _extractMedicineQuery(String raw, List<String> terms) {",
    r'''class _ExplicitSaleQuantity {
  const _ExplicitSaleQuantity(this.remainingText, this.quantity);

  final String remainingText;
  final int? quantity;
}

_ExplicitSaleQuantity _extractExplicitSaleQuantity(String raw) {
  final expression = RegExp(
    r'(?:(?:qty|quantity)\s*[:=]?\s*([0-9०-९]{1,9})|([0-9०-९]{1,9})\s*(?:units?|pcs?|pieces?|यूनिट(?:्स)?))',
    caseSensitive: false,
    unicode: true,
  );
  final matches = expression.allMatches(raw).toList();
  // Multiple quantity statements are ambiguous. Preserve the original command
  // and fall back to the reviewed editor instead of guessing which number wins.
  if (matches.length != 1) return _ExplicitSaleQuantity(raw, null);
  final match = matches.single;
  final digits = _asciiDigits(match.group(1) ?? match.group(2) ?? '');
  final quantity = int.tryParse(digits);
  if (quantity == null || quantity < 1 || quantity > 100000000) {
    return _ExplicitSaleQuantity(raw, null);
  }
  final remaining = raw.replaceRange(match.start, match.end, ' ');
  return _ExplicitSaleQuantity(remaining, quantity);
}

String _asciiDigits(String value) {
  const devanagari = '०१२३४५६७८९';
  final output = StringBuffer();
  for (final rune in value.runes) {
    final char = String.fromCharCode(rune);
    final index = devanagari.indexOf(char);
    output.write(index < 0 ? char : index.toString());
  }
  return output.toString();
}

String _extractMedicineQuery(String raw, List<String> terms) {''',
)
replace_once(
    "lib/domain/app_brain.dart",
    "const _scanTerms = <String>[",
    """const _attentionTerms = <String>[
  'what needs attention',
  'needs attention',
  'attention brief',
  'attention summary',
  'risk summary',
  'problem stock',
  'data quality',
  'data quality check',
  'inventory problems',
  'stock problems',
  'duplicate stock',
  'duplicate entries',
  'barcode conflict',
  'scan conflict',
  'missing expiry',
  'missing quantity',
  'future mfg',
  'future manufacturing date',
  'aaj kya dekhna hai',
  'aaj kya karna hai',
  'kya dikkat hai',
  'क्या देखना है',
  'आज क्या करना है',
  'क्या दिक्कत है',
  'डाटा क्वालिटी',
];

const _scanTerms = <String>[""",
)

# Controller applies the reviewed plan as one optimistic-concurrency transaction.
replace_once(
    "lib/state/pharmacy_controller.dart",
    """import '../domain/backup.dart';
import '../domain/inventory.dart';""",
    """import '../domain/backup.dart';
import '../domain/dispensing_plan.dart';
import '../domain/inventory.dart';""",
)
replace_once(
    "lib/state/pharmacy_controller.dart",
    """  Medicine? preferredDispensingStock(String id, {DateTime? on}) {
    final choices = dispensingChoices(id, on: on);
    return choices.isEmpty ? null : choices.first;
  }

  Future<void> _commit(InventoryMutation mutation) {""",
    r'''  Medicine? preferredDispensingStock(String id, {DateTime? on}) {
    final choices = dispensingChoices(id, on: on);
    return choices.isEmpty ? null : choices.first;
  }

  ReviewedFefoSale reviewFefoSale(
    String id, {
    required int quantity,
    DateTime? occurredAt,
  }) {
    final anchor = snapshot.records[id];
    if (anchor == null || anchor.archived || anchor.sold) {
      throw StateError('Choose an active stock entry before recording a FEFO sale.');
    }
    final time = occurredAt ?? clock();
    if (civilDay(time).isAfter(today)) {
      throw const FormatException('A sale cannot be recorded in the future.');
    }
    final plan = planFefoDispensing(
      records: records,
      requested: anchor,
      quantity: quantity,
      date: time,
    );
    return ReviewedFefoSale(
      baseRevision: snapshot.revision,
      occurredAt: time,
      plan: plan,
    );
  }

  Future<void> applyFefoSale(ReviewedFefoSale review) async {
    if (review.baseRevision != snapshot.revision) {
      throw StateError(
        'Inventory changed after the FEFO review. Review the sale again before saving.',
      );
    }
    final plan = review.plan;
    if (!plan.complete || plan.allocations.isEmpty) {
      throw StateError(
        'This FEFO sale is incomplete and cannot be saved automatically.',
      );
    }

    final updates = <Medicine>[];
    final saleEvents = <SaleEvent>[];
    for (final allocation in plan.allocations) {
      final live = snapshot.records[allocation.stockId];
      if (live == null || live.archived || live.sold) {
        throw StateError(
          'A reviewed FEFO batch is no longer available. Review the sale again.',
        );
      }
      if (live.identity != plan.productKey) {
        throw StateError(
          'A reviewed FEFO batch no longer matches the medicine identity.',
        );
      }
      validateDispensingDate(live, review.occurredAt);
      final available = live.quantity;
      if (available == null || available != allocation.availableQuantity) {
        throw StateError(
          'A reviewed FEFO batch quantity changed or became unknown. Review again.',
        );
      }
      if (allocation.quantity < 1 || allocation.quantity > available) {
        throw StateError('The reviewed FEFO allocation is no longer valid.');
      }

      final remaining = available - allocation.quantity;
      final soldOut = remaining == 0;
      updates.add(
        live.patch({
          'quantity': remaining,
          if (soldOut) ...{
            'sold': true,
            'soldAt': review.occurredAt.toIso8601String(),
            'soldQuantity': available,
            'soldUnitPricePaise': live.unitPricePaise,
          },
        }),
      );
      saleEvents.add(
        SaleEvent(
          id: newId(),
          stockId: live.id,
          medicineName: live.name,
          strength: live.strength,
          form: live.form,
          salt: live.salt,
          quantity: allocation.quantity,
          occurredAt: review.occurredAt,
          savedUnitPricePaise: live.unitPricePaise,
        ),
      );
    }

    await _commit(
      InventoryMutation(
        expectedRevision: review.baseRevision,
        label:
            'FEFO sale · ${plan.title} · ${plan.requestedQuantity} units · ${plan.allocations.length} ${plan.allocations.length == 1 ? 'batch' : 'batches'}',
        upserts: updates,
        upsertSales: saleEvents,
      ),
    );
  }

  Future<void> _commit(InventoryMutation mutation) {''',
)

# Brain UI resolves one product identity, reviews FEFO allocations, then confirms.
replace_once(
    "lib/ui/brain_screen.dart",
    """import '../domain/attention.dart';
import '../domain/inventory.dart';""",
    """import '../domain/attention.dart';
import '../domain/dispensing_plan.dart';
import '../domain/inventory.dart';""",
)
replace_once(
    "lib/ui/brain_screen.dart",
    "      await _openActionTarget(intent.action, remembered, fromContext: true);",
    """      await _openActionTarget(
        intent.action,
        remembered,
        fromContext: true,
        requestedQuantity: intent.quantity,
      );""",
)
replace_once(
    "lib/ui/brain_screen.dart",
    "    final direct = _singleSafeTarget(viable);",
    r'''    if (intent.action == AppBrainAction.recordSale &&
        intent.quantity != null) {
      final productTarget = _singleSafeProductTarget(viable);
      if (productTarget != null) {
        await _openActionTarget(
          intent.action,
          productTarget,
          requestedQuantity: intent.quantity,
        );
        return;
      }
    }

    final direct = _singleSafeTarget(viable);''',
)
replace_once(
    "lib/ui/brain_screen.dart",
    "        await _openActionTarget(intent.action, record);",
    """        await _openActionTarget(
          intent.action,
          record,
          requestedQuantity: intent.quantity,
        );""",
)
replace_once(
    "lib/ui/brain_screen.dart",
    """      action: intent.action,
    );""",
    """      action: intent.action,
      requestedQuantity: intent.quantity,
    );""",
)
replace_once(
    "lib/ui/brain_screen.dart",
    """    Medicine record, {
    bool fromContext = false,
  }) async {""",
    """    Medicine record, {
    bool fromContext = false,
    int? requestedQuantity,
  }) async {""",
)
replace_once(
    "lib/ui/brain_screen.dart",
    "    setState(() => _reply = '$prefix${_editorInstruction(action, record)}');",
    """    final instruction =
        action == AppBrainAction.recordSale && requestedQuantity != null
        ? '${record.title} matched. Preparing a deterministic $requestedQuantity-unit FEFO allocation across active batches.'
        : _editorInstruction(action, record);
    setState(() => _reply = '$prefix$instruction');""",
)
replace_once(
    "lib/ui/brain_screen.dart",
    """    if (action == AppBrainAction.markSold) {
      await _markSoldTarget(record);
      return;
    }

    // Editing and sales keep the richer editor because it owns field validation,
    // FEFO guidance, historical-sale validation and amount/quantity review.
    await openEditor(context, widget.controller, record: record);""",
    """    if (action == AppBrainAction.markSold) {
      await _markSoldTarget(record);
      return;
    }
    if (action == AppBrainAction.recordSale && requestedQuantity != null) {
      await _recordFefoSale(record, requestedQuantity);
      return;
    }

    // Editing and sales without an explicit unit quantity keep the richer editor
    // because it owns amount entry, historical-sale validation and field review.
    await openEditor(context, widget.controller, record: record);""",
)
replace_once(
    "lib/ui/brain_screen.dart",
    """  SearchHit? _singleSafeTarget(List<SearchHit> hits) {
    if (hits.isEmpty) return null;
    final first = hits.first;
    if (first.uncertain || first.score < .95) return null;
    if (hits.length == 1) return first;
    final second = hits[1];
    if (second.score >= .90 && (first.score - second.score).abs() < .08) {
      return null;
    }
    return first;
  }""",
    r'''  SearchHit? _singleSafeTarget(List<SearchHit> hits) {
    if (hits.isEmpty) return null;
    final first = hits.first;
    if (first.uncertain || first.score < .95) return null;
    if (hits.length == 1) return first;
    final second = hits[1];
    if (second.score >= .90 && (first.score - second.score).abs() < .08) {
      return null;
    }
    return first;
  }

  Medicine? _singleSafeProductTarget(List<SearchHit> hits) {
    if (hits.isEmpty || hits.first.uncertain || hits.first.score < .95) {
      return null;
    }
    final records = hits
        .map((hit) => widget.controller.snapshot.records[hit.id])
        .whereType<Medicine>()
        .where((medicine) => !medicine.archived && !medicine.sold)
        .toList(growable: false);
    if (records.isEmpty) return null;
    if (records.map((medicine) => medicine.identity).toSet().length != 1) {
      return null;
    }
    return records.first;
  }''',
)
replace_once(
    "lib/ui/brain_screen.dart",
    """    AppBrainAction action = AppBrainAction.search,
  }) async {""",
    """    AppBrainAction action = AppBrainAction.search,
    int? requestedQuantity,
  }) async {""",
)
replace_once(
    "lib/ui/brain_screen.dart",
    "                        await _openActionTarget(action, record);",
    """                        await _openActionTarget(
                          action,
                          record,
                          requestedQuantity: requestedQuantity,
                        );""",
)
replace_once(
    "lib/ui/brain_screen.dart",
    "  String _stockIdentityCue(Medicine record) {",
    r'''  Future<void> _recordFefoSale(Medicine anchor, int quantity) async {
    final review = widget.controller.reviewFefoSale(
      anchor.id,
      quantity: quantity,
    );
    final plan = review.plan;
    if (!plan.complete) {
      if (!mounted) return;
      setState(() {
        _reply = plan.blockedByUnknownQuantity
            ? 'FEFO automation stopped safely: an earlier-priority batch has unknown quantity. Verify that physical batch first; no stock or sale was changed.'
            : 'FEFO automation found only ${plan.plannedQuantity} safely allocatable known units for the requested ${plan.requestedQuantity}. No sale was recorded.';
      });
      return;
    }

    String allocationLine(FefoAllocation allocation) {
      final expiry = allocation.expiry == null
          ? 'EXP unknown'
          : allocation.expiryMonthOnly
          ? 'EXP ${dateText(allocation.expiry!).substring(0, 7)}'
          : 'EXP ${dateText(allocation.expiry!)}';
      final batch = allocation.batchNumber.trim().isEmpty
          ? 'Batch not set'
          : 'Batch ${allocation.batchNumber.trim()}';
      final location = allocation.address.trim().isEmpty
          ? 'Location not set'
          : allocation.address.trim();
      return '${allocation.quantity} units · $batch · $expiry · $location${allocation.emptiesStock ? ' · stock finishes' : ''}';
    }

    final lines = plan.allocations.map(allocationLine).join('\n');
    final expiryWarning = plan.requiresExpiryVerification
        ? '\n\nAt least one allocated batch has no recorded expiry. Verify its physical pack before confirming.'
        : '';
    final confirmed = await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (ctx) => AlertDialog(
            title: Text('Record FEFO sale · ${plan.requestedQuantity} units?'),
            content: SingleChildScrollView(
              child: Text(
                'Aaris will use the earliest valid expiry first and split this sale across ${plan.allocations.length} ${plan.allocations.length == 1 ? 'batch' : 'batches'}:\n\n$lines$expiryWarning\n\nExpired, SOLD, removed and future-manufacturing-date stock is excluded. The reviewed movements save as one atomic, undoable inventory transaction. No customer or patient data is collected.',
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Record FEFO sale'),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed || !mounted) {
      setState(() => _reply = 'FEFO sale cancelled. Nothing changed.');
      return;
    }

    await widget.controller.applyFefoSale(review);
    if (!mounted) return;
    setState(
      () => _reply =
          '${plan.requestedQuantity} units recorded across ${plan.allocations.length} FEFO ${plan.allocations.length == 1 ? 'batch' : 'batches'}. Stock, sales tracking and reorder intelligence updated atomically; Undo is available.',
    );
  }

  String _stockIdentityCue(Medicine record) {''',
)

# Parser regression coverage.
replace_once(
    "test/app_brain_test.dart",
    "    test('scanner language routes to the authoritative stock surface', () {",
    r'''    test('explicit sale units are parsed without confusing medicine strength', () {
      final intent = parseAppBrainIntent('Dolo 650 12 units record sale');
      expect(intent.action, AppBrainAction.recordSale);
      expect(intent.query, 'Dolo 650');
      expect(intent.quantity, 12);

      final qtyIntent = parseAppBrainIntent('Dolo 650 record sale qty 7');
      expect(qtyIntent.query, 'Dolo 650');
      expect(qtyIntent.quantity, 7);

      final hindiDigits = parseAppBrainIntent('Dolo 650 ५ units record sale');
      expect(hindiDigits.query, 'Dolo 650');
      expect(hindiDigits.quantity, 5);

      final strengthOnly = parseAppBrainIntent('Dolo 650 record sale');
      expect(strengthOnly.query, 'Dolo 650');
      expect(strengthOnly.quantity, isNull);
    });

    test('ambiguous multiple sale quantities never auto-plan a mutation', () {
      final intent = parseAppBrainIntent('Dolo 650 qty 5 6 units record sale');
      expect(intent.action, AppBrainAction.recordSale);
      expect(intent.quantity, isNull);
    });

    test('phrase boundaries prevent medicine text from becoming a write command', () {
      final intent = parseAppBrainIntent('Wholesaler 10');
      expect(intent.action, AppBrainAction.search);
      expect(intent.query, 'Wholesaler 10');
      expect(intent.destructive, isFalse);
    });

    test('data quality language opens the deterministic attention engine', () {
      for (final command in [
        'data quality check',
        'barcode conflict',
        'missing expiry',
        'future mfg',
      ]) {
        final intent = parseAppBrainIntent(command);
        expect(intent.action, AppBrainAction.attentionBrief, reason: command);
        expect(intent.destructive, isFalse, reason: command);
      }
    });

    test('scanner language routes to the authoritative stock surface', () {''',
)

# End-to-end FEFO domain/controller tests.
Path("test/fefo_automation_test.dart").write_text(
    r'''import 'package:aaris_pharmacy/data/inventory_database.dart';
import 'package:aaris_pharmacy/domain/dispensing_plan.dart';
import 'package:aaris_pharmacy/domain/inventory.dart';
import 'package:aaris_pharmacy/domain/medicine.dart';
import 'package:aaris_pharmacy/state/pharmacy_controller.dart';
import 'package:flutter_test/flutter_test.dart';

Medicine stock({
  required String id,
  required DateTime? expiry,
  required int? quantity,
  DateTime? mfg,
  String batch = '',
  bool sold = false,
  bool archived = false,
}) => Medicine(
  id: id,
  name: 'Dolo',
  strength: '650 mg',
  form: 'Tablet',
  mfg: mfg,
  expiry: expiry,
  quantity: sold ? 0 : quantity,
  batchNumber: batch,
  sold: sold,
  archived: archived,
);

void main() {
  final today = DateTime(2026, 9, 9, 12);

  test('FEFO plan spans physical batches in expiry order', () {
    final early = stock(
      id: 'early',
      expiry: DateTime.utc(2026, 10, 1),
      quantity: 3,
      batch: 'A',
    );
    final later = stock(
      id: 'later',
      expiry: DateTime.utc(2026, 12, 1),
      quantity: 5,
      batch: 'B',
    );
    final plan = planFefoDispensing(
      records: [later, early],
      requested: later,
      quantity: 6,
      date: today,
    );

    expect(plan.complete, isTrue);
    expect(plan.allocations.map((item) => item.stockId), ['early', 'later']);
    expect(plan.allocations.map((item) => item.quantity), [3, 3]);
    expect(plan.allocations.first.emptiesStock, isTrue);
    expect(plan.allocations.last.emptiesStock, isFalse);
  });

  test('unknown earlier FEFO quantity blocks automatic allocation', () {
    final unknown = stock(
      id: 'unknown',
      expiry: DateTime.utc(2026, 10, 1),
      quantity: null,
      batch: 'A',
    );
    final known = stock(
      id: 'known',
      expiry: DateTime.utc(2026, 11, 1),
      quantity: 10,
      batch: 'B',
    );
    final plan = planFefoDispensing(
      records: [known, unknown],
      requested: known,
      quantity: 5,
      date: today,
    );

    expect(plan.complete, isFalse);
    expect(plan.blockedByUnknownQuantity, isTrue);
    expect(plan.plannedQuantity, 0);
    expect(plan.unknownQuantityStockIds, ['unknown']);
  });

  test('future manufacturing stock is excluded from FEFO choices', () {
    final future = stock(
      id: 'future',
      mfg: DateTime.utc(2026, 10, 1),
      expiry: DateTime.utc(2026, 11, 1),
      quantity: 4,
      batch: 'F',
    );
    final valid = stock(
      id: 'valid',
      expiry: DateTime.utc(2026, 12, 1),
      quantity: 5,
      batch: 'V',
    );

    expect(isDispensableOn(future, today), isFalse);
    final plan = planFefoDispensing(
      records: [future, valid],
      requested: valid,
      quantity: 4,
      date: today,
    );
    expect(plan.complete, isTrue);
    expect(plan.allocations.map((item) => item.stockId), ['valid']);
  });

  test('unknown expiry is visible and requires physical verification', () {
    final dated = stock(
      id: 'dated',
      expiry: DateTime.utc(2026, 10, 1),
      quantity: 2,
    );
    final unknownExpiry = stock(id: 'unknown-exp', expiry: null, quantity: 5);
    final plan = planFefoDispensing(
      records: [unknownExpiry, dated],
      requested: dated,
      quantity: 4,
      date: today,
    );
    expect(plan.complete, isTrue);
    expect(plan.requiresExpiryVerification, isTrue);
    expect(plan.allocations.map((item) => item.stockId), ['dated', 'unknown-exp']);
  });

  test('controller applies reviewed multi-batch sale atomically and undo restores all', () async {
    final early = stock(
      id: 'early',
      expiry: DateTime.utc(2026, 10, 1),
      quantity: 3,
      batch: 'A',
    );
    final later = stock(
      id: 'later',
      expiry: DateTime.utc(2026, 12, 1),
      quantity: 5,
      batch: 'B',
    );
    final storage = MemoryInventoryStorage(
      InventorySnapshot(records: {'early': early, 'later': later}),
    );
    final controller = PharmacyController(
      storage,
      clock: () => today,
      backgroundSearch: false,
    );
    await controller.initialize();

    final review = controller.reviewFefoSale('later', quantity: 6);
    expect(review.baseRevision, 0);
    expect(review.plan.complete, isTrue);
    await controller.applyFefoSale(review);

    expect(controller.snapshot.revision, 1);
    expect(controller.snapshot.records['early']!.quantity, 0);
    expect(controller.snapshot.records['early']!.sold, isTrue);
    expect(controller.snapshot.records['later']!.quantity, 2);
    expect(controller.snapshot.records['later']!.sold, isFalse);
    expect(controller.sales.map((sale) => sale.quantity).toList()..sort(), [3, 3]);
    expect(controller.canUndo, isTrue);

    await controller.undo();
    expect(controller.snapshot.records['early']!.quantity, 3);
    expect(controller.snapshot.records['early']!.sold, isFalse);
    expect(controller.snapshot.records['later']!.quantity, 5);
    expect(controller.sales, isEmpty);
    controller.dispose();
  });

  test('stale FEFO review cannot mutate a newer inventory revision', () async {
    final item = stock(
      id: 'one',
      expiry: DateTime.utc(2026, 12, 1),
      quantity: 10,
    );
    final storage = MemoryInventoryStorage(
      InventorySnapshot(records: {'one': item}),
    );
    final controller = PharmacyController(
      storage,
      clock: () => today,
      backgroundSearch: false,
    );
    await controller.initialize();
    final review = controller.reviewFefoSale('one', quantity: 2);
    await controller.save(
      item.patch({'notes': 'counted'}),
      expectedRevision: controller.snapshot.revision,
    );

    await expectLater(
      controller.applyFefoSale(review),
      throwsA(isA<StateError>()),
    );
    expect(controller.snapshot.records['one']!.quantity, 10);
    expect(controller.sales, isEmpty);
    controller.dispose();
  });
}
'''
)

# Attention/reorder regression coverage for the new safety detectors.
Path("test/operational_safety_upgrade_test.dart").write_text(
    r'''import 'package:aaris_pharmacy/domain/attention.dart';
import 'package:aaris_pharmacy/domain/medicine.dart';
import 'package:aaris_pharmacy/domain/tracking.dart';
import 'package:flutter_test/flutter_test.dart';

Medicine item({
  required String id,
  required String batch,
  required int? quantity,
  DateTime? mfg,
  DateTime? expiry,
  String barcode = '',
  String location = '',
}) => Medicine(
  id: id,
  name: 'Amox',
  strength: '500 mg',
  form: 'Capsule',
  batchNumber: batch,
  quantity: quantity,
  mfg: mfg,
  expiry: expiry,
  barcode: barcode,
  location: location,
);

void main() {
  final today = DateTime.utc(2026, 9, 9);

  test('attention flags future MFG and probable duplicate physical batch rows', () {
    final future = item(
      id: 'future',
      batch: 'F1',
      quantity: 10,
      mfg: DateTime.utc(2026, 10, 1),
      expiry: DateTime.utc(2027, 1, 1),
      barcode: '12345678',
      location: 'Rack 1',
    );
    final duplicateA = item(
      id: 'a',
      batch: 'B1',
      quantity: 4,
      expiry: DateTime.utc(2027, 1, 1),
      barcode: '87654321',
      location: 'Rack 2',
    );
    final duplicateB = item(
      id: 'b',
      batch: 'B1',
      quantity: 4,
      expiry: DateTime.utc(2027, 1, 1),
      barcode: '87654321',
      location: 'Rack 2',
    );

    final report = PharmacyAttentionReport.build(
      medicines: [future, duplicateA, duplicateB],
      settings: const WarningSettings(),
      today: today,
      reorder: const [],
    );

    expect(
      report.items.any(
        (entry) => entry.kind == AttentionKind.futureManufactureDate,
      ),
      isTrue,
    );
    final duplicates = report.items.where(
      (entry) => entry.kind == AttentionKind.possibleDuplicateBatch,
    );
    expect(duplicates, hasLength(1));
    expect(duplicates.single.stockIds.toSet(), {'a', 'b'});
  });

  test('future-MFG-only stock cannot suppress reorder and remains review-gated', () {
    final future = item(
      id: 'future',
      batch: 'F1',
      quantity: 20,
      mfg: DateTime.utc(2026, 10, 1),
      expiry: DateTime.utc(2027, 1, 1),
    );
    final sales = [
      SaleEvent(
        id: 'sale-1',
        stockId: future.id,
        medicineName: future.name,
        strength: future.strength,
        form: future.form,
        quantity: 5,
        occurredAt: DateTime.utc(2026, 9, 5),
      ),
    ];
    final stats = TrackingStats(
      medicines: [future],
      sales: sales,
      range: TrackingRange.lastDays(today, 30),
      today: today,
    );

    expect(stats.reorder, hasLength(1));
    final suggestion = stats.reorder.single;
    expect(suggestion.reviewRequired, isTrue);
    expect(suggestion.confidence, lessThan(.75));
    expect(suggestion.reason, contains('Manufacturing date needs review'));
    expect(suggestion.currentQuantity, 0);
  });
}
'''
)

Path("docs/AARIS_REVIEWED_FEFO_AUTOMATION_2026_09_09.md").write_text(
    r'''# Aaris Reviewed FEFO Automation — 2026-09-09

This upgrade extends the existing local-first Aaris Pharmacy architecture without creating a second inventory authority.

## New operational path

When Aaris Brain receives an explicit sale command with a physical unit quantity, for example `Dolo 650 12 units record sale`, it now:

1. parses only an explicit `unit / units / pcs / pieces / qty / quantity` count; medicine strengths such as `650 mg` are never treated as stock quantity,
2. resolves one medicine identity conservatively,
3. builds a deterministic First-Expiry-First-Out allocation across current physical batches,
4. excludes expired, SOLD, removed, and future-manufacturing-date rows,
5. stops if an earlier FEFO batch has unknown quantity rather than skipping or guessing it,
6. shows every batch, quantity, expiry and location that will be affected,
7. requires explicit pharmacist confirmation,
8. commits every batch movement and sale event in one revision-checked SQLite transaction,
9. leaves the whole transaction undoable through the existing audit history.

No AI model can bypass this transaction boundary. Local/remote AI may understand language, but deterministic inventory facts, revision checks and human confirmation remain authoritative.

## Proactive integrity checks

The Needs Attention engine additionally surfaces:

- future manufacturing dates as high-priority data-quality issues,
- likely duplicate physical batch rows when medicine identity + batch + barcode/location repeat,
- existing barcode identity conflicts, expiry risks, unknown quantities/expiries and reorder evidence.

Reorder intelligence now uses the same dispensability predicate as FEFO. Future-MFG rows do not count as usable current stock and any reorder suggestion influenced by that condition is forced into pharmacist review instead of being high-confidence/preselected.

## Safety invariants preserved

- one authoritative medicine database,
- no silent destructive action,
- no invented medicine or clinical facts,
- no automatic mutation from uncertain OCR/AI,
- local-first data processing,
- optimistic revision concurrency control,
- atomic audited mutations and undo,
- patient/customer identity is not collected by the sale automation.
'''
)
