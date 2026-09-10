/// Conservative parser for GS1 healthcare element strings emitted by barcode
/// scanners. It intentionally recognizes only the small identity/traceability
/// subset Aaris can use without guessing: GTIN (01), batch/lot (10), production
/// date (11), expiry (17) and serial (21).
///
/// Variable-length fields are never split without an FNC1/group separator unless
/// they are the final field. Unknown application identifiers stop parsing rather
/// than allowing one batch/serial value to bleed into another field.
class Gs1HealthcareData {
  const Gs1HealthcareData({
    required this.raw,
    this.gtin = '',
    this.batchLot = '',
    this.manufacturingYyMmDd = '',
    this.expiryYyMmDd = '',
    this.serial = '',
  });

  final String raw;
  final String gtin;
  final String batchLot;
  final String manufacturingYyMmDd;
  final String expiryYyMmDd;
  final String serial;

  bool get hasTraceability =>
      gtin.isNotEmpty ||
      batchLot.isNotEmpty ||
      manufacturingYyMmDd.isNotEmpty ||
      expiryYyMmDd.isNotEmpty ||
      serial.isNotEmpty;
}

Gs1HealthcareData? parseGs1HealthcareBarcode(String input) {
  var raw = input.trim();
  if (raw.isEmpty || raw.length > 512) return null;

  // AIM symbology identifiers such as ]d2 can prefix a decoded GS1 DataMatrix.
  if (raw.length >= 3 && raw.codeUnitAt(0) == 0x5d) {
    final identifier = raw.substring(0, 3).toLowerCase();
    if (identifier == ']d2' || identifier == ']c1') raw = raw.substring(3);
  }

  final humanReadable = _parseParenthesized(raw);
  if (humanReadable != null) return humanReadable;
  return _parseElementString(raw);
}

Gs1HealthcareData? _parseParenthesized(String raw) {
  final marker = RegExp(r'\((01|10|11|17|21)\)');
  final matches = marker.allMatches(raw).toList(growable: false);
  if (matches.isEmpty || matches.first.start > 4) return null;

  final values = <String, String>{};
  for (var index = 0; index < matches.length; index++) {
    final match = matches[index];
    final ai = match.group(1)!;
    final end = index + 1 < matches.length ? matches[index + 1].start : raw.length;
    final value = raw.substring(match.end, end).trim();
    if (!_accept(ai, value, values)) return null;
  }
  return _result(raw, values);
}

Gs1HealthcareData? _parseElementString(String raw) {
  const groupSeparator = '\u001d';
  var cursor = 0;
  final values = <String, String>{};

  // Aaris only treats an unparenthesized payload as GS1 when it starts with the
  // canonical GTIN AI. This prevents arbitrary numeric/lot strings from being
  // reinterpreted as structured medicine data.
  if (!raw.startsWith('01')) return null;

  while (cursor < raw.length) {
    while (cursor < raw.length && raw[cursor] == groupSeparator) {
      cursor++;
    }
    if (cursor >= raw.length) break;
    if (cursor + 2 > raw.length) return null;

    final ai = raw.substring(cursor, cursor + 2);
    cursor += 2;
    int? fixedLength;
    if (ai == '01') {
      fixedLength = 14;
    } else if (ai == '11' || ai == '17') {
      fixedLength = 6;
    } else if (ai != '10' && ai != '21') {
      // Unknown AIs can have arbitrary fixed/variable lengths. Do not guess how
      // to skip them because that can silently corrupt a later batch or expiry.
      return values['01']?.isNotEmpty == true ? _result(raw, values) : null;
    }

    String value;
    if (fixedLength != null) {
      if (cursor + fixedLength > raw.length) return null;
      value = raw.substring(cursor, cursor + fixedLength);
      cursor += fixedLength;
    } else {
      final separator = raw.indexOf(groupSeparator, cursor);
      if (separator < 0) {
        value = raw.substring(cursor);
        cursor = raw.length;
      } else {
        value = raw.substring(cursor, separator);
        cursor = separator + 1;
      }
    }
    if (!_accept(ai, value, values)) return null;
  }
  return _result(raw, values);
}

bool _accept(String ai, String input, Map<String, String> values) {
  final value = input.trim();
  if (value.isEmpty || values.containsKey(ai)) return false;
  switch (ai) {
    case '01':
      if (!RegExp(r'^\d{14}$').hasMatch(value) || !_validGtin(value)) {
        return false;
      }
      break;
    case '11':
    case '17':
      if (!_validGs1Date(value)) return false;
      break;
    case '10':
    case '21':
      if (value.length > 20 || value.contains(RegExp(r'[\x00-\x1c\x1e-\x1f]'))) {
        return false;
      }
      break;
    default:
      return false;
  }
  values[ai] = value;
  return true;
}

Gs1HealthcareData? _result(String raw, Map<String, String> values) {
  final result = Gs1HealthcareData(
    raw: raw,
    gtin: values['01'] ?? '',
    batchLot: values['10'] ?? '',
    manufacturingYyMmDd: values['11'] ?? '',
    expiryYyMmDd: values['17'] ?? '',
    serial: values['21'] ?? '',
  );
  return result.hasTraceability ? result : null;
}

bool _validGs1Date(String value) {
  if (!RegExp(r'^\d{6}$').hasMatch(value)) return false;
  final month = int.parse(value.substring(2, 4));
  final day = int.parse(value.substring(4, 6));
  if (month < 1 || month > 12 || day < 0 || day > 31) return false;
  if (day == 0) return true; // GS1 permits 00 to represent month-end.

  // Validate day/month shape without inventing a century. Leap-day validity is
  // checked using 2000, which deliberately accepts Feb 29 for any YY value; the
  // inventory date resolver can later apply its own century/business-date rule.
  final year = int.parse(value.substring(0, 2));
  final leapSafeYear = year % 4 == 0 ? 2000 : 2001;
  final date = DateTime(leapSafeYear, month, day);
  return date.month == month && date.day == day;
}

bool _validGtin(String digits) {
  if (digits.length != 14 || !RegExp(r'^\d{14}$').hasMatch(digits)) {
    return false;
  }
  var sum = 0;
  for (var index = digits.length - 2, position = 1;
      index >= 0;
      index--, position++) {
    final digit = int.parse(digits[index]);
    sum += digit * (position.isOdd ? 3 : 1);
  }
  return (10 - sum % 10) % 10 == int.parse(digits[digits.length - 1]);
}
