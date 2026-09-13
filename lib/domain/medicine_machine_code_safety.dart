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

class MedicineMachineCodeSelection {
  const MedicineMachineCodeSelection({
    required this.payloads,
    required this.assessment,
  });

  final List<String> payloads;
  final MedicineMachineCodeAssessment assessment;

  bool get ambiguousTrustedProductCodes => assessment.ambiguous;
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

/// Selects machine-code evidence that is safe to expose to exact product
/// resolution. Raw structured GS1 payloads are preserved alongside their
/// canonical GTIN because the former carries lot/expiry while the latter is an
/// efficient product key.
///
/// Equivalent EAN/UPC/GTIN encodings are also accompanied by the same GTIN-14
/// key. Downstream frame grouping can therefore recognize the same medicine when
/// one side exposes EAN-13 and another scanner path exposes GTIN-14/DataMatrix,
/// instead of splitting one physical pack because the raw strings differ.
///
/// If one immutable image contains two different checksum-valid product keys,
/// no machine code from that image is forwarded as exact identity evidence.
/// OCR remains usable and the caller can request a single-pack recapture. This
/// avoids arbitrary sorting deciding which medicine wins in a multi-pack image.
MedicineMachineCodeSelection selectSafeMedicineMachineCodes(
  Iterable<String> rawCodes, {
  int inputLimit = 24,
  int outputLimit = 8,
}) {
  final values = <String>{};
  final boundedInput = inputLimit < 1 ? 1 : inputLimit;
  for (final candidate in rawCodes.take(boundedInput)) {
    final raw = candidate.trim();
    if (raw.isEmpty) continue;
    values.add(raw);
    final canonical = canonicalTrustedMedicineProductKey(raw);
    if (canonical.isNotEmpty) values.add(canonical);
  }

  final assessment = assessMedicineMachineCodes(values, limit: boundedInput * 2);
  if (assessment.ambiguous) {
    return MedicineMachineCodeSelection(
      payloads: const <String>[],
      assessment: assessment,
    );
  }

  final ranked = values.toList(growable: false)
    ..sort((left, right) {
      final score = _machineCodeRank(right).compareTo(_machineCodeRank(left));
      return score != 0 ? score : left.compareTo(right);
    });
  final boundedOutput = outputLimit < 1 ? 1 : outputLimit;
  return MedicineMachineCodeSelection(
    payloads: List<String>.unmodifiable(ranked.take(boundedOutput)),
    assessment: assessment,
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

int _machineCodeRank(String value) {
  final digits = value.replaceAll(RegExp(r'\D'), '');
  if (digits == value && const <int>{8, 12, 13, 14}.contains(digits.length)) {
    return canonicalTrustedMedicineProductKey(value).isNotEmpty ? 6 : 3;
  }
  final structured = parseRegulatoryMedicineCode(value);
  if (structured != null && structured.gtin.isNotEmpty) return 5;
  if (digits == value && digits.length >= 6) return 3;
  if (structured != null && structured.hasTraceability) return 2;
  return 1;
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
