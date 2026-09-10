from pathlib import Path

brain = Path('lib/ui/brain_screen.dart')
text = brain.read_text()
unused = "import '../domain/warning_policy.dart';\n"
if text.count(unused) != 1:
    raise SystemExit('brain_screen.dart: warning-policy import anchor missing')
brain.write_text(text.replace(unused, '', 1))

policy = Path('lib/domain/warning_policy.dart')
text = policy.read_text()
anchor = "  if (dayValues.length > 1) {\n"
insertion = """  final numericTokens = RegExp(
    r'(?:^|[^0-9])([0-9]{1,3})(?=$|[^0-9])',
  ).allMatches(ascii).length;
  if (numericTokens != dayValues.length + monthValues.length) {
    throw const FormatException(
      'Every expiry-warning number must have an explicit day or month unit.',
    );
  }

  if (dayValues.length > 1) {
"""
if text.count(anchor) != 1:
    raise SystemExit('warning_policy.dart: ambiguity anchor missing')
policy.write_text(text.replace(anchor, insertion, 1))

app_brain = Path('lib/domain/app_brain.dart')
text = app_brain.read_text()
old_deferred = """  if (_containsAny(text, _deferredWriteSafetyTerms) ||
      _looksLikeScheduledMutation(raw)) {
    return AppBrainSafetyReason.deferredMutation;
  }
"""
new_deferred = """  final warningPolicyOnly =
      families.length == 1 && families.contains('warning-policy');
  if (_containsAny(text, _deferredWriteSafetyTerms) ||
      _looksLikeScheduledMutation(
        raw,
        allowBareDuration: !warningPolicyOnly,
      )) {
    return AppBrainSafetyReason.deferredMutation;
  }
"""
if text.count(old_deferred) != 1:
    raise SystemExit('app_brain.dart: deferred safety anchor missing')
text = text.replace(old_deferred, new_deferred, 1)
old_signature = """bool _looksLikeScheduledMutation(String raw) =>
"""
new_signature = """bool _looksLikeScheduledMutation(
  String raw, {
  bool allowBareDuration = true,
}) =>
"""
if text.count(old_signature) != 1:
    raise SystemExit('app_brain.dart: schedule signature anchor missing')
text = text.replace(old_signature, new_signature, 1)
old_duration = """    RegExp(
      r'\\b(?:in\\s+)?\\d+\\s*(?:minutes?|hours?|days?|weeks?|months?)\\b',
      caseSensitive: false,
    ).hasMatch(raw) ||
"""
new_duration = """    RegExp(
      allowBareDuration
          ? r'\\b(?:in\\s+)?\\d+\\s*(?:minutes?|hours?|days?|weeks?|months?)\\b'
          : r'\\b(?:in|after)\\s+\\d+\\s*(?:minutes?|hours?|days?|weeks?|months?)\\b',
      caseSensitive: false,
    ).hasMatch(raw) ||
"""
if text.count(old_duration) != 1:
    raise SystemExit('app_brain.dart: schedule duration anchor missing')
app_brain.write_text(text.replace(old_duration, new_duration, 1))
