import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('dialog text controllers are owned by widget lifecycle, not timers', () {
    for (final path in <String>[
      'lib/ui/home_screen.dart',
      'lib/ui/search_screen.dart',
      'lib/ui/editor_screen.dart',
    ]) {
      final source = File(path).readAsStringSync();
      expect(
        RegExp(
          r'Future(?:<void>)?\.delayed[\s\S]{0,320}?\.dispose\(\)',
        ).hasMatch(source),
        isFalse,
        reason: '$path must not guess when a dialog is safe to dispose.',
      );
    }

    final home = File('lib/ui/home_screen.dart').readAsStringSync();
    expect(home, contains('class _WarningSettingsDialog extends StatefulWidget'));
    expect(home, contains('_days.dispose();'));
    expect(home, contains('_months.dispose();'));

    final search = File('lib/ui/search_screen.dart').readAsStringSync();
    expect(search, contains('TextFormField('));
    expect(search, contains('onChanged: (value) => draft = value'));

    final editor = File('lib/ui/editor_screen.dart').readAsStringSync();
    expect(editor, contains("var quantityText = '1';"));
    expect(editor, contains("var amountText = '';"));
    expect(editor, contains('onChanged: (value) => quantityText = value'));
    expect(editor, contains('onChanged: (value) => amountText = value'));
  });
}
