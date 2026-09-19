import 'dart:async';

import 'package:flutter/material.dart';

import '../domain/intake_match_presentation.dart';
import '../domain/intake_resolution.dart';
import '../domain/inventory.dart';
import '../domain/medicine.dart';
import '../domain/medicine_scan_commit.dart';
import '../domain/medicine_understanding.dart';
import '../domain/search.dart';
import '../services/medicine_review_pipeline.dart';
import '../services/offline_recognition_memory_service.dart';
import '../state/operational_context.dart';
import '../state/pharmacy_controller.dart';
import 'design.dart';
import 'editor_screen.dart';

/// The one pharmacist-facing review surface for every medicine intake source.
///
/// Camera, durable photo/video, rapid capture, text/file/paste and explicit
/// cloud assistance all enter through MedicineReviewPipeline, then land here.
/// Source-specific intelligence stays underneath; the visible journey is always
/// one extracted medicine, one Next action and a ranked list of saved matches.
class MedicineReviewScreen extends StatefulWidget {
  const MedicineReviewScreen({
    super.key,
    required this.controller,
    required this.input,
  });

  final PharmacyController controller;
  final MedicineReviewInput input;

  @override
  State<MedicineReviewScreen> createState() => _MedicineReviewScreenState();
}

class _MedicineReviewScreenState extends State<MedicineReviewScreen> {
  late final MedicineReviewPipeline _pipeline;
  List<PreparedMedicineReviewDraft> _drafts =
      const <PreparedMedicineReviewDraft>[];
  int _index = 0;
  int _sourceGeneration = 0;
  int _matchGeneration = 0;
  int _inventoryRevision = -1;
  Object? _inventoryRecords;
  DateTime? _inventoryDay;
  bool _controllerListening = false;
  bool _sourceLoading = true;
  bool _matchLoading = false;
  bool _busy = false;
  bool _autoSaveAttempted = false;
  String _error = '';
  String _warning = '';
  String _routeLabel = '';
  int _ignoredFrames = 0;
  _MedicineReview? _review;

  @override
  void initState() {
    super.initState();
    _pipeline = MedicineReviewPipeline();
    _captureInventoryWitness();
    unawaited(_loadSource());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final active = TickerMode.valuesOf(context).enabled;
    if (active == _controllerListening) return;
    if (!active) {
      widget.controller.removeListener(_inventoryChanged);
      _controllerListening = false;
      return;
    }

    widget.controller.addListener(_inventoryChanged);
    _controllerListening = true;
    // A covered Navigator route may have missed stock edits or a civil-day
    // rollover. Catch up exactly once from the authoritative inputs when the
    // pharmacist returns instead of doing matching work behind another screen.
    _inventoryChanged();
  }

  @override
  void dispose() {
    ++_sourceGeneration;
    ++_matchGeneration;
    if (_controllerListening) {
      widget.controller.removeListener(_inventoryChanged);
    }
    _pipeline.cancel();
    super.dispose();
  }

  void _captureInventoryWitness() {
    final snapshot = widget.controller.snapshot;
    _inventoryRevision = snapshot.revision;
    _inventoryRecords = snapshot.records;
    _inventoryDay = widget.controller.today;
  }

  void _inventoryChanged() {
    if (!mounted) return;
    final snapshot = widget.controller.snapshot;
    final day = widget.controller.today;
    final revision = snapshot.revision;
    final recordsChanged = !identical(_inventoryRecords, snapshot.records);
    final dayChanged = _inventoryDay != day;
    if (revision == _inventoryRevision && !recordsChanged && !dayChanged) return;

    _inventoryRevision = revision;
    _inventoryRecords = snapshot.records;
    _inventoryDay = day;

    // Matching and intake resolution consume medicine rows and the civil day.
    // Supplier/settings/sales/audit-only publications must not rerun fuzzy
    // matching, and inactive routes do not stay subscribed at all.
    if (!recordsChanged && !dayChanged) return;
    if (_sourceLoading || _busy || _drafts.isEmpty) return;
    unawaited(_prepareMatches());
  }

  Future<void> _loadSource() async {
    final generation = ++_sourceGeneration;
    setState(() {
      _sourceLoading = true;
      _matchLoading = false;
      _error = '';
      _warning = '';
      _review = null;
    });
    try {
      final preparation = await _pipeline.prepare(
        widget.input,
        widget.controller.records,
      );
      if (!mounted || generation != _sourceGeneration) return;
      setState(() {
        _drafts = preparation.drafts;
        _ignoredFrames = preparation.ignoredFrames;
        _warning = preparation.warning;
        _routeLabel = preparation.routeLabel;
        _sourceLoading = false;
        _index = 0;
      });
      if (_drafts.isEmpty) {
        setState(() => _error = 'No medicine was available to review.');
        return;
      }
      await _prepareMatches();
    } catch (error) {
      if (!mounted || generation != _sourceGeneration) return;
      setState(() {
        _sourceLoading = false;
        _error = _cleanError(error).isEmpty
            ? 'Medicine review could not be prepared. Try again.'
            : _cleanError(error);
      });
    }
  }

  PreparedMedicineReviewDraft get _current => _drafts[_index];

  IntakeResolution _resolve(MedicineScanDraft draft) => resolveIntakeDraft(
        draft: draft,
        records: widget.controller.records,
        today: widget.controller.today,
      );

  /// A nested editor is not allowed to use the inventory's global revision as
  /// its completion signal. Any unrelated stock write may advance that revision
  /// while this route is open. Existing-stock completion is therefore bound to
  /// the exact row that this review handed to the editor. The current immutable
  /// scan draft is carried only as post-save learning provenance; the saved row
  /// remains the editor's field authority.
  Future<bool> _editExistingForScan(
    Medicine record,
    MedicineScanDraft scanDraft,
  ) async {
    if (_busy) return false;
    final beforeRevision = record.revision;
    setState(() => _busy = true);
    try {
      await openEditor(
        context,
        widget.controller,
        record: record,
        scanDraft: scanDraft,
      );
      if (!mounted) return false;
      final current = widget.controller.snapshot.records[record.id];
      return current != null &&
          !current.archived &&
          !current.sold &&
          current.revision > beforeRevision &&
          widget.controller.operationalTargetId == record.id;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// A new scan has no stock ID before the editor opens. The editor remembers
  /// the exact row only after a successful save, and scan OCR is hidden immutable
  /// provenance in that editor. Requiring both prevents an unrelated inventory
  /// write from being mistaken for this scan's save.
  Future<bool> _editNewScanForResult(MedicineScanDraft draft) async {
    if (_busy) return false;
    // InventorySnapshot is immutable. Keep the pre-editor map itself as the
    // witness instead of copying every stock ID on the UI isolate before
    // navigation. This preserves the exact "must be a newly created row"
    // safety check with O(1) lookup and no inventory-sized allocation.
    final beforeRecords = widget.controller.snapshot.records;
    final previousTargetId = widget.controller.operationalTargetId;
    setState(() => _busy = true);
    try {
      await openEditor(context, widget.controller, scanDraft: draft);
      if (!mounted) return false;
      final targetId = widget.controller.operationalTargetId;
      if (targetId == null ||
          targetId == previousTargetId ||
          beforeRecords.containsKey(targetId)) {
        return false;
      }
      final saved = widget.controller.snapshot.records[targetId];
      if (saved == null || saved.archived || saved.sold) return false;

      final expectedOcr = draft.searchableOcrText.trim();
      if (expectedOcr.isNotEmpty) {
        return saved.ocrText == expectedOcr;
      }
      final expectedBarcode = normalize(draft.barcode);
      return expectedBarcode.isNotEmpty &&
          normalize(saved.barcode) == expectedBarcode;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _prepareMatches() async {
    if (_drafts.isEmpty || _index >= _drafts.length) return;
    final generation = ++_matchGeneration;
    setState(() {
      _matchLoading = true;
      _error = '';
    });
    try {
      final prepared = _current;
      final draft = prepared.draft;
      final resolution = _resolve(draft);
      final found = <String, SearchHit>{};

      if (draft.barcode.trim().isNotEmpty) {
        for (final hit in await widget.controller.search(
          draft.barcode,
          SearchScope.all,
        )) {
          found[hit.id] = hit;
        }
      }

      // Raw OCR contains legal text, addresses, prices and storage directions.
      // It stays evidence, not a fuzzy inventory query. Match only identity facts.
      final identityParts = <String>{
        confirmedScanName(draft),
        draft.brand,
        draft.salt,
        draft.strength,
        confirmedScanForm(draft),
        draft.manufacturer,
        draft.batchNumber,
      }.where((value) => value.trim().isNotEmpty).toList(growable: false);
      if (identityParts.isNotEmpty) {
        final query = identityParts.join('\n');
        for (final hit in await widget.controller.search(
          query,
          SearchScope.all,
        )) {
          final previous = found[hit.id];
          if (previous == null || previous.score < hit.score) {
            found[hit.id] = hit;
          }
        }
      }

      if (!mounted || generation != _matchGeneration) return;
      final hits = found.values.toList(growable: false)
        ..sort((a, b) => b.score.compareTo(a.score));
      final matches = rankIntakeMatches(resolution, hits, limit: 8);
      setState(() {
        _review = _MedicineReview(
          prepared: prepared,
          resolution: resolution,
          matches: matches,
        );
        _matchLoading = false;
      });

      if (widget.input.autoSaveReadyDrafts &&
          _drafts.length == 1 &&
          !_autoSaveAttempted) {
        _autoSaveAttempted = true;
        unawaited(_attemptAutoSave());
      }
    } catch (_) {
      if (!mounted || generation != _matchGeneration) return;
      setState(() {
        _matchLoading = false;
        _error = 'Saved medicines could not be checked. Try again.';
      });
    }
  }

  Future<void> _attemptAutoSave() async {
    if (!mounted || _busy || _review == null) return;
    final review = _review!;
    var resolution = _resolve(review.draft);
    var decision = scanAutoSaveDecision(
      review.draft,
      resolution,
      verifier: review.prepared.autoSaveVerifier,
    );
    if (!decision.allowed) return;

    setState(() => _busy = true);
    try {
      resolution = _resolve(review.draft);
      decision = scanAutoSaveDecision(
        review.draft,
        resolution,
        verifier: review.prepared.autoSaveVerifier,
      );
      if (!decision.allowed) return;
      final expectedRevision = widget.controller.snapshot.revision;
      final medicine = medicineFromConfirmedScan(review.draft);
      await widget.controller.save(
        medicine,
        expectedRevision: expectedRevision,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${medicine.title} saved.')),
      );
      Navigator.pop(context, true);
    } catch (_) {
      if (mounted) await _prepareMatches();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _next() async {
    if (_busy || _sourceLoading || _matchLoading || _review == null) return;
    final review = _review!;
    final liveResolution = _resolve(review.draft);

    if (liveResolution.kind == IntakeResolutionKind.exactLot) {
      final id = liveResolution.exactStockId;
      if (id == null) {
        await _editScannedDraft(review.draft);
        return;
      }
      if (liveResolution.safeToReceive) {
        await _receiveExactLot(id, review.draft);
      } else {
        final record = widget.controller.snapshot.records[id];
        if (record == null || record.archived) {
          await _prepareMatches();
          return;
        }
        final saved = await _editExistingForScan(record, review.draft);
        if (!mounted) return;
        if (saved) {
          await _advanceOrFinish();
        } else {
          await _prepareMatches();
        }
      }
      return;
    }

    final quick = scanQuickAddDecision(review.draft, liveResolution);
    if (quick.allowed) {
      await _saveConfirmed(review.draft, liveResolution, quick);
      return;
    }
    await _editScannedDraft(review.draft);
  }

  Future<void> _saveConfirmed(
    MedicineScanDraft draft,
    IntakeResolution resolution,
    ScanQuickAddDecision decision,
  ) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final liveResolution = _resolve(draft);
      final liveDecision = scanQuickAddDecision(draft, liveResolution);
      if (!liveDecision.allowed ||
          liveDecision.isNewBatch != decision.isNewBatch ||
          liveResolution.kind != resolution.kind) {
        throw StateError('Saved medicines changed. Check the matches again.');
      }

      final expectedRevision = widget.controller.snapshot.revision;
      final medicine = medicineFromConfirmedScan(draft);
      await widget.controller.save(
        medicine,
        expectedRevision: expectedRevision,
      );
      await OfflineRecognitionMemoryService.instance.learnFromConfirmedScan(
        draft,
        medicine,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            liveDecision.isNewBatch
                ? '${medicine.title} added as a new batch.'
                : '${medicine.title} added to your medicines.',
          ),
        ),
      );
      await _advanceOrFinish();
    } catch (error) {
      if (mounted) showError(context, error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _editScannedDraft(MedicineScanDraft draft) async {
    final saved = await _editNewScanForResult(draft);
    if (!mounted) return;
    if (saved) {
      await _advanceOrFinish();
    } else {
      await _prepareMatches();
    }
  }

  Future<void> _advanceOrFinish() async {
    if (!mounted) return;
    if (_index + 1 >= _drafts.length) {
      Navigator.pop(context, true);
      return;
    }
    setState(() {
      _index++;
      _review = null;
      _error = '';
      _autoSaveAttempted = true;
    });
    _captureInventoryWitness();
    await _prepareMatches();
  }

  Future<void> _receiveExactLot(
    String expectedId,
    MedicineScanDraft draft,
  ) async {
    var resolution = _resolve(draft);
    if (!resolution.hasExactLot ||
        resolution.exactStockId != expectedId ||
        !resolution.safeToReceive) {
      await _prepareMatches();
      return;
    }
    final current = widget.controller.snapshot.records[expectedId];
    if (current == null || current.archived) {
      await _prepareMatches();
      return;
    }

    final formKey = GlobalKey<FormState>();
    final quantityController = TextEditingController();
    final units = await showDialog<int>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Add stock to ${current.title}'),
        content: Form(
          key: formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                current.quantity == null
                    ? 'Saved stock count needs checking.'
                    : 'Current stock: ${current.quantity} units',
                style: const TextStyle(color: muted, fontSize: 12),
              ),
              const SizedBox(height: 14),
              TextFormField(
                controller: quantityController,
                autofocus: true,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Units received',
                  hintText: 'Example: 20',
                ),
                validator: (raw) {
                  final value = int.tryParse(raw?.trim() ?? '');
                  if (value == null || value < 1) return 'Enter received units.';
                  if (value > 100000000) return 'Quantity is too large.';
                  return null;
                },
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
            child: const Text('Next'),
          ),
        ],
      ),
    );
    quantityController.dispose();
    if (units == null || !mounted) return;

    resolution = _resolve(draft);
    if (!resolution.hasExactLot ||
        resolution.exactStockId != expectedId ||
        !resolution.safeToReceive) {
      showError(context, 'Saved stock changed. Check this medicine again.');
      await _prepareMatches();
      return;
    }

    try {
      final stockReview = widget.controller.reviewStockAdjustment(
        expectedId,
        kind: StockAdjustmentKind.receive,
        quantity: units,
      );
      final live = widget.controller.snapshot.records[expectedId];
      if (live == null || live.archived) {
        throw StateError('This saved medicine is no longer available.');
      }
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Confirm stock'),
          content: Text(
            '${live.title}\n\n'
            '${stockReview.beforeQuantity} units  →  ${stockReview.afterQuantity} units',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Back'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Save'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
      setState(() => _busy = true);
      await widget.controller.applyStockAdjustment(stockReview);
      final confirmedRecord = widget.controller.snapshot.records[expectedId];
      if (confirmedRecord != null && !confirmedRecord.archived) {
        await OfflineRecognitionMemoryService.instance.learnFromConfirmedScan(
          draft,
          confirmedRecord,
        );
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$units units added to ${live.title}.')),
      );
      await _advanceOrFinish();
    } catch (error) {
      if (mounted) showError(context, error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  bool _expired(MedicineScanDraft draft) {
    final raw = draft.expiry.trim();
    if (raw.isEmpty) return false;
    try {
      final value = parseDate(raw, monthEnd: draft.expiryMonthOnly);
      return value != null && value.isBefore(civilDay(widget.controller.today));
    } on FormatException {
      return false;
    }
  }

  String _cleanError(Object error) => error
      .toString()
      .replaceFirst(
        RegExp(r'^(Exception|FormatException|Bad state|StateError):\s*'),
        '',
      )
      .trim();

  @override
  Widget build(BuildContext context) {
    final loading = _sourceLoading || _matchLoading;
    return Scaffold(
      appBar: AppBar(title: const Text('Confirm medicine')),
      body: _sourceLoading
          ? const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 14),
                  Text(
                    'Reading medicine…',
                    style: TextStyle(color: muted, fontSize: 12),
                  ),
                ],
              ),
            )
          : RefreshIndicator(
              onRefresh: _drafts.isEmpty ? _loadSource : _prepareMatches,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(18, 10, 18, 32),
                children: [
                  if (_drafts.length > 1) _progressCard(),
                  if (_warning.isNotEmpty) ...[
                    _smallNotice(_warning, amber),
                    const SizedBox(height: 10),
                  ],
                  if (_error.isNotEmpty) ...[
                    _smallNotice(_error, red),
                    const SizedBox(height: 12),
                  ],
                  if (_drafts.isEmpty && _error.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 40),
                      child: Text(
                        'No medicine to review.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: muted),
                      ),
                    ),
                  if (_review != null) ...[
                    _scannedMedicineCard(_review!.draft),
                    const SizedBox(height: 10),
                    SizedBox(
                      height: 54,
                      child: FilledButton.icon(
                        onPressed: _busy || loading ? null : _next,
                        icon: _busy
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : const Icon(Icons.arrow_forward_rounded),
                        label: const Text(
                          'Next',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 24),
                    _matchingSection(_review!),
                  ] else if (_matchLoading) ...[
                    const SizedBox(height: 30),
                    const Center(child: CircularProgressIndicator()),
                  ],
                  if (_ignoredFrames > 0) ...[
                    const SizedBox(height: 14),
                    Text(
                      '$_ignoredFrames duplicate or unclear capture${_ignoredFrames == 1 ? '' : 's'} ignored automatically.',
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: muted, fontSize: 10.5),
                    ),
                  ],
                  if (_routeLabel.isNotEmpty && _warning.isEmpty) ...[
                    const SizedBox(height: 8),
                    Text(
                      _routeLabel,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: muted, fontSize: 10),
                    ),
                  ],
                ],
              ),
            ),
    );
  }

  Widget _smallNotice(String message, Color tone) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: tone.withValues(alpha: .07),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          message,
          style: TextStyle(
            color: tone,
            fontSize: 11.5,
            fontWeight: FontWeight.w700,
          ),
        ),
      );

  Widget _progressCard() => Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 10),
        decoration: BoxDecoration(
          color: primary.withValues(alpha: .06),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          children: [
            const Icon(Icons.medication_outlined, color: primary, size: 19),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Medicine ${_index + 1} of ${_drafts.length}',
                style: const TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 12.5,
                ),
              ),
            ),
            const Text(
              'One at a time',
              style: TextStyle(color: muted, fontSize: 11),
            ),
          ],
        ),
      );

  Widget _scannedMedicineCard(MedicineScanDraft draft) {
    final confirmedName = confirmedScanName(draft).trim();
    final name = confirmedName.isEmpty ? 'Medicine' : confirmedName;
    final form = confirmedScanForm(draft);
    final expired = _expired(draft);
    final ready = scanQuickIdentityIssue(draft).isEmpty && !expired;
    final facts = <(String, String)>[
      ('Brand', draft.brand),
      ('Salt', draft.salt),
      ('Strength', draft.strength),
      ('Form', form),
      ('Manufacturer', draft.manufacturer),
      ('MFG', draft.mfg),
      ('EXP', draft.expiry),
      ('Batch', draft.batchNumber),
    ].where((entry) => entry.$2.trim().isNotEmpty).toList(growable: false);

    return Surface(
      padding: const EdgeInsets.fromLTRB(16, 15, 12, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  color: primary.withValues(alpha: .09),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: const Icon(Icons.medication_rounded, color: primary),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Scanned medicine',
                      style: TextStyle(
                        color: muted,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      name,
                      style: const TextStyle(
                        color: ink,
                        fontSize: 20,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    if (draft.salt.trim().isNotEmpty ||
                        draft.strength.trim().isNotEmpty ||
                        form.isNotEmpty)
                      Text(
                        <String>[
                          draft.salt.trim(),
                          draft.strength.trim(),
                          form.trim(),
                        ].where((value) => value.isNotEmpty).join(' · '),
                        style: const TextStyle(color: muted, fontSize: 12),
                      ),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Edit medicine',
                visualDensity: VisualDensity.compact,
                onPressed: _busy ? null : () => _editScannedDraft(draft),
                icon: const Icon(Icons.edit_outlined, size: 20),
              ),
            ],
          ),
          if (facts.isNotEmpty) ...[
            const SizedBox(height: 14),
            const Divider(height: 1),
            const SizedBox(height: 12),
            for (final fact in facts) _factRow(fact.$1, fact.$2.trim()),
          ],
          const SizedBox(height: 5),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
            decoration: BoxDecoration(
              color: (expired ? red : ready ? green : amber).withValues(
                alpha: .08,
              ),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                Icon(
                  expired
                      ? Icons.warning_amber_rounded
                      : ready
                          ? Icons.check_circle_rounded
                          : Icons.info_outline_rounded,
                  color: expired ? red : ready ? green : amber,
                  size: 19,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    expired
                        ? 'Expired medicine — check the EXP date.'
                        : ready
                            ? 'Details look good'
                            : 'Check the details before saving',
                    style: TextStyle(
                      color: expired ? red : ready ? green : amber,
                      fontWeight: FontWeight.w800,
                      fontSize: 12,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _factRow(String label, String value) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 94,
              child: Text(
                label,
                style: const TextStyle(color: muted, fontSize: 12),
              ),
            ),
            Expanded(
              child: Text(
                value,
                style: const TextStyle(
                  color: ink,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ],
        ),
      );

  Widget _matchingSection(_MedicineReview review) {
    final visibleMatches = <(IntakeMatchCandidate, Medicine)>[];
    for (final match in review.matches) {
      final record = widget.controller.snapshot.records[match.id];
      if (record == null || record.archived) continue;
      visibleMatches.add((match, record));
    }

    final sameCount = visibleMatches
        .where(
          (item) =>
              item.$1.kind == IntakeMatchKind.exactStock ||
              item.$1.kind == IntakeMatchKind.sameMedicine,
        )
        .length;
    late final String title;
    late final String subtitle;
    if (review.resolution.kind == IntakeResolutionKind.exactLot &&
        sameCount > 0) {
      title = 'Exact stock match';
      subtitle = 'This medicine is already saved in your stock.';
    } else if (review.resolution.kind == IntakeResolutionKind.sameProduct &&
        sameCount > 0) {
      title = '$sameCount matching medicine${sameCount == 1 ? '' : 's'} found';
      subtitle = 'Same medicine is already in your Medicine Database.';
    } else if ((review.resolution.kind == IntakeResolutionKind.ambiguous ||
            review.resolution.kind == IntakeResolutionKind.needsReview) &&
        visibleMatches.isNotEmpty) {
      title = '${visibleMatches.length} possible match${visibleMatches.length == 1 ? '' : 'es'}';
      subtitle = 'Choose carefully before changing saved stock.';
    } else if (visibleMatches.isNotEmpty) {
      title = '${visibleMatches.length} similar medicine${visibleMatches.length == 1 ? '' : 's'} found';
      subtitle = 'Closest saved medicines are shown from best match to lower match.';
    } else {
      title = 'No matching medicine found';
      subtitle = 'This looks new in your Medicine Database.';
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: primary.withValues(alpha: .08),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Icon(Icons.manage_search_rounded, color: primary),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      color: ink,
                      fontSize: 16,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: const TextStyle(color: muted, fontSize: 11.5),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (visibleMatches.isEmpty)
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: primary.withValues(alpha: .035),
              borderRadius: BorderRadius.circular(15),
              border: Border.all(color: primary.withValues(alpha: .10)),
            ),
            child: const Text(
              'No saved medicine needs your attention here.',
              style: TextStyle(color: muted, fontSize: 12),
            ),
          )
        else ...[
          for (var i = 0; i < visibleMatches.take(5).length; i++)
            _matchCard(
              visibleMatches[i].$1,
              visibleMatches[i].$2,
              scanDraft: review.draft,
              best: i == 0,
            ),
          if (visibleMatches.length > 5)
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Text(
                '+ ${visibleMatches.length - 5} more saved matches',
                textAlign: TextAlign.center,
                style: const TextStyle(color: muted, fontSize: 11),
              ),
            ),
        ],
      ],
    );
  }

  Widget _matchCard(
    IntakeMatchCandidate match,
    Medicine record, {
    required MedicineScanDraft scanDraft,
    required bool best,
  }) {
    final (badge, tone) = switch (match.kind) {
      IntakeMatchKind.exactStock => ('Exact stock', green),
      IntakeMatchKind.sameMedicine => ('Same medicine', primary),
      IntakeMatchKind.possible => (best ? 'Closest match' : 'Similar', amber),
    };
    final identity = <String>[
      record.salt.trim(),
      record.strength.trim(),
      record.form.trim(),
    ].where((value) => value.isNotEmpty).join(' · ');
    final lot = <String>[
      if (record.batchNumber.trim().isNotEmpty) 'Batch ${record.batchNumber}',
      if (record.expiry != null) 'EXP ${dateText(record.expiry!)}',
      if (record.quantity != null) '${record.quantity} units',
      if (record.sold) 'SOLD',
    ].join(' · ');

    return Padding(
      padding: const EdgeInsets.only(bottom: 9),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () => openEditor(
            context,
            widget.controller,
            record: record,
            scanDraft: scanDraft,
          ),
          borderRadius: BorderRadius.circular(16),
          child: Ink(
            padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
            decoration: BoxDecoration(
              color: tone.withValues(alpha: .045),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: tone.withValues(alpha: .14)),
            ),
            child: Row(
              children: [
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: tone.withValues(alpha: .10),
                    borderRadius: BorderRadius.circular(13),
                  ),
                  child: Icon(
                    Icons.medication_outlined,
                    color: tone,
                    size: 22,
                  ),
                ),
                const SizedBox(width: 11),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              record.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: ink,
                                fontSize: 14,
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: tone.withValues(alpha: .10),
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Text(
                              badge,
                              style: TextStyle(
                                color: tone,
                                fontSize: 9.5,
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                          ),
                        ],
                      ),
                      if (identity.isNotEmpty) ...[
                        const SizedBox(height: 3),
                        Text(
                          identity,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: muted, fontSize: 11.5),
                        ),
                      ],
                      if (lot.isNotEmpty) ...[
                        const SizedBox(height: 3),
                        Text(
                          lot,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: ink,
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 6),
                const Icon(Icons.chevron_right_rounded, color: muted),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _MedicineReview {
  const _MedicineReview({
    required this.prepared,
    required this.resolution,
    required this.matches,
  });

  final PreparedMedicineReviewDraft prepared;
  final IntakeResolution resolution;
  final List<IntakeMatchCandidate> matches;

  MedicineScanDraft get draft => prepared.draft;
}
