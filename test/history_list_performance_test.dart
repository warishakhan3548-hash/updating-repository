import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/data/inventory_database.dart';
import '../lib/domain/medicine.dart';
import '../lib/domain/search.dart';
import '../lib/state/pharmacy_controller.dart';
import '../lib/ui/design.dart';
import '../lib/ui/removed_stock_screen.dart';
import '../lib/ui/profile_screen.dart';
import '../lib/ui/version_history_screen.dart';

Future<PharmacyController> _controller(InventorySnapshot snapshot) async {
  final controller = PharmacyController(
    MemoryInventoryStorage(snapshot),
    clock: () => DateTime(2026, 9, 20, 12),
    backgroundSearch: false,
  );
  await controller.initialize();
  return controller;
}

class _PulseNotifier extends ChangeNotifier {
  int token = 0;

  void pulse() => notifyListeners();

  void advance() {
    token++;
    notifyListeners();
  }
}

void main() {
  testWidgets('active builder filters irrelevant listenable notifications', (
    tester,
  ) async {
    final notifier = _PulseNotifier();
    addTearDown(notifier.dispose);
    var builds = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: ActiveListenableBuilder(
          listenable: notifier,
          rebuildToken: () => notifier.token,
          builder: (context, _) {
            builds++;
            return Text('build ${notifier.token}');
          },
        ),
      ),
    );

    expect(builds, 1);
    notifier.pulse();
    await tester.pump();
    expect(builds, 1);

    notifier.advance();
    await tester.pump();
    expect(builds, 2);
    expect(find.text('build 1'), findsOneWidget);
  });

  testWidgets('removed-stock history lazily builds a large archive', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final removed = <Medicine>[];
    for (var index = 0; index < 240; index++) {
      removed.add(
        archiveMedicine(
          Medicine(
            id: 'removed-$index',
            name: 'Removed Medicine ${index.toString().padLeft(3, '0')}',
            strength: '500mg',
            form: 'Tablet',
            expiry: DateTime(2027, 12, 31),
            quantity: 10,
          ),
          reason: 'Performance fixture',
          at: DateTime.utc(2026, 9, 1).add(Duration(minutes: index)),
        ),
      );
    }

    final controller = await _controller(
      InventorySnapshot(
        records: {for (final medicine in removed) medicine.id: medicine},
      ),
    );
    addTearDown(controller.dispose);

    final browse = await controller.searchArchived('');
    // Removed-stock browsing is intentionally bounded so opening history does
    // not materialize an unbounded archive on ordinary phones.
    expect(browse.length, MedicineSearch.maxArchivedResults);
    final firstTitle = controller.snapshot.records[browse.first.id]!.title;
    final farTitle = controller.snapshot.records[browse[99].id]!.title;

    await tester.pumpWidget(
      MaterialApp(
        theme: pharmacyTheme(),
        home: RemovedStockScreen(controller: controller),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text(firstTitle), findsOneWidget);
    expect(
      find.text(farTitle),
      findsNothing,
      reason:
          'A far removed-stock card must stay outside the element tree until it nears the viewport.',
    );

    final archiveList = find.byType(ListView).last;
    for (
      var scroll = 0;
      scroll < 50 && find.text(farTitle).evaluate().isEmpty;
      scroll++
    ) {
      await tester.drag(archiveList, const Offset(0, -700));
      await tester.pumpAndSettle();
    }

    expect(find.text(farTitle), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });
  testWidgets('activity history lazily builds retained audit rows', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final events = List<Map<String, dynamic>>.generate(
      200,
      (index) => <String, dynamic>{
        'id': 'activity-$index',
        'revision': 200 - index,
        'label': 'Activity ${index.toString().padLeft(3, '0')}',
        'time': DateTime.utc(2026, 9, 20, 12)
            .subtract(Duration(minutes: index))
            .toIso8601String(),
        'undoable': false,
        'undone': false,
      },
      growable: false,
    );

    final controller = await _controller(
      InventorySnapshot(revision: 200, events: events),
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: pharmacyTheme(),
        home: ActivityScreen(controller: controller),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Activity 000'), findsOneWidget);
    expect(
      find.text('Activity 099'),
      findsNothing,
      reason:
          'A far activity card must stay outside the element tree until it nears the viewport.',
    );

    await tester.scrollUntilVisible(
      find.text('Activity 099'),
      700,
      scrollable: find.byType(Scrollable).last,
      maxScrolls: 40,
    );

    expect(find.text('Activity 099'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });


  testWidgets('version history lazily builds retained medicine versions', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final events = List<Map<String, dynamic>>.generate(
      200,
      (index) {
        final version = Medicine(
          id: 'version-target',
          name: 'Version Medicine ${index.toString().padLeft(3, '0')}',
          expiry: DateTime(2027, 12, 31),
          quantity: index + 1,
        );
        return <String, dynamic>{
          'id': 'version-event-$index',
          'revision': 200 - index,
          'label': 'Edit ${index.toString().padLeft(3, '0')}',
          'time': DateTime.utc(2026, 9, 20, 12)
              .subtract(Duration(minutes: index))
              .toIso8601String(),
          'undoable': false,
          'undone': false,
          'before': <String, dynamic>{'version-target': version.toJson()},
        };
      },
      growable: false,
    );

    final controller = await _controller(
      InventorySnapshot(revision: 200, events: events),
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: pharmacyTheme(),
        home: VersionHistoryScreen(
          controller: controller,
          medicineId: 'version-target',
        ),
      ),
    );
    await tester.pumpAndSettle();

    final list = tester.widget<ListView>(find.byType(ListView).first);
    expect(list.childrenDelegate, isA<SliverChildBuilderDelegate>());
    expect(find.text('Version Medicine 000'), findsOneWidget);
    expect(
      find.text('Version Medicine 099'),
      findsNothing,
      reason:
          'A far medicine version must stay outside the element tree until it nears the viewport.',
    );

    await tester.scrollUntilVisible(
      find.text('Version Medicine 099'),
      700,
      scrollable: find.byType(Scrollable).first,
      maxScrolls: 50,
    );

    expect(find.text('Version Medicine 099'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

}
