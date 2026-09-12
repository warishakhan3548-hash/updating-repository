import 'package:flutter_test/flutter_test.dart';

import 'video_medicine_contract.dart';

void main() {
  for (final entry in videoMedicineContract().entries) {
    test(entry.key, entry.value);
  }
}
