import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/domain/medicine.dart';
import '../lib/ui/design.dart';

void main() {
  testWidgets(
    'medicine rows keep one elevated surface and a bounded shadow budget',
    (tester) async {
      final medicine = Medicine(
        id: 'paint-budget',
        name: 'Paracetamol',
        strength: '500mg',
        form: 'Tablet',
        expiry: DateTime(2027, 1, 1),
        quantity: 10,
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: pharmacyTheme(),
          home: Scaffold(
            body: MedicineCard(
              record: medicine,
              settings: const WarningSettings(),
              today: DateTime(2026, 9, 20),
              onTap: () {},
            ),
          ),
        ),
      );

      final card = find.byType(MedicineCard);
      final panels = tester
          .widgetList<GlassPanel>(
            find.descendant(of: card, matching: find.byType(GlassPanel)),
          )
          .toList(growable: false);

      expect(panels.where((panel) => panel.elevation > 0).length, 1);

      var renderedShadows = 0;
      for (final box in tester.widgetList<DecoratedBox>(
        find.descendant(of: card, matching: find.byType(DecoratedBox)),
      )) {
        final decoration = box.decoration;
        if (decoration is! BoxDecoration) continue;
        final shadows = decoration.boxShadow ?? const <BoxShadow>[];
        expect(
          shadows.length,
          lessThanOrEqualTo(3),
          reason:
              'One shared surface must never fan out into an unbounded shadow stack.',
        );
        renderedShadows += shadows.length;
      }

      expect(renderedShadows, lessThanOrEqualTo(3));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('semantic glass surfaces use at most three paint shadows', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: GlassPanel(
            tint: primarySoft,
            accentColor: primary,
            shadowColor: primary,
            child: const SizedBox(width: 120, height: 80),
          ),
        ),
      ),
    );

    final shadows = tester
        .widgetList<DecoratedBox>(
          find.descendant(
            of: find.byType(GlassPanel),
            matching: find.byType(DecoratedBox),
          ),
        )
        .expand((box) {
          final decoration = box.decoration;
          return decoration is BoxDecoration
              ? decoration.boxShadow ?? const <BoxShadow>[]
              : const <BoxShadow>[];
        })
        .toList(growable: false);

    expect(shadows.length, lessThanOrEqualTo(3));
    expect(shadows, isNotEmpty);
    expect(tester.takeException(), isNull);
  });
}
