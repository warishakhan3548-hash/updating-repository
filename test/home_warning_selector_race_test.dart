import 'dart:async';

import 'package:aaris_pharmacy/data/inventory_database.dart';
import 'package:aaris_pharmacy/state/pharmacy_controller.dart';
import 'package:aaris_pharmacy/ui/home_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _BlockingStorage implements InventoryStorage {
  _BlockingStorage({
    this.failFirstCommit = false,
    this.blockSecondCommit = false,
  });

  final MemoryInventoryStorage _inner = MemoryInventoryStorage();
  final Completer<void> _firstCommitGate = Completer<void>();
  final Completer<void> _secondCommitGate = Completer<void>();
  final bool failFirstCommit;
  final bool blockSecondCommit;
  int commits = 0;

  void releaseFirstCommit() {
    if (!_firstCommitGate.isCompleted) _firstCommitGate.complete();
  }

  void releaseSecondCommit() {
    if (!_secondCommitGate.isCompleted) _secondCommitGate.complete();
  }

  @override
  Future<InventorySnapshot> load() => _inner.load();

  @override
  Future<InventorySnapshot> commit(InventoryMutation mutation) async {
    commits++;
    if (commits == 1) {
      await _firstCommitGate.future;
      if (failFirstCommit) throw StateError('planned first write failure');
    }
    if (commits == 2 && blockSecondCommit) {
      await _secondCommitGate.future;
    }
    return _inner.commit(mutation);
  }

  @override
  Future<void> close() => _inner.close();
}

Future<void> _disposeHarness(
  WidgetTester tester,
  PharmacyController controller,
) async {
  controller.dispose();
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
}

Future<void> _chooseShortDays(WidgetTester tester, String label) async {
  await tester.tap(find.byType(PopupMenuButton<int>).first);
  // A pending warning-window save intentionally shows an indeterminate
  // progress indicator, so pumpAndSettle can never complete while exercising
  // the rapid-intent race. Advance only the popup route animation instead.
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.tap(find.text(label));
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  testWidgets(
    'warning selector keeps a rapid last intent that returns to the baseline',
    (tester) async {
      final storage = _BlockingStorage();
      final controller = PharmacyController(
        storage,
        clock: () => DateTime(2026, 9, 20, 10),
        backgroundSearch: false,
      );
      await controller.initialize();

      try {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: HomeScreen(controller: controller, onDatabase: () {}),
            ),
          ),
        );

        expect(controller.settings.shortDays, 8);
        await _chooseShortDays(tester, '5 Days');

        // The first write is still blocked. Choosing the originally committed
        // value is therefore a real second intent, not a no-op.
        expect(controller.settings.shortDays, 8);
        await _chooseShortDays(tester, '8 Days');

        storage.releaseFirstCommit();
        await tester.pumpAndSettle();

        expect(storage.commits, 2);
        expect(controller.settings.shortDays, 8);
        expect(controller.settings.months, 2);
        expect(controller.snapshot.revision, 2);
      } finally {
        await _disposeHarness(tester, controller);
      }
    },
  );

  testWidgets(
    'failed older equal-valued request cannot retire the latest intent',
    (tester) async {
      final storage = _BlockingStorage(
        failFirstCommit: true,
        blockSecondCommit: true,
      );
      final controller = PharmacyController(
        storage,
        clock: () => DateTime(2026, 9, 20, 10),
        backgroundSearch: false,
      );
      await controller.initialize();

      try {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: HomeScreen(controller: controller, onDatabase: () {}),
            ),
          ),
        );

        // Queue 5 -> 8 -> 5 while the first 5 is blocked. The first request is
        // deliberately failed after the newest pending value has returned to 5.
        await _chooseShortDays(tester, '5 Days');
        await _chooseShortDays(tester, '8 Days');
        await _chooseShortDays(tester, '5 Days');
        storage.releaseFirstCommit();

        // Let the failed first request settle and hold the second write. The
        // authoritative snapshot is still 8, while the latest pending intent is
        // 5. A final tap back to 8 must therefore enqueue a fourth request.
        for (var attempt = 0; attempt < 20 && storage.commits < 2; attempt++) {
          await tester.pump(const Duration(milliseconds: 10));
        }
        expect(storage.commits, 2);
        expect(controller.settings.shortDays, 8);
        await _chooseShortDays(tester, '8 Days');

        storage.releaseSecondCommit();
        await tester.pumpAndSettle();

        // The queued return-to-baseline request becomes a serialized no-op
        // after the older failing write leaves 8 as the authoritative value.
        // The fourth UI intent still has to survive and win: storage therefore
        // sees the failed first 5, the later committed 5, and the final 8.
        expect(storage.commits, 3);
        expect(controller.settings.shortDays, 8);
        expect(controller.snapshot.revision, 2);
      } finally {
        storage.releaseFirstCommit();
        storage.releaseSecondCommit();
        await _disposeHarness(tester, controller);
      }
    },
  );
}
