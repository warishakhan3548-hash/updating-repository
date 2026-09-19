import 'package:flutter_test/flutter_test.dart';

import '../lib/domain/medicine_date_intelligence.dart';
import '../lib/domain/medicine_ocr_text.dart';
import '../lib/domain/medicine_understanding.dart';

void main() {
  test('overlapping row tolerances cannot create a cyclic date sort', () {
    const lines = [
      MedicineTextLineEvidence(text: 'MFG', left: 100, top: 0,
        width: 30, height: 10),
      MedicineTextLineEvidence(text: 'EXP', left: 50, top: 5,
        width: 30, height: 10),
      MedicineTextLineEvidence(text: '05/26', left: 0, top: 10,
        width: 30, height: 10),
    ];
    for (final order in [
      [0, 1, 2], [0, 2, 1], [1, 0, 2],
      [1, 2, 0], [2, 0, 1], [2, 1, 0],
    ]) {
      final sorted = order.map((index) => lines[index]).toList()
        ..sort(compareMedicineDateLayoutPosition);
      expect(sorted.map((line) => line.text), ['MFG', 'EXP', '05/26']);
    }
  });

  test('existing labelled compact/spaced date grammar survives the layout fix', () {
    for (final entry in {
      'MFG05/26': '2026-05',
      'MFG0526': '2026-05',
      'EXP04/28': '2028-04',
      'MFG052026': '2026-05',
      'EXPMAY28': '2028-05',
      'MFG 05 04 2027': '2027-04-05',
    }.entries) {
      expect(parseMedicineDateText(normalizeMedicineOcrLine(entry.key))?.value,
        entry.value);
    }
    expect(parseMedicineDateText('EXP 31/02/2028'), isNull);
  });
}
