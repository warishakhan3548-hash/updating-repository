import 'dart:async';

import 'package:flutter/material.dart';

import '../domain/intake_resolution.dart';
import '../domain/medicine.dart';
import '../domain/medicine_intake.dart';
import '../domain/medicine_scan_commit.dart';
import '../domain/medicine_understanding.dart';
import '../services/local_ai_service.dart';
import '../services/medicine_intake_service.dart';
import '../state/pharmacy_controller.dart';
import 'design.dart';
import 'import_screen.dart';

class MedicineIntakePanel extends StatefulWidget {
  const MedicineIntakePanel({super.key, required this.controller, this.onAsk});
  final PharmacyController controller;
  final void Function(String evidence)? onAsk;
  @override
  State<MedicineIntakePanel> createState() => _MedicineIntakePanelState();
}

class _MedicineIntakePanelState extends State<MedicineIntakePanel> {
  final queue = MedicineIntakeService.instance;
  int visible = 5;
  String error = '';
  bool _savingQuickAdd = false;

  @override
  void initState() {
    super.initState();
    unawaited(
      _run(
        () => queue.attach(
          () => widget.controller.records,
          revision: () => widget.controller.snapshot.revision,
        ),
      ),
    );
  }

  Future<void> _run(Future<void> Function() action) async {
    try {
      await action();
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    }
  }

  Future<void> _review(MedicineIntakeJob job) async {
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => ImportInboxScreen(
          controller: widget.controller,
          evidence: const [],
          preparedDrafts: List.of(job.drafts),
        ),
      ),
    );
  }

  bool _expired(String value) {
    try {
      return parseDate(
            value,
            monthEnd: true,
          )?.isBefore(civilDay(widget.controller.today)) ??
          false;
    } on FormatException {
      return false; // A malformed recovered draft remains reviewable, not a UI crash.
    }
  }

  String _fact(String label, String value) =>
      '$label: ${value.trim().isEmpty ? 'Unknown' : value.trim()}';

  bool _hasCompleteQuickIdentity(MedicineScanDraft draft) {
    // Keep the quick-add affordance on the same authoritative identity projection
    // that the commit boundary persists. Raw deterministic form candidates can be
    // deliberately conservative or legacy-normalized; confirmedScanForm() first
    // recovers an unambiguous pharmaceutical form directly from source OCR and
    // otherwise requires a strong non-conflicted extracted form. The preview,
    // button gate and saved Medicine therefore cannot disagree about Form.
    final form = confirmedScanForm(draft);
    return confirmedScanName(draft).isNotEmpty &&
        draft.brand.trim().isNotEmpty &&
        draft.salt.trim().isNotEmpty &&
        draft.strength.trim().isNotEmpty &&
        form.isNotEmpty;
  }

  ScanQuickAddDecision _quickAddDecision(MedicineScanDraft draft) {
    if (!_hasCompleteQuickIdentity(draft)) {
      return const ScanQuickAddDecision.blocked(
        'Brand, salt, strength and a recognized form are required for one-tap add. Open detailed review for this scan.',
      );
    }
    return scanQuickAddDecision(
      draft,
      resolveIntakeDraft(
        draft: draft,
        records: widget.controller.records,
        today: widget.controller.today,
      ),
    );
  }

  bool _canConfirmAdd(MedicineScanDraft draft) =>
      _quickAddDecision(draft).allowed;

  bool _identityNeedsReview(MedicineScanDraft draft) {
    if (confirmedScanForm(draft).isEmpty) return true;
    return ['name', 'brand', 'salt', 'strength']
        .any((key) => draft.field(key).needsReview);
  }

  Future<void> _confirmAndAdd(MedicineScanDraft draft) async {
    if (_savingQuickAdd) return;
    final initialDecision = _quickAddDecision(draft);
    if (!initialDecision.allowed) {
      setState(() => error = initialDecision.reason);
      return;
    }

    setState(() {
      _savingQuickAdd = true;
      error = '';
    });
    try {
      // The same deterministic gate is shared with ImportInbox. It owns duplicate
      // lot detection, trusted-batch admission and date-conflict/chronology rules
      // so every Confirm/Add entry point has identical safety semantics.
      final decision = _quickAddDecision(draft);
      if (!decision.allowed) throw StateError(decision.reason);

      final expectedRevision = widget.controller.snapshot.revision;
      final record = medicineFromConfirmedScan(draft);

      // Re-resolve immediately before the revision-bound commit. A concurrent
      // stock write can revoke the shortcut instead of creating a duplicate lot.
      final finalDecision = _quickAddDecision(draft);
      if (!finalDecision.allowed ||
          finalDecision.isNewBatch != decision.isNewBatch) {
        throw StateError(
          finalDecision.reason.isEmpty
              ? 'Inventory changed before save. Review this scan again; nothing was added.'
              : finalDecision.reason,
        );
      }
      await widget.controller.save(record, expectedRevision: expectedRevision);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            decision.isNewBatch
                ? '${record.title} added as a reviewed new batch.'
                : '${record.title} added from the confirmed AI preview.',
          ),
        ),
      );
    } catch (e) {
      if (mounted) {
        setState(
          () => error = e
              .toString()
              .replaceFirst(RegExp(r'^(Bad state|StateError):\s*'), ''),
        );
      }
    } finally {
      if (mounted) setState(() => _savingQuickAdd = false);
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([queue, LocalAiService.instance]),
    builder: (context, _) {
      if (!queue.supported || (queue.jobs.isEmpty && error.isEmpty)) {
        return const SizedBox.shrink();
      }
      final local = LocalAiService.instance;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: Text(
                  'AI scan preview · ${queue.jobs.length}',
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
              ),
              TextButton(
                onPressed: () => queue.setPaused(!queue.paused),
                child: Text(
                  queue.paused ? 'Resume' : 'Pause after current step',
                ),
              ),
            ],
          ),
          const Text(
            'OCR stays local, deterministic extraction runs first, then the active Local AI can refine evidence-grounded Brand, Salt, Strength and Form. Nothing enters stock until you confirm.',
            style: TextStyle(fontSize: 11, color: muted),
          ),
          if (local.hasSelection && local.scannerEnabled && !local.scanVerified)
            const Padding(
              padding: EdgeInsets.only(top: 5),
              child: Text(
                'Smart warning: this model loaded successfully but did not pass the optional extraction probe. Scan AI is still available; verify its preview before adding.',
                style: TextStyle(fontSize: 11, color: amber),
              ),
            ),
          if (queue.pauseReason.isNotEmpty)
            Text(queue.pauseReason, style: const TextStyle(color: amber)),
          if (queue.persistenceError.isNotEmpty)
            Text(queue.persistenceError, style: const TextStyle(color: red)),
          if (error.isNotEmpty) Text(error, style: const TextStyle(color: red)),
          for (final job in queue.jobs.reversed.take(visible))
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      job.title,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    Text(
                      '${job.status} · ${job.drafts.length} medicine drafts',
                      style: const TextStyle(fontSize: 12),
                    ),
                    if (!job.terminal)
                      LinearProgressIndicator(
                        value: job.kind == 'video'
                            ? job.videoProgress
                            : job.status == 'reasoning' && job.drafts.isNotEmpty
                            ? job.aiIndex / job.drafts.length
                            : null,
                      ),
                    if (job.error.isNotEmpty)
                      Text(
                        job.error,
                        style: const TextStyle(color: amber, fontSize: 12),
                      ),
                    for (final draft in job.drafts.take(3))
                      Padding(
                        padding: const EdgeInsets.only(top: 10),
                        child: Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(11),
                          decoration: BoxDecoration(
                            color: primary.withValues(alpha: .045),
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(
                              color: primary.withValues(alpha: .12),
                            ),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                confirmedScanName(draft).isEmpty
                                    ? 'Identity needs review'
                                    : confirmedScanName(draft),
                                style: const TextStyle(
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                              const SizedBox(height: 5),
                              Text(
                                [
                                  _fact('Brand', draft.brand),
                                  _fact('Salt', draft.salt),
                                  _fact('Strength', draft.strength),
                                  _fact('Form', confirmedScanForm(draft)),
                                  _fact('EXP', draft.expiry),
                                ].join('\n'),
                                style: const TextStyle(fontSize: 12, height: 1.35),
                              ),
                              if (_expired(draft.expiry))
                                const Padding(
                                  padding: EdgeInsets.only(top: 5),
                                  child: Text(
                                    'Expired — do not dispense. Check the printed date.',
                                    style: TextStyle(
                                      color: red,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                              if (job.terminal &&
                                  _canConfirmAdd(draft) &&
                                  _identityNeedsReview(draft))
                                const Padding(
                                  padding: EdgeInsets.only(top: 6),
                                  child: Text(
                                    'Evidence-refined identity: compare these values with the pack before confirming.',
                                    style: TextStyle(
                                      color: amber,
                                      fontSize: 11,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                              if (job.terminal && _canConfirmAdd(draft))
                                Padding(
                                  padding: const EdgeInsets.only(top: 8),
                                  child: FilledButton.icon(
                                    onPressed: _savingQuickAdd
                                        ? null
                                        : () => _confirmAndAdd(draft),
                                    icon: const Icon(
                                      Icons.check_circle_outline_rounded,
                                    ),
                                    label: Text(
                                      _savingQuickAdd
                                          ? 'Adding…'
                                          : _quickAddDecision(draft).actionLabel,
                                    ),
                                  ),
                                ),
                              if (widget.onAsk != null && job.terminal)
                                TextButton(
                                  // AI routing belongs to AiScreen/AiService, not
                                  // this scan-preview widget. A cloud-only route
                                  // is valid, a busy Local AI turn can queue at
                                  // the shared lease, and a missing route is
                                  // handled by AiScreen's Connections flow.
                                  onPressed: () => widget.onAsk!(draft.rawText),
                                  child: const Text('Ask about this scan'),
                                ),
                            ],
                          ),
                        ),
                      ),
                    if (job.drafts.length > 3)
                      Text('+ ${job.drafts.length - 3} more in review'),
                    Wrap(
                      spacing: 8,
                      children: [
                        if (job.terminal && job.drafts.isNotEmpty)
                          FilledButton.icon(
                            onPressed: () => _review(job),
                            icon: const Icon(Icons.fact_check_outlined),
                            label: const Text('Preview & Confirm / Add'),
                          ),
                        if (job.terminal)
                          TextButton(
                            onPressed: () => _run(() => queue.retry(job)),
                            child: const Text('Retry local reasoning'),
                          ),
                        if (job.terminal)
                          IconButton(
                            tooltip: 'Dismiss capture draft',
                            onPressed: () async {
                              final confirmed = await showDialog<bool>(
                                context: context,
                                builder: (context) => AlertDialog(
                                  title: const Text('Dismiss this capture?'),
                                  content: const Text(
                                    'This removes its saved draft and retained source file. Saved inventory is unchanged. Recapture to recover it.',
                                  ),
                                  actions: [
                                    TextButton(
                                      onPressed: () =>
                                          Navigator.pop(context, false),
                                      child: const Text('Cancel'),
                                    ),
                                    TextButton(
                                      onPressed: () =>
                                          Navigator.pop(context, true),
                                      child: const Text('Dismiss'),
                                    ),
                                  ],
                                ),
                              );
                              if (confirmed == true) {
                                await _run(() => queue.dismiss(job));
                              }
                            },
                            icon: const Icon(Icons.close),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          if (queue.jobs.length > visible)
            TextButton(
              onPressed: () => setState(() => visible += 10),
              child: const Text('Show more captures'),
            ),
        ],
      );
    },
  );
}
