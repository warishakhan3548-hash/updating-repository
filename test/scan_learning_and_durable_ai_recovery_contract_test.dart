import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('scan-linked existing-stock edits retain learning provenance', () {
    final review = File(
      'lib/ui/medicine_review_screen.dart',
    ).readAsStringSync();

    expect(
      review,
      contains(
        'Future<bool> _editExistingForScan(\n'
        '    Medicine record,\n'
        '    MedicineScanDraft scanDraft,',
      ),
    );
    expect(
      review,
      contains('record: record,\n        scanDraft: scanDraft,'),
    );
    expect(
      review,
      contains('_editExistingForScan(record, review.draft)'),
    );
    expect(review, contains('scanDraft: review.draft,'));
  });

  test('durable Local AI recovery queues lease races instead of skipping', () {
    final intake = File(
      'lib/services/medicine_intake_service.dart',
    ).readAsStringSync();
    final start = intake.indexOf(
      'Future<MedicineScanDraft> _understandWithRecovery(',
    );
    final end = intake.indexOf('Future<void> _reason(', start);

    expect(start, greaterThanOrEqualTo(0));
    expect(end, greaterThan(start));
    final recovery = intake.substring(start, end);

    expect(recovery, contains('_retryLocalAiWhenIdle'));
    expect(recovery, contains('local.busy || local.transferring'));
    expect(recovery, contains('_localLeaseContention(suspendError)'));
    expect(recovery, contains('_routeStillOwnsResult(local, routedModelId)'));
    expect(recovery, isNot(contains('LocalBrainRoutePolicy.mayReasonWith')));
  });
}
