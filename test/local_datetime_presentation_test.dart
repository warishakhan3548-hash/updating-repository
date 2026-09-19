import 'package:aaris_pharmacy/ui/design.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('local date time formatter accepts persisted timestamps', () {
    final instant = DateTime.parse('2026-09-19T23:47:05.987Z');
    final local = instant.toLocal();
    final expected = local.toString().split('.').first;
    expect(localDateTimeLabel(instant.toIso8601String()), expected);
    expect(localDateTimeLabel(instant), expected);
  });

  test('local date time formatter has a safe malformed fallback', () {
    expect(localDateTimeLabel('not-a-date'), 'Time unavailable');
    expect(localDateTimeLabel(null), 'Time unavailable');
  });
}
