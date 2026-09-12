import 'package:flutter_test/flutter_test.dart';

import 'offline_capture_context_contract.dart';

void main() {
  for (final entry in offlineCaptureContextContract().entries) {
    test(entry.key, entry.value);
  }
}
