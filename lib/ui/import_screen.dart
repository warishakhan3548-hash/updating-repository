import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../domain/intake_resolution.dart';
import '../domain/inventory.dart';
import '../domain/medicine.dart';
import '../domain/medicine_scan_commit.dart';
import '../domain/medicine_understanding.dart';
import '../domain/search.dart';
import '../services/backup_service.dart';
import '../services/local_ai_service.dart';
import '../services/local_brain_route_policy.dart';
import '../services/media_import_service.dart';
import '../services/medicine_intake_service.dart';
import '../services/scan_service.dart';
import '../state/pharmacy_controller.dart';
import 'design.dart';
import 'editor_screen.dart';
import 'import_screen.dart' show ImportInboxScreen;
import 'medicine_capture.dart';
import 'medicine_intake_panel.dart';
import 'scanner_screen.dart';

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
  int _done = 0;
  int _total = 0;
  int _generation = 0;
  bool _cancelRequested = false;

  @override
  void dispose() {
    ++_generation;
    super.dispose();
  }

  Future<void> _scan() async {
    final result = await Navigator.push<ScanResult>(
      context,
      MaterialPageRoute(builder: (_) => const ScannerScreen()),
    );
    if (result == null || !mounted) return;
    await _openInbox(
      result.evidence.isNotEmpty
          ? result.evidence
          : <ScanEvidence>[
              ScanEvidence(
                barcode: result.barcode,
                text: result.text,
                source: 'Live camera',
              ),
            ],
    );
  }

  Future<void> _photo() async {
    if (_busy) return;
    final generation = ++_generation;
    PickedImportSource? picked;
    final vision = MedicineVisionService();
    setState(() {
      _busy = true;
      _cancelRequested = false;
      _done = 0;
      _total = 1;
    });
    try {
      final source = await _media.pick('image');
      picked = source;
      if (source == null || !mounted || generation != _generation) return;
      final evidence = await vision.analyzeFile(
        source.path,
        source: source.name,
      );
      if (!mounted || generation != _generation) return;
      setState(() => _done = 1);
      await _openInbox([evidence]);
    } catch (error) {
      if (mounted && generation == _generation) showError(context, error);
    } finally {
      try {
        await vision.close();
      } catch (_) {}
      if (picked != null) {
        try {
          await _media.cleanup([picked.path]);
        } catch (_) {}
      }
      if (mounted) {
        setState(() {
          _busy = false;
          _cancelRequested = false;
        });
      }
    }
  }

  Future<void> _video() async {
    if (_busy) return;
    final generation = ++_generation;
    PickedImportSource? picked;
    setState(() {
      _busy = true;
      _cancelRequested = false;
      _done = 0;
      _total = 0;
    });
    try {
      final source = await _media.pick('video');
      picked = source;
      if (source == null || !mounted || generation != _generation) return;
      final queue = MedicineIntakeService.instance;
      await queue.attach(
        () => widget.controller.records,
        revision: () => widget.controller.snapshot.revision,
      );
      if (!mounted || generation != _generation) return;
      await queue.addFile(source.path, kind: 'video', title: source.name);
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
      if (text.contains('aaris.pharmacy.backup.v1')) {
        throw const FormatException(
          'This is a full backup. Open Profile → Backup & Restore so it can be validated safely.',
        );
      }
      await _openInbox(
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
      await _openInbox(medicineListEvidence(text, source: 'Clipboard'));
    } catch (error) {
      if (mounted) showError(context, error);
    }
  }

  Future<void> _openInbox(List<ScanEvidence> evidence) async {
    if (evidence.every(
      (item) => item.barcode.isEmpty && item.text.trim().isEmpty,
    )) {
      throw const FormatException('No barcode or medicine text was captured.');
    }
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => ImportInboxScreen(
          controller: widget.controller,
          evidence: evidence,
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
          onTap: _busy ? null : () => openEditor(context, widget.controller),
        ),
        _ImportAction(
          icon: Icons.qr_code_scanner_rounded,
          title: 'Scan medicine',
          detail: 'Barcode and packaging text together.',
          onTap: _busy ? null : _scan,
        ),
        _ImportAction(
          icon: Icons.add_photo_alternate_outlined,
          title: 'Upload photo',
          detail: 'Read an existing label or medicine-list photo.',
          onTap: _busy ? null : _photo,
        ),
        _ImportAction(
          icon: Icons.video_library_outlined,
          title: 'Upload video',
          detail: 'Read medicine packs from a video on your phone.',
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
          LinearProgressIndicator(value: _total == 0 ? null : _done / _total),
          const SizedBox(height: 10),
          Text(
            _cancelRequested
                ? 'Finishing the current local step and cleaning temporary files…'
                : _total == 0
                ? 'Preparing local import…'
                : 'Reading frame $_done of $_total locally…',
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
        contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
        leading: DepthIcon(icon),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
        subtitle: Text(detail),
        trailing: const Icon(Icons.chevron_right_rounded),
        enabled: onTap != null,
        onTap: onTap,
      ),
    ),
  );
}

class ImportInboxScreen extends StatefulWidget {
  const ImportInboxScreen({
    super.key,
    required this.controller,
    required this.evidence,
    this.preparedDrafts,
  });

  final PharmacyController controller;
  final List<ScanEvidence> evidence;
  final List<MedicineScanDraft>? preparedDrafts;

  @override
  State<ImportInboxScreen> createState() => _ImportInboxScreenState();
}

class _ImportInboxScreenState extends State<ImportInboxScreen> {
  List<_ImportDraftReview> _drafts = const <_ImportDraftReview>[];
  int _ignoredFrames = 0;
  String _error = '';
  bool _loading = true;
  int _generation = 0;
  int _inventoryRevision = -1;
  final _semanticCache = <String, MedicineScanDraft>{};
  String _semanticWarning = '';
  bool _localBrainScanActive = false;
  int? _savingDraftIndex;

  @override
  void initState() {
    super.initState();
    _inventoryRevision = widget.controller.snapshot.revision;
    widget.controller.addListener(_inventoryChanged);
    unawaited(_prepare());
  }

  @override
  void dispose() {
    ++_generation;
    widget.controller.removeListener(_inventoryChanged);
    super.dispose();
  }

  void _inventoryChanged() {
    if (!mounted) return;
    if (_inventoryRevision == widget.controller.snapshot.revision) {
      setState(() {});
      return;
    }
    _inventoryRevision = widget.controller.snapshot.revision;
    unawaited(_prepare());
  }

  IntakeResolution _resolve(MedicineScanDraft draft) => resolveIntakeDraft(
    draft: draft,
    records: widget.controller.records,
    today: widget.controller.today,
  );

  Future<void> _prepare() async {
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = '';
      _semanticWarning = '';
      _localBrainScanActive = false;
    });
    try {
      final knowledge = medicineKnowledgeFromRecords(widget.controller.records);
      final payload = widget.preparedDrafts != null
          ? MedicineUnderstandingResult(
              drafts: widget.preparedDrafts!,
            ).toMessage()
          : await compute(understandMedicineEvidenceMessage, <String, Object?>{
              'evidence': widget.evidence
                  .map((item) => item.toMessage())
                  .toList(growable: false),
              'knowledge': knowledge
                  .map((entry) => entry.toMessage())
                  .toList(growable: false),
            });
      if (!mounted || generation != _generation) return;
      final understanding = MedicineUnderstandingResult.fromMessage(payload);
      final reviews = <_ImportDraftReview>[];
      final local = LocalAiService.instance;
      await local.initialize();

      String? scanModelId;
      if (widget.preparedDrafts == null) {
        try {
          final brainEnabled = await LocalBrainRoutePolicy.enabled();
          if (!mounted || generation != _generation) return;
          scanModelId = await LocalBrainRoutePolicy.captureModelId(local);
          if (!mounted || generation != _generation) return;
          if (brainEnabled &&
              scanModelId == null &&
              local.hasSelection &&
              local.scannerEnabled &&
              !local.scanReady) {
            _semanticWarning =
                'Aaris Brain is enabled, but the selected Local AI is not Ready for scan review yet. Deterministic OCR preview is being used.';
          }
        } catch (_) {
          if (!mounted || generation != _generation) return;
          scanModelId = null;
          _semanticWarning =
              'Aaris Brain state could not be loaded for this scan. Deterministic OCR preview is being used; nothing was sent externally.';
        }
      }

      var localBrainUsed = false;
      for (final original in understanding.drafts) {
        if (!mounted || generation != _generation) return;
        var draft = original;
        final leasedModelId = scanModelId;
        if (leasedModelId != null) {
          try {
            final mayReason = await LocalBrainRoutePolicy.mayReasonWith(
              local,
              leasedModelId,
            );
            if (!mounted || generation != _generation) return;
            if (!mayReason) {
              scanModelId = null;
              _semanticWarning =
                  'Aaris Brain was turned off or the selected Local AI changed during this scan. Remaining OCR drafts stay deterministic for review.';
            } else {
              final key = '$leasedModelId:${jsonEncode(original.toMessage())}';
              final candidate =
                  _semanticCache[key] ?? await local.understand(original);
              if (!mounted || generation != _generation) return;
              final leaseStillValid = await LocalBrainRoutePolicy.mayReasonWith(
                local,
                leasedModelId,
              );
              if (!mounted || generation != _generation) return;
              if (leaseStillValid) {
                draft = candidate;
                _semanticCache[key] = candidate;
                localBrainUsed = true;
              } else {
                scanModelId = null;
                _semanticWarning =
                    'Aaris Brain was turned off or its Local AI changed while OCR was being reviewed. That AI result was discarded; deterministic OCR was retained.';
              }
            }
          } catch (_) {
            _semanticWarning =
                'Local AI could not safely finish this OCR handoff. Original deterministic OCR drafts were retained; nothing was sent to an external AI.';
          }
        }
        if (!mounted || generation != _generation) return;
        final found = <String, SearchHit>{};
        if (draft.barcode.isNotEmpty) {
          for (final hit in await widget.controller.search(
            draft.barcode,
            SearchScope.all,
          )) {
            found[hit.id] = hit;
          }
        }
        final identityQuery = <String>[
          draft.name,
          draft.brand,
          draft.salt,
          draft.strength,
          draft.batchNumber,
          draft.rawText,
        ].where((value) => value.trim().isNotEmpty).join('\n');
        if (identityQuery.isNotEmpty) {
          for (final hit in await widget.controller.search(
            identityQuery,
            SearchScope.all,
          )) {
            if (found[hit.id] == null || found[hit.id]!.score < hit.score) {
              found[hit.id] = hit;
            }
          }
        }
        if (!mounted || generation != _generation) return;
        final hits = found.values.toList()
          ..sort((a, b) => b.score.compareTo(a.score));
        reviews.add(
          _ImportDraftReview(
            draft: draft,
            hits: hits.take(6).toList(growable: false),
            resolution: _resolve(draft),
          ),
        );
      }
      if (mounted && generation == _generation) {
        setState(() {
          _drafts = reviews;
          _ignoredFrames = understanding.ignoredFrames;
          _localBrainScanActive = localBrainUsed;
          _loading = false;
        });
      }
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() {
          _loading = false;
          _error = 'The import inbox could not rank these scans. Try again.';
        });
      }
    }
  }

  Future<void> _confirmAndAdd(
    int index,
    _ImportDraftReview review,
  ) async {
    if (_savingDraftIndex != null) return;

    var resolution = _resolve(review.draft);
    var decision = scanQuickAddDecision(review.draft, resolution);
    if (!decision.allowed) {
      showError(context, decision.reason);
      return;
    }

    setState(() => _savingDraftIndex = index);
    try {
      resolution = _resolve(review.draft);
      decision = scanQuickAddDecision(review.draft, resolution);
      if (!decision.allowed) {
        throw StateError(
          decision.reason.isEmpty
              ? 'Inventory changed. Review this scan again before adding it.'
              : decision.reason,
        );
      }

      final expectedRevision = widget.controller.snapshot.revision;
      final medicine = medicineFromConfirmedScan(review.draft);
      await widget.controller.save(
        medicine,
        expectedRevision: expectedRevision,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            decision.isNewBatch
                ? '${medicine.title} added as a reviewed new batch.'
                : '${medicine.title} added from the confirmed scan preview.',
          ),
        ),
      );
    } catch (error) {
      if (mounted) showError(context, error);
    } finally {
      if (mounted && _savingDraftIndex == index) {
        setState(() => _savingDraftIndex = null);
      }
    }
  }

  Future<void> _receiveExactLot(
    BuildContext context,
    _ImportDraftReview review,
  ) async {
    final expectedId = review.resolution.exactStockId;
    if (expectedId == null) return;

    IntakeResolution preflight = _resolve(review.draft);
    if (!preflight.hasExactLot ||
        preflight.exactStockId != expectedId ||
        !preflight.safeToReceive) {
      showError(
        context,
        preflight.receiveBlockReason.isNotEmpty
            ? preflight.receiveBlockReason
            : 'Inventory or scan evidence changed. Review the medicine again before receiving stock.',
      );
      return;
    }

    final current = widget.controller.snapshot.records[expectedId];
    if (current == null || current.archived) {
      showError(context, 'The exact stock entry is no longer active.');
      return;
    }

    final formKey = GlobalKey<FormState>();
    final quantityController = TextEditingController();
    final units = await showDialog<int>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Receive ${current.title}'),
        content: Form(
          key: formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                [
                  if (current.batchNumber.isNotEmpty)
                    'Batch ${current.batchNumber}',
                  if (current.expiry != null)
                    'EXP ${dateText(current.expiry!)}',
                  if (current.address.isNotEmpty) current.address,
                ].join(' · '),
                style: const TextStyle(color: muted, fontSize: 12),
              ),
              const SizedBox(height: 14),
              TextFormField(
                controller: quantityController,
                autofocus: true,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Units received',
                  helperText: 'Enter the physical units you are receiving now.',
                ),
                validator: (raw) {
                  final value = int.tryParse(raw?.trim() ?? '');
                  if (value == null || value < 1) {
                    return 'Enter a positive whole-number quantity.';
                  }
                  if (value > 100000000) {
                    return 'Quantity is above the supported limit.';
                  }
                  return null;
                },
                onFieldSubmitted: (_) {
                  if (formKey.currentState?.validate() != true) return;
                  Navigator.pop(
                    dialogContext,
                    int.parse(quantityController.text.trim()),
                  );
                },
              ),
              const SizedBox(height: 12),
              const Text(
                'Aaris will change stock quantity only. Scanned name, batch, dates, price and location cannot silently overwrite this saved lot.',
                style: TextStyle(color: muted, fontSize: 11, height: 1.35),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              if (formKey.currentState?.validate() != true) return;
              Navigator.pop(
                dialogContext,
                int.parse(quantityController.text.trim()),
              );
            },
            child: const Text('Review receipt'),
          ),
        ],
      ),
    );
    quantityController.dispose();
    if (units == null || !mounted) return;

    preflight = _resolve(review.draft);
    if (!preflight.hasExactLot ||
        preflight.exactStockId != expectedId ||
        !preflight.safeToReceive) {
      showError(
        context,
        preflight.receiveBlockReason.isNotEmpty
            ? preflight.receiveBlockReason
            : 'Inventory or scan evidence changed. Review the exact lot again.',
      );
      return;
    }

    try {
      final receiptReview = widget.controller.reviewStockAdjustment(
        expectedId,
        kind: StockAdjustmentKind.receive,
        quantity: units,
      );
      final live = widget.controller.snapshot.records[expectedId];
      if (live == null || live.archived) {
        throw StateError('The exact stock entry is no longer active.');
      }
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Confirm stock receipt'),
          content: Text(
            '${live.title}\n'
            '${live.batchNumber.isEmpty ? 'Saved lot' : 'Batch ${live.batchNumber}'}'
            '${live.address.isEmpty ? '' : ' · ${live.address}'}\n\n'
            'Current: ${receiptReview.beforeQuantity} units\n'
            'Receive: +${receiptReview.requestedQuantity} units\n'
            'After: ${receiptReview.afterQuantity} units\n\n'
            '${receiptReview.wasSold ? 'This SOLD row will be explicitly reopened. ' : ''}'
            'Only the stock quantity/lifecycle will change. OCR facts remain review evidence.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Receive stock'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
      await widget.controller.applyStockAdjustment(receiptReview);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Received $units units into ${live.title}. Inventory audit history was saved.',
          ),
        ),
      );
    } catch (error) {
      if (mounted) showError(context, error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ready = _drafts.where((item) => item.hasStrongLocalMatch).length;
    final review = _drafts.length - ready;
    return Scaffold(
      appBar: AppBar(title: const Text('Review import')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(22, 8, 22, 30),
              children: [
                const FlowSteps(['Add or scan', 'Review', 'Save'], current: 1),
                Surface(
                  color: ink,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'LOCAL REVIEW',
                        style: TextStyle(
                          color: inverseMuted,
                          fontSize: 10,
                          letterSpacing: 1.4,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        '${_drafts.length} medicine draft${_drafts.length == 1 ? '' : 's'} · $ready matched · $review need review',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 19,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'Aaris resolves trusted pack evidence against the live Medicine Database. Exact lots can use the reviewed stock-receipt flow; uncertainty never changes inventory.',
                        style: TextStyle(color: inverseMuted, fontSize: 12),
                      ),
                    ],
                  ),
                ),
                if (_localBrainScanActive)
                  const Padding(
                    padding: EdgeInsets.only(top: 10),
                    child: Text(
                      'Aaris Brain · raw OCR was handed to the active Local AI on-device before this preview. Confirmed fields still require your tap before inventory changes.',
                      style: TextStyle(
                        color: primary,
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                if (_error.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 14),
                    child: Text(_error, style: const TextStyle(color: red)),
                  ),
                if (_semanticWarning.isNotEmpty)
                  Text(_semanticWarning, style: const TextStyle(color: amber)),
                if (_drafts.isEmpty && _error.isEmpty)
                  const Padding(
                    padding: EdgeInsets.only(top: 20),
                    child: Text(
                      'No readable medicine evidence was found. Try a closer, steadier scan.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: muted),
                    ),
                  ),
                for (var index = 0; index < _drafts.length; index++)
                  _draftReview(context, _drafts[index], index),
                if (_ignoredFrames > 0)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(
                      '$_ignoredFrames duplicate or unreadable frame${_ignoredFrames == 1 ? '' : 's'} ignored automatically.',
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: muted, fontSize: 11),
                    ),
                  ),
                const Padding(
                  padding: EdgeInsets.only(top: 10),
                  child: Text(
                    'OCR text stays separate from your personal note. Every auto-filled fact remains review evidence until you explicitly save a reviewed action.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: muted, fontSize: 11),
                  ),
                ),
              ],
            ),
    );
  }

  Widget _resolutionCard(
    BuildContext context,
    _ImportDraftReview review,
  ) {
    final resolution = review.resolution;
    final (title, icon, tone) = switch (resolution.kind) {
      IntakeResolutionKind.exactLot => (
        'Exact saved lot identified',
        Icons.verified_rounded,
        green,
      ),
      IntakeResolutionKind.sameProduct => (
        'Existing medicine · batch needs review',
        Icons.inventory_2_outlined,
        primary,
      ),
      IntakeResolutionKind.ambiguous => (
        'Ambiguous stock identity',
        Icons.warning_amber_rounded,
        red,
      ),
      IntakeResolutionKind.needsReview => (
        'Verification required',
        Icons.fact_check_outlined,
        amber,
      ),
      IntakeResolutionKind.newStock => (
        'No exact local stock found',
        Icons.add_box_outlined,
        primary,
      ),
    };
    final exactId = resolution.exactStockId;
    final exact = exactId == null
        ? null
        : widget.controller.snapshot.records[exactId];

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Surface(
        color: tone.withValues(alpha: .08),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: tone, size: 21),
                const SizedBox(width: 9),
                Expanded(
                  child: Text(
                    title,
                    style: TextStyle(
                      color: tone,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              resolution.reason,
              style: const TextStyle(color: muted, fontSize: 12, height: 1.4),
            ),
            if (exact != null && !exact.archived) ...[
              const SizedBox(height: 10),
              Text(
                [
                  exact.title,
                  if (exact.batchNumber.isNotEmpty) 'Batch ${exact.batchNumber}',
                  if (exact.expiry != null) 'EXP ${dateText(exact.expiry!)}',
                  if (exact.quantity != null) '${exact.quantity} units',
                  if (exact.address.isNotEmpty) exact.address,
                ].join(' · '),
                style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12),
              ),
              if (resolution.receiveBlockReason.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  resolution.receiveBlockReason,
                  style: const TextStyle(
                    color: amber,
                    fontWeight: FontWeight.w700,
                    fontSize: 11,
                    height: 1.35,
                  ),
                ),
              ],
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  if (resolution.safeToReceive)
                    FilledButton.icon(
                      onPressed: () => _receiveExactLot(context, review),
                      icon: const Icon(Icons.add_shopping_cart_rounded),
                      label: const Text('Receive into exact lot'),
                    ),
                  OutlinedButton.icon(
                    onPressed: () => openEditor(
                      context,
                      widget.controller,
                      record: exact,
                    ),
                    icon: const Icon(Icons.open_in_new_rounded),
                    label: const Text('Open exact stock'),
                  ),
                ],
              ),
            ],
            if (resolution.kind == IntakeResolutionKind.ambiguous &&
                resolution.candidateStockIds.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                '${resolution.candidateStockIds.length} saved rows need manual verification. No receive shortcut is enabled.',
                style: const TextStyle(color: red, fontSize: 11),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _draftReview(
    BuildContext context,
    _ImportDraftReview review,
    int index,
  ) {
    final draft = review.draft;
    final title = draft.name.isEmpty ? 'Medicine ${index + 1}' : draft.name;
    final quickAdd = scanQuickAddDecision(draft, review.resolution);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionHeading('$title · ${_confidence(draft.overallConfidence)}'),
        _resolutionCard(context, review),
        if (review.hits.isNotEmpty &&
            review.resolution.kind != IntakeResolutionKind.exactLot) ...[
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              review.hasStrongLocalMatch
                  ? 'Existing stock candidates found'
                  : 'Possible existing stock — verify carefully',
              style: const TextStyle(color: muted, fontSize: 12),
            ),
          ),
          for (final hit in review.hits.take(3)) _hit(context, hit),
        ],
        Surface(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'AUTO-FILLED FACTS',
                style: TextStyle(
                  color: muted,
                  fontSize: 10,
                  letterSpacing: 1.2,
                ),
              ),
              const SizedBox(height: 10),
              for (final entry in <(String, String)>[
                ('Medicine', 'name'),
                ('Brand', 'brand'),
                ('Salt / composition', 'salt'),
                ('Strength', 'strength'),
                ('Form', 'form'),
                ('Manufacturer', 'manufacturer'),
                ('MFG', 'mfg'),
                ('EXP', 'expiry'),
                ('Batch', 'batchNumber'),
                ('Barcode', 'barcode'),
              ])
                if (!draft.field(entry.$2).isEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 5),
                    child: Text(
                      '${entry.$1}: ${draft.field(entry.$2).value} · ${_confidence(draft.field(entry.$2).confidence)}${draft.field(entry.$2).conflicted ? ' · verify conflict' : ''}',
                      style: TextStyle(
                        color: draft.field(entry.$2).needsReview ? amber : ink,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
              if (draft.printedPackSize.isNotEmpty)
                Text(
                  'Printed pack: ${draft.printedPackSize} · not stock quantity',
                  style: const TextStyle(color: muted, fontSize: 11),
                ),
              if (draft.printedMrp.isNotEmpty)
                Text(
                  'Printed MRP: ${draft.printedMrp} · not entered amount',
                  style: const TextStyle(color: muted, fontSize: 11),
                ),
              const SizedBox(height: 10),
              SelectableText(
                draft.rawText.isEmpty
                    ? 'No readable packaging text.'
                    : draft.rawText,
                maxLines: 12,
                style: const TextStyle(color: muted, fontSize: 11),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        if (review.resolution.kind != IntakeResolutionKind.exactLot)
          if (quickAdd.allowed) ...[
            FilledButton.icon(
              onPressed: _savingDraftIndex == null
                  ? () => _confirmAndAdd(index, review)
                  : null,
              icon: _savingDraftIndex == index
                  ? const SizedBox(
                      width: 17,
                      height: 17,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.check_circle_outline_rounded),
              label: Text(
                _savingDraftIndex == index ? 'Adding…' : quickAdd.actionLabel,
              ),
            ),
            const SizedBox(height: 7),
            OutlinedButton.icon(
              onPressed: _savingDraftIndex == null
                  ? () => openEditor(
                      context,
                      widget.controller,
                      scanDraft: draft,
                    )
                  : null,
              icon: const Icon(Icons.edit_outlined),
              label: const Text('Edit preview first'),
            ),
          ] else
            (review.resolution.kind == IntakeResolutionKind.sameProduct
                ? OutlinedButton.icon(
                    onPressed: () => openEditor(
                      context,
                      widget.controller,
                      scanDraft: draft,
                    ),
                    icon: const Icon(Icons.add_box_outlined),
                    label: const Text('Review as a new batch'),
                  )
                : FilledButton.icon(
                    onPressed: () => openEditor(
                      context,
                      widget.controller,
                      scanDraft: draft,
                    ),
                    icon: const Icon(Icons.rate_review_outlined),
                    label: Text(
                      review.resolution.kind == IntakeResolutionKind.newStock
                          ? 'Review & create new medicine ${index + 1}'
                          : 'Review scanned facts manually',
                    ),
                  )),
      ],
    );
  }

  String _confidence(double value) => value >= .85
      ? 'high confidence'
      : value >= .68
      ? 'medium confidence'
      : 'review needed';

  Widget _hit(BuildContext context, SearchHit hit) {
    final record = widget.controller.snapshot.records[hit.id];
    if (record == null || record.archived) return const SizedBox.shrink();
    return MedicineCard(
      record: record,
      settings: widget.controller.settings,
      today: widget.controller.today,
      onTap: () => openEditor(context, widget.controller, record: record),
      matchLabel: hit.uncertain
          ? '${hit.confidence} confidence · ${hit.reason} · verify before editing'
          : '${hit.confidence} confidence · ${hit.reason} · matched from import',
    );
  }
}

class _ImportDraftReview {
  const _ImportDraftReview({
    required this.draft,
    required this.hits,
    required this.resolution,
  });

  final MedicineScanDraft draft;
  final List<SearchHit> hits;
  final IntakeResolution resolution;

  bool get hasStrongLocalMatch =>
      resolution.kind == IntakeResolutionKind.exactLot ||
      resolution.kind == IntakeResolutionKind.sameProduct ||
      hits.any((hit) => !hit.uncertain);
}
