import 'dart:async';

import 'package:aaris_pharmacy/domain/ai_configuration.dart';
import 'package:aaris_pharmacy/domain/medicine.dart';
import 'package:aaris_pharmacy/domain/medicine_understanding.dart';
import 'package:aaris_pharmacy/services/cloud_scan_ai_service.dart';
import 'package:aaris_pharmacy/services/medicine_review_pipeline.dart';
import 'package:flutter_test/flutter_test.dart';

const _evidence = <MedicineFrameEvidence>[
  MedicineFrameEvidence(
    text: 'DOLO 650 TABLETS\nParacetamol IP 650 mg\nEXP 05/2028',
    source: 'review-cancellation-test',
  ),
];

class _BlockingCloudScanAiService extends CloudScanAiService {
  final configurationEntered = Completer<void>();
  final releaseConfiguration = Completer<void>();
  int refineCalls = 0;

  @override
  Future<AiConfiguration> requireConfiguration() async {
    if (!configurationEntered.isCompleted) configurationEntered.complete();
    await releaseConfiguration.future;
    return const AiConfiguration(
      provider: 'Gemini',
      model: 'test-model',
      key: 'test-key-never-sent',
    );
  }

  @override
  String routeLabel(AiConfiguration config) => 'test-cloud';

  @override
  Future<MedicineScanDraft> refine(
    AiConfiguration config,
    MedicineScanDraft draft,
  ) async {
    refineCalls++;
    return draft;
  }
}

void main() {
  group('medicine review cancellation', () {
    test('cancelled pipeline cannot start a later preparation', () async {
      final pipeline = MedicineReviewPipeline();
      pipeline.cancel();

      await expectLater(
        pipeline.prepare(
          const MedicineReviewInput.cloudEvidence(_evidence),
          const <Medicine>[],
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            'Medicine review cancelled.',
          ),
        ),
      );
    });

    test('cancel persists across an in-flight async stage', () async {
      final cloud = _BlockingCloudScanAiService();
      final pipeline = MedicineReviewPipeline(cloud: cloud);

      final preparation = pipeline.prepare(
        const MedicineReviewInput.cloudEvidence(_evidence),
        const <Medicine>[],
      );
      await cloud.configurationEntered.future;

      pipeline.cancel();
      cloud.releaseConfiguration.complete();

      await expectLater(
        preparation,
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            'Medicine review cancelled.',
          ),
        ),
      );
      expect(cloud.refineCalls, 0);
    });
  });
}
