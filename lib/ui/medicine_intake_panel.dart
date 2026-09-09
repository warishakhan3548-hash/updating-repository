import 'dart:async';

import 'package:flutter/material.dart';

import '../domain/medicine.dart';
import '../domain/medicine_intake.dart';
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

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: queue,
    builder: (context, _) {
      if (!queue.supported || (queue.jobs.isEmpty && error.isEmpty))
        return const SizedBox.shrink();
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: Text(
                  'Capture inbox · ${queue.jobs.length}',
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
            'Drafts are saved locally. OCR/AI processes while the app is alive; interrupted jobs resume here. Nothing enters stock without review.',
            style: TextStyle(fontSize: 11, color: muted),
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
                        padding: const EdgeInsets.only(top: 8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${draft.name.isEmpty ? 'Identity needs review' : draft.name} · ${draft.strength}',
                            ),
                            Text(
                              'Salt: ${draft.salt.isEmpty ? 'Unknown' : draft.salt}\nEXP: ${draft.expiry.isEmpty ? 'Unknown' : draft.expiry}',
                              style: const TextStyle(fontSize: 12),
                            ),
                            if (_expired(draft.expiry))
                              const Text(
                                'Expired — do not dispense. Check the printed date.',
                                style: TextStyle(
                                  color: red,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            if (widget.onAsk != null && job.terminal)
                              TextButton(
                                onPressed:
                                    !LocalAiService.instance.hasSelection ||
                                        LocalAiService.instance.busy
                                    ? null
                                    : () => widget.onAsk!(draft.rawText),
                                child: const Text('Ask about this scan'),
                              ),
                          ],
                        ),
                      ),
                    if (job.drafts.length > 3)
                      Text('+ ${job.drafts.length - 3} more in review'),
                    Wrap(
                      spacing: 8,
                      children: [
                        if (job.terminal && job.drafts.isNotEmpty)
                          FilledButton(
                            onPressed: () => _review(job),
                            child: const Text('Add / Edit details'),
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
                              if (confirmed == true)
                                await _run(() => queue.dismiss(job));
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
