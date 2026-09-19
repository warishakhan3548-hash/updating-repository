import 'search.dart';

// Shared lexical rule for OCR, ingredient evidence and the final add gate.
// Never read the tail of a decimal or the prefix of an unknown unit. An
// explicit concentration must be consumed in full, including its denominator.
// "1,000" is ambiguous between grouping and a decimal comma. Keep it for
// review rather than silently turning 1000 into 1. Decimal 0,125 remains valid.
const _number = r'(?![1-9]\d*,\d{3}(?!\d))\d+(?:[.,]\d+)?';
const _unit = r'(?:mcg|ug|µg|μg|mg|gm|g|ml|meq|iu|i\.u\.|units?|%)';
const _denominator = r'(?:mcg|ug|µg|μg|mg|gm|ml|g|l|dose|actuation|iu|units?)';
const _strength =
    '$_number\\s*$_unit'
    '(?:\\s*(?:w\\s*/\\s*w|w\\s*/\\s*v|v\\s*/\\s*v)'
    '|\\s*/\\s*(?:$_number\\s*)?$_denominator)?';

final medicineStrengthPattern = RegExp(
  r'(?<![a-z0-9.,/µμ\u0900-\u097f-])' +
      _strength +
      r'(?![a-z0-9µμ\u0900-\u097f]|\s*(?:/|[wv]\s*/))',
  caseSensitive: false,
);

final _completeStrength = RegExp('^$_strength\$', caseSensitive: false);

bool hasCompleteMedicineStrength(String value) {
  final text = value.trim();
  if (!_completeStrength.hasMatch(text)) return false;
  // A zero amount or denominator cannot certify an ingredient concentration.
  return RegExp(_number).allMatches(text).every((match) {
    final amount = double.tryParse(match[0]!.replaceAll(',', '.'));
    return amount != null && amount.isFinite && amount > 0;
  });
}

/// Search normalization drops %, / and +. Those characters define different
/// strengths, so retain them when comparing medical identity or disagreement.
/// This normalizes spelling/spacing only; it never converts dose units.
String medicineStrengthKey(String value) => value
    .toLowerCase()
    .replaceAll('µg', 'mcg')
    .replaceAll('μg', 'mcg')
    .replaceAll(RegExp(r'\bug\b|(?<=\d)ug\b'), 'mcg')
    .replaceAll(',', '.')
    .replaceAll(RegExp(r'i\.u\.', caseSensitive: false), 'iu')
    .splitMapJoin(
      RegExp(r'[%/+]'),
      onMatch: (match) => match[0]!,
      onNonMatch: (part) => searchText(part).replaceAll(' ', ''),
    );
