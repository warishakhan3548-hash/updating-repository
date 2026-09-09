from pathlib import Path


def replace_once(path: str, old: str, new: str) -> None:
    p = Path(path)
    text = p.read_text()
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{path}: expected exactly one anchor, found {count}")
    p.write_text(text.replace(old, new, 1))


# Durable removal provenance lives on the authoritative medicine row.
replace_once(
    "lib/domain/medicine.dart",
    """    this.sold = false,
    this.archived = false,
    this.soldAt,
""",
    """    this.sold = false,
    this.archived = false,
    this.archivedAt,
    this.archiveReason = '',
    this.soldAt,
""",
)
replace_once(
    "lib/domain/medicine.dart",
    """  final bool mfgMonthOnly, expiryMonthOnly, sold, archived;
  final int? quantity, unitPricePaise, soldQuantity, soldUnitPricePaise;
  final String? soldAt;
""",
    """  final bool mfgMonthOnly, expiryMonthOnly, sold, archived;
  final int? quantity, unitPricePaise, soldQuantity, soldUnitPricePaise;
  final DateTime? archivedAt;
  final String archiveReason;
  final String? soldAt;
""",
)
replace_once(
    "lib/domain/medicine.dart",
    """    'sold',
    'archived',
    'soldAt',
""",
    """    'sold',
    'archived',
    'archivedAt',
    'archiveReason',
    'soldAt',
""",
)
replace_once(
    "lib/domain/medicine.dart",
    """    'sold': sold,
    'archived': archived,
    'soldAt': soldAt,
""",
    """    'sold': sold,
    'archived': archived,
    'archivedAt': archivedAt?.toIso8601String(),
    'archiveReason': archiveReason,
    'soldAt': soldAt,
""",
)
replace_once(
    "lib/domain/medicine.dart",
    """    final sold = json['sold'] == true;
    final quantity = number('quantity', 100000000);
""",
    """    final sold = json['sold'] == true;
    final archived = json['archived'] == true;
    final archiveReason = text('archiveReason');
    final archivedAtRaw = json['archivedAt'];
    DateTime? archivedAt;
    if (archivedAtRaw != null && archivedAtRaw != '') {
      if (archivedAtRaw is! String || archivedAtRaw.length > 80) {
        throw const FormatException('Invalid archivedAt.');
      }
      final parsed = DateTime.tryParse(archivedAtRaw);
      if (parsed == null || parsed.year < 2000 || parsed.year > 2200) {
        throw const FormatException('Invalid archivedAt.');
      }
      archivedAt = parsed.toUtc();
    }
    if (!archived && (archivedAt != null || archiveReason.isNotEmpty)) {
      throw const FormatException(
        'Active stock cannot carry removed-stock audit facts.',
      );
    }
    if (archived && ((archivedAt == null) != archiveReason.isEmpty)) {
      throw const FormatException(
        'Removed-stock audit reason and time must be recorded together.',
      );
    }
    final quantity = number('quantity', 100000000);
""",
)
replace_once(
    "lib/domain/medicine.dart",
    """      sold: sold,
      archived: json['archived'] == true,
      soldAt: json['soldAt'] as String?,
""",
    """      sold: sold,
      archived: archived,
      archivedAt: archivedAt,
      archiveReason: archiveReason,
      soldAt: json['soldAt'] as String?,
""",
)
replace_once(
    "lib/domain/medicine.dart",
    """  Medicine patch(Map<String, dynamic> changes) => Medicine.fromJson({
    ...toJson(),
    ...changes,
    'id': id,
    'revision': revision + 1,
  });
}

class WarningSettings {
""",
    """  Medicine patch(Map<String, dynamic> changes) => Medicine.fromJson({
    ...toJson(),
    ...changes,
    'id': id,
    'revision': revision + 1,
  });
}

/// The single authoritative transition into Removed stock.
///
/// Removal provenance is system-owned metadata, not an AI-editable medicine
/// fact. Legacy archived rows may have no provenance; every new removal records
/// a bounded reason and an unambiguous UTC timestamp.
Medicine archiveMedicine(
  Medicine record, {
  required String reason,
  required DateTime at,
}) {
  final cleanReason = reason.replaceAll(RegExp(r'\\s+'), ' ').trim();
  if (cleanReason.isEmpty || cleanReason.length > 300) {
    throw const FormatException('Choose a valid removal reason.');
  }
  if (record.archived) {
    throw StateError('This stock entry is already removed.');
  }
  return record.patch({
    'archived': true,
    'archivedAt': at.toUtc().toIso8601String(),
    'archiveReason': cleanReason,
  });
}

/// The single authoritative transition back from Removed stock.
Medicine restoreArchivedMedicine(Medicine record) {
  if (!record.archived) {
    throw StateError('This stock entry is not removed.');
  }
  return record.patch({
    'archived': false,
    'archivedAt': null,
    'archiveReason': '',
  });
}

class WarningSettings {
""",
)

# Every controller pathway uses the same archive lifecycle transition.
replace_once(
    "lib/state/pharmacy_controller.dart",
    """        upserts: [
          m.patch({'archived': true}),
        ],
""",
    """        upserts: [
          archiveMedicine(m, reason: reason, at: clock()),
        ],
""",
)
replace_once(
    "lib/state/pharmacy_controller.dart",
    """    final orderedIds = activeIds.toList()..sort();
    await _commit(
""",
    """    final orderedIds = activeIds.toList()..sort();
    final removedAt = clock();
    await _commit(
""",
)
replace_once(
    "lib/state/pharmacy_controller.dart",
    """          for (final id in orderedIds) snapshot.records[id]!.patch({'archived': true}),
""",
    """          for (final id in orderedIds)
            archiveMedicine(
              snapshot.records[id]!,
              reason: 'Protected bulk removal',
              at: removedAt,
            ),
""",
)
replace_once(
    "lib/state/pharmacy_controller.dart",
    """        upserts: [
          m.patch({'archived': false}),
        ],
""",
    """        upserts: [restoreArchivedMedicine(m)],
""",
)
replace_once(
    "lib/state/pharmacy_controller.dart",
    """    final restored = <Medicine>[];
    for (final record in review.backup.records.values) {
""",
    """    final restored = <Medicine>[];
    final restoreStartedAt = clock();
    for (final record in review.backup.records.values) {
""",
)
replace_once(
    "lib/state/pharmacy_controller.dart",
    """        restored.add(record.patch({'archived': true}));
""",
    """        restored.add(
          archiveMedicine(
            record,
            reason: 'Not present in restored backup',
            at: restoreStartedAt,
          ),
        );
""",
)

# Strict AI protocol: exact archived rows may be restored, and AI removals gain
# durable provenance. Existing revision/replay/review gates stay authoritative.
replace_once(
    "lib/domain/ai_protocol.dart",
    """      if (!{'add', 'update', 'remove', 'mark_sold', 'restock'}.contains(op))
""",
    """      if (!{
        'add',
        'update',
        'remove',
        'mark_sold',
        'restock',
        'restore',
      }.contains(op))
""",
)
replace_once(
    "lib/domain/ai_protocol.dart",
    """        before = records[id]!;
        if (before.archived)
          throw const FormatException('This entry has been removed.');
        if ((op == 'remove' || op == 'mark_sold') && fields.isNotEmpty)
          throw const FormatException(
            'This operation cannot also edit medicine facts.',
          );
        if (op == 'mark_sold') {
""",
    """        before = records[id]!;
        if (before.archived && op != 'restore') {
          throw const FormatException('This entry has been removed.');
        }
        if (op == 'restore' && !before.archived) {
          throw const FormatException('Restore targets a removed stock entry.');
        }
        if ((op == 'remove' || op == 'mark_sold' || op == 'restore') &&
            fields.isNotEmpty) {
          throw const FormatException(
            'This operation cannot also edit medicine facts.',
          );
        }
        if (op == 'mark_sold') {
""",
)
replace_once(
    "lib/domain/ai_protocol.dart",
    """        } else if (op == 'remove') {
          after = before.patch({'archived': true});
        } else if (op == 'restock') {
""",
    """        } else if (op == 'remove') {
          after = archiveMedicine(
            before,
            reason: 'AI reviewed removal',
            at: now,
          );
        } else if (op == 'restore') {
          after = restoreArchivedMedicine(before);
        } else if (op == 'restock') {
""",
)

# The local model can only restore a row it actually retrieved from archived/get.
replace_once(
    "lib/domain/local_ai_protocol.dart",
    """Allowed proposals: {\"op\":\"add\",\"fields\":{\"name\":\"...\"}}, {\"op\":\"update\",\"id\":\"retrieved ID\",\"fields\":{\"quantity\":25}}, {\"op\":\"remove\",\"id\":\"retrieved ID\"}, {\"op\":\"mark_sold\",\"id\":\"retrieved ID\"}, {\"op\":\"restock\",\"id\":\"retrieved ID\",\"fields\":{\"quantity\":25}}.
""",
    """Allowed proposals: {\"op\":\"add\",\"fields\":{\"name\":\"...\"}}, {\"op\":\"update\",\"id\":\"retrieved ID\",\"fields\":{\"quantity\":25}}, {\"op\":\"remove\",\"id\":\"retrieved ID\"}, {\"op\":\"mark_sold\",\"id\":\"retrieved ID\"}, {\"op\":\"restock\",\"id\":\"retrieved ID\",\"fields\":{\"quantity\":25}}, {\"op\":\"restore\",\"id\":\"retrieved archived ID\"}.
""",
)
replace_once(
    "lib/domain/local_ai_protocol.dart",
    """Remove archives, never deletes permanently. No raw SQL, paths or hidden tools. At most 8 proposals. EVERY mutation requires the app's review before saving. Expiry/status and sales totals come from deterministic tools, not your memory.
""",
    """Remove archives, never deletes permanently. Restore only an exact archived row returned by the archived/get tool; never guess a removed ID. No raw SQL, paths or hidden tools. At most 8 proposals. EVERY mutation requires the app's review before saving. Expiry/status and sales totals come from deterministic tools, not your memory.
""",
)
replace_once(
    "lib/domain/local_ai_protocol.dart",
    """      'sold': m.sold,
      'archived': m.archived,
      'batchNumber': text('batchNumber', m.batchNumber),
""",
    """      'sold': m.sold,
      'archived': m.archived,
      if (m.archived) ...{
        'archiveReason': text('archiveReason', m.archiveReason),
        'archivedAt': m.archivedAt?.toIso8601String(),
      },
      'batchNumber': text('batchNumber', m.batchNumber),
""",
)

# High-impact AI lifecycle operations require a deliberate checkbox selection.
replace_once(
    "lib/ui/ai_screen.dart",
    """            if (plan.changes[i].possibleDuplicates.isEmpty &&
                plan.changes[i].operation != 'remove')
              i,
""",
    """            if (plan.changes[i].possibleDuplicates.isEmpty &&
                !_requiresExplicitLifecycleSelection(
                  plan.changes[i].operation,
                ))
              i,
""",
)
replace_once(
    "lib/ui/ai_screen.dart",
    """    'remove' => red,
    'mark_sold' => amber,
    'restock' => _aiPurple,
""",
    """    'remove' => red,
    'mark_sold' => amber,
    'restock' => _aiPurple,
    'restore' => green,
""",
)
replace_once(
    "lib/ui/ai_screen.dart",
    """              'Unselected changes stay untouched. Remove actions are never pre-selected.',
""",
    """              'Unselected changes stay untouched. Remove, SOLD and Restore actions are never pre-selected.',
""",
)
replace_once(
    "lib/ui/ai_screen.dart",
    """String _operationLabel(String operation) =>
    {
""",
    """bool _requiresExplicitLifecycleSelection(String operation) =>
    const {'remove', 'mark_sold', 'restore'}.contains(operation);

String _operationLabel(String operation) =>
    {
""",
)
replace_once(
    "lib/ui/ai_screen.dart",
    """      'restock': 'Restock medicine',
    }[operation] ??
""",
    """      'restock': 'Restock medicine',
      'restore': 'Restore removed stock',
    }[operation] ??
""",
)
replace_once(
    "lib/ui/ai_screen.dart",
    """      'soldAt': 'Marked sold at',
    }[key] ??
""",
    """      'soldAt': 'Marked sold at',
      'archiveReason': 'Removal reason',
      'archivedAt': 'Removed at',
    }[key] ??
""",
)

# Recovery UX shows provenance even when old activity events have rolled off.
replace_once(
    "lib/ui/profile_screen.dart",
    """import 'package:flutter/material.dart';

import '../state/pharmacy_controller.dart';
""",
    """import 'package:flutter/material.dart';

import '../domain/medicine.dart';
import '../state/pharmacy_controller.dart';
""",
)
replace_once(
    "lib/ui/profile_screen.dart",
    """        final records = controller.records.where((m) => m.archived).toList();
""",
    """        final records = controller.records.where((m) => m.archived).toList()
          ..sort((a, b) {
            final aTime = a.archivedAt;
            final bTime = b.archivedAt;
            if (aTime == null && bTime != null) return 1;
            if (bTime == null && aTime != null) return -1;
            if (aTime != null && bTime != null) {
              final recent = bTime.compareTo(aTime);
              if (recent != 0) return recent;
            }
            return a.title.compareTo(b.title);
          });
""",
)
replace_once(
    "lib/ui/profile_screen.dart",
    """                    subtitle: Text(m.address),
""",
    """                    subtitle: Text(
                      [
                        if (m.archiveReason.isNotEmpty) m.archiveReason,
                        if (m.archivedAt != null)
                          'Removed ${dateText(m.archivedAt!.toLocal())}',
                        if (m.address.isNotEmpty) m.address,
                      ].join(' · '),
                    ),
""",
)

# Keep architecture docs aligned with the executable contract.
replace_once(
    "docs/ARCHITECTURE.md",
    """- Remove is soft archive. Restore, latest-change Undo and bounded per-record
  version history protect against accidental and bulk changes.
""",
    """- Remove is soft archive. Every new removal carries system-owned durable
  provenance (bounded reason + UTC removal timestamp) on the same medicine row,
  so the reason survives the 200-event activity window and full backup/restore.
  Legacy removed rows without provenance remain readable. Restore clears the
  removal marker atomically; latest-change Undo and bounded per-record version
  history still protect against accidental and bulk changes.
""",
)
replace_once(
    "docs/PROGRESS.md",
    "# Implementation status — 2026-09-09\n",
    "# Implementation status — 2026-09-10\n",
)
replace_once(
    "docs/PROGRESS.md",
    """- Manual add/edit/remove/restock, explicit SOLD, aggregate sale recording,
  FEFO batch guidance, expired-sale/MFG-date guards, soft-delete history, latest
  Undo and per-medicine version restore.
""",
    """- Manual add/edit/remove/restock, explicit SOLD, aggregate sale recording,
  FEFO batch guidance, expired-sale/MFG-date guards, durable removal reason/time,
  local-AI reviewed recovery of exact archived rows, soft-delete history, latest
  Undo and per-medicine version restore. Remove/SOLD/Restore AI lifecycle actions
  require explicit checkbox selection before the final atomic Apply.
""",
)

Path("docs/AARIS_DURABLE_REMOVAL_AND_RECOVERY_2026_09_10.md").write_text(
    """# Aaris durable removal & recovery upgrade — 10 September 2026

## Why this exists

Aaris already used soft archive and a 200-event activity journal. The journal is
excellent for Undo, but it is intentionally bounded; after enough later changes,
a removal reason could disappear from history even though the removed medicine
row still existed. That is weak provenance for a pharmacy inventory system.

## New authoritative lifecycle

- Every new single, protected bulk, AI-reviewed, or backup-reconciliation removal
  goes through one domain transition and writes `archiveReason` plus `archivedAt`
  on the same authoritative `Medicine` row.
- Those fields are system-owned audit metadata. They are stored/backed up but are
  not in `Medicine.editable`, so AI cannot rewrite them as medicine facts.
- Restore goes through the paired domain transition and clears removal metadata.
  If a restored row is still SOLD or expired, those independent deterministic
  states remain intact; restore does not manufacture on-hand stock.
- Old backups/rows with `archived=true` and no provenance remain valid for
  backward compatibility. Partial or stale removal metadata is rejected.
- Removed Stock sorts known removal times newest first and shows reason/date.

## AI recovery safety

The local inventory tool already had explicit `archived`/`get` reads. It may now
propose `restore` only for an exact archived ID it actually retrieved. The app
still owns the schema, revision, replay ID and mutation. Remove, whole-stock SOLD,
and Restore are deliberately not pre-selected in an AI multi-change review; the
pharmacist must select them and then press Apply.

This adds no second database, cloud sync, treatment engine, or direct AI SQL path.
All changes still converge on the existing atomic inventory mutation pipeline and
remain undoable.
"""
)

Path("test/removal_recovery_test.dart").write_text(
    """import 'dart:convert';

import 'package:aaris_pharmacy/data/inventory_database.dart';
import 'package:aaris_pharmacy/domain/ai_protocol.dart';
import 'package:aaris_pharmacy/domain/backup.dart';
import 'package:aaris_pharmacy/domain/local_ai_protocol.dart';
import 'package:aaris_pharmacy/domain/medicine.dart';
import 'package:aaris_pharmacy/state/pharmacy_controller.dart';
import 'package:flutter_test/flutter_test.dart';

Medicine stock(String id) => Medicine.fromJson({
  'id': id,
  'name': 'Dolo',
  'strength': '650 mg',
  'form': 'Tablet',
  'quantity': 10,
  'expiry': '2027-12',
  'revision': 1,
});

Future<PharmacyController> controllerAt(DateTime now) async {
  final controller = PharmacyController(
    MemoryInventoryStorage(),
    clock: () => now,
    backgroundSearch: false,
  );
  await controller.initialize();
  return controller;
}

void main() {
  final now = DateTime.utc(2026, 9, 10, 12, 30);

  test('single removal provenance survives backup, restore and undo', () async {
    final controller = await controllerAt(now);
    addTearDown(controller.dispose);
    await controller.save(stock('a'), expectedRevision: 0);

    await controller.archive('a', 'Damaged', expectedRevision: 1);
    var removed = controller.snapshot.records['a']!;
    expect(removed.archived, isTrue);
    expect(removed.archiveReason, 'Damaged');
    expect(removed.archivedAt, now);

    final roundTrip = PharmacyBackup.parse(controller.createBackup().encode());
    expect(roundTrip.records['a']!.archiveReason, 'Damaged');
    expect(roundTrip.records['a']!.archivedAt, now);

    await controller.restoreArchived('a');
    var restored = controller.snapshot.records['a']!;
    expect(restored.archived, isFalse);
    expect(restored.archiveReason, isEmpty);
    expect(restored.archivedAt, isNull);

    await controller.undo();
    removed = controller.snapshot.records['a']!;
    expect(removed.archived, isTrue);
    expect(removed.archiveReason, 'Damaged');
    expect(removed.archivedAt, now);
  });

  test('protected bulk removal gives all rows one audited instant', () async {
    final controller = await controllerAt(now);
    addTearDown(controller.dispose);
    await controller.save(stock('a'), expectedRevision: 0);
    await controller.save(stock('b'), expectedRevision: 1);

    final review = controller.reviewArchiveAll();
    await controller.applyArchiveAll(review);
    final removed = controller.records.toList();
    expect(removed, hasLength(2));
    expect(removed.every((row) => row.archived), isTrue);
    expect(
      removed.map((row) => row.archiveReason).toSet(),
      {'Protected bulk removal'},
    );
    expect(removed.map((row) => row.archivedAt).toSet(), {now});

    await controller.undo();
    expect(controller.records.every((row) => !row.archived), isTrue);
    expect(controller.records.every((row) => row.archivedAt == null), isTrue);
  });

  test('backup reconciliation archives missing live rows with provenance', () async {
    final controller = await controllerAt(now);
    addTearDown(controller.dispose);
    await controller.save(stock('a'), expectedRevision: 0);

    final backup = PharmacyBackup(
      createdAt: now.subtract(const Duration(days: 1)),
      sourceRevision: 0,
      settings: const WarningSettings(),
      records: const {},
      sales: const {},
      soldValue: 0,
      unknownSold: 0,
    );
    await controller.restoreBackup(
      BackupReview(backup: backup, currentRevision: 1),
    );

    final removed = controller.snapshot.records['a']!;
    expect(removed.archived, isTrue);
    expect(removed.archiveReason, 'Not present in restored backup');
    expect(removed.archivedAt, now);
  });

  test('AI remove is audited and exact archived rows can be safely restored', () {
    final active = stock('a');
    final removeEnvelope = jsonEncode({
      'schema': pharmacySchema,
      'requestId': 'remove_req_123',
      'baseRevision': 7,
      'actions': [
        {'op': 'remove', 'id': 'a'},
      ],
    });
    final removePlan = parseAiPlan(
      removeEnvelope,
      {'a': active},
      7,
      const {},
      now,
    );
    final removed = removePlan.changes.single.after;
    expect(removed.archived, isTrue);
    expect(removed.archiveReason, 'AI reviewed removal');
    expect(removed.archivedAt, now);

    final local = LocalInventoryContext(
      records: [removed],
      sales: const [],
      revision: 8,
      today: now,
    );
    final archivedPage = local.read({'tool': 'archived', 'offset': 0});
    final rows = archivedPage['rows']! as List;
    expect(rows, hasLength(1));
    expect((rows.single as Map)['archiveReason'], 'AI reviewed removal');

    final restoreEnvelope = local.finish({
      'reply': 'Exact removed stock row found. Restore is ready for review.',
      'actions': [
        {'op': 'restore', 'id': 'a'},
      ],
    });
    final restorePlan = parseAiPlan(
      restoreEnvelope,
      {'a': removed},
      8,
      const {},
      now,
    );
    expect(restorePlan.changes.single.operation, 'restore');
    final restored = restorePlan.changes.single.after;
    expect(restored.archived, isFalse);
    expect(restored.archiveReason, isEmpty);
    expect(restored.archivedAt, isNull);
  });

  test('partial or stale archive audit metadata fails closed', () {
    expect(
      () => Medicine.fromJson({
        'id': 'active',
        'name': 'Dolo',
        'archived': false,
        'archivedAt': now.toIso8601String(),
        'archiveReason': 'Damaged',
      }),
      throwsFormatException,
    );
    expect(
      () => Medicine.fromJson({
        'id': 'removed',
        'name': 'Dolo',
        'archived': true,
        'archiveReason': 'Damaged',
      }),
      throwsFormatException,
    );

    final legacy = Medicine.fromJson({
      'id': 'legacy',
      'name': 'Dolo',
      'archived': true,
    });
    expect(legacy.archived, isTrue);
    expect(legacy.archiveReason, isEmpty);
    expect(legacy.archivedAt, isNull);
  });
}
"""
)
