import 'package:flutter_test/flutter_test.dart';

import 'medicine_understanding_contract.dart';

void main() {
  for (final contract in medicineUnderstandingContract().entries) {
    test(contract.key, contract.value);
  }
}
