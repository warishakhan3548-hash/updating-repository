import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/ui/design.dart';

void main() {
  testWidgets(
    'active listenable builder sleeps under inactive TickerMode and catches up',
    (tester) async {
      final source = ValueNotifier<int>(0);
      addTearDown(source.dispose);
      var builds = 0;

      Widget host(bool active) => MaterialApp(
        home: TickerMode(
          enabled: active,
          child: ActiveListenableBuilder(
            listenable: source,
            builder: (context, _) {
              builds++;
              return Text('value ${source.value}');
            },
          ),
        ),
      );

      await tester.pumpWidget(host(true));
      expect(find.text('value 0'), findsOneWidget);

      source.value = 1;
      await tester.pump();
      expect(find.text('value 1'), findsOneWidget);

      await tester.pumpWidget(host(false));
      final hiddenBuilds = builds;

      source.value = 2;
      await tester.pump();
      expect(builds, hiddenBuilds);
      expect(find.text('value 1'), findsOneWidget);

      await tester.pumpWidget(host(true));
      expect(find.text('value 2'), findsOneWidget);
      expect(builds, greaterThan(hiddenBuilds));
      expect(tester.takeException(), isNull);
    },
  );
}
