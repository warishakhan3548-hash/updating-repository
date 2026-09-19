import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('every medicine intake source uses one simple review surface', () {
    final panel = File('lib/ui/medicine_intake_panel.dart').readAsStringSync();
    final import = File('lib/ui/import_screen.dart').readAsStringSync();
    final capture = File('lib/ui/medicine_capture.dart').readAsStringSync();
    final review = File('lib/ui/medicine_review_screen.dart').readAsStringSync();
    final pipeline = File('lib/services/medicine_review_pipeline.dart')
        .readAsStringSync();
    final cardinality = File('lib/domain/medicine_review_cardinality.dart')
        .readAsStringSync();

    expect(panel, contains('MedicineReviewScreen('));
    expect(panel, contains('MedicineReviewInput.prepared('));
    expect(panel, contains('final reviewDrafts = _reviewDrafts(job);'));
    expect(panel, isNot(contains('job.drafts.take(3)')));
    expect(panel, contains('Next reviews them one at a time.'));
    expect(panel, contains("job.kind == 'photo' || job.kind == 'evidence'"));

    expect(import, contains('MedicineReviewInput.localEvidence('));
    expect(import, isNot(contains('ImportInboxScreen')));
    expect(capture, contains('MedicineReviewInput.cloudEvidence('));
    expect(capture, isNot(contains('CloudScanReviewScreen')));

    expect(review, contains("'Scanned medicine'"));
    expect(review, contains("'Next'"));
    expect(review, contains('matching medicine'));
    expect(review, contains('similar medicine'));
    expect(review, contains('rankIntakeMatches('));
    expect(review, isNot(contains('AUTO-FILLED FACTS')));
    expect(review, isNot(contains('SCAN REVIEW')));
    expect(review, isNot(contains('Verification required')));
    expect(review, isNot(contains('Possible existing stock — verify carefully')));
    expect(review, isNot(contains('Review scanned facts manually')));

    expect(pipeline, contains('MedicineReviewInputKind.prepared'));
    expect(pipeline, contains('MedicineReviewInputKind.localEvidence'));
    expect(pipeline, contains('MedicineReviewInputKind.cloudEvidence'));
    expect(pipeline, contains('normalizeMedicineReviewDrafts('));
    expect(cardinality, contains('singlePackExpected'));
    expect(cardinality, contains('overallConfidence: min(primary.overallConfidence, .74)'));
    expect(File('lib/ui/prepared_medicine_review_screen.dart').existsSync(), isFalse);
    expect(File('lib/ui/cloud_scan_review_screen.dart').existsSync(), isFalse);
  });
}
