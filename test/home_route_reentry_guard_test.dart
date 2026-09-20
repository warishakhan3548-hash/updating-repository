import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('home serializes route entry from cards and medicine shortcuts', () {
    final home = File('lib/ui/home_screen.dart').readAsStringSync();

    expect(home, contains('bool _routeOpening = false;'));
    expect(home, contains('if (_routeOpening || !mounted) return;'));
    expect(home, contains('unawaited(_open(SearchScope.shortExpiry))'));
    expect(home, contains('unawaited(_open(SearchScope.expired))'));
    expect(home, contains('unawaited(_edit(record: live))'));
  });
}
