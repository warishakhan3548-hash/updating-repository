import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'Aaris Brain keeps chat primary with compact safe quick actions',
    () {
      final brain = File('lib/ui/brain_screen.dart').readAsStringSync();
      final ai = File('lib/ui/ai_screen.dart').readAsStringSync();

      expect(brain, isNot(contains('Aaris App Brain · offline commands')));
      expect(brain, isNot(contains('_brainBar(')));
      expect(ai, contains("hintText: 'Ask AI or paste pharmacy JSON…'"));
      expect(
        RegExp("hintText: 'Ask AI or paste pharmacy JSON…'")
            .allMatches(ai)
            .length,
        1,
      );
      expect(brain, contains('onLocalCommand: _handleUnifiedCommand'));
      expect(brain, contains('onQuickAction: _handleQuickAction'));

      for (final label in <String>[
        "label: 'Add'",
        "label: 'Sold'",
        "label: 'Stock'",
        "label: 'More'",
      ]) {
        expect(ai, contains(label), reason: label);
      }
      expect(ai, contains("title: const Text('Removed stock')"));
      expect(ai, contains("title: const Text('Delete medicine')"));
      expect(ai, contains("title: const Text('Modify medicine')"));
      expect(ai, isNot(contains('GridView.count(')));
      expect(ai, contains('status: true'));
      expect(ai, contains('class _AiEmptyConversation'));
      expect(ai, contains('if (_messages.isEmpty &&'));
      expect(ai, contains("'Ask Aaris naturally'"));
      expect(ai, contains('color: Colors.white.withAlpha(238)'));
      expect(
        ai,
        isNot(
          contains(
            'child: Surface(\n        color: _aiPurple.withAlpha(8)',
          ),
        ),
      );

      final buildStart = ai.indexOf(
        'Widget build(BuildContext context) => ActiveListenableBuilder(',
      );
      final buildEnd = ai.indexOf('class _AiHubHeader', buildStart);
      final build = ai.substring(buildStart, buildEnd);
      expect(build, contains('rebuildToken: _screenRebuildToken'));
      expect(
        ai,
        contains('_plan == null ? null : controller.snapshot.revision'),
      );
      expect(
        ai,
        contains(
          'plan.baseRevision != widget.controller.snapshot.revision',
        ),
      );
      expect(
        ai,
        contains('Inventory changed after this review.'),
      );
      expect(build, contains('child: CustomScrollView('));
      expect(build, contains('sliver: SliverList.builder('));
      expect(build, contains('itemCount: _messages.length'));
      expect(build, isNot(contains('for (final message in _messages)')));
      expect(
        build.indexOf('SliverList.builder('),
        lessThan(build.indexOf('MedicineIntakePanel(')),
      );
      expect(
        build.indexOf('Expanded('),
        lessThan(build.indexOf('_AiQuickActions(')),
      );
      expect(
        build.indexOf('_AiQuickActions('),
        lessThan(build.indexOf('_AiComposer(')),
      );

      final app = File('lib/app.dart').readAsStringSync();
      expect(app, contains('autopilot: widget.autopilot'));
      expect(app, contains('onOpenWorkQueue: () => unawaited(_openAutopilotQueue())'));
      expect(app, isNot(contains('AarisAutopilotBeacon(')));
      expect(app, isNot(contains('Positioned(')));

      final deleteRoute = RegExp(
        r'AiHubQuickAction\.delete\s*=>\s*_openQuickTargetPicker\(\s*AppBrainAction\.removeMedicine,?\s*\)',
        multiLine: true,
      );
      final modifyRoute = RegExp(
        r'AiHubQuickAction\.modify\s*=>\s*_openQuickTargetPicker\(\s*AppBrainAction\.editMedicine,?\s*\)',
        multiLine: true,
      );
      expect(deleteRoute.hasMatch(brain), isTrue);
      expect(modifyRoute.hasMatch(brain), isTrue);
    },
  );

  test(
    'scan evidence Ask delegates route selection to the unified AI hub',
    () {
      final panel = File('lib/ui/medicine_intake_panel.dart')
          .readAsStringSync();
      final ai = File('lib/ui/ai_screen.dart').readAsStringSync();
      final routing = File('lib/services/ai_service.dart').readAsStringSync();

      // Ask may first advance a durable intake job before handing the evidence
      // to the unified composer. The routing contract is the callback itself,
      // not the exact shape of the surrounding onPressed closure.
      expect(panel, contains('await queue.continueWithDraft(job);'));
      expect(panel, contains('widget.onAsk?.call(draft.rawText)'));
      expect(
        panel,
        isNot(contains('!LocalAiService.instance.hasSelection ||')),
      );
      expect(ai, contains('MedicineIntakePanel('));
      expect(ai, contains('unawaited(_ask());'));
      expect(
        ai,
        contains("? _local.hasSelection\n      : _configuration.key.isNotEmpty"),
      );
      expect(routing, contains('if (config.localBrainEnabled)'));
      // The cloud route explicitly validates the configured endpoint before it
      // derives the conversation-specific provider configuration. Do not bind
      // this source contract to a throwaway local variable name.
      expect(routing, contains('config.uri;'));
      expect(
        routing,
        contains('final conversationConfig = config.forConversation;'),
      );
    },
  );
  test('AI More quick action serializes modal route opening', () {
    final source = File('lib/ui/ai_screen.dart').readAsStringSync();

    expect(source, contains('class _AiQuickActions extends StatefulWidget'));
    expect(source, contains('bool _moreOpening = false;'));
    expect(
      source,
      contains('if (widget.busy || _moreOpening || !mounted) return;'),
    );
    expect(source, contains('setState(() => _moreOpening = true);'));
    expect(source, contains('onTap: widget.busy || _moreOpening'));
    expect(
      source,
      contains('if (mounted) setState(() => _moreOpening = false);'),
    );
  });

}
