import 'package:flutter/material.dart';

import '../domain/medicine_understanding.dart';
import '../services/media_import_service.dart';
import '../services/medicine_intake_service.dart';
import '../services/scan_service.dart';
import '../state/pharmacy_controller.dart';
import 'cloud_scan_review_screen.dart';
import 'design.dart';
import 'scanner_screen.dart';

Future<void> openMedicineCapture(
  BuildContext context,
  PharmacyController controller,
) async {
  final queue = MedicineIntakeService.instance;
  try {
    await queue.attach(
      () => controller.records,
      revision: () => controller.snapshot.revision,
    );
    if (!context.mounted) return;
    if (!queue.supported) {
      throw UnsupportedError(
        'Photo/video intake is available in the Android app.',
      );
    }

    // Capture must never wait behind optional AI setup. The normal lane remains
    // privacy-first and local: OCR -> deterministic extractor -> active Local AI
    // when explicitly enabled -> review. Cloud camera/photo routes are separate
    // owner-selected actions so OCR can never start leaving the device merely
    // because an API key happens to be saved for chat.
    final choice = await showModalBottomSheet<String>(
      context: context,
      useSafeArea: true,
      builder: (context) => SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ListTile(
              title: Text('Capture medicine'),
              subtitle: Text(
                'Aaris Offline Core works without any LLM or API. Local AI can refine it when enabled; Cloud AI is used only when you explicitly choose a cloud scan/photo lane.',
              ),
            ),
            for (final item in const [
              ('scan', 'Scan one pack · Offline Core', Icons.camera_alt_outlined),
              ('cloud', 'Scan with cloud AI', Icons.cloud_outlined),
              (
                'cloudPhoto',
                'Choose photo · Cloud AI',
                Icons.add_photo_alternate_outlined,
              ),
              ('rapid', 'Rapid photos', Icons.burst_mode_outlined),
              (
                'photo',
                'Choose photo · Local queue',
                Icons.photo_library_outlined,
              ),
              ('video', 'Choose video', Icons.video_library_outlined),
            ])
              ListTile(
                leading: Icon(item.$3),
                title: Text(item.$2),
                subtitle: item.$1 == 'cloud' || item.$1 == 'cloudPhoto'
                    ? const Text(
                        'OCR/barcode reading happens on-device first. Only bounded scan evidence may be sent; inventory stays local and every AI field remains review-only until Confirm/Add.',
                      )
                    : item.$1 == 'scan'
                    ? const Text(
                        'On-device OCR + barcode + deterministic medicine reasoning. No model download, API key or internet is required.',
                      )
                    : null,
                onTap: () => Navigator.pop(context, item.$1),
              ),
          ],
        ),
      ),
    );
    if (choice == null || !context.mounted) return;

    // Interactive cloud review does not consume durable queue capacity. A full
    // local photo/video queue must therefore never block an explicitly requested
    // cloud camera/photo review.
    if (choice != 'cloud' && choice != 'cloudPhoto' && queue.full) {
      throw StateError('The queue is full. Review/dismiss captures first.');
    }

    if (choice == 'rapid') {
      await Navigator.push<void>(
        context,
        MaterialPageRoute(
          builder: (_) => ScannerScreen(
            onCaptureQueued: (path) =>
                queue.addFile(path, kind: 'photo', title: 'Rapid capture'),
          ),
        ),
      );
    } else if (choice == 'cloud') {
      final scan = await Navigator.push<ScanResult>(
        context,
        MaterialPageRoute(
          builder: (_) => const ScannerScreen(autoSubmit: true),
        ),
      );
      if (scan == null || !context.mounted) return;
      final evidence = scan.evidence.isNotEmpty
          ? scan.evidence
          : <MedicineFrameEvidence>[
              MedicineFrameEvidence(
                text: scan.text,
                barcode: scan.barcode,
                source: 'Cloud AI camera scan',
              ),
            ];
      await Navigator.push<void>(
        context,
        MaterialPageRoute(
          builder: (_) => CloudScanReviewScreen(
            controller: controller,
            evidence: evidence,
          ),
        ),
      );
    } else if (choice == 'cloudPhoto') {
      final media = MediaImportService();
      final source = await media.pick('image');
      if (source == null) return;
      if (!context.mounted) {
        await media.cleanup([source.path]);
        return;
      }

      // Gallery media never goes to the configured AI provider. Read the image
      // with the same local OCR/barcode engine as the live scanner, retire the
      // temporary picker file, then hand only bounded evidence to cloud review.
      final vision = MedicineVisionService();
      MedicineFrameEvidence? evidence;
      try {
        evidence = await vision.analyzeFile(
          source.path,
          source: source.name,
        );
      } finally {
        try {
          await vision.close();
        } finally {
          await media.cleanup([source.path]);
        }
      }
      if (!context.mounted) return;
      await Navigator.push<void>(
        context,
        MaterialPageRoute(
          builder: (_) => CloudScanReviewScreen(
            controller: controller,
            evidence: <MedicineFrameEvidence>[evidence!],
          ),
        ),
      );
    } else if (choice == 'scan') {
      final scan = await Navigator.push<ScanResult>(
        context,
        MaterialPageRoute(
          builder: (_) => const ScannerScreen(autoSubmit: true),
        ),
      );
      if (scan != null) {
        await queue.addEvidence(
          scan.evidence.isNotEmpty
              ? scan.evidence
              : [
                  MedicineFrameEvidence(
                    text: scan.text,
                    barcode: scan.barcode,
                    source: 'AI Hub camera',
                  ),
                ],
        );
      }
    } else {
      final media = MediaImportService();
      final source = await media.pick(choice == 'video' ? 'video' : 'image');
      if (source == null) return;
      try {
        await queue.addFile(source.path, kind: choice, title: source.name);
      } finally {
        // Picker staging files are housekeeping only. MediaImportService makes
        // cleanup best-effort so a cleanup failure can never turn a successfully
        // queued capture into a false user-visible import failure.
        await media.cleanup([source.path]);
      }
    }
  } catch (e) {
    if (context.mounted) showError(context, e);
  }
}
