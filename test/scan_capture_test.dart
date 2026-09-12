import 'package:flutter_test/flutter_test.dart';

import 'scan_capture_contract.dart';

void main() {
  for (final entry in scanCaptureContract().entries) {
    test(entry.key, entry.value);
  }
}
