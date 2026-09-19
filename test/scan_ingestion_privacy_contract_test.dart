import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('normal and explicit cloud intake share UI but keep privacy routes distinct', () {
    final normal = File('lib/ui/import_screen.dart').readAsStringSync();
    final capture = File('lib/ui/medicine_capture.dart').readAsStringSync();
    final pipeline = File('lib/services/medicine_review_pipeline.dart')
        .readAsStringSync();
    final scanner = File('lib/ui/scanner_screen.dart').readAsStringSync();
    final commitPolicy = File('lib/domain/medicine_scan_commit.dart')
        .readAsStringSync();

    expect(normal, contains('MedicineReviewInput.localEvidence('));
    expect(normal, isNot(contains('CloudScanAiService')));
    expect(capture, contains('MedicineReviewInput.cloudEvidence('));
    expect(capture, contains('Scan with cloud AI'));
    expect(capture, isNot(contains('CloudScanReviewScreen')));

    expect(pipeline, contains('CloudScanAiService'));
    expect(pipeline, contains('MedicineReviewInputKind.localEvidence'));
    expect(pipeline, contains('MedicineReviewInputKind.cloudEvidence'));
    expect(pipeline, contains('medicineKnowledgeFromRecords(records)'));
    expect(
      pipeline,
      contains("config == null\n        ? medicineKnowledgeFromRecords(records)\n        : const <MedicineKnowledgeEntry>[]"),
    );
    expect(
      pipeline,
      contains("config == null\n        ? await OfflineRecognitionMemoryService.instance.enrichKnowledge"),
    );
    expect(pipeline, contains("'knowledge': knowledge"));
    expect(pipeline, contains("'catalog': catalogue"));

    expect(scanner, contains('understandMedicineEvidenceV2Message'));
    expect(scanner, contains("'knowledge': const <Object?>[]"));
    expect(scanner, contains("'catalog': const <Object?>[]"));
    expect(scanner, isNot(contains('CloudScanAiService')));
    expect(scanner, isNot(contains('CanonicalMedicineCatalogService')));
    expect(commitPolicy, isNot(contains('cloudAi')));
  });

  test('gallery photo and video both enter the durable intake queue', () {
    final source = File('lib/ui/import_screen.dart').readAsStringSync();

    expect(source, contains("Future<void> _photo() => _queueMedia('photo');"));
    expect(source, contains("Future<void> _video() => _queueMedia('video');"));
    expect(source, contains('await queue.addFile('));
    expect(source, contains('source.path,'));
    expect(source, contains('kind: kind,'));
    expect(source, contains('title: source.name,'));
    expect(
      source,
      contains('cancelled: () => !mounted || generation != _generation,'),
    );
    expect(source, isNot(contains('final vision = MedicineVisionService();')));
  });
}
