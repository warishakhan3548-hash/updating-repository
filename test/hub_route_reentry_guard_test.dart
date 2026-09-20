import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('profile, supplier and stats hubs serialize interactive entry', () {
    final profile = File('lib/ui/profile_screen.dart').readAsStringSync();
    final suppliers = File('lib/ui/supplier_screen.dart').readAsStringSync();
    final stats = File('lib/ui/stats_screen.dart').readAsStringSync();

    expect(
      profile,
      contains('class _ProfileScreenState extends State<ProfileScreen>'),
    );
    expect(profile, contains('bool _actionInProgress = false;'));
    expect(
      profile,
      contains(
        'Future<void> _runExclusiveAction(Future<void> Function() action) async',
      ),
    );
    expect(profile, contains('if (_actionInProgress || !mounted) return;'));
    expect(profile, contains('onTap: _actionInProgress'));

    expect(
      suppliers,
      contains('class _SupplierScreenState extends State<SupplierScreen>'),
    );
    expect(suppliers, contains('bool _routeOpening = false;'));
    expect(
      suppliers,
      contains(
        'bool get _interactionLocked => _returning || _routeOpening;',
      ),
    );
    expect(suppliers, contains('final VoidCallback? onTap;'));

    expect(
      stats,
      contains('class _StatsScreenState extends State<StatsScreen>'),
    );
    expect(stats, contains('bool _routeOpening = false;'));
    expect(
      stats,
      contains(
        'onTap: _routeOpening ? null : () => unawaited(_openTracker())',
      ),
    );
  });
}
