import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/ui/design.dart';
import '../lib/ui/scanner_view.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    await (FontLoader(
      'Manrope',
    )..addFont(rootBundle.load('assets/fonts/Manrope.ttf'))).load();
  });

  final longText = List.generate(
    180,
    (index) => 'Medicine label $index · Paracetamol 650 mg · EXP 12/2028',
  ).join('\n');

  Widget view({
    String text = '',
    bool starting = false,
    bool capturing = false,
    bool cameraReady = true,
    bool rapid = false,
    String error = '',
    VoidCallback? onCapture,
    VoidCallback? onUseScan,
  }) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: pharmacyTheme(),
    home: ScannerView(
      preview: cameraReady ? const ColoredBox(color: ink) : null,
      cameraReady: cameraReady,
      starting: starting,
      capturing: capturing,
      autoSubmit: true,
      rapidCapture: rapid,
      manualOnly: false,
      torchOn: false,
      text: text,
      barcode: '',
      error: error,
      qualityHint: '',
      onCapture: onCapture,
      onUseScan: onUseScan,
      onTorch: null,
    ),
  );

  void size(WidgetTester tester, Size size, double scale) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = scale;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  }

  for (final phone in [
    const Size(320, 568),
    const Size(360, 720),
    const Size(390, 844),
    const Size(780, 360),
  ]) {
    for (final scale in [1.0, 1.6, 2.0]) {
      testWidgets('actions stay reachable at $phone / text $scale', (
        tester,
      ) async {
        size(tester, phone, scale);
        var captures = 0;
        var uses = 0;
        await tester.pumpWidget(view(onCapture: () => captures++));
        await tester.pumpAndSettle();
        final actions = find.byKey(const ValueKey('scan-actions'));
        final original = tester.getRect(actions);
        expect(original.top, greaterThanOrEqualTo(0));
        expect(original.bottom, lessThanOrEqualTo(phone.height));
        expect(tester.takeException(), isNull);

        await tester.pumpWidget(
          view(
            text: longText,
            onCapture: () => captures++,
            onUseScan: () => uses++,
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.getRect(actions), original);
        expect(
          tester.widget<SelectableText>(find.byType(SelectableText)).data,
          longText,
        );
        await tester.tap(find.text('Capture & automate'));
        await tester.tap(find.text('Use scan'));
        expect(captures, 1);
        expect(uses, 1);

        await tester.drag(
          find.byKey(const ValueKey('scan-content')),
          const Offset(0, -500),
        );
        await tester.pumpAndSettle();
        expect(tester.getRect(actions), original);
        await tester.tap(find.text('Capture & automate'));
        await tester.tap(find.text('Use scan'));
        expect(captures, 2);
        expect(uses, 2);
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('opening, busy, retry and rapid capture have usable controls', (
    tester,
  ) async {
    size(tester, const Size(320, 568), 1.6);
    await tester.pumpWidget(view(starting: true, cameraReady: false));
    expect(find.text('Opening camera…'), findsWidgets);
    expect(
      tester.widget<OutlinedButton>(find.byType(OutlinedButton)).onPressed,
      isNull,
    );
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNull,
    );

    await tester.pumpWidget(view(capturing: true, text: longText));
    expect(find.text('Reading…'), findsOneWidget);
    expect(
      tester.widget<OutlinedButton>(find.byType(OutlinedButton)).onPressed,
      isNull,
    );
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNull,
    );

    var retries = 0;
    await tester.pumpWidget(
      view(
        cameraReady: false,
        error: 'Allow camera access, then retry.',
        onCapture: () => retries++,
      ),
    );
    await tester.tap(find.text('Retry camera'));
    expect(retries, 1);

    var finished = false;
    await tester.pumpWidget(
      view(
        rapid: true,
        text: '2 photos queued.',
        onCapture: () {},
        onUseScan: () => finished = true,
      ),
    );
    await tester.tap(find.text('Finish captures'));
    expect(finished, isTrue);
    expect(find.text('Capture photo'), findsOneWidget);
    expect(find.text('Captures saved'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('scanner long-text screenshot uses production layout', (
    tester,
  ) async {
    size(tester, const Size(390, 844), 1);
    final key = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: view(text: longText, onCapture: () {}, onUseScan: () {}),
      ),
    );
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 2);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File('build/ui-review/scanner-long-text.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
    expect(tester.takeException(), isNull);
  });
}
