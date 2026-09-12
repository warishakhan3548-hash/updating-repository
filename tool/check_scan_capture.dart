import 'dart:io';

import '../test/scan_capture_contract.dart';

Future<void> main() async {
  var passed = 0, failed = 0;
  for (final entry in scanCaptureContract().entries) {
    try {
      await entry.value();
      passed++;
    } catch (error, stack) {
      failed++;
      stdout.writeln('FAIL ${entry.key}: $error\n$stack');
    }
  }
  stdout.writeln('Scan/capture contract: $passed passed, $failed failed.');
  if (failed != 0) exitCode = 1;
}
