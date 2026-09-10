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
