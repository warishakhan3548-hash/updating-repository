import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../domain/import_text_guard.dart';
import '../domain/medicine_understanding.dart';
import '../services/backup_service.dart';
import '../services/media_import_service.dart';
import '../services/medicine_intake_service.dart';
import '../services/medicine_review_pipeline.dart';
import '../services/scan_service.dart';
import '../state/pharmacy_controller.dart';
import 'design.dart';
import 'editor_screen.dart';
import 'medicine_capture.dart';
import 'medicine_intake_panel.dart';
import 'medicine_review_screen.dart';
import 'scanner_screen.dart';

export 'medicine_review_legacy_entry.dart';

class ImportCenterScreen extends StatefulWidget {
  const ImportCenterScreen({super.key, required this.controller});

  final PharmacyController controller;

  @override
  State<ImportCenterScreen> createState() => _ImportCenterScreenState();
}

class _ImportCenterScreenState extends State<ImportCenterScreen> {
  final _media = MediaImportService();
  final _files = BackupService();
  bool _busy = false;
  int _generation = 0;
  bool _cancelRequested = false;

  void _rejectFullBackup(String text) {
    if (isAarisPharmacyBackupText(text)) {
      throw const FormatException(
        'This is a full backup. Open Profile → Backup & Restore so it can be validated safely.',
      );
    }
  }

  @override
  void dispose() {
    ++_generation;
    super.dispose();
  }

  Future<void> _scan() async {
    final result = await Navigator.push<ScanResult>(
      context,
      MaterialPageRoute(builder: (_) => const ScannerScreen(autoSubmit: true)),
    );
    if (result == null || !mounted) return;
    await _openReview(
      result.evidence.isNotEmpty
          ? result.evidence
          : <ScanEvidence>[
              ScanEvidence(
                barcode: result.barcode,
                text: result.text,
                source: 'Live camera',
              ),
            ],
      autoSaveReadyDrafts: true,
    );
  }

  Future<void> _photo() => _queueMedia('photo');

  Future<void> _video() => _queueMedia('video');

  Future<void> _queueMedia(String kind) async {
    if (_busy) return;
    if (kind != 'photo' && kind != 'video') {
      throw const FormatException('Choose a photo or video import.');
    }
    final generation = ++_generation;
    PickedImportSource? picked;
    setState(() {
      _busy = true;
      _cancelRequested = false;
    });
    try {
      final source = await _media.pick(kind == 'video' ? 'video' : 'image');
      picked = source;
      if (source == null || !mounted || generation != _generation) return;

      // Media is durably queued before OCR/reasoning. The queue owns resumable
      // preparation; every completed draft later opens the same review screen as
      // direct camera, text and cloud-assisted intake.
      final queue = MedicineIntakeService.instance;
      await queue.attach(
        () => widget.controller.records,
        revision: () => widget.controller.snapshot.revision,
      );
      if (!mounted || generation != _generation) return;
      await queue.addFile(
        source.path,
        kind: kind,
        title: source.name,
        cancelled: () => !mounted || generation != _generation,
      );
    } on MedicineIntakeEnqueueCancelled {
      // Explicit user cancellation is expected and leaves no partial queue row.
    } catch (error) {
      if (mounted && generation == _generation) showError(context, error);
    } finally {
      try {
        if (picked != null) await _media.cleanup([picked.path]);
      } catch (_) {}
      if (mounted) {
        setState(() {
          _busy = false;
          _cancelRequested = false;
        });
      }
    }
  }

  Future<void> _textFile() async {
    if (_busy) return;
    final generation = ++_generation;
    setState(() {
      _busy = true;
      _cancelRequested = false;
    });
    try {
      final text = await _files.pickBackupText();
      if (text == null || !mounted || generation != _generation) return;
      _rejectFullBackup(text);
      await _openReview(
        medicineListEvidence(text, source: 'Imported text file'),
      );
    } on MissingPluginException {
      if (mounted) {
        showError(
          context,
          'File import is available in the installed Android app.',
        );
      }
    } catch (error) {
      if (mounted && generation == _generation) showError(context, error);
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _cancelRequested = false;
        });
      }
    }
  }

  Future<void> _pasteList() async {
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      if (!mounted) return;
      final text = data?.text?.trim() ?? '';
      if (text.isEmpty) {
        showError(context, 'Clipboard has no medicine text.');
        return;
      }
      _rejectFullBackup(text);
      await _openReview(medicineListEvidence(text, source: 'Clipboard'));
    } catch (error) {
      if (mounted) showError(context, error);
    }
  }

  Future<void> _openReview(
    List<ScanEvidence> evidence, {
    bool autoSaveReadyDrafts = false,
  }) async {
    if (evidence.every(
      (item) => item.barcode.isEmpty && item.text.trim().isEmpty,
    )) {
      throw const FormatException('No barcode or medicine text was captured.');
    }
    await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => MedicineReviewScreen(
          controller: widget.controller,
          input: MedicineReviewInput.localEvidence(
            evidence,
            autoSaveReadyDrafts: autoSaveReadyDrafts,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Add / Import')),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(22, 8, 22, 30),
          children: [
            const ScreenIntro(
              title: 'Add your medicines',
              message:
                  'Choose the easiest way to start. Review captured details before saving.',
              icon: Icons.add_box_outlined,
            ),
            const FlowSteps(['Add or scan', 'Review', 'Save']),
            _ImportAction(
              icon: Icons.burst_mode_outlined,
              title: 'Queued photo / video capture',
              detail:
                  'Rapid capture, resumable processing, selected local AI and saved drafts.',
              onTap: _busy
                  ? null
                  : () => openMedicineCapture(context, widget.controller),
            ),
            MedicineIntakePanel(controller: widget.controller),
            _ImportAction(
              icon: Icons.edit_note_rounded,
              title: 'Add manually',
              detail: 'Only medicine name is required.',
              onTap:
                  _busy ? null : () => openEditor(context, widget.controller),
            ),
            _ImportAction(
              icon: Icons.qr_code_scanner_rounded,
              title: 'Scan medicine',
              detail:
                  'Capture once · on-device OCR · Local AI when enabled · smart deterministic fallback.',
              onTap: _busy ? null : _scan,
            ),
            _ImportAction(
              icon: Icons.add_photo_alternate_outlined,
              title: 'Upload photo',
              detail:
                  'Saved first, then read locally in the resumable intake queue.',
              onTap: _busy ? null : _photo,
            ),
            _ImportAction(
              icon: Icons.video_library_outlined,
              title: 'Upload video',
              detail:
                  'Saved first, then sampled locally in resumable video windows.',
              onTap: _busy ? null : _video,
            ),
            _ImportAction(
              icon: Icons.upload_file_outlined,
              title: 'Upload text file',
              detail: 'Choose a medicine list, then review its matches.',
              onTap: _busy ? null : _textFile,
            ),
            _ImportAction(
              icon: Icons.content_paste_rounded,
              title: 'Paste medicine list',
              detail: 'Invoices and long lists can be matched in one pass.',
              onTap: _busy ? null : _pasteList,
            ),
            if (_busy) ...[
              const SizedBox(height: 12),
              const LinearProgressIndicator(),
              const SizedBox(height: 10),
              Text(
                _cancelRequested
                    ? 'Finishing the current local step and cleaning temporary files…'
                    : 'Preparing local import…',
                textAlign: TextAlign.center,
                style: const TextStyle(color: muted, fontSize: 12),
              ),
              TextButton(
                onPressed: _cancelRequested
                    ? null
                    : () {
                        ++_generation;
                        setState(() => _cancelRequested = true);
                      },
                child: Text(_cancelRequested ? 'Cancelling…' : 'Cancel'),
              ),
            ],
          ],
        ),
      );
}

class _ImportAction extends StatelessWidget {
  const _ImportAction({
    required this.icon,
    required this.title,
    required this.detail,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String detail;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 11),
        child: Surface(
          padding: EdgeInsets.zero,
          child: ListTile(
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
            leading: DepthIcon(icon),
            title: Text(
              title,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            subtitle: Text(detail),
            trailing: const Icon(Icons.chevron_right_rounded),
            enabled: onTap != null,
            onTap: onTap,
          ),
        ),
      );
}
