import 'medicine.dart';

enum InventoryIntegritySeverity { high, medium, low }

enum InventoryIntegrityKind {
  conflictingLotFacts,
  soldAuditGap,
  staleSoldMetadata,
}

class InventoryIntegrityIssue {
  const InventoryIntegrityIssue({
    required this.key,
    required this.kind,
    required this.severity,
    required this.title,
    required this.detail,
    required this.stockIds,
  });

  final String key;
  final InventoryIntegrityKind kind;
  final InventoryIntegritySeverity severity;
  final String title;
  final String detail;
  final List<String> stockIds;
}

/// Deterministic, local-only checks for saved stock facts that can make
/// automation unsafe. This engine never changes inventory and never infers
/// clinical facts; it only compares facts already saved by the pharmacist.
class InventoryIntegrityReport {
  InventoryIntegrityReport._(List<InventoryIntegrityIssue> source)
    : issues = List.unmodifiable(source);

  factory InventoryIntegrityReport.build({
    required Iterable<Medicine> medicines,
    required DateTime today,
  }) {
    final day = civilDay(today);
    final records = medicines
        .where((medicine) => !medicine.archived)
        .toList(growable: false);
    final issues = <InventoryIntegrityIssue>[];

    _addConflictingLotFacts(records, issues);
    _addSaleAuditIssues(records, day, issues);

    issues.sort((a, b) {
      final severity = a.severity.index.compareTo(b.severity.index);
      if (severity != 0) return severity;
      final kind = a.kind.index.compareTo(b.kind.index);
      if (kind != 0) return kind;
      return a.title.compareTo(b.title);
    });
    return InventoryIntegrityReport._(issues);
  }

  final List<InventoryIntegrityIssue> issues;
  bool get isEmpty => issues.isEmpty;
}

void _addConflictingLotFacts(
  List<Medicine> records,
  List<InventoryIntegrityIssue> issues,
) {
  final groups = <String, List<Medicine>>{};
  for (final medicine in records.where((medicine) => !medicine.sold)) {
    final batch = normalize(medicine.batchNumber);
    if (batch.isEmpty) continue;

    final barcode = normalize(medicine.barcode);
    final manufacturer = normalize(medicine.manufacturer);
    final brand = normalize(medicine.brand);

    // Batch numbers are not globally unique. Compare only when another strong
    // physical/source anchor exists, otherwise unrelated manufacturers can
    // legitimately reuse the same batch text.
    final String? anchor = barcode.isNotEmpty
        ? 'barcode:$barcode|batch:$batch'
        : manufacturer.isNotEmpty
        ? 'product:${medicine.identity}|manufacturer:$manufacturer|batch:$batch'
        : brand.isNotEmpty
        ? 'product:${medicine.identity}|brand:$brand|batch:$batch'
        : null;
    if (anchor == null) continue;
    groups.putIfAbsent(anchor, () => <Medicine>[]).add(medicine);
  }

  for (final group in groups.values.where((rows) => rows.length > 1)) {
    // A shared barcode with different product identities is handled by the
    // stronger barcode-identity rule in the attention engine.
    if (group.map((medicine) => medicine.identity).toSet().length != 1) {
      continue;
    }

    final conflicts = <String>[];
    if (_dateValues(group, (medicine) => medicine.expiry).length > 1) {
      conflicts.add('expiry');
    }
    if (_dateValues(group, (medicine) => medicine.mfg).length > 1) {
      conflicts.add('manufacturing date');
    }

    final sameBarcode =
        group
            .map((medicine) => normalize(medicine.barcode))
            .where((value) => value.isNotEmpty)
            .toSet()
            .length ==
        1;
    if (sameBarcode) {
      if (_textValues(group, (medicine) => medicine.manufacturer).length > 1) {
        conflicts.add('manufacturer');
      }
      if (_textValues(group, (medicine) => medicine.brand).length > 1) {
        conflicts.add('brand');
      }
    }

    if (conflicts.isEmpty) continue;
    final ids = group.map((medicine) => medicine.id).toList()..sort();
    final first = group.first;
    final barcode = first.barcode.trim();
    final lotCue = barcode.isNotEmpty
        ? 'barcode $barcode and batch ${first.batchNumber.trim()}'
        : 'batch ${first.batchNumber.trim()} for the same product source';
    issues.add(
      InventoryIntegrityIssue(
        key: 'lot-conflict:${ids.join(':')}',
        kind: InventoryIntegrityKind.conflictingLotFacts,
        severity: InventoryIntegritySeverity.high,
        title: '${first.title} · conflicting saved batch facts',
        detail:
            '${group.length} active rows appear to describe the same physical lot ($lotCue) but disagree on ${_joined(conflicts)}. Verify the physical packs before FEFO, scanner selection, stock receiving or consolidation. Aaris will not merge or overwrite these rows automatically.',
        stockIds: List.unmodifiable(ids),
      ),
    );
  }
}

void _addSaleAuditIssues(
  List<Medicine> records,
  DateTime day,
  List<InventoryIntegrityIssue> issues,
) {
  for (final medicine in records) {
    if (!medicine.sold) {
      final hasStaleMetadata =
          (medicine.soldAt?.trim().isNotEmpty ?? false) ||
          medicine.soldQuantity != null ||
          medicine.soldUnitPricePaise != null;
      if (!hasStaleMetadata) continue;
      issues.add(
        InventoryIntegrityIssue(
          key: 'stale-sold:${medicine.id}',
          kind: InventoryIntegrityKind.staleSoldMetadata,
          severity: InventoryIntegritySeverity.high,
          title: '${medicine.title} · active stock has stale SOLD audit facts',
          detail: 'This row is currently active/not SOLD but still carries historical SOLD fields. Those stale facts can distort operational history or reorder evidence. Review the exact stock row; Aaris will not silently clear audit data.',
          stockIds: List.unmodifiable(<String>[medicine.id]),
        ),
      );
      continue;
    }

    final problems = <String>[];
    var severity = InventoryIntegritySeverity.medium;
    final rawSoldAt = medicine.soldAt?.trim() ?? '';
    final soldAt = rawSoldAt.isEmpty ? null : DateTime.tryParse(rawSoldAt);
    if (rawSoldAt.isEmpty) {
      problems.add('SOLD time is missing');
    } else if (soldAt == null) {
      problems.add('SOLD time is invalid');
      severity = InventoryIntegritySeverity.high;
    } else if (civilDay(soldAt).isAfter(day)) {
      problems.add('SOLD time is in the future');
      severity = InventoryIntegritySeverity.high;
    }
    if (medicine.soldQuantity == null) {
      problems.add('original sold quantity is unknown');
    }
    if (problems.isEmpty) continue;

    issues.add(
      InventoryIntegrityIssue(
        key: 'sold-audit:${medicine.id}',
        kind: InventoryIntegrityKind.soldAuditGap,
        severity: severity,
        title: '${medicine.title} · SOLD audit needs review',
        detail:
            '${_sentence(problems)}. Current stock state stays unchanged; verify the historical row if accurate sale/reorder evidence matters.',
        stockIds: List.unmodifiable(<String>[medicine.id]),
      ),
    );
  }
}

Set<String> _dateValues(
  Iterable<Medicine> records,
  DateTime? Function(Medicine) select,
) => records.map(select).whereType<DateTime>().map(dateText).toSet();

Set<String> _textValues(
  Iterable<Medicine> records,
  String Function(Medicine) select,
) => records
    .map((medicine) => normalize(select(medicine)))
    .where((value) => value.isNotEmpty)
    .toSet();

String _joined(List<String> values) {
  if (values.length == 1) return values.single;
  if (values.length == 2) return '${values.first} and ${values.last}';
  return '${values.take(values.length - 1).join(', ')}, and ${values.last}';
}

String _sentence(List<String> values) {
  final joined = _joined(values);
  return joined.isEmpty
      ? joined
      : '${joined.substring(0, 1).toUpperCase()}${joined.substring(1)}';
}
