import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'AI connections stays simple and keeps local routing independent from cloud credentials',
    () {
      final panel = File('lib/ui/local_models_panel.dart').readAsStringSync();
      final service = File('lib/services/local_ai_service_io.dart')
          .readAsStringSync();
      final ai = File('lib/ui/ai_screen.dart').readAsStringSync();
      final routing = File('lib/services/ai_service.dart').readAsStringSync();

      expect(panel, contains('Download / Change model'));
      expect(panel, contains('Local AI · Ready'));
      expect(panel, contains('Search Qwen, Gemma, Llama or paste model link'));
      expect(panel, contains('Installed models'));
      expect(panel, contains('Use Local AI for scan review'));
      expect(panel, contains('Choose a model and wait for Ready first.'));
      expect(panel, contains('Memory estimates warn; they do not block.'));
      expect(
        panel,
        contains('model file size alone never blocks native inference.'),
      );
      expect(panel, isNot(contains('Weight-file size filter only')));
      expect(
        panel,
        isNot(contains('Browse current public GGUF models or paste an exact')),
      );

      expect(service, contains('LocalModelSetupStage.testing'));
      expect(service, contains('await activate(model.sha256);'));
      expect(service, contains('planLocalExecution('));
      expect(service, contains('memoryWarning'));

      expect(routing, contains('if (config.localBrainEnabled)'));
      expect(routing, contains("await saveConfiguration(config.copyWith(key: ''));"));
      expect(routing, isNot(contains("forgetKey() => _storage.delete")));

      expect(ai, contains('Choose how Aaris uses AI.'));
      expect(ai, contains('Connect with Other AI'));
      expect(ai, contains('Use AI inside the app'));
      expect(ai, contains('Activate Aaris Brain'));
      expect(ai, contains('if (apiExpanded) _apiFields(context)'));
      expect(ai, isNot(contains('Models, external AI, or your own API.')));
      expect(ai, isNot(contains('Key stays in secure device storage.')));

      // Cloud credentials and the local Brain switch are independent
      // capabilities. Saving an API connection must not silently turn off or
      // suspend an already-selected on-device route.
      final saveStart = ai.indexOf('Future<void> _save() async');
      final saveEnd = ai.indexOf('Future<void> _setLocalBrain', saveStart);
      expect(saveStart, greaterThanOrEqualTo(0));
      expect(saveEnd, greaterThan(saveStart));
      final cloudSave = ai.substring(saveStart, saveEnd);
      expect(cloudSave, contains('localBrainEnabled: localBrainEnabled'));
      expect(cloudSave, isNot(contains('localBrainEnabled: false')));
      expect(cloudSave, isNot(contains('await local.suspend();')));
      expect(ai, contains('Cloud connection saved'));
    },
  );

  test('medicine capture keeps an explicit always-available offline lane', () {
    final capture = File('lib/ui/medicine_capture.dart').readAsStringSync();

    expect(capture, contains('Scan one pack · Offline Core'));
    expect(
      capture,
      contains('No model download, API key or internet is required.'),
    );
    expect(capture, contains('Scan with cloud AI'));
    expect(
      capture,
      contains("Only this scan’s bounded OCR may leave the device."),
    );
  });
}
