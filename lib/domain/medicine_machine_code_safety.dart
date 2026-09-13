import 'regulatory_medicine_code.dart';

/// Durable evidence marker for one immutable image that contained more than one
/// independently valid medicine product identity. It is carried in `source`
/// because legacy persisted evidence already serializes that field, so this
/// safety signal survives queue/review handoff without a migration.
const String ambiguousMedicineMachineCodesMarker =
    '[aaris:ambiguous-medicine-machine-codes]';

bool medicineMachineCodeSourceIsAmbiguous(String source) =>
    source.contains(ambiguousMedicineMachineCodesMarker);

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

/// Selects machine-code evidence that is safe to expose to medicine resolution.
///
/// When one checksum/GS1-valid product identity exists, equivalent EAN/UPC/GTIN
/// representations are collapsed to ONE payload. A structured GS1/Digital-Link
/// representation wins over a plain linear code when it carries lot/expiry,
/// because keeping both equivalent strings would make the generic barcode field
/// look falsely conflicted even though both prove the same product.
///
/// Non-authoritative marketing/proprietary codes are not mixed into that trusted
/// identity lane. When no trusted GTIN exists at all, they are retained as bounded
/// review/local-search clues so existing proprietary barcode workflows keep
/// working, but they never gain exact product authority.
///
/// If one immutable image contains two different checksum-valid product keys,
/// every machine code from that image is quarantined. OCR remains usable and the
/// caller requests a single-pack recapture rather than picking one code by order.
MedicineMachineCodeSelection selectSafeMedicineMachineCodes(
  Iterable<String> rawCodes, {
  int inputLimit = 24,
  int outputLimit = 8,
}) {
  final boundedInput = inputLimit < 1 ? 1 : inputLimit;
  final values = <String>[];
  final seen = <String>{};
  for (final candidate in rawCodes.take(boundedInput)) {
    final raw = candidate.trim();
    if (raw.isEmpty || !seen.add(raw)) continue;
    values.add(raw);
  }

  final assessment = assessMedicineMachineCodes(values, limit: boundedInput);
  if (assessment.ambiguous) {
    return MedicineMachineCodeSelection(
      payloads: const <String>[],
      assessment: assessment,
    );
  }

  final trustedKey = assessment.singleTrustedProduct;
  if (trustedKey.isNotEmpty) {
    final equivalent = values
        .where(
          (value) => canonicalTrustedMedicineProductKey(value) == trustedKey,
        )
        .toList(growable: false)
      ..sort((left, right) {
        final rank = _machineCodeRank(right).compareTo(_machineCodeRank(left));
        return rank != 0 ? rank : left.compareTo(right);
      });
    final selected = equivalent.isEmpty ? trustedKey : equivalent.first;
    return MedicineMachineCodeSelection(
      payloads: List<String>.unmodifiable(<String>[selected]),
      assessment: assessment,
    );
  }

  final ranked = values.toList(growable: false)
    ..sort((left, right) {
      final rank = _machineCodeRank(right).compareTo(_machineCodeRank(left));
      return rank != 0 ? rank : left.compareTo(right);
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
  final structured = parseRegulatoryMedicineCode(value);
  if (structured != null && structured.gtin.isNotEmpty) {
    // Prefer one GS1 payload carrying physical traceability over an equivalent
    // plain GTIN; the resolver can still derive the canonical product key from it.
    return structured.batchLot.isNotEmpty ||
            structured.expiryYyMmDd.isNotEmpty ||
            structured.manufacturingYyMmDd.isNotEmpty ||
            structured.serial.isNotEmpty
        ? 8
        : 6;
  }

  final digits = value.trim();
  if (RegExp(r'^\d+$').hasMatch(digits) &&
      const <int>{8, 12, 13, 14}.contains(digits.length) &&
      canonicalTrustedMedicineProductKey(digits).isNotEmpty) {
    return 7;
  }
  if (RegExp(r'^\d{6,}$').hasMatch(digits)) return 3;
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
