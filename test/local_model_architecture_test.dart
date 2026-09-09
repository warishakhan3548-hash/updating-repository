import 'package:flutter_test/flutter_test.dart';

import '../tool/check_local_ai.dart' as protocol;
import '../tool/check_local_ai_runtime.dart' as runtime;
import '../tool/check_model_catalogue.dart' as catalogue;
import '../tool/check_model_preflight.dart' as preflight;

// The same source-only contracts can run in restricted workspaces and in the
// owner's normal Flutter suite. These tests never download or load real weights.
void main() {
  test(
    'model catalogue pagination, pinned manifests and bounded cache',
    catalogue.main,
  );
  test('GGUF inspection, memory admission and setup probes', preflight.main);
  test(
    'local tools and medicine evidence retain review authority',
    protocol.main,
  );
  test('local runtime disposal, context and Unicode boundaries', runtime.main);
}
