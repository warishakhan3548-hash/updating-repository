import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'AI connections stays simple and uses one authoritative local setup flow',
    () {
      final panel = File('lib/ui/local_models_panel.dart').readAsStringSync();
      final service = File('lib/services/local_ai_service_io.dart')
          .readAsStringSync();
      final ai = File('lib/ui/ai_screen.dart').readAsStringSync();

      expect(panel, contains('Download / Change model'));
      expect(panel, contains('Local AI · Ready'));
      expect(panel, contains('Local AI · Chat Ready'));
      expect(panel, contains('Search Qwen, Gemma, Llama or paste model link'));
      expect(panel, contains('Installed models'));
      expect(panel, contains('Use Local AI for scan review'));
      expect(panel, contains('Choose a model and wait for Chat Ready first.'));
      expect(panel, isNot(contains('Weight-file size filter only')));
      expect(
        panel,
        isNot(contains('Browse current public GGUF models or paste an exact')),
      );

      expect(service, contains('LocalModelSetupStage.testing'));
      expect(service, contains('await activate(model.sha256);'));
      expect(
        service,
        contains('This model is Chat Ready but has not passed the stricter scan-review test.'),
      );
      expect(
        service,
        contains('Local AI Ready · chat works; scan review not verified'),
      );
      expect(
        service,
        contains('Memory data is advisory.'),
      );

      expect(ai, contains('Choose how Aaris uses AI.'));
      expect(ai, contains('Connect with Other AI'));
      expect(ai, contains('Use AI inside the app'));
      expect(ai, contains('Activate Aaris Brain'));
      expect(ai, contains('if (apiExpanded) _apiFields(context)'));
      expect(ai, isNot(contains('Models, external AI, or your own API.')));
      expect(ai, isNot(contains('Key stays in secure device storage.')));
    },
  );
}
