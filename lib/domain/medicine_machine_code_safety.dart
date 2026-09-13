import 'regulatory_medicine_code.dart';

/// Bounded deterministic assessment of machine-readable product identities seen
/// in one physical observation. This is deliberately smaller than a full GS1
/// parser: it answers only whether a code proves one canonical GTIN product key.
class MedicineMachineCodeAssessment {
  const MedicineMachineCodeAssessment(this.trustedProductKeys);

  final List<String> trustedProductKeys;

  bool get hasTrustedProduct => trustedProductKeys.isNotEmpty;
  bool get ambiguous => trustedProductKeys.length > 1;
  String get singleTrustedProduct => trustedProductKeys.length == 1
      ? trustedProductKeys.single
      : '';
}

MedicineMachineCodeAssessment assessMedicineMachineCodes(
  Iterable<String> rawCodes, {
  int limit = 24,
}) {
  final keys = <String>{};
  final bounded = limit < 1 ? 1 : limit;
  for (final raw in rawCodes.take(bounded)) {
    final key = canonicalTrustedMedicineProductKey(raw);
    if (key.isNotEmpty) keys.add(key);
  }
  final ordered = keys.toList(growable: false)..sort();
  return MedicineMachineCodeAssessment(
    List<String>.unmodifiable(ordered),
  );
}

/// Returns a 14-digit canonical GTIN only when the scanned value is independently
/// check-digit verifiable. Structured GS1/DataMatrix/Digital-Link payloads are
/// delegated to the regulatory parser; plain EAN/UPC/GTIN values are normalized
/// to the equivalent GTIN-14 representation.
///
/// Promotional QR URLs, proprietary numeric payloads and malformed check digits
/// return an empty string. They may remain search/review clues, but cannot gain
/// exact medicine-product authority.
String canonicalTrustedMedicineProductKey(String raw) {
  final value = raw.trim();
  if (value.isEmpty || value.length > 1600) return '';

  final structured = parseRegulatoryMedicineCode(value);
  if (structured != null && structured.gtin.isNotEmpty) {
    return structured.gtin;
  }

  if (!RegExp(r'^\d+$').hasMatch(value) ||
      !const <int>{8, 12, 13, 14}.contains(value.length) ||
      !_validGtin(value)) {
    return '';
  }
  return value.padLeft(14, '0');
}

bool _validGtin(String digits) {
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
