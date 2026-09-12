import 'dart:math';

import 'medicine.dart';
import 'search.dart';

/// Identity projection used by the offline LASA (look-alike/sound-alike)
/// firewall. It deliberately contains product identity only; lot, price and
/// inventory facts must never influence a product-name safety decision.
class MedicineConfusionIdentity {
  const MedicineConfusionIdentity({
    required this.name,
    this.brand = '',
    this.salt = '',
    this.strength = '',
    this.form = '',
  });

  final String name;
  final String brand;
  final String salt;
  final String strength;
  final String form;

  String get displayName => name.trim().isNotEmpty ? name.trim() : brand.trim();
}

class MedicineConfusionAssessment {
  const MedicineConfusionAssessment({
    required this.riskScore,
    required this.orthographicSimilarity,
    required this.phoneticSimilarity,
    required this.commonPrefix,
    required this.commonSuffix,
    required this.criticalFields,
  });

  final double riskScore;
  final double orthographicSimilarity;
  final double phoneticSimilarity;
  final int commonPrefix;
  final int commonSuffix;
  final Set<String> criticalFields;

  /// A high-risk pair is intentionally NOT the same as a likely match. The
  /// products look/sound confusingly similar while at least one clinically
  /// important identity field differs. Downstream code must demand independent
  /// discriminating evidence instead of rewarding fuzzy-name similarity.
  bool get highRisk => criticalFields.isNotEmpty && riskScore >= .78;
}

MedicineConfusionAssessment assessMedicineConfusion(
  MedicineConfusionIdentity left,
  MedicineConfusionIdentity right,
) {
  final a = _nameKey(left.displayName);
  final b = _nameKey(right.displayName);
  if (a.length < 3 || b.length < 3 || a == b) {
    return MedicineConfusionAssessment(
      riskScore: 0,
      orthographicSimilarity: a == b && a.isNotEmpty ? 1 : 0,
      phoneticSimilarity: 0,
      commonPrefix: _commonPrefix(a, b),
      commonSuffix: _commonSuffix(a, b),
      criticalFields: _criticalDifferences(left, right),
    );
  }

  final edit = _damerauSimilarity(a, b);
  final dice = _bigramDice(a, b);
  final orthographic = max(edit, dice * .97).clamp(0, 1).toDouble();
  final phonetic = _damerauSimilarity(_phoneticKey(a), _phoneticKey(b));
  final prefix = _commonPrefix(a, b);
  final suffix = _commonSuffix(a, b);

  // Drug-name confusions often preserve a long prefix/suffix while changing a
  // short middle segment (for example vinBLAStine / vinCRIStine). Rewarding only
  // whole-string edit similarity can miss exactly this dangerous shape.
  var structural = 0.0;
  if (prefix >= 3 && suffix >= 4 && edit >= .54) {
    structural = .86;
  } else if ((prefix >= 4 || suffix >= 4) && edit >= .66) {
    structural = .80;
  }

  final risk = max(
    orthographic,
    max(phonetic * .96, structural),
  ).clamp(0, 1).toDouble();
  return MedicineConfusionAssessment(
    riskScore: risk,
    orthographicSimilarity: orthographic,
    phoneticSimilarity: phonetic,
    commonPrefix: prefix,
    commonSuffix: suffix,
    criticalFields: _criticalDifferences(left, right),
  );
}

Set<String> _criticalDifferences(
  MedicineConfusionIdentity left,
  MedicineConfusionIdentity right,
) {
  final result = <String>{};
  final leftSalt = searchText(left.salt);
  final rightSalt = searchText(right.salt);
  if (leftSalt.isNotEmpty && rightSalt.isNotEmpty && leftSalt != rightSalt) {
    result.add('salt');
  }
  final leftStrength = _strengthKey(left.strength);
  final rightStrength = _strengthKey(right.strength);
  if (leftStrength.isNotEmpty &&
      rightStrength.isNotEmpty &&
      leftStrength != rightStrength) {
    result.add('strength');
  }
  final leftForm = normalizeForm(left.form);
  final rightForm = normalizeForm(right.form);
  if (leftForm.isNotEmpty && rightForm.isNotEmpty && leftForm != rightForm) {
    result.add('form');
  }
  return Set<String>.unmodifiable(result);
}

String _nameKey(String value) =>
    searchText(value).replaceAll(RegExp(r'[^a-z0-9\u0900-\u097f]+'), '');

String _strengthKey(String value) =>
    searchText(value)
        .replaceAll(' ', '')
        .replaceAll('μ', 'µ')
        .replaceAll('ug', 'mcg');

String _phoneticKey(String input) {
  var value = input.toLowerCase();
  value = value
      .replaceAll('ph', 'f')
      .replaceAll('ck', 'k')
      .replaceAll('qu', 'k')
      .replaceAll('q', 'k')
      .replaceAll('c', 'k')
      .replaceAll('x', 'ks')
      .replaceAll('z', 's')
      .replaceAll('v', 'w')
      .replaceAll('y', 'i');
  if (value.isEmpty) return '';
  final out = StringBuffer(value[0]);
  var previous = value[0];
  for (var index = 1; index < value.length; index++) {
    final char = value[index];
    if ('aeiou'.contains(char)) continue;
    if (char == previous) continue;
    out.write(char);
    previous = char;
  }
  return out.toString();
}

int _commonPrefix(String left, String right) {
  final limit = min(left.length, right.length);
  var count = 0;
  while (count < limit && left.codeUnitAt(count) == right.codeUnitAt(count)) {
    count++;
  }
  return count;
}

int _commonSuffix(String left, String right) {
  final limit = min(left.length, right.length);
  var count = 0;
  while (count < limit &&
      left.codeUnitAt(left.length - 1 - count) ==
          right.codeUnitAt(right.length - 1 - count)) {
    count++;
  }
  return count;
}

double _bigramDice(String left, String right) {
  if (left == right) return 1;
  if (left.length < 2 || right.length < 2) return 0;
  final a = <String, int>{};
  final b = <String, int>{};
  for (var i = 0; i + 2 <= left.length; i++) {
    final gram = left.substring(i, i + 2);
    a.update(gram, (value) => value + 1, ifAbsent: () => 1);
  }
  for (var i = 0; i + 2 <= right.length; i++) {
    final gram = right.substring(i, i + 2);
    b.update(gram, (value) => value + 1, ifAbsent: () => 1);
  }
  var overlap = 0;
  for (final entry in a.entries) {
    overlap += min(entry.value, b[entry.key] ?? 0);
  }
  return (2 * overlap / ((left.length - 1) + (right.length - 1)))
      .clamp(0, 1)
      .toDouble();
}

double _damerauSimilarity(String left, String right) {
  if (left == right) return 1;
  if (left.isEmpty || right.isEmpty) return 0;
  final rows = List<List<int>>.generate(
    left.length + 1,
    (i) => List<int>.filled(right.length + 1, 0),
  );
  for (var i = 0; i <= left.length; i++) rows[i][0] = i;
  for (var j = 0; j <= right.length; j++) rows[0][j] = j;
  for (var i = 1; i <= left.length; i++) {
    for (var j = 1; j <= right.length; j++) {
      final cost = left.codeUnitAt(i - 1) == right.codeUnitAt(j - 1) ? 0 : 1;
      var best = min(
        rows[i - 1][j] + 1,
        min(rows[i][j - 1] + 1, rows[i - 1][j - 1] + cost),
      );
      if (i > 1 &&
          j > 1 &&
          left.codeUnitAt(i - 1) == right.codeUnitAt(j - 2) &&
          left.codeUnitAt(i - 2) == right.codeUnitAt(j - 1)) {
        best = min(best, rows[i - 2][j - 2] + 1);
      }
      rows[i][j] = best;
    }
  }
  return (1 - rows.last.last / max(left.length, right.length))
      .clamp(0, 1)
      .toDouble();
}
