import 'package:aaris_pharmacy/services/medicine_intake_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('medicine intake exposes one stable read-only queue view', () {
    final queue = MedicineIntakeService.instance;
    final first = queue.jobs;

    expect(identical(first, queue.jobs), isTrue);
    expect(first.clear, throwsUnsupportedError);
  });
}
