import 'dart:convert';

import 'gs1_healthcare.dart';

/// Structured traceability recovered from a machine-readable medicine code.
///
/// This layer never treats a URL/QR as proof of authenticity. A checksum-valid
/// GTIN is an identity key that may resolve against Aaris' verified local/master
/// catalogue; batch/date fields remain physical-pack evidence.
enum RegulatoryMedicineCodeKind {
  gs1ElementString,
  gs1DigitalLink,
  labelledPayload,
}

class RegulatoryMedicineCodeData {
  const RegulatoryMedicineCodeData({
    required this.raw,
    required this.kind,
    this.gtin = '',
    this.batchLot = '',
    this.manufacturingYyMmDd = '',
    this.expiryYyMmDd = '',
    this.serial = '',
  });

  final String raw;
  final RegulatoryMedicineCodeKind kind;
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

  bool get hasVerifiedProductIdentifier => gtin.isNotEmpty;
}

RegulatoryMedicineCodeData? parseRegulatoryMedicineCode(String input) {
  final raw = input.trim();
  if (raw.isEmpty || raw.length > 1600) return null;

  final gs1 = parseGs1HealthcareBarcode(raw);
  if (gs1 != null) {
    return RegulatoryMedicineCodeData(
      raw: raw,
      kind: RegulatoryMedicineCodeKind.gs1ElementString,
      gtin: gs1.gtin,
      batchLot: gs1.batchLot,
      manufacturingYyMmDd: gs1.manufacturingYyMmDd,
      expiryYyMmDd: gs1.expiryYyMmDd,
      serial: gs1.serial,
    );
  }

  return _parseDigitalLink(raw) ?? _parseLabelledPayload(raw);
}

RegulatoryMedicineCodeData? _parseDigitalLink(String raw) {
  final uri = Uri.tryParse(raw);
  if (uri == null ||
      !(uri.scheme == 'https' || uri.scheme == 'http') ||
      uri.host.isEmpty) {
    return null;
  }

  final values = <String, String>{};
  final segments = uri.pathSegments
      .map((value) => value.trim())
      .where((value) => value.isNotEmpty)
      .take(40)
      .toList(growable: false);
  for (var index = 0; index + 1 < segments.length; index++) {
    final ai = segments[index];
    if (!const {'01', '10', '11', '17', '21'}.contains(ai)) continue;
    final value = segments[index + 1].trim();
    if (value.isEmpty) continue;
    values.putIfAbsent(ai, () => value);
    index++;
  }
  for (final ai in const ['01', '10', '11', '17', '21']) {
    final query = uri.queryParameters[ai]?.trim() ?? '';
    if (query.isNotEmpty) values.putIfAbsent(ai, () => query);
  }

  final gtin = _normalizeGtin(values['01'] ?? '');
  if (gtin.isEmpty) return null;
  final batch = _boundedLot(values['10'] ?? '');
  final mfg = _normalizeDate(values['11'] ?? '');
  final expiry = _normalizeDate(values['17'] ?? '');
  final serial = _boundedLot(values['21'] ?? '');
  return RegulatoryMedicineCodeData(
    raw: raw,
    kind: RegulatoryMedicineCodeKind.gs1DigitalLink,
    gtin: gtin,
    batchLot: batch,
    manufacturingYyMmDd: mfg,
    expiryYyMmDd: expiry,
    serial: serial,
  );
}

RegulatoryMedicineCodeData? _parseLabelledPayload(String raw) {
  if (raw.startsWith('http://') || raw.startsWith('https://')) return null;
  final values = <String, String>{};

  if (raw.startsWith('{') && raw.endsWith('}')) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        for (final entry in decoded.entries.take(80)) {
          if (entry.key is! String || entry.value == null) continue;
          final key = _labelKey(entry.key as String);
          if (key.isEmpty) continue;
          final value = entry.value.toString().trim();
          if (value.isNotEmpty) values.putIfAbsent(key, () => value);
        }
      }
    } catch (_) {
      // Fall through to the strict labelled-text parser.
    }
  }

  final matcher = RegExp(
    r'\b(gtin|batch(?:\s*(?:no|number))?|lot(?:\s*no)?|mfg|mfd|manufacturing(?:\s*date)?|exp|expiry|expiration(?:\s*date)?|serial(?:\s*(?:no|number))?)\s*[:=]\s*([^;|\r\n]{1,80})',
    caseSensitive: false,
  );
  for (final match in matcher.allMatches(raw).take(24)) {
    final key = _labelKey(match.group(1) ?? '');
    final value = (match.group(2) ?? '').trim();
    if (key.isNotEmpty && value.isNotEmpty) {
      values.putIfAbsent(key, () => value);
    }
  }
  if (values.isEmpty) return null;

  final gtin = _normalizeGtin(values['01'] ?? '');
  final batch = _boundedLot(values['10'] ?? '');
  final mfg = _normalizeDate(values['11'] ?? '');
  final expiry = _normalizeDate(values['17'] ?? '');
  final serial = _boundedLot(values['21'] ?? '');
  final facts = <String>[
    gtin,
    batch,
    mfg,
    expiry,
    serial,
  ].where((value) => value.isNotEmpty).length;

  // One labelled GTIN is independently checksum-verifiable. Without a GTIN,
  // require at least two explicit traceability facts so ordinary promotional QR
  // text cannot be promoted into structured medicine evidence accidentally.
  if (gtin.isEmpty && facts < 2) return null;
  if (facts == 0) return null;
  return RegulatoryMedicineCodeData(
    raw: raw,
    kind: RegulatoryMedicineCodeKind.labelledPayload,
    gtin: gtin,
    batchLot: batch,
    manufacturingYyMmDd: mfg,
    expiryYyMmDd: expiry,
    serial: serial,
  );
}

String _labelKey(String raw) {
  final key = raw.toLowerCase().replaceAll(RegExp(r'[^a-z]'), '');
  if (key == 'gtin') return '01';
  if (key.startsWith('batch') || key.startsWith('lot')) return '10';
  if (key == 'mfg' || key == 'mfd' || key.startsWith('manufacturing')) {
    return '11';
  }
  if (key == 'exp' ||
      key.startsWith('expiry') ||
      key.startsWith('expiration')) {
    return '17';
  }
  if (key.startsWith('serial')) return '21';
  return '';
}

String _normalizeGtin(String raw) {
  final digits = raw.replaceAll(RegExp(r'\D'), '');
  if (!const {8, 12, 13, 14}.contains(digits.length) || !_validGtin(digits)) {
    return '';
  }
  return digits.padLeft(14, '0');
}

bool _validGtin(String digits) {
  if (!const {8, 12, 13, 14}.contains(digits.length)) return false;
  var sum = 0;
  for (
    var index = digits.length - 2, position = 1;
    index >= 0;
    index--, position++
  ) {
    sum += int.parse(digits[index]) * (position.isOdd ? 3 : 1);
  }
  return (10 - sum % 10) % 10 == int.parse(digits[digits.length - 1]);
}

String _boundedLot(String raw) {
  final value = raw.trim();
  if (value.isEmpty || value.length > 20) return '';
  if (value.contains(RegExp(r'[\x00-\x1f]'))) return '';
  return value;
}

/// Normalizes labelled dates to the same YYMMDD representation used by GS1.
/// Day 00 intentionally means month precision only.
String _normalizeDate(String raw) {
  final value = raw.trim();
  if (value.isEmpty || value.length > 24) return '';
  if (RegExp(r'^\d{6}$').hasMatch(value)) {
    return _validYyMmDd(value) ? value : '';
  }
  if (RegExp(r'^\d{8}$').hasMatch(value)) {
    final year = int.parse(value.substring(0, 4));
    final month = int.parse(value.substring(4, 6));
    final day = int.parse(value.substring(6, 8));
    return _dateParts(year, month, day);
  }

  final parts = value.split(RegExp(r'[-/.]'));
  if (parts.length == 2) {
    int year;
    int month;
    if (parts[0].length == 4) {
      year = int.tryParse(parts[0]) ?? 0;
      month = int.tryParse(parts[1]) ?? 0;
    } else {
      month = int.tryParse(parts[0]) ?? 0;
      final shortYear = int.tryParse(parts[1]) ?? -1;
      year = parts[1].length == 2 ? 2000 + shortYear : shortYear;
    }
    return _dateParts(year, month, 0);
  }
  if (parts.length == 3) {
    int year;
    int month;
    int day;
    if (parts[0].length == 4) {
      year = int.tryParse(parts[0]) ?? 0;
      month = int.tryParse(parts[1]) ?? 0;
      day = int.tryParse(parts[2]) ?? 0;
    } else {
      day = int.tryParse(parts[0]) ?? 0;
      month = int.tryParse(parts[1]) ?? 0;
      final shortYear = int.tryParse(parts[2]) ?? -1;
      year = parts[2].length == 2 ? 2000 + shortYear : shortYear;
    }
    return _dateParts(year, month, day);
  }
  return '';
}

String _dateParts(int year, int month, int day) {
  if (year < 2000 || year > 2099 || month < 1 || month > 12) return '';
  if (day == 0) {
    return '${(year % 100).toString().padLeft(2, '0')}${month.toString().padLeft(2, '0')}00';
  }
  final date = DateTime.utc(year, month, day);
  if (date.year != year || date.month != month || date.day != day) return '';
  return '${(year % 100).toString().padLeft(2, '0')}${month.toString().padLeft(2, '0')}${day.toString().padLeft(2, '0')}';
}

bool _validYyMmDd(String value) {
  final month = int.parse(value.substring(2, 4));
  final day = int.parse(value.substring(4, 6));
  if (month < 1 || month > 12 || day < 0 || day > 31) return false;
  if (day == 0) return true;
  final year = 2000 + int.parse(value.substring(0, 2));
  final date = DateTime.utc(year, month, day);
  return date.year == year && date.month == month && date.day == day;
}
