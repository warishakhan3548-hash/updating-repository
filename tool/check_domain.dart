import 'dart:io';
import '../test/domain_contract.dart';

void main() {
  var passed = 0, failed = 0;
  for (final contract in domainContract().entries) {
    try {
      contract.value();
      passed++;
    } catch (e, stack) {
      failed++;
      stdout.writeln('FAIL: ${contract.key}\n$e\n$stack');
    }
  }
  stdout.writeln('Domain contract: $passed passed, $failed failed.');
  if (failed > 0) exitCode = 1;
}
