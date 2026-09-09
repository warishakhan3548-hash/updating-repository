import 'dart:convert';

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
    expect(removed.map((row) => row.archiveReason).toSet(), {
      'Protected bulk removal',
    });
    expect(removed.map((row) => row.archivedAt).toSet(), {now});

    await controller.undo();
    expect(controller.records.every((row) => !row.archived), isTrue);
    expect(controller.records.every((row) => row.archivedAt == null), isTrue);
  });

  test(
    'backup reconciliation archives missing live rows with provenance',
    () async {
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
    },
  );

  test(
    'AI remove is audited and exact archived rows can be safely restored',
    () {
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
    },
  );

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
