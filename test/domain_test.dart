import 'package:flutter_test/flutter_test.dart';
import 'domain_contract.dart';

void main() {
  for (final contract in domainContract().entries) {
    test(contract.key, contract.value);
  }
}
