import 'medicine.dart';

/// A narrow, deterministic update to the pharmacist's expiry-warning policy.
///
/// This is app configuration, never a medicine fact. Values are intentionally
/// unit-qualified so a strength such as "650 mg" cannot become a warning value.
class WarningPolicyPatch {
  const WarningPolicyPatch({this.shortDays, this.months})
    : assert(shortDays != null || months != null);

  final int? shortDays;
  final int? months;

  WarningSettings apply(WarningSettings current) => WarningSettings.fromJson({
    'shortDays': shortDays ?? current.shortDays,
    'months': months ?? current.months,
  });

  String describe() {
    final parts = <String>[
      if (shortDays != null) 'short-expiry: $shortDays days',
      if (months != null) 'month-expiry: $months months',
    ];
    return parts.join(' · ');
  }
}

WarningPolicyPatch? parseWarningPolicyCommand(String raw) {
  if (raw.trim().isEmpty || raw.length > 500) return null;
  final ascii = _asciiDigits(raw);
  final text = _normalizePolicy(ascii);
  if (!_looksLikePolicyContext(text) || !_hasPolicyMutationVerb(text)) {
    return null;
  }

  final dayValues = _unitValues(
    ascii,
    RegExp(
      r'(?:^|[^0-9])([0-9]{1,3})\s*(?:day|days|din|दिन)(?=$|[^A-Za-z0-9\u0900-\u097f])',
      caseSensitive: false,
      unicode: true,
    ),
  );
  final monthValues = _unitValues(
    ascii,
    RegExp(
      r'(?:^|[^0-9])([0-9]{1,2})\s*(?:month|months|mahina|mahine|mahinae|महीना|महीने)(?=$|[^A-Za-z0-9\u0900-\u097f])',
      caseSensitive: false,
      unicode: true,
    ),
  );

  final numericTokens = RegExp(r'(?:^|[^0-9])([0-9]{1,3})(?=$|[^0-9])')
      .allMatches(ascii)
      .length;
  if (numericTokens != dayValues.length + monthValues.length) {
    throw const FormatException(
      'Every expiry-warning number must have an explicit day or month unit.',
    );
  }

  if (dayValues.length > 1) {
    throw const FormatException(
      'Use one day value for the short-expiry warning in a single command.',
    );
  }
  if (monthValues.length > 1) {
    throw const FormatException(
      'Use one month value for the month-expiry warning in a single command.',
    );
  }
  if (dayValues.isEmpty && monthValues.isEmpty) {
    throw const FormatException(
      'Say the expiry-warning value with an explicit unit, for example “10 days” or “3 months”.',
    );
  }

  final days = dayValues.isEmpty ? null : dayValues.single;
  final months = monthValues.isEmpty ? null : monthValues.single;
  if (days != null && (days < 1 || days > 365)) {
    throw const FormatException('Short-expiry warning must be 1–365 days.');
  }
  if (months != null && (months < 1 || months > 24)) {
    throw const FormatException('Month-expiry warning must be 1–24 months.');
  }
  return WarningPolicyPatch(shortDays: days, months: months);
}

/// Fast safety-family detector used before the command parser routes writes.
bool looksLikeWarningPolicyMutation(String raw) {
  if (raw.trim().isEmpty || raw.length > 500) return false;
  final text = _normalizePolicy(_asciiDigits(raw));
  return _looksLikePolicyContext(text) && _hasPolicyMutationVerb(text);
}

List<int> _unitValues(String raw, RegExp pattern) => pattern
    .allMatches(raw)
    .map((match) => int.parse(match.group(1)!))
    .toList(growable: false);

bool _looksLikePolicyContext(String text) => _containsPolicyPhrase(text, const [
  'warning',
  'warning window',
  'expiry warning',
  'expiry alert',
  'alert window',
  'short expiry',
  'short expiry warning',
  'month expiry',
  'month expiry warning',
  'expiry window',
  'चेतावनी',
  'एक्सपायरी चेतावनी',
  'एक्सपायरी अलर्ट',
  'शॉर्ट एक्सपायरी',
  'मंथ एक्सपायरी',
]);

bool _hasPolicyMutationVerb(String text) => _containsPolicyPhrase(text, const [
  'set',
  'set karo',
  'set kar do',
  'change',
  'change karo',
  'update',
  'update karo',
  'configure',
  'rakho',
  'rakh do',
  'badlo',
  'badal do',
  'सेट',
  'सेट करो',
  'सेट कर दो',
  'अपडेट',
  'अपडेट करो',
  'बदलो',
  'बदल दो',
  'रखो',
  'रख दो',
]);

bool _containsPolicyPhrase(String text, List<String> phrases) =>
    phrases.any((p) {
      final phrase = _normalizePolicy(p);
      return text == phrase ||
          text.startsWith('$phrase ') ||
          text.endsWith(' $phrase') ||
          text.contains(' $phrase ');
    });

String _normalizePolicy(String value) => value
    .toLowerCase()
    .replaceAll(RegExp(r'[^a-z0-9\u0900-\u097f]+', unicode: true), ' ')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

String _asciiDigits(String value) {
  const devanagari = '०१२३४५६७८९';
  final out = StringBuffer();
  for (final rune in value.runes) {
    final char = String.fromCharCode(rune);
    final index = devanagari.indexOf(char);
    out.write(index < 0 ? char : index);
  }
  return out.toString();
}
