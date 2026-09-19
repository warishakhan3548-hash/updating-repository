import 'dart:io';

import '../test/video_medicine_contract.dart';

void main() {
  var passed = 0, failed = 0;
  for (final entry in videoMedicineContract().entries) {
    try {
      entry.value();
      passed++;
    } catch (error, stack) {
      failed++;
      stdout.writeln('FAIL ${entry.key}: $error\n$stack');
    }
  }
  stdout.writeln('Video medicine contract: $passed passed, $failed failed.');
  if (failed != 0) exitCode = 1;
}
