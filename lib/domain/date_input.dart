import 'medicine.dart';

/// Presentation dates are day-first; stored and exchanged dates remain ISO.
String inputDateText(DateTime date, {bool monthOnly = false}) {
  final month = date.month.toString().padLeft(2, '0');
  final year = date.year.toString().padLeft(4, '0');
  return monthOnly
      ? '$month/$year'
      : '${date.day.toString().padLeft(2, '0')}/$month/$year';
}

String normalizeDateDigits(String text) => String.fromCharCodes(
  text.runes.map((code) {
    for (final zero in [0x0966, 0x0660, 0x06f0, 0xff10]) {
      if (code >= zero && code <= zero + 9) return 48 + code - zero;
    }
    return code;
  }),
);

String? inputDateToIso(String raw, {bool monthOnly = false}) {
  final text = normalizeDateDigits(raw).trim();
  if (text.isEmpty) return null;
  // Existing ISO values and complete ISO clipboard dates remain supported.
  if (RegExp(monthOnly ? r'^\d{4}-\d{2}$' : r'^\d{4}-\d{2}-\d{2}$')
      .hasMatch(text)) {
    parseDate(text, monthEnd: monthOnly);
    return text;
  }
  final match = RegExp(
    monthOnly ? r'^(\d{2})/?(\d{4})$' : r'^(\d{2})/?(\d{2})/?(\d{4})$',
  ).firstMatch(text);
  if (match == null) {
    throw FormatException(
      monthOnly
          ? 'Enter all 6 digits: MM/YYYY (for example, 04/2026).'
          : 'Enter all 8 digits: DD/MM/YYYY (for example, 04/09/2026).',
    );
  }
  final iso = monthOnly
      ? '${match[2]}-${match[1]}'
      : '${match[3]}-${match[2]}-${match[1]}';
  parseDate(iso, monthEnd: monthOnly);
  return iso;
}
