from pathlib import Path

path = Path('lib/domain/medicine_semantic_roles.dart')
text = path.read_text()


def replace_once(old, new):
    global text
    count = text.count(old)
    if count != 1:
        raise SystemExit(f'expected one semantic anchor, found {count}: {old[:120]!r}')
    text = text.replace(old, new, 1)


# One physical frame is one semantic vote. Overlapping textual windows inside
# that frame may recover complementary text, but they cannot multiply support.
replace_once(
    '''    final windows = _compositionWindows(lines);\n    for (final window in windows) {\n      for (final component in _parseComposition(window, quality)) {\n        rememberComponent(component);\n      }\n    }\n''',
    '''    final windows = _compositionWindows(lines);\n    final frameComponents = <String, _ComponentCandidate>{};\n    for (final window in windows) {\n      for (final component in _parseComposition(window, quality)) {\n        final key = searchText(component.ingredient);\n        if (key.length < 3) continue;\n        final old = frameComponents[key];\n        if (old == null || component.confidence > old.confidence) {\n          frameComponents[key] = component;\n        }\n      }\n    }\n    for (final component in frameComponents.values) {\n      rememberComponent(component);\n    }\n''',
)

# Explicit role labels are already handled above. Do not feed label-bearing
# lines back into the generic prominent-heading brand heuristic.
replace_once(
    '''      if (_compositionCue.hasMatch(normalized) ||\n          _semanticLegalNoise.hasMatch(normalized) ||\n''',
    '''      if (_compositionCue.hasMatch(normalized) ||\n          _brandLabel.hasMatch(normalized) ||\n          _genericLabel.hasMatch(normalized) ||\n          _semanticLegalNoise.hasMatch(normalized) ||\n''',
)

# Composition sections can contain nested cues ("Composition" followed by
# "Each tablet contains"). Consume one non-overlapping window and skip its
# nested starts, otherwise one ingredient can become multiple fake votes.
old_windows = '''List<String> _compositionWindows(List<_SemanticLine> lines) {\n  final result = <String>[];\n  for (var index = 0; index < lines.length; index++) {\n    final normalized = searchText(lines[index].text);\n    if (!_compositionCue.hasMatch(normalized)) continue;\n    final parts = <String>[lines[index].text];\n    for (var next = index + 1; next < lines.length && next <= index + 7; next++) {\n      final value = searchText(lines[next].text);\n      if (_compositionStop.hasMatch(value)) break;\n      parts.add(lines[next].text);\n      if (parts.fold<int>(0, (sum, value) => sum + value.length) > 420) break;\n    }\n    result.add(parts.join('\\n'));\n  }\n  return result;\n}\n'''
new_windows = '''List<String> _compositionWindows(List<_SemanticLine> lines) {\n  final result = <String>[];\n  for (var index = 0; index < lines.length; index++) {\n    final normalized = searchText(lines[index].text);\n    if (!_compositionCue.hasMatch(normalized)) continue;\n    final parts = <String>[lines[index].text];\n    var consumedThrough = index;\n    for (var next = index + 1; next < lines.length && next <= index + 7; next++) {\n      final value = searchText(lines[next].text);\n      if (_compositionStop.hasMatch(value)) break;\n      parts.add(lines[next].text);\n      consumedThrough = next;\n      if (parts.fold<int>(0, (sum, value) => sum + value.length) > 420) break;\n    }\n    final window = parts.join('\\n');\n    if (_strengthPattern.hasMatch(window)) result.add(window);\n    index = consumedThrough;\n  }\n  return result;\n}\n'''
replace_once(old_windows, new_windows)

# "Generic Name" is semantic identity evidence, not a composition-section
# opener. Patch only the _compositionCue declaration so the generic label itself
# remains available to _genericLabel.
start = text.find('final _compositionCue = RegExp(')
end = text.find('final _compositionStop = RegExp(', start)
if start < 0 or end < 0:
    raise SystemExit('composition cue section not found')
section = text[start:end]
needle = r'generic\s+name|'
if section.count(needle) != 1:
    raise SystemExit(f'expected one generic-name composition alternative, found {section.count(needle)}')
section = section.replace(needle, '', 1)
text = text[:start] + section + text[end:]

path.write_text(text)
print('V11 overlapping semantic evidence guard applied')
