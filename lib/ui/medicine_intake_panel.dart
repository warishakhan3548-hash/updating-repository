import 'dart:async';

import 'package:flutter/material.dart';

import '../domain/medicine.dart';
import '../domain/medicine_intake.dart';
import '../domain/medicine_review_cardinality.dart';
import '../domain/medicine_scan_commit.dart';
import '../domain/medicine_understanding.dart';
import '../services/medicine_intake_service.dart';
import '../services/medicine_review_pipeline.dart';
import '../state/pharmacy_controller.dart';
import 'design.dart';
import 'medicine_review_screen.dart';

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
  String? _openingJob;

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
      if (mounted) setState(() => error = _cleanError(e));
    }
  }

  String _cleanError(Object value) => value
      .toString()
      .replaceFirst(RegExp(r'^(Exception|Bad state|StateError):\s*'), '')
      .trim();

  bool _singlePackExpected(MedicineIntakeJob job) =>
      job.kind == 'photo' || job.kind == 'evidence';

  List<MedicineScanDraft> _reviewDrafts(MedicineIntakeJob job) =>
      normalizeMedicineReviewDrafts(
        job.drafts,
        singlePackExpected: _singlePackExpected(job),
      );

  Future<void> _review(MedicineIntakeJob job) async {
    if (_openingJob != null || !job.canReview) return;
    setState(() => _openingJob = job.id);
    try {
      await queue.continueWithDraft(job);
      if (!mounted) return;
      final drafts = _reviewDrafts(job);
      final completed = await Navigator.push<bool>(
        context,
        MaterialPageRoute(
          builder: (_) => MedicineReviewScreen(
            controller: widget.controller,
            input: MedicineReviewInput.prepared(
              drafts,
              singlePackExpected: _singlePackExpected(job),
            ),
          ),
        ),
      );
      if (completed == true) {
        await _run(() => queue.dismiss(job));
      }
    } catch (value) {
      if (mounted) setState(() => error = _cleanError(value));
    } finally {
      if (mounted) setState(() => _openingJob = null);
    }
  }

  bool _expired(String value) {
    try {
      return parseDate(
            value,
            monthEnd: true,
          )?.isBefore(civilDay(widget.controller.today)) ??
          false;
    } on FormatException {
      return false;
    }
  }

  String _value(String value) =>
      value.trim().isEmpty ? 'Not found' : value.trim();

  String _statusTitle(MedicineIntakeJob job) {
    if (job.status == 'reasoning') return 'Improving medicine details…';
    if (job.kind == 'video') return 'Reading medicine video…';
    return 'Reading medicine…';
  }

  String _simpleJobError(MedicineIntakeJob job) {
    final raw = job.error.toLowerCase();
    if (raw.contains('no medicine could be read')) {
      return job.kind == 'video'
          ? 'No medicine could be read clearly. Try the video again or use closer, steadier views.'
          : 'Medicine could not be read clearly. Try a closer, steadier image.';
    }
    if (raw.contains('storage')) {
      return 'This scan could not continue because the device needs more free storage.';
    }
    return 'Medicine details could not be completed. Try again.';
  }

  Future<void> _retry(MedicineIntakeJob job) => _run(
        () => job.canRescanVideo
            ? queue.retry(job, rescanVideo: true)
            : queue.retry(job),
      );

  @override
  Widget build(BuildContext context) => ActiveListenableBuilder(
        listenable: queue,
        builder: (context, _) {
          if (!queue.supported || (queue.jobs.isEmpty && error.isEmpty)) {
            return const SizedBox.shrink();
          }

      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 16),
          const Text(
            'Medicine preview',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 5),
          const Text(
            'Your scan is read automatically. Check the details, then tap Next.',
            style: TextStyle(color: muted, fontSize: 12, height: 1.35),
          ),
          if (queue.persistenceError.isNotEmpty) ...[
            const SizedBox(height: 8),
            const Text(
              'Saved scan processing needs attention. Your medicine database was not changed.',
              style: TextStyle(color: red, fontSize: 12),
            ),
          ],
          if (error.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(error, style: const TextStyle(color: red, fontSize: 12)),
          ],
          const SizedBox(height: 8),
          for (final job in queue.jobs.reversed.take(visible)) _jobCard(job),
          if (queue.jobs.length > visible)
            TextButton(
              onPressed: () => setState(() => visible += 10),
              child: const Text('Show more'),
            ),
        ],
      );
    },
  );

  Widget _jobCard(MedicineIntakeJob job) {
    final processing = !job.terminal;
    final failedWithoutDraft = job.status == 'failed' && job.drafts.isEmpty;
    final reviewDrafts = _reviewDrafts(job);
    final preview = reviewDrafts.isEmpty ? null : reviewDrafts.first;

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (processing) ...[
              Row(
                children: [
                  Container(
                    width: 46,
                    height: 46,
                    decoration: BoxDecoration(
                      color: primary.withValues(alpha: .08),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: const Icon(
                      Icons.document_scanner_outlined,
                      color: primary,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _statusTitle(job),
                          style: const TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: 16,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          job.canReview
                              ? 'Check the details below. You can tap Next now.'
                              : 'Please wait a moment',
                          style: const TextStyle(color: muted, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              LinearProgressIndicator(
                value: job.status == 'reasoning'
                    ? null
                    : job.kind == 'video'
                        ? job.videoProgress
                        : null,
                minHeight: 5,
                borderRadius: BorderRadius.circular(10),
              ),
              if (job.canReview) const SizedBox(height: 12),
            ],
            if (failedWithoutDraft) ...[
              const Row(
                children: [
                  Icon(Icons.error_outline_rounded, color: amber),
                  SizedBox(width: 9),
                  Expanded(
                    child: Text(
                      'Couldn’t read this medicine',
                      style: TextStyle(fontWeight: FontWeight.w800),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                _simpleJobError(job),
                style: const TextStyle(color: muted, fontSize: 12),
              ),
              const SizedBox(height: 10),
              OutlinedButton.icon(
                onPressed: () => _retry(job),
                icon: const Icon(Icons.refresh_rounded),
                label:
                    Text(job.kind == 'video' ? 'Try video again' : 'Try again'),
              ),
            ] else if (job.canReview || !processing) ...[
              if (preview != null) _draftCard(job, preview, 0),
              if (preview != null &&
                  !processing &&
                  job.error.contains('Local AI')) ...[
                const SizedBox(height: 6),
                const Text(
                  'AI review could not finish. Check the scanned details, then tap Next.',
                  style: TextStyle(color: muted, fontSize: 12),
                ),
              ],
              if (reviewDrafts.length > 1)
                Container(
                  margin: const EdgeInsets.only(top: 2, bottom: 4),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
                  decoration: BoxDecoration(
                    color: primary.withValues(alpha: .055),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.layers_outlined,
                        color: primary,
                        size: 18,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '${reviewDrafts.length} medicines found · Next reviews them one at a time.',
                          style: const TextStyle(
                            color: primary,
                            fontSize: 11.5,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              if (job.coverageWarning.isNotEmpty) ...[
                const SizedBox(height: 9),
                const Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.info_outline_rounded, color: amber, size: 18),
                    SizedBox(width: 7),
                    Expanded(
                      child: Text(
                        'Some parts of this video were unclear. Check the medicine count before saving.',
                        style: TextStyle(
                          color: amber,
                          fontSize: 11.5,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
                if (job.canRescanVideo)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: () => _retry(job),
                      icon: const Icon(Icons.video_library_outlined, size: 18),
                      label: const Text('Read video again'),
                    ),
                  ),
              ],
              const SizedBox(height: 10),
              SizedBox(
                height: 52,
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: primary.withValues(alpha: .10),
                    foregroundColor: primary,
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                      side: BorderSide(
                        color: primary.withValues(alpha: .16),
                      ),
                    ),
                  ),
                  onPressed: reviewDrafts.isEmpty || _openingJob != null
                      ? null
                      : () => _review(job),
                  icon: const Icon(Icons.arrow_forward_rounded),
                  label: const Text(
                    'Next',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ),
            ],
            if (job.terminal) ...[
              const SizedBox(height: 2),
              Align(
                alignment: Alignment.centerRight,
                child: IconButton(
                  tooltip: 'Remove this scan',
                  visualDensity: VisualDensity.compact,
                  onPressed: () => _dismiss(job),
                  icon: const Icon(Icons.close_rounded, size: 20),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _draftCard(MedicineIntakeJob job, MedicineScanDraft draft, int index) {
    final name = confirmedScanName(draft).isEmpty
        ? 'Medicine ${index + 1}'
        : confirmedScanName(draft);

    return Container(
      margin: const EdgeInsets.only(bottom: 9),
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: primary.withValues(alpha: .045),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: primary.withValues(alpha: .12)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  name,
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
              if (!_identityIncomplete(draft))
                const Icon(Icons.check_circle_rounded, color: green, size: 20),
            ],
          ),
          const SizedBox(height: 11),
          _factRow('Brand', _value(draft.brand)),
          _factRow('Salt', _value(draft.salt)),
          _factRow('Strength', _value(draft.strength)),
          _factRow('Form', _value(confirmedScanForm(draft))),
          _factRow('MFG', _value(draft.mfg)),
          _factRow('EXP', _value(draft.expiry)),
          if (_expired(draft.expiry)) ...[
            const SizedBox(height: 8),
            const Row(
              children: [
                Icon(Icons.warning_amber_rounded, color: red, size: 18),
                SizedBox(width: 7),
                Expanded(
                  child: Text(
                    'Expired medicine — check the printed date.',
                    style: TextStyle(
                      color: red,
                      fontSize: 11.5,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ],
            ),
          ] else if (_identityIncomplete(draft)) ...[
            const SizedBox(height: 8),
            const Text(
              'Some details need checking before saving.',
              style: TextStyle(
                color: amber,
                fontSize: 11.5,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
          if (widget.onAsk != null && draft.rawText.trim().isNotEmpty) ...[
            const SizedBox(height: 6),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => _run(() async {
                  await queue.continueWithDraft(job);
                  if (mounted) widget.onAsk?.call(draft.rawText);
                }),
                icon: const Icon(Icons.auto_awesome_rounded, size: 18),
                label: const Text('Ask AI'),
              ),
            ),
          ],
        ],
      ),
    );
  }

  bool _identityIncomplete(MedicineScanDraft draft) =>
      confirmedScanName(draft).isEmpty ||
      draft.brand.trim().isEmpty ||
      draft.salt.trim().isEmpty ||
      draft.strength.trim().isEmpty ||
      confirmedScanForm(draft).isEmpty;

  Widget _factRow(String label, String value) => Padding(
    padding: const EdgeInsets.only(bottom: 7),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 82,
          child: Text(
            label,
            style: const TextStyle(color: muted, fontSize: 12.5),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: TextStyle(
              color: value == 'Not found' ? amber : ink,
              fontSize: 12.5,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
      ],
    ),
  );

  Future<void> _dismiss(MedicineIntakeJob job) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove this scan?'),
        content: const Text(
          'This removes only this saved scan draft. Your medicine database is unchanged.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed == true) await _run(() => queue.dismiss(job));
  }
}
