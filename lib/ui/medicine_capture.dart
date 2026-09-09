import 'package:flutter/material.dart';

import '../domain/medicine_understanding.dart';
import '../services/media_import_service.dart';
import '../services/medicine_intake_service.dart';
import '../state/pharmacy_controller.dart';
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
    if (!queue.supported)
      throw UnsupportedError(
        'Photo/video intake is available in the Android app.',
      );
    final choice = await showModalBottomSheet<String>(
      context: context,
      useSafeArea: true,
      builder: (context) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const ListTile(
            title: Text('Capture to local review queue'),
            subtitle: Text(
              'OCR → selected local AI → Add / Ask / Edit. Stock changes require Save.',
            ),
          ),
          for (final item in const [
            ('scan', 'Scan one pack', Icons.camera_alt_outlined),
            ('rapid', 'Rapid photos', Icons.burst_mode_outlined),
            ('photo', 'Choose photo', Icons.photo_library_outlined),
            ('video', 'Choose video', Icons.video_library_outlined),
          ])
            ListTile(
              leading: Icon(item.$3),
              title: Text(item.$2),
              onTap: () => Navigator.pop(context, item.$1),
            ),
        ],
      ),
    );
    if (choice == null || !context.mounted) return;
    if (queue.full)
      throw StateError('The queue is full. Review/dismiss captures first.');
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
    } else if (choice == 'scan') {
      final scan = await Navigator.push<ScanResult>(
        context,
        MaterialPageRoute(
          builder: (_) => const ScannerScreen(autoSubmit: true),
        ),
      );
      if (scan != null)
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
    } else {
      final media = MediaImportService();
      final source = await media.pick(choice == 'video' ? 'video' : 'image');
      if (source == null) return;
      try {
        await queue.addFile(source.path, kind: choice, title: source.name);
      } finally {
        await media.cleanup([source.path]);
      }
    }
  } catch (e) {
    if (context.mounted) showError(context, e);
  }
}
