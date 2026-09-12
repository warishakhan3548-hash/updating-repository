import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('normal import inbox has no implicit cloud scan transport', () {
    final normal = File('lib/ui/import_screen.dart').readAsStringSync();
    final explicitCloud = File('lib/ui/cloud_scan_review_screen.dart')
        .readAsStringSync();
    final capture = File('lib/ui/medicine_capture.dart').readAsStringSync();
    final scanner = File('lib/ui/scanner_screen.dart').readAsStringSync();
    final commitPolicy = File('lib/domain/medicine_scan_commit.dart')
        .readAsStringSync();

    expect(normal, isNot(contains('CloudScanAiService')));
    expect(normal, isNot(contains("../services/cloud_scan_ai_service.dart")));
    expect(normal, contains('understandMedicineEvidenceV2Message'));
    expect(normal, contains('CanonicalMedicineCatalogService.instance'));
    expect(normal, contains("'catalog': catalogue"));
    expect(explicitCloud, contains('CloudScanAiService'));
    expect(capture, contains('Scan with cloud AI'));
    expect(capture, contains('CloudScanReviewScreen'));
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
    expect(
      source,
      contains(
        'await queue.addFile(source.path, kind: kind, title: source.name);',
      ),
    );
    expect(source, isNot(contains('final vision = MedicineVisionService();')));
  });
}
