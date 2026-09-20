import 'package:aaris_pharmacy/data/inventory_database.dart';
import 'package:aaris_pharmacy/domain/medicine.dart';
import 'package:aaris_pharmacy/state/autopilot_supervisor.dart';
import 'package:aaris_pharmacy/state/pharmacy_controller.dart';
import 'package:aaris_pharmacy/ui/design.dart';
import 'package:aaris_pharmacy/ui/home_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('Home previews the canonical today-work queue only', (tester) async {
    final medicine = Medicine.fromJson(<String, dynamic>{
      'id': 'home-work',
      'name': 'Dolo',
      'strength': '650mg',
      'form': 'Tablet',
      'quantity': 12,
      'location': 'Rack A',
    });
    final controller = PharmacyController(
      MemoryInventoryStorage(
        InventorySnapshot(
          records: <String, Medicine>{medicine.id: medicine},
        ),
      ),
      clock: () => DateTime(2026, 9, 20, 10),
      backgroundSearch: false,
    );
    await controller.initialize();
    final autopilot = AarisAutopilotSupervisor(
      controller,
      startImmediately: false,
    );
    var opens = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: pharmacyTheme(),
        home: Scaffold(
          body: HomeScreen(
            controller: controller,
            autopilot: autopilot,
            onOpenWorkQueue: () => opens++,
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('आज के काम'), findsOneWidget);
    expect(find.text('Attention first'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('आज के काम अपडेट हो रहे हैं…'), findsOneWidget);

    final all = find.text('सभी देखें');
    await tester.ensureVisible(all);
    await tester.tap(all);
    await tester.pump();
    expect(opens, 1);

    await tester.pumpWidget(const SizedBox.shrink());
    autopilot.dispose();
    controller.dispose();
    await tester.pump();
  });

  test('Text buttons use the app font instead of the default block font', () {
    final style = pharmacyTheme().textButtonTheme.style;
    final textStyle = style?.textStyle?.resolve(const <WidgetState>{});
    expect(textStyle?.fontFamily, 'Manrope');
    expect(textStyle?.fontFamilyFallback, contains('NotoSansDevanagari'));
  });
}
