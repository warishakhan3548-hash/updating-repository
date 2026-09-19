import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('medicine intake stays automatic under memory pressure', () {
    final service = File(
      'lib/services/medicine_intake_service.dart',
    ).readAsStringSync();
    final memoryHandler = RegExp(
      r'void didHaveMemoryPressure\(\) \{([\s\S]*?)\n  \}',
    ).firstMatch(service);

    expect(memoryHandler, isNotNull);
    final body = memoryHandler!.group(1)!;
    expect(body, isNot(contains('_paused')));
    expect(body, isNot(contains('pauseReason')));
    expect(body, contains('_knowledge = null;'));
    expect(body, contains('_kick();'));
    expect(service, isNot(contains('void setPaused(')));
    expect(service, isNot(contains('bool get paused')));
    expect(service, isNot(contains('resume this saved queue')));
  });

  test('medicine intake UI has one simple automatic review path', () {
    final panel = File(
      'lib/ui/medicine_intake_panel.dart',
    ).readAsStringSync();

    expect(panel, isNot(contains("'Resume'")));
    expect(panel, isNot(contains('Pause after current step')));
    expect(panel, isNot(contains('AI scan preview')));
    expect(panel, isNot(contains('Cloud refine this draft')));
    expect(panel, isNot(contains('Retry local reasoning')));
    expect(panel, contains("'Medicine preview'"));
    expect(panel, contains("'Reading medicine…'"));
    expect(panel, contains("'Next'"));
    expect(panel, contains('queue.retry(job, rescanVideo: true)'));
  });
  test('media import cancellation reaches the durable queue boundary', () {
    final service = File(
      'lib/services/medicine_intake_service.dart',
    ).readAsStringSync();
    final screen = File('lib/ui/import_screen.dart').readAsStringSync();

    expect(
      service,
      contains('class MedicineIntakeEnqueueCancelled implements Exception'),
    );
    expect(service, contains('bool Function()? cancelled,'));
    expect(service, contains('_throwIfEnqueueCancelled(cancelled);'));
    expect(
      RegExp(r'_persist\(job, insert: true, publish: false\)')
          .allMatches(service)
          .length,
      2,
    );
    expect(service, contains('if (publish) notifyListeners();'));
    expect(
      screen,
      contains(
        'cancelled: () => !mounted || generation != _generation,',
      ),
    );
    expect(screen, contains('on MedicineIntakeEnqueueCancelled'));
  });

  test('review navigation waits for a durable terminal checkpoint', () {
    final service = File(
      'lib/services/medicine_intake_service.dart',
    ).readAsStringSync();
    final start = service.indexOf('Future<void> continueWithDraft(');
    final end = service.indexOf('Future<void> _enqueue(', start);
    expect(start, greaterThanOrEqualTo(0));
    expect(end, greaterThan(start));

    final body = service.substring(start, end);
    expect(body, contains('if (!_jobs.contains(job) || !job.canReview) return;'));
    expect(body, contains('await _persist(job, publish: false);'));
    expect(
      body.indexOf('await _persist(job, publish: false);'),
      lessThan(body.lastIndexOf('notifyListeners();')),
    );
    expect(
      body,
      contains("throw StateError('This saved capture is no longer available.');"),
    );
  });

}
