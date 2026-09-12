import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'Aaris Brain uses one unified AI composer with six real quick actions',
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
        "label: 'Sold'",
        "label: 'Removed'",
        "label: 'Stock summary'",
        "label: 'Add'",
        "label: 'Delete'",
        "label: 'Modify'",
      ]) {
        expect(ai, contains(label), reason: label);
      }

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

  test('scan evidence Ask delegates route selection to the unified AI hub', () {
    final panel = File('lib/ui/medicine_intake_panel.dart').readAsStringSync();
    final ai = File('lib/ui/ai_screen.dart').readAsStringSync();
    final routing = File('lib/services/ai_service.dart').readAsStringSync();

    expect(panel, contains('onPressed: () => widget.onAsk!(draft.rawText)'));
    expect(panel, isNot(contains('!LocalAiService.instance.hasSelection ||')));
    expect(ai, contains('MedicineIntakePanel('));
    expect(ai, contains('unawaited(_ask());'));
    expect(
      ai,
      contains("? _local.hasSelection\n      : _configuration.key.isNotEmpty"),
    );
    expect(routing, contains('if (config.localBrainEnabled)'));
    expect(routing, contains('final endpoint = config.uri;'));
  });
}
