import 'dart:io';
import '../test/date_input_contract.dart';

void main() {
  var passed = 0, failed = 0;
  for (final entry in dateInputContract().entries) {
    try {
      entry.value();
      passed++;
    } catch (e) {
      failed++;
      stdout.writeln('FAIL: ${entry.key}: $e');
    }
  }
  stdout.writeln('Date input contract: $passed passed, $failed failed.');
  if (failed > 0) exitCode = 1;
}
