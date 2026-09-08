import 'dart:io';

import '../test/medicine_understanding_contract.dart';

void main() {
  var passed = 0;
  var failed = 0;
  for (final contract in medicineUnderstandingContract().entries) {
    try {
      contract.value();
      passed++;
    } catch (error, stack) {
      failed++;
      stdout.writeln('FAIL: ${contract.key}\n$error\n$stack');
    }
  }
  stdout.writeln(
    'Medicine understanding contract: $passed passed, $failed failed.',
  );
  if (failed > 0) exitCode = 1;
}
