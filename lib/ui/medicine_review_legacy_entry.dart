import 'package:flutter/material.dart';

import '../services/medicine_review_pipeline.dart';
import '../services/scan_service.dart';
import '../state/pharmacy_controller.dart';
import 'medicine_review_screen.dart';

/// Source-compatible doorway for one stale caller while all medicine-review
/// behavior remains owned by MedicineReviewPipeline + MedicineReviewScreen.
/// This widget performs no OCR, matching, AI routing, persistence or mutation.
class ImportInboxScreen extends StatelessWidget {
  const ImportInboxScreen({
    super.key,
    required this.controller,
    required this.evidence,
  });

  final PharmacyController controller;
  final List<ScanEvidence> evidence;

  @override
  Widget build(BuildContext context) => MedicineReviewScreen(
        controller: controller,
        input: MedicineReviewInput.localEvidence(evidence),
      );
}
