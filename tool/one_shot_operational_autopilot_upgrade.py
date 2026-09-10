#!/usr/bin/env python3
from pathlib import Path


def read(path: str) -> str:
    return Path(path).read_text(encoding='utf-8')


def write(path: str, text: str) -> None:
    Path(path).write_text(text, encoding='utf-8')


def replace_once(path: str, old: str, new: str) -> None:
    text = read(path)
    count = text.count(old)
    if count != 1:
        raise SystemExit(f'{path}: expected exactly one replacement anchor, found {count}')
    write(path, text.replace(old, new, 1))


def replace_between(path: str, start: str, end: str, replacement: str) -> None:
    text = read(path)
    start_index = text.find(start)
    if start_index < 0:
        raise SystemExit(f'{path}: start marker missing: {start!r}')
    if text.find(start, start_index + 1) >= 0:
        raise SystemExit(f'{path}: start marker is ambiguous: {start!r}')
    end_index = text.find(end, start_index)
    if end_index < 0:
        raise SystemExit(f'{path}: end marker missing: {end!r}')
    write(path, text[:start_index] + replacement + text[end_index:])


# ---------------------------------------------------------------------------
# 1) Broaden only the existing deterministic next-task vocabulary.
#    These phrases are read/route commands, not mutation commands.
# ---------------------------------------------------------------------------
replace_once(
    'lib/domain/app_brain.dart',
    """const _nextTaskTerms = <String>[\n  'next task',\n  'next work',\n  'next issue',\n  'next problem',\n  'do next task',\n  'open next task',\n  'fix next issue',\n  'what next',\n  'ab kya karu',\n  'ab kya karna hai',\n  'agla kaam',\n  'agla task',\n  'agli problem',\n  'अगला काम',\n  'अगला टास्क',\n  'अगली समस्या',\n  'अब क्या करूं',\n  'अब क्या करना है',\n];\n""",
    """const _nextTaskTerms = <String>[\n  'next task',\n  'next safe task',\n  'next work',\n  'next issue',\n  'next problem',\n  'do next task',\n  'start next task',\n  'start work',\n  'open next task',\n  'handle next task',\n  'fix next issue',\n  'what next',\n  'ab kya karu',\n  'ab kya karna hai',\n  'agla kaam',\n  'agla kaam kholo',\n  'agla task',\n  'agli problem',\n  'अगला काम',\n  'अगला काम खोलो',\n  'अगला टास्क',\n  'अगली समस्या',\n  'अब क्या करूं',\n  'अब क्या करना है',\n];\n""",
)

# ---------------------------------------------------------------------------
# 2) Upgrade Aaris Brain's "next task" from a passive plan opener into a
#    deterministic work router. It always rebuilds the queue from live local
#    state, revalidates the exact attention key immediately before routing, and
#    never commits a mutation by itself. Expired stock enters the existing
#    reviewed removal flow; all other exact-row work opens the authoritative
#    editor; multi-row integrity work stays in Needs Attention for explicit row
#    choice; purchasing opens the existing reviewed order surface.
# ---------------------------------------------------------------------------
new_attention_block = r'''  PharmacyAttentionReport _currentAttentionReport() {
    final range = TrackingRange.lastDays(widget.controller.today, 30);
    return PharmacyAttentionReport.build(
      medicines: widget.controller.records,
      settings: widget.controller.settings,
      today: widget.controller.today,
      reorder: widget.controller.tracking(range).reorder,
      sales: widget.controller.sales,
    );
  }

  PharmacyOperationsPlan _currentOperationsPlan(
    PharmacyAttentionReport report,
  ) => PharmacyOperationsPlan.build(
    items: report.items,
    medicines: widget.controller.records,
  );

  OperationsPlanStep? _findPlanStep(
    PharmacyOperationsPlan plan,
    String key,
  ) {
    for (final step in plan.steps) {
      if (step.item.key == key) return step;
    }
    return null;
  }

  Future<void> _openRecommendedAttentionStep(
    OperationsPlanStep proposed,
  ) async {
    if (!mounted) return;

    // Never route from a cached operational recommendation. Rebuild the
    // deterministic report and require the exact attention key to still exist
    // and still be unblocked immediately before navigation. A concurrent stock
    // change therefore invalidates the recommendation instead of acting on a
    // stale task.
    final liveReport = _currentAttentionReport();
    final livePlan = _currentOperationsPlan(liveReport);
    final step = _findPlanStep(livePlan, proposed.item.key);
    if (step == null || step.blocked) {
      final replacement = livePlan.nextStep;
      setState(
        () => _reply = replacement == null
            ? 'The operating queue changed before this task opened. Aaris stopped instead of using a stale recommendation. Open Needs attention to review the current verified blockers.'
            : 'The operating queue changed before this task opened. Nothing was changed. The new next safe task is ${replacement.item.title}.',
      );
      if (replacement == null) {
        await Navigator.push<void>(
          context,
          MaterialPageRoute(
            builder: (_) => AttentionScreen(controller: widget.controller),
          ),
        );
      }
      return;
    }

    final item = step.item;
    if (item.isReorder) {
      await _reorderReview();
      return;
    }

    final records = item.stockIds
        .map((id) => widget.controller.snapshot.records[id])
        .whereType<Medicine>()
        .where((medicine) => !medicine.archived)
        .toList(growable: false);

    // Cross-row conflicts and grouped FEFO-readiness findings deliberately
    // require an explicit row choice. Aaris may prioritize the work, but it may
    // not guess which physical pack the pharmacist intends to correct.
    if (records.length != 1) {
      setState(
        () => _reply = records.isEmpty
            ? 'That recommended task changed while Aaris was opening it. Nothing was changed; the live operating plan is opening for re-evaluation.'
            : '${item.title} involves ${records.length} exact stock rows. Aaris opened the operating plan so you can choose the physical row instead of guessing.',
      );
      await Navigator.push<void>(
        context,
        MaterialPageRoute(
          builder: (_) => AttentionScreen(controller: widget.controller),
        ),
      );
      return;
    }

    final record = records.single;
    _remember(record);
    widget.onOpenSection(AppSection.stock);
    setState(
      () => _reply =
          'Starting the next safe task: ${item.title}. ${step.actionLabel} Aaris has selected only this exact stock ID; no inventory change happens without the existing review/confirmation boundary.',
    );
    await Future<void>.delayed(Duration.zero);
    if (!mounted) return;

    if (item.kind == AttentionKind.expiredStock) {
      // Expiry itself is a deterministic stored-date fact. Route straight into
      // the existing protected Expired removal review, which still shows the
      // exact stock identity and requires explicit confirmation before archive.
      await _removeTarget(record, reasonHint: RemovalReasonHint.expired);
      return;
    }

    // Verification, quantity, location, FEFO-placement and integrity work all
    // reuse the authoritative editor. The task router does not prefill uncertain
    // values and cannot bypass editor/controller validation.
    await openEditor(context, widget.controller, record: record);
  }

  void _refreshAttentionReply(String attemptedKey) {
    if (!mounted) return;
    final report = _currentAttentionReport();
    if (report.isEmpty) {
      setState(
        () => _reply =
            'Task review closed. The deterministic operating queue is clear right now.',
      );
      return;
    }

    final plan = _currentOperationsPlan(report);
    final attempted = _findPlanStep(plan, attemptedKey);
    final next = plan.nextStep;
    setState(() {
      if (attempted != null) {
        _reply =
            'Task review closed. “${attempted.item.title}” still needs attention, so Aaris kept it in the live queue instead of pretending it was completed.${next == null ? '' : ' Next safe task: ${next.item.title}.'}';
      } else if (next != null) {
        _reply =
            'The reviewed task is no longer in the live attention queue. Aaris recalculated from current inventory; next safe task: ${next.item.title}.';
      } else {
        _reply =
            'The reviewed task changed the queue. Remaining work is waiting on verified prerequisites, so Aaris will not advance automatically.';
      }
    });
  }

  Future<void> _attentionBrief({bool focusNext = false}) async {
    final report = _currentAttentionReport();
    final plan = _currentOperationsPlan(report);
    final next = plan.nextStep;

    if (report.isEmpty) {
      if (mounted) {
        setState(
          () => _reply = focusNext
              ? 'There is no deterministic pharmacist task waiting right now. Nothing changed.'
              : 'Attention brief: no deterministic operational issue needs attention right now.',
        );
      }
      return;
    }

    if (!focusNext) {
      if (mounted) {
        setState(
          () => _reply = next == null
              ? 'Attention queue: ${report.items.length} items, but no downstream task is safe to start until its recorded prerequisites are rechecked. Opening the operating plan; nothing will be changed automatically.'
              : 'Attention queue: ${report.items.length} item${report.items.length == 1 ? '' : 's'} · ${report.critical} critical · ${report.high} high · ${report.medium} medium · ${plan.readyCount} ready now · ${plan.blockedCount} waiting on prerequisites. Next safe task: ${next.item.title}.',
        );
      }
      await Future<void>.delayed(Duration.zero);
      if (!mounted) return;
      await Navigator.push<void>(
        context,
        MaterialPageRoute(
          builder: (_) => AttentionScreen(controller: widget.controller),
        ),
      );
      return;
    }

    if (next == null) {
      if (mounted) {
        setState(
          () => _reply =
              'No task can be started safely from the current queue because the remaining work is waiting on verified prerequisites. Opening the operating plan instead; nothing will be changed automatically.',
        );
      }
      await Future<void>.delayed(Duration.zero);
      if (!mounted) return;
      await Navigator.push<void>(
        context,
        MaterialPageRoute(
          builder: (_) => AttentionScreen(controller: widget.controller),
        ),
      );
      return;
    }

    if (mounted) {
      setState(
        () => _reply =
            'Recommended next: ${next.item.title}. Revalidating the live queue before opening the exact safe workflow…',
      );
    }
    await Future<void>.delayed(Duration.zero);
    if (!mounted) return;
    await _openRecommendedAttentionStep(next);
    if (!mounted) return;
    _refreshAttentionReply(next.item.key);
  }

'''
replace_between(
    'lib/ui/brain_screen.dart',
    '  Future<void> _attentionBrief({bool focusNext = false}) async {',
    '  void _bulkRemoveBlocked() {',
    new_attention_block,
)

# ---------------------------------------------------------------------------
# 3) Regression tests: parser vocabulary + widget proof that "next task" routes
#    directly to protected expired-stock review without silent destruction.
# ---------------------------------------------------------------------------
replace_once(
    'test/app_brain_test.dart',
    """    test('routes proactive attention brief locally', () {\n      final intent = parseAppBrainIntent('aaj kya karna hai');\n      expect(intent.action, AppBrainAction.attentionBrief);\n      expect(intent.confidence, greaterThanOrEqualTo(.98));\n    });\n""",
    """    test('routes proactive attention brief locally', () {\n      final intent = parseAppBrainIntent('aaj kya karna hai');\n      expect(intent.action, AppBrainAction.attentionBrief);\n      expect(intent.confidence, greaterThanOrEqualTo(.98));\n    });\n\n    test('routes operational autopilot phrases to the next safe task', () {\n      for (final command in [\n        'next safe task',\n        'start next task',\n        'start work',\n        'agla kaam kholo',\n        'अगला काम खोलो',\n      ]) {\n        final intent = parseAppBrainIntent(command);\n        expect(intent.action, AppBrainAction.nextAttentionTask, reason: command);\n        expect(intent.destructive, isFalse, reason: command);\n        expect(intent.mutatesInventory, isFalse, reason: command);\n      }\n    });\n""",
)

brain_test = read('test/brain_screen_test.dart')
insert_at = brain_test.rfind('\n}')
if insert_at < 0:
    raise SystemExit('test/brain_screen_test.dart: main closing brace not found')
widget_test = r'''

  testWidgets(
    'next task routes expired stock directly to protected review without silent mutation',
    (tester) async {
      final medicine = _stock(
        'autopilot-expired',
        name: 'ExpiryTask',
        strength: '500mg',
        expiry: '2026-09-01',
        batchNumber: 'EXP-1',
        location: 'Rack E1',
        quantity: 4,
      );
      final controller = PharmacyController(
        MemoryInventoryStorage(
          InventorySnapshot(records: {medicine.id: medicine}),
        ),
        clock: () => _today,
        backgroundSearch: false,
      );
      await controller.initialize();
      addTearDown(controller.dispose);

      AppSection? openedSection;
      await tester.pumpWidget(
        MaterialApp(
          theme: pharmacyTheme(),
          home: Scaffold(
            body: BrainScreen(
              controller: controller,
              onOpenSection: (section) => openedSection = section,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final beforeRevision = controller.snapshot.revision;
      await tester.enterText(find.byType(TextField).first, 'next task');
      await tester.tap(find.byTooltip('Run command').first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));

      expect(openedSection, AppSection.stock);
      expect(find.text('Remove ExpiryTask?'), findsOneWidget);
      expect(find.textContaining('Reason: Expired'), findsOneWidget);
      expect(controller.snapshot.records[medicine.id]!.archived, isFalse);
      expect(controller.snapshot.revision, beforeRevision);

      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));

      expect(controller.snapshot.records[medicine.id]!.archived, isFalse);
      expect(controller.snapshot.revision, beforeRevision);
      expect(find.textContaining('still needs attention'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
      await tester.pump();
    },
  );
'''
write('test/brain_screen_test.dart', brain_test[:insert_at] + widget_test + brain_test[insert_at:])

# ---------------------------------------------------------------------------
# 4) Architecture contract + focused implementation note.
# ---------------------------------------------------------------------------
replace_once(
    'docs/ARCHITECTURE.md',
    '## Backup and local-only boundary\n',
    """## Deterministic operational autopilot\n\nAaris Brain's **Next task** command is an execution router over the existing local\nNeeds Attention plan, not a second automation engine. The router rebuilds the\nattention report from the current Medicine Database, revalidates the exact task\nkey immediately before navigation, and stops if that task disappeared or became\nblocked. Exact single-row work opens the authoritative editor; an expired row may\nopen the existing protected Expired-removal review directly; grouped/conflicting\nrows require explicit pharmacist selection; purchasing opens Order Review. After\nthe workflow closes, Aaris recalculates the queue and reports whether the task is\nresolved, still pending, or replaced by a new next-safe task. The router never\nprefills uncertain medical facts and never commits inventory by itself. Existing\nreview, confirmation, revision/CAS, audit and Undo boundaries remain authoritative.\n\n## Backup and local-only boundary\n""",
)

Path('docs/AARIS_OPERATIONAL_AUTOPILOT_2026_09_10.md').write_text(
    """# Aaris Brain — Deterministic Operational Autopilot (2026-09-10)\n\nThis upgrade makes Aaris Brain behave more like a pharmacist work coordinator\nwithout turning AI into an inventory authority.\n\n## What changed\n\n- `next task`, `next safe task`, `start next task`, `start work`, Hindi/Hinglish\n  variants and the existing quick action all use the same deterministic route.\n- The next task is selected from `PharmacyOperationsPlan`, which already orders\n  safety and fact-verification prerequisites ahead of dependent FEFO/reorder work.\n- Immediately before navigation, Aaris rebuilds the live attention report and\n  requires the exact task key to still exist and remain unblocked. Concurrent\n  inventory changes therefore invalidate stale recommendations.\n- A single expired stock row routes directly to the existing Expired removal\n  review with the exact stock ID and `Expired` reason already identified from the\n  deterministic date engine. The pharmacist still must explicitly confirm; no\n  archive occurs from the command alone.\n- Other exact-row verification/location/quantity/FEFO work opens the existing\n  authoritative medicine editor without guessing missing values.\n- Multi-row conflicts and grouped readiness findings open Needs Attention for an\n  explicit physical-row choice rather than guessing. Reorder work opens the\n  existing reviewed Order Review surface.\n- When the workflow closes, Aaris recomputes the queue from authoritative current\n  state and reports whether the attempted task is still pending, resolved, or has\n  been replaced by another safe task.\n\n## Safety properties\n\nThere is still one Medicine Database and one mutation gateway. The autopilot is a\nrouter only: it does not write SQL, invent medicine facts, trust uncertain OCR/AI,\nmark a task complete by UI navigation, or bypass explicit review. Existing\nrevision checks, stale-review rejection, atomic commits, audit history and Undo\nremain intact.\n\n## Regression coverage\n\nParser tests prove new autopilot phrases remain non-mutating intents. A widget\nregression proves an expired-stock `next task` opens the protected review directly\nwhile database revision and archive state remain unchanged until confirmation.\n""",
    encoding='utf-8',
)

print('Aaris operational autopilot patch prepared successfully.')
