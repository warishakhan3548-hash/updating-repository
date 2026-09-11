import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../domain/intake_resolution.dart';
import '../domain/medicine_scan_commit.dart';
import '../domain/medicine_understanding.dart';
import '../services/ai_service.dart';
import '../services/cloud_scan_ai_service.dart';
import '../state/pharmacy_controller.dart';
import 'design.dart';
import 'editor_screen.dart';

/// Explicit cloud-assisted scan lane.
///
/// OCR is still extracted on-device first. The configured cloud provider sees
/// only the bounded OCR handoff for each deterministic draft, never the pharmacy
/// inventory export. Returned values remain evidence-validated preview data and
/// cannot write stock until the existing revision-bound Confirm/Add or editor
/// review succeeds.
class CloudScanReviewScreen extends StatefulWidget {
  const CloudScanReviewScreen({
    super.key,
    required this.controller,
    required this.evidence,
  });

  final PharmacyController controller;
  final List<MedicineFrameEvidence> evidence;

  @override
  State<CloudScanReviewScreen> createState() => _CloudScanReviewScreenState();
}

class _CloudScanReviewScreenState extends State<CloudScanReviewScreen> {
  final _cloud = CloudScanAiService.instance;
  List<MedicineScanDraft> _drafts = const [];
  bool _loading = true;
  int? _savingIndex;
  String _route = '';
  String _error = '';
  String _warning = '';
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _prepare();
  }

  @override
  void dispose() {
    ++_generation;
    super.dispose();
  }

  Future<void> _prepare() async {
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = '';
      _warning = '';
      _drafts = const [];
    });
    try {
      if (widget.evidence.isEmpty ||
          widget.evidence.every(
            (item) => item.text.trim().isEmpty && item.barcode.trim().isEmpty,
          )) {
        throw const FormatException('No barcode or medicine text was captured.');
      }

      final knowledge = medicineKnowledgeFromRecords(widget.controller.records);
      final payload = await compute(
        understandMedicineEvidenceMessage,
        <String, Object?>{
          'evidence': widget.evidence
              .map((item) => item.toMessage())
              .toList(growable: false),
          'knowledge': knowledge
              .map((item) => item.toMessage())
              .toList(growable: false),
        },
      );
      if (!mounted || generation != _generation) return;
      final deterministic = MedicineUnderstandingResult.fromMessage(payload);
      if (deterministic.drafts.isEmpty) {
        throw const FormatException(
          'No medicine could be read. Take a closer, steadier scan.',
        );
      }

      AiConfiguration? config;
      try {
        config = await _cloud.requireConfiguration();
        if (!mounted || generation != _generation) return;
        _route = _cloud.routeLabel(config);
      } catch (error) {
        if (!mounted || generation != _generation) return;
        _warning =
            '${_cleanError(error)} Deterministic OCR preview is retained; nothing was sent externally.';
      }

      final refined = <MedicineScanDraft>[];
      for (final original in deterministic.drafts) {
        if (!mounted || generation != _generation) return;
        if (config == null) {
          refined.add(original);
          continue;
        }
        try {
          refined.add(await _cloud.refine(config, original));
        } catch (error) {
          refined.add(original);
          _warning =
              'Cloud AI could not safely validate every scan. Deterministic OCR was retained for affected drafts. ${_cleanError(error)}';
        }
      }

      if (!mounted || generation != _generation) return;
      setState(() {
        _drafts = refined;
        _loading = false;
      });
    } catch (error) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _loading = false;
        _error = _cleanError(error);
      });
    }
  }

  String _cleanError(Object error) => error
      .toString()
      .replaceFirst(
        RegExp(r'^(Exception|FormatException|Bad state|StateError):\s*'),
        '',
      )
      .trim();

  IntakeResolution _resolution(MedicineScanDraft draft) => resolveIntakeDraft(
    draft: draft,
    records: widget.controller.records,
    today: widget.controller.today,
  );

  ScanQuickAddDecision _quickDecision(MedicineScanDraft draft) =>
      scanQuickAddDecision(draft, _resolution(draft));

  Future<void> _confirmAndAdd(int index, MedicineScanDraft draft) async {
    if (_savingIndex != null) return;
    var decision = _quickDecision(draft);
    if (!decision.allowed) {
      showError(context, decision.reason);
      return;
    }

    setState(() => _savingIndex = index);
    try {
      // Re-resolve immediately before the revision-bound write. A concurrent
      // inventory change can revoke quick-add instead of creating a duplicate.
      decision = _quickDecision(draft);
      if (!decision.allowed) throw StateError(decision.reason);
      final expectedRevision = widget.controller.snapshot.revision;
      final medicine = medicineFromConfirmedScan(draft);
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
                : '${medicine.title} added from the confirmed cloud-assisted scan.',
          ),
        ),
      );
    } catch (error) {
      if (mounted) showError(context, error);
    } finally {
      if (mounted && _savingIndex == index) {
        setState(() => _savingIndex = null);
      }
    }
  }

  String _value(String value) =>
      value.trim().isEmpty ? 'Needs review' : value.trim();

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Cloud AI scan review')),
    body: _loading
        ? const Center(
            child: Padding(
              padding: EdgeInsets.all(28),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 16),
                  Text(
                    'Reading OCR locally, then validating medicine fields with your configured cloud AI…',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: muted, fontSize: 12),
                  ),
                ],
              ),
            ),
          )
        : ListView(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 30),
            children: [
              const FlowSteps(['Scan', 'AI preview', 'Confirm / Add'], current: 1),
              Surface(
                color: primarySoft,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Row(
                      children: [
                        Icon(Icons.cloud_done_outlined, color: primary),
                        SizedBox(width: 9),
                        Expanded(
                          child: Text(
                            'Bounded cloud scan lane',
                            style: TextStyle(
                              fontWeight: FontWeight.w900,
                              color: primary,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _route.isEmpty
                          ? 'Cloud route unavailable · deterministic OCR preview retained.'
                          : '$_route\nOnly this scan’s bounded OCR is sent. Full inventory is not uploaded.',
                      style: const TextStyle(fontSize: 11.5, height: 1.4),
                    ),
                    const SizedBox(height: 6),
                    const Text(
                      'AI output is treated as a proposal, checked against exact OCR evidence, and cannot change stock until you confirm.',
                      style: TextStyle(color: muted, fontSize: 11),
                    ),
                  ],
                ),
              ),
              if (_warning.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    _warning,
                    style: const TextStyle(color: amber, fontSize: 12),
                  ),
                ),
              if (_error.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    _error,
                    style: const TextStyle(color: red, fontSize: 12),
                  ),
                ),
              for (var index = 0; index < _drafts.length; index++)
                _draftCard(index, _drafts[index]),
              if (_drafts.isEmpty && _error.isEmpty)
                const Padding(
                  padding: EdgeInsets.only(top: 24),
                  child: Text(
                    'No medicine draft is available. Scan the pack again with clearer front and composition panels.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: muted),
                  ),
                ),
            ],
          ),
  );

  Widget _draftCard(int index, MedicineScanDraft draft) {
    final decision = _quickDecision(draft);
    final form = confirmedScanForm(draft);
    final name = confirmedScanName(draft);
    final resolution = _resolution(draft);
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Surface(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              name.isEmpty ? 'Medicine ${index + 1} · identity needs review' : name,
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 10),
            Text(
              [
                'Brand: ${_value(draft.brand)}',
                'Salt: ${_value(draft.salt)}',
                'Strength: ${_value(draft.strength)}',
                'Form: ${_value(form)}',
                'Manufacturer: ${_value(draft.manufacturer)}',
                'Batch: ${_value(draft.batchNumber)}',
                'MFG: ${_value(draft.mfg)}',
                'EXP: ${_value(draft.expiry)}',
                if (draft.barcode.trim().isNotEmpty)
                  'Barcode: ${draft.barcode.trim()}',
              ].join('\n'),
              style: const TextStyle(fontSize: 12.5, height: 1.48),
            ),
            const SizedBox(height: 9),
            Text(
              resolution.reason,
              style: TextStyle(
                color: resolution.kind == IntakeResolutionKind.ambiguous
                    ? red
                    : muted,
                fontSize: 11.5,
                height: 1.35,
              ),
            ),
            if (!decision.allowed && decision.reason.isNotEmpty) ...[
              const SizedBox(height: 7),
              Text(
                decision.reason,
                style: const TextStyle(color: amber, fontSize: 11.5),
              ),
            ],
            const SizedBox(height: 12),
            if (decision.allowed)
              FilledButton.icon(
                onPressed: _savingIndex == null
                    ? () => _confirmAndAdd(index, draft)
                    : null,
                icon: _savingIndex == index
                    ? const SizedBox(
                        width: 17,
                        height: 17,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.check_circle_outline_rounded),
                label: Text(
                  _savingIndex == index ? 'Adding…' : decision.actionLabel,
                ),
              ),
            const SizedBox(height: 7),
            OutlinedButton.icon(
              onPressed: _savingIndex == null
                  ? () => openEditor(
                      context,
                      widget.controller,
                      scanDraft: draft,
                    )
                  : null,
              icon: const Icon(Icons.fact_check_outlined),
              label: const Text('Review / edit every field first'),
            ),
          ],
        ),
      ),
    );
  }
}
