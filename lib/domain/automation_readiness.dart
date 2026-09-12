import 'inventory.dart';
import 'medicine.dart';

enum AutomationReadinessKind { fefoExpiryUncertainty, fefoQuantityBlocker }

class AutomationReadinessIssue {
  const AutomationReadinessIssue({
    required this.key,
    required this.kind,
    required this.title,
    required this.detail,
    required this.stockIds,
    required this.productKey,
  });

  final String key;
  final AutomationReadinessKind kind;
  final String title;
  final String detail;
  final List<String> stockIds;
  final String productKey;
}

/// Read-only automation-preflight checks for multi-lot dispensing.
///
/// The engine deliberately uses only facts already stored in the authoritative
/// Medicine Database. It does not infer an expiry, quantity or clinical fact and
/// it never mutates inventory. Its job is to tell the pharmacist *before* a
/// sale/FEFO command which missing physical facts can reduce or stop deterministic
/// automation.
class PharmacyAutomationReadinessReport {
  PharmacyAutomationReadinessReport._(List<AutomationReadinessIssue> source)
    : issues = List.unmodifiable(source);

  factory PharmacyAutomationReadinessReport.build({
    required Iterable<Medicine> medicines,
    required DateTime today,
  }) {
    final day = civilDay(today);
    final groups = <String, List<Medicine>>{};

    for (final medicine in medicines) {
      if (!isDispensableOn(medicine, day) || medicine.quantity == 0) continue;
      groups.putIfAbsent(medicine.identity, () => <Medicine>[]).add(medicine);
    }

    final issues = <AutomationReadinessIssue>[];
    final orderedKeys = groups.keys.toList()..sort();
    for (final productKey in orderedKeys) {
      final group = groups[productKey]!;
      if (group.length < 2) continue;

      // Reuse the exact FEFO candidate ordering used by the sale planner. This
      // prevents the proactive queue from disagreeing with the transaction path.
      final candidates = dispensingCandidates(group, group.first, day);
      if (candidates.length < 2) continue;

      _addExpiryReadiness(productKey, candidates, issues);
      _addQuantityReadiness(productKey, candidates, issues);
    }

    issues.sort((a, b) {
      final kind = a.kind.index.compareTo(b.kind.index);
      if (kind != 0) return kind;
      return a.key.compareTo(b.key);
    });
    return PharmacyAutomationReadinessReport._(issues);
  }

  final List<AutomationReadinessIssue> issues;
  bool get isEmpty => issues.isEmpty;
}

void _addExpiryReadiness(
  String productKey,
  List<Medicine> candidates,
  List<AutomationReadinessIssue> issues,
) {
  final unknown = candidates
      .where((medicine) => medicine.expiry == null)
      .toList(growable: false);
  if (unknown.isEmpty) return;

  final known = candidates
      .where((medicine) => medicine.expiry != null)
      .toList(growable: false);
  final ids = unknown.map((medicine) => medicine.id).toList()..sort();
  final first = candidates.first;
  final unknownCount = unknown.length;
  final detail = known.isEmpty
      ? '${candidates.length} active sellable stock rows share this medicine identity, but none has a recorded expiry. True first-expiry-first-out order cannot be proven from saved facts. Verify the physical packs and record expiry before relying on automatic FEFO ordering.'
      : '$unknownCount active stock row${unknownCount == 1 ? '' : 's'} ${unknownCount == 1 ? 'has' : 'have'} no recorded expiry. Aaris safely places undated stock after ${known.length} dated FEFO row${known.length == 1 ? '' : 's'}, but once those dated units are exhausted it cannot prove which remaining lot expires first. Verify the physical pack${unknownCount == 1 ? '' : 's'}; no expiry will be invented.';

  issues.add(
    AutomationReadinessIssue(
      key: 'fefo-expiry:$productKey:${ids.join(':')}',
      kind: AutomationReadinessKind.fefoExpiryUncertainty,
      title: '${first.title} · FEFO needs expiry verification',
      detail: detail,
      stockIds: List.unmodifiable(ids),
      productKey: productKey,
    ),
  );
}

void _addQuantityReadiness(
  String productKey,
  List<Medicine> candidates,
  List<AutomationReadinessIssue> issues,
) {
  final unknown = candidates
      .where((medicine) => medicine.quantity == null)
      .toList(growable: false);
  if (unknown.isEmpty) return;

  var firstUnknownIndex = -1;
  for (var index = 0; index < candidates.length; index++) {
    if (candidates[index].quantity == null) {
      firstUnknownIndex = index;
      break;
    }
  }
  if (firstUnknownIndex < 0) return;

  var knownUnitsBefore = 0;
  for (var index = 0; index < firstUnknownIndex; index++) {
    final quantity = candidates[index].quantity;
    if (quantity != null && quantity > 0) knownUnitsBefore += quantity;
  }

  final firstBlocker = candidates[firstUnknownIndex];
  final ids = unknown.map((medicine) => medicine.id).toList()..sort();
  final prefix = knownUnitsBefore == 0
      ? 'The first reachable FEFO-priority stock row has unknown quantity, so any automatic multi-lot sale must stop before allocating from it.'
      : 'Aaris can deterministically allocate up to $knownUnitsBefore known unit${knownUnitsBefore == 1 ? '' : 's'} from earlier FEFO rows; a larger request reaches an unknown-quantity row and must stop for a physical count.';

  issues.add(
    AutomationReadinessIssue(
      key: 'fefo-quantity:$productKey:${ids.join(':')}',
      kind: AutomationReadinessKind.fefoQuantityBlocker,
      title: '${candidates.first.title} · FEFO quantity blocks full automation',
      detail:
          '$prefix First blocker: ${_stockCue(firstBlocker)}. Verify the unknown count before continuing; Aaris will never skip an unknown-priority lot or guess stock.',
      stockIds: List.unmodifiable(ids),
      productKey: productKey,
    ),
  );
}

String _stockCue(Medicine medicine) {
  final parts = <String>[
    if (medicine.batchNumber.trim().isNotEmpty)
      'Batch ${medicine.batchNumber.trim()}',
    if (medicine.expiry != null) 'EXP ${dateText(medicine.expiry!)}',
    if (medicine.address.trim().isNotEmpty) medicine.address.trim(),
  ];
  return parts.isEmpty ? medicine.title : parts.join(' · ');
}
