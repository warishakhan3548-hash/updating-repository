import 'package:aaris_pharmacy/domain/import_text_guard.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('full backup schema family never enters medicine-list import', () {
    for (final schema in <String>[
      'aaris.pharmacy.backup.v1',
      'aaris.pharmacy.backup.v2',
      'aaris.pharmacy.backup.v9',
    ]) {
      expect(
        isAarisPharmacyBackupText('{"schema":"$schema","medicines":[]}'),
        isTrue,
      );
    }
  });

  test('whitespace and fenced backup JSON are still recognized', () {
    expect(
      isAarisPharmacyBackupText(
        '```json\n{ "schema" : "aaris.pharmacy.backup.v2" }\n```',
      ),
      isTrue,
    );
  });

  test('ordinary medicine lists and unrelated JSON stay importable', () {
    expect(isAarisPharmacyBackupText('Dolo 650mg\nCefixime 200mg'), isFalse);
    expect(
      isAarisPharmacyBackupText(
        '{"schema":"supplier.invoice.v1","medicine":"Dolo 650"}',
      ),
      isFalse,
    );
    expect(
      isAarisPharmacyBackupText('note: aaris.pharmacy.backup.v2 migration'),
      isFalse,
    );
  });
}
