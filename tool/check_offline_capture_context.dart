import 'dart:io';

import '../test/offline_capture_context_contract.dart';

Future<void> main() async {
  var passed = 0, failed = 0;
  for (final entry in offlineCaptureContextContract().entries) {
    try {
      await entry.value();
      passed++;
    } catch (error, stack) {
      failed++;
      stdout.writeln('FAIL ${entry.key}: $error\n$stack');
    }
  }
  stdout.writeln(
    'Offline capture/context contract: $passed passed, $failed failed.',
  );
  if (failed != 0) exitCode = 1;
}
