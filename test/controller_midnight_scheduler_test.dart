import 'package:aaris_pharmacy/state/pharmacy_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('midnight refresh preserves UTC clock basis', () {
    final now = DateTime.utc(2026, 9, 20, 23, 59, 59);

    final next = nextInventoryDayRefreshInstant(now);

    expect(next.isUtc, isTrue);
    expect(next, DateTime.utc(2026, 9, 21, 0, 0, 1));
    expect(next.difference(now), const Duration(seconds: 2));
  });

  test('midnight refresh preserves local clock basis', () {
    final now = DateTime(2026, 9, 20, 23, 59, 59);

    final next = nextInventoryDayRefreshInstant(now);

    expect(next.isUtc, isFalse);
    expect(next.year, 2026);
    expect(next.month, 9);
    expect(next.day, 21);
    expect(next.hour, 0);
    expect(next.minute, 0);
    expect(next.second, 1);
    expect(next.difference(now), const Duration(seconds: 2));
  });
}
