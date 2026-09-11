import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../domain/intake_resolution.dart';
import '../domain/inventory.dart';
import '../domain/medicine.dart';
import '../domain/medicine_resolution_v2.dart';
import '../domain/medicine_scan_commit.dart';
import '../domain/medicine_understanding.dart';
import '../domain/search.dart';
import '../services/backup_service.dart';
import '../services/canonical_medicine_catalog_service.dart';
import '../services/local_ai_service.dart';
import '../services/local_brain_route_policy.dart';
import '../services/media_import_service.dart';
import '../services/medicine_intake_service.dart';
import '../services/scan_service.dart';
import '../state/pharmacy_controller.dart';
import 'design.dart';
import 'editor_screen.dart';
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
      MaterialPageRoute(builder: (_) => const ScannerScreen(autoSubmit: true)),
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

      // Copy + durable job insert happen before this call returns. OCR and Local
      // AI may continue afterwards, but a process death cannot erase the chosen
      // source or its queue identity once the user sees it in the intake panel.
      final queue = MedicineIntakeService.instance;
      await queue.attach(
        () => widget.controller.records,
        revision: () => widget.controller.snapshot.revision,
      );
      if (!mounted || generation != _generation) return;
      await queue.addFile(source.path, kind: kind, title: source.name);
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

  Future<void> _openInbox(
    List<ScanEvidence> evidence, {
    bool autoSaveReadyDrafts = false,
  }) async {
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
          autoSaveReadyDrafts: autoSaveReadyDrafts,
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
          message: 'Choose the easiest way to start. Review captured details before saving.',
          icon: Icons.add_box_outlined,
        ),
        const FlowSteps(['Add or scan', 'Review', 'Save']),
        _ImportAction(
          icon: Icons.burst_mode_outlined,
          title: 'Queued photo / video capture',
          detail: 'Rapid capture, resumable processing, selected local AI and saved drafts.',
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
          detail: 'Capture once · on-device OCR · Local AI when enabled · smart deterministic fallback · verified local scans can save automatically.',
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
    this.autoSaveReadyDrafts = false,
  });

  final PharmacyController controller;
  final List<ScanEvidence> evidence;
  final List<MedicineScanDraft>? preparedDrafts;

  /// True only for the direct camera scanner. Photo/video/text and prepared
  /// batch imports preserve explicit review semantics.
  final bool autoSaveReadyDrafts;

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
  bool _autoSaveAttempted = false;

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

  bool _recoverableLocalTransportFailure(Object error) {
    if (error is FormatException || error is ArgumentError) return false;
    final message = error.toString().toLowerCase();
    if (message.contains('cancel') ||
        message.contains('busy') ||
        message.contains('select a local model') ||
        message.contains('selected model is missing') ||
        message.contains('model file is incomplete') ||
        message.contains('invalid model') ||
        message.contains('unsupported context')) {
      return false;
    }
    return message.contains('runtime') ||
        message.contains('transport') ||
        message.contains('connection') ||
        message.contains('closed') ||
        message.contains('isolate') ||
        message.contains('native');
  }

  bool _localLeaseContention(Object error) {
    final message = error.toString().toLowerCase();
    return message.contains('local ai is busy') ||
        message.contains('runtime is unavailable or still processing') ||
        message.contains('runtime is busy or closing') ||
        message.contains('runtime is still processing a failed model load');
  }

  Future<bool> _routeStillOwnsScan(
    LocalAiService local,
    String routedModelId,
  ) async =>
      await LocalBrainRoutePolicy.mayReasonWith(local, routedModelId) &&
      local.activeId == routedModelId;

  Future<MedicineScanDraft> _understandWithRecovery(
    LocalAiService local,
    String routedModelId,
    MedicineScanDraft draft,
  ) async {
    var transportRecovered = false;
    while (true) {
      try {
        return await local.understand(draft);
      } catch (error, stack) {
        // mayReasonWith() closes the common busy window, but another foreground
        // Send can still acquire the single native lease in the final event-loop
        // gap before understand(). Treat that as queue contention, never as an
        // extraction failure. Re-run the full owner-switch/model check and retry
        // the exact same OCR draft without advancing or replacing evidence.
        if (_localLeaseContention(error)) {
          if (!await _routeStillOwnsScan(local, routedModelId)) {
            throw StateError(
              'Aaris Brain route changed while this scan was waiting for Local AI. Deterministic OCR draft retained for review.',
            );
          }
          continue;
        }

        if (transportRecovered || !_recoverableLocalTransportFailure(error)) {
          Error.throwWithStackTrace(error, stack);
        }
        transportRecovered = true;

        // One genuine runtime/transport failure gets one clean-runtime repair.
        // suspend() itself can lose a narrow lease race to a foreground Send, so
        // wait/revalidate and retry the retirement rather than discarding this
        // scan. Never retry malformed model output or validation failures.
        while (true) {
          try {
            await local.suspend();
            break;
          } catch (suspendError) {
            if (!_localLeaseContention(suspendError) ||
                !await _routeStillOwnsScan(local, routedModelId)) {
              Error.throwWithStackTrace(error, stack);
            }
          }
        }
        if (!await _routeStillOwnsScan(local, routedModelId)) {
          throw StateError(
            'Aaris Brain route changed while recovering this scan. Deterministic OCR draft retained for review.',
          );
        }
      }
    }
  }

  Future<void> _prepare() async {
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = '';
      _semanticWarning = '';
      _localBrainScanActive = false;
    });
    try {
      final local = LocalAiService.instance;
      String? scanModelId;

      // The normal ImportInbox is privacy-first and local by construction.
      // A configured cloud API is not scan consent. Only the separate
      // CloudScanReviewScreen, reached from the explicit "Scan with cloud AI"
      // choice, may send bounded OCR outside the device.
      if (widget.preparedDrafts == null) {
        try {
          final brainEnabled = await LocalBrainRoutePolicy.enabled();
          if (!mounted || generation != _generation) return;
          if (brainEnabled) {
            scanModelId = await LocalBrainRoutePolicy.captureModelId(local);
            if (!mounted || generation != _generation) return;
            if (scanModelId == null) {
              _semanticWarning =
                  local.hasSelection && local.scannerEnabled && !local.scanReady
                  ? 'Aaris Brain is enabled, but the selected Local AI is not Ready for scan review yet. Deterministic on-device extraction is being used.'
                  : 'Aaris Brain is enabled, but no scan-ready Local AI route is available right now. Deterministic on-device extraction is being used; no cloud fallback is allowed from this scan lane.';
            }
          }
        } catch (_) {
          if (!mounted || generation != _generation) return;
          scanModelId = null;
          _semanticWarning = 'Local AI route state could not be loaded for this scan. Smart deterministic on-device extraction is being used; nothing was sent externally.';
        }
      }

      final knowledge = medicineKnowledgeFromRecords(widget.controller.records);
      final catalogue = widget.preparedDrafts == null
          ? await CanonicalMedicineCatalogService.instance
                .candidatesForEvidence(widget.evidence)
          : const <CanonicalMedicineProduct>[];
      if (!mounted || generation != _generation) return;

      // Direct camera and durable photo/video must resolve the same physical
      // pack with the same product-first engine. Tier-2 catalogue lookup stays
      // local and bounded; only identity candidates cross the isolate boundary.
      // Prepared durable drafts have already crossed Resolver V2, so they are
      // never reinterpreted a second time here.
      final payload = widget.preparedDrafts != null
          ? MedicineUnderstandingResult(drafts: widget.preparedDrafts!)
                .toMessage()
          : await compute(
              understandMedicineEvidenceV2Message,
              <String, Object?>{
                'evidence': widget.evidence
                    .map((item) => item.toMessage())
                    .toList(growable: false),
                'knowledge': knowledge
                    .map((entry) => entry.toMessage())
                    .toList(growable: false),
                'catalog': catalogue
                    .map((entry) => entry.toMessage())
                    .toList(growable: false),
              },
            );
      if (!mounted || generation != _generation) return;
      final understanding = MedicineUnderstandingResult.fromMessage(payload);
      final reviews = <_ImportDraftReview>[];

      var localBrainUsed = false;
      for (final original in understanding.drafts) {
        if (!mounted || generation != _generation) return;
        var draft = original;
        ScanAutoSaveVerifier? autoSaveVerifier;
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
              _semanticWarning = 'Aaris Brain was turned off, its model changed, or Local AI is busy with model setup. Remaining OCR drafts stay deterministic for review.';
            } else {
              // mayReasonWith intentionally lets the current selected model own
              // a queued scan after a healthy model switch. Cache and validate
              // against that actual route, never the stale capture witness.
              final routedModelId = local.activeId;
              if (routedModelId == null) {
                scanModelId = null;
                _semanticWarning = 'The Local AI route disappeared before OCR reasoning started. Deterministic OCR preview is being used.';
              } else {
                final key =
                    '$routedModelId:${jsonEncode(original.toMessage())}';
                final candidate =
                    _semanticCache[key] ??
                    await _understandWithRecovery(
                      local,
                      routedModelId,
                      original,
                    );
                if (!mounted || generation != _generation) return;
                final leaseStillValid =
                    await LocalBrainRoutePolicy.mayReasonWith(
                      local,
                      routedModelId,
                    ) &&
                    local.activeId == routedModelId;
                if (!mounted || generation != _generation) return;
                if (leaseStillValid) {
                  draft = candidate;
                  _semanticCache[key] = candidate;
                  localBrainUsed = true;
                  if (local.isModelScanVerified(routedModelId)) {
                    autoSaveVerifier = ScanAutoSaveVerifier.localAi;
                  }
                  scanModelId = routedModelId;
                } else {
                  scanModelId = null;
                  _semanticWarning = 'Aaris Brain was turned off or its Local AI changed while OCR was being reviewed. That AI result was discarded; deterministic OCR was retained.';
                }
              }
            }
          } catch (_) {
            _semanticWarning = 'Local AI could not safely finish this OCR handoff. Original deterministic OCR drafts were retained; nothing was sent to an external AI.';
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
            autoSaveVerifier: autoSaveVerifier,
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
        if (widget.autoSaveReadyDrafts &&
            reviews.length == 1 &&
            !_autoSaveAttempted) {
          unawaited(_attemptScannerAutoSave(generation, reviews.single));
        }
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

  Future<void> _attemptScannerAutoSave(
    int preparedGeneration,
    _ImportDraftReview review,
  ) async {
    if (!widget.autoSaveReadyDrafts ||
        _autoSaveAttempted ||
        !mounted ||
        preparedGeneration != _generation) {
      return;
    }
    _autoSaveAttempted = true;

    var resolution = _resolve(review.draft);
    var decision = scanAutoSaveDecision(
      review.draft,
      resolution,
      verifier: review.autoSaveVerifier,
    );
    if (!decision.allowed) {
      setState(() {
        _semanticWarning = 'Auto-save paused · ${decision.reason}';
      });
      return;
    }

    setState(() => _savingDraftIndex = 0);
    try {
      // Re-resolve against the live database immediately before CAS. Any lot,
      // duplicate or concurrent inventory change fails closed rather than
      // turning a probabilistic AI result into a second stock row.
      resolution = _resolve(review.draft);
      decision = scanAutoSaveDecision(
        review.draft,
        resolution,
        verifier: review.autoSaveVerifier,
      );
      if (!decision.allowed) {
        throw StateError(
          decision.reason.isEmpty
              ? 'Inventory changed. Review this scan before saving.'
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
                ? '${medicine.title} auto-saved as a verified new batch.'
                : '${medicine.title} verified by ${scanAutoSaveVerifierLabel(review.autoSaveVerifier!)} and auto-saved.',
          ),
        ),
      );
    } catch (error) {
      if (mounted) {
        setState(() {
          _semanticWarning = 'Auto-save paused safely · $error';
        });
      }
    } finally {
      if (mounted && _savingDraftIndex == 0) {
        setState(() => _savingDraftIndex = null);
      }
    }
  }

  Future<void> _confirmAndAdd(int index, _ImportDraftReview review) async {
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
        preflight.receiveBlockReason.isNotEmpty ? preflight.receiveBlockReason : 'Inventory or scan evidence changed. Review the medicine again before receiving stock.',
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
          ? AnimatedBuilder(
              animation: LocalAiService.instance,
              builder: (context, _) {
                final local = LocalAiService.instance;
                final scanThinking =
                    local.busy &&
                    local.status.toLowerCase().contains('scan preview');
                final message = scanThinking
                    ? local.status
                    : local.busy
                    ? 'Aaris Brain is finishing the current Local AI request, then it will review this scan…'
                    : 'Preparing deterministic OCR and the medicine preview…';
                return Center(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 30),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const CircularProgressIndicator(),
                        const SizedBox(height: 16),
                        Text(
                          message,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: muted,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            )
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
                        'SCAN REVIEW',
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
                  Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: Text(
                      widget.autoSaveReadyDrafts
                          ? 'Aaris Brain · raw OCR was handed to the active Local AI on-device. One scan-verified, unambiguous medicine can save automatically; uncertainty and duplicates stop here for review.'
                          : 'Aaris Brain · raw OCR was handed to the active Local AI on-device before this preview. Confirmed fields still require your tap before inventory changes.',
                      style: const TextStyle(
                        color: primary,
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                if (widget.autoSaveReadyDrafts && !_localBrainScanActive)
                  const Padding(
                    padding: EdgeInsets.only(top: 10),
                    child: Text(
                      'Aaris Smart Extractor · on-device OCR + pharmacy NER/rules auto-filled supported medicine fields. No source-verified AI route completed this scan, so the preview stays review-first instead of writing uncertain OCR directly to stock.',
                      style: TextStyle(
                        color: amber,
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
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Text(
                    widget.autoSaveReadyDrafts
                        ? 'OCR text stays separate from your personal note. Automatic save is allowed only after source-verified Local AI plus deterministic duplicate, lot, chronology, confidence and revision checks. With no Local AI route, the smart on-device extractor still auto-fills the preview for review; cloud use requires the separate explicit Cloud AI scan action.'
                        : 'OCR text stays separate from your personal note. Every auto-filled fact remains review evidence until you explicitly save a reviewed action.',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: muted, fontSize: 11),
                  ),
                ),
              ],
            ),
    );
  }

  Widget _resolutionCard(BuildContext context, _ImportDraftReview review) {
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
                    style: TextStyle(color: tone, fontWeight: FontWeight.w800),
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
                  if (exact.batchNumber.isNotEmpty)
                    'Batch ${exact.batchNumber}',
                  if (exact.expiry != null) 'EXP ${dateText(exact.expiry!)}',
                  if (exact.quantity != null) '${exact.quantity} units',
                  if (exact.address.isNotEmpty) exact.address,
                ].join(' · '),
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 12,
                ),
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
                    onPressed: () =>
                        openEditor(context, widget.controller, record: exact),
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
                  ? () =>
                        openEditor(context, widget.controller, scanDraft: draft)
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
    required this.autoSaveVerifier,
  });

  final MedicineScanDraft draft;
  final List<SearchHit> hits;
  final IntakeResolution resolution;
  final ScanAutoSaveVerifier? autoSaveVerifier;

  bool get hasStrongLocalMatch =>
      resolution.kind == IntakeResolutionKind.exactLot ||
      resolution.kind == IntakeResolutionKind.sameProduct ||
      hits.any((hit) => !hit.uncertain);
}
