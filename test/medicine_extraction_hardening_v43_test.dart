import 'package:aaris_pharmacy/domain/local_scan_evidence.dart';
import 'package:aaris_pharmacy/domain/medicine_date_parser.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('medicine extraction hardening V43', () {
    test('long OCR keeps late identity, electrolyte dose, dates, and owner', () {
      String filler(String prefix, int count) => List<String>.generate(
        count,
        (index) =>
            '$prefix $index regulatory packaging copy for pharmacy evidence selection only',
      ).join('\n');

      final source = <String>[
        'PACKAGE INSERT',
        'READ ALL PRINTED INFORMATION',
        filler('LEGAL FRONT', 72),
        'PRODUCT NAME: ELECTRAL FORTE',
        'ORAL SOLUTION',
        filler('LEGAL MIDDLE', 38),
        'SODIUM CHLORIDE 20 mEq/15 ml',
        filler('LEGAL DATE', 22),
        'MFG 04/2026',
        'EXP 04/2028',
        filler('LEGAL OWNER', 10),
        'MANUFACTURED BY FDC LIMITED',
      ].join('\n');

      expect(source.length, greaterThan(7000));
      final selected = LocalScanEvidence.select(source, limit: 1600);
      final text = selected.excerpts.map((entry) => entry.text).join('\n');

      expect(selected.truncated, isTrue);
      expect(text, contains('PRODUCT NAME: ELECTRAL FORTE'));
      expect(text, contains('SODIUM CHLORIDE 20 mEq/15 ml'));
      expect(text, contains('MFG 04/2026'));
      expect(text, contains('EXP 04/2028'));
      expect(text, contains('MANUFACTURED BY FDC LIMITED'));
    });

    test('raw spatial dates accept full-width and Arabic OCR punctuation', () {
      expect(
        parseMedicineDateText('ＭＦＧ：０５．０４．２０２７')?.value,
        '2027-04-05',
      );
      expect(
        parseMedicineDateText('EXP\u3000٠٤٫٢٠٢٨')?.value,
        '2028-04',
      );
      expect(parseMedicineDateText('ＥＸＰ０４２８')?.value, '2028-04');
    });
  });
}
