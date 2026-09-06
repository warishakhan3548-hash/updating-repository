from pathlib import Path


def replace_once(path: str, old: str, new: str) -> bool:
    file = Path(path)
    text = file.read_text(encoding="utf-8")
    if new in text:
        return False
    count = text.count(old)
    if count != 1:
        raise SystemExit(
            f"Expected exactly one patch anchor in {path}, found {count}: {old[:80]!r}"
        )
    file.write_text(text.replace(old, new, 1), encoding="utf-8")
    return True


def insert_after_once(path: str, anchor: str, insertion: str, sentinel: str) -> bool:
    file = Path(path)
    text = file.read_text(encoding="utf-8")
    if sentinel in text:
        return False
    count = text.count(anchor)
    if count != 1:
        raise SystemExit(
            f"Expected exactly one insertion anchor in {path}, found {count}: {anchor[:80]!r}"
        )
    file.write_text(text.replace(anchor, anchor + insertion, 1), encoding="utf-8")
    return True


changed = []
controller = "lib/services/voice_dice_controller.dart"

if replace_once(
    controller,
    "    'पाच': 5,\n    'paanch': 5,",
    "    'पाच': 5,\n    'पान्च': 5,\n    'paanch': 5,",
):
    changed.append("accept native-biased पान्च")

if replace_once(
    controller,
    "    'छक्के': 6,\n    'chakka': 6,",
    "    'छक्के': 6,\n    'छको': 6,\n    'chakka': 6,",
):
    changed.append("accept native-biased छको")

if replace_once(
    controller,
    "    'chhaka': 6,\n    'chakkaa': 6,",
    "    'chhaka': 6,\n    'chhakkaa': 6,\n    'chakkaa': 6,",
):
    changed.append("accept native-biased chhakkaa")

if replace_once(
    controller,
    "    '5', '५', 'five', 'पांच', 'पाँच', 'paanch', 'panch', 'फाइव',\n"
    "    '6', '६', 'six', 'छह', 'छः', 'छक्का', 'chakka', 'chhakka', 'सिक्स',",
    "    '5', '५', 'five', 'पांच', 'पाँच', 'पाच', 'पान्च', 'paanch', 'panch', 'फाइव', 'फाईव',\n"
    "    '6', '६', 'six', 'छह', 'छः', 'छक्का', 'छका', 'छक्क', 'chakka', 'chaka', 'chhakka', 'chhaka', 'chhakkaa', 'सिक्स',",
):
    changed.append("expand quiet-speech high-precision aliases without admitting short noisy forms")

anchor = """  static bool isDiceOnlyPhrase(String input) {
    final normalized = _normalize(input);
    if (normalized.isEmpty) return false;
    final tokens = normalized.split(RegExp(r'\\s+'));
    return tokens.every(_aliases.containsKey);
  }
"""
insertion = """

  /// Returns true only for a partial hypothesis that can be committed with
  /// extremely low ambiguity. Android partial callbacks often omit confidence
  /// scores, so broad aliases such as \"छ\", \"सिक\", \"tin\" and \"char\"
  /// must wait for a final result instead of bypassing the confidence guard.
  /// Repeated high-precision forms of the same dice value stay on the fast path.
  static bool isFastPartialCommand(String input) {
    final normalized = _normalize(input);
    if (normalized.isEmpty) return false;
    final tokens = normalized.split(RegExp(r'\\s+'));
    int? value;
    for (final token in tokens) {
      if (!_highPrecisionAliases.contains(token)) return false;
      final tokenValue = _aliases[token];
      if (tokenValue == null) return false;
      value ??= tokenValue;
      if (tokenValue != value) return false;
    }
    return value != null;
  }
"""
if insert_after_once(
    controller,
    anchor,
    insertion,
    "static bool isFastPartialCommand(String input)",
):
    changed.append("gate low-latency partial commits with a high-precision bounded grammar")

if replace_once(
    controller,
    "      if (!finalResult && !candidate.strongContext && !DiceVoiceIntentParser.isDiceOnlyPhrase(heard)) continue;",
    "      if (!finalResult && !candidate.strongContext && !DiceVoiceIntentParser.isFastPartialCommand(heard)) continue;",
):
    changed.append("route partial results through the precision fast path")

if replace_once(
    controller,
    "    if (parsed == null) {\n      _safeNotify();\n      return;\n    }",
    "    if (parsed == null) return;",
):
    changed.append("stop rebuilding voice UI for transcript noise that changed no state")

voice_test = "test/voice_turn_binding_test.dart"
if replace_once(
    voice_test,
    "      expect(VoiceDiceController.parseLastDiceValue('panj'), 5);",
    "      expect(VoiceDiceController.parseLastDiceValue('panj'), 5);\n"
    "      expect(VoiceDiceController.parseLastDiceValue('पान्च'), 5);\n"
    "      expect(VoiceDiceController.parseLastDiceValue('छको'), 6);\n"
    "      expect(VoiceDiceController.parseLastDiceValue('chhakkaa'), 6);",
):
    changed.append("cover native-bias/parser vocabulary parity")

partial_test_anchor = """    test('dice-only partial phrases are distinguishable from sentence prefixes', () {
      expect(DiceVoiceIntentParser.isDiceOnlyPhrase('छक्का'), isTrue);
      expect(DiceVoiceIntentParser.isDiceOnlyPhrase('छक्का छक्का'), isTrue);
      expect(DiceVoiceIntentParser.isDiceOnlyPhrase('six six'), isTrue);
      expect(DiceVoiceIntentParser.isDiceOnlyPhrase('पाँच पाँच'), isTrue);
      expect(DiceVoiceIntentParser.isDiceOnlyPhrase('six players'), isFalse);
      expect(DiceVoiceIntentParser.isDiceOnlyPhrase('मुझे छक्का दे'), isFalse);
    });
"""
partial_test_insertion = """

    test('partial fast path is precise while common quiet variants stay instant', () {
      expect(DiceVoiceIntentParser.isFastPartialCommand('छक्का'), isTrue);
      expect(DiceVoiceIntentParser.isFastPartialCommand('छका'), isTrue);
      expect(DiceVoiceIntentParser.isFastPartialCommand('छक्का छक्का'), isTrue);
      expect(DiceVoiceIntentParser.isFastPartialCommand('six six'), isTrue);
      expect(DiceVoiceIntentParser.isFastPartialCommand('पान्च'), isTrue);
      expect(DiceVoiceIntentParser.isFastPartialCommand('chhakkaa'), isTrue);

      expect(DiceVoiceIntentParser.isFastPartialCommand('छ'), isFalse);
      expect(DiceVoiceIntentParser.isFastPartialCommand('सिक'), isFalse);
      expect(DiceVoiceIntentParser.isFastPartialCommand('tin'), isFalse);
      expect(DiceVoiceIntentParser.isFastPartialCommand('char'), isFalse);
      expect(DiceVoiceIntentParser.isFastPartialCommand('six five'), isFalse);
      expect(DiceVoiceIntentParser.isFastPartialCommand('give me six'), isFalse);
    });
"""
if insert_after_once(
    voice_test,
    partial_test_anchor,
    partial_test_insertion,
    "partial fast path is precise while common quiet variants stay instant",
):
    changed.append("add partial-latency safety regression coverage")

android_test = "test/android_build_contract_test.dart"
if replace_once(
    android_test,
    "      expect(controller, contains('DiceVoiceIntentParser.isDiceOnlyPhrase(heard)'));",
    "      expect(controller, contains('DiceVoiceIntentParser.isFastPartialCommand(heard)'));",
):
    changed.append("update Android voice contract for precision partial gating")

if replace_once(
    android_test,
    "      expect(controller, contains('recognitionConfidence < .30'));",
    "      expect(controller, contains('measuredConfidence < .30'));",
):
    changed.append("align confidence contract with normalized measured confidence guard")

crash_test = "test/crash_resilience_test.dart"
if replace_once(
    crash_test,
    "      expect(engine, contains('current.recognizedAt.isAfter'));",
    "      expect(engine, contains('intent.matches(voiceTurnBinding)'));\n"
    "      expect(engine, contains('intent.isExpiredAt(clock)'));\n"
    "      expect(engine, contains('if (_pendingVoiceDiceIntent != null) return false;'));",
):
    changed.append("align crash contract with deterministic first-command-wins ownership")

pubspec = Path("pubspec.yaml")
pubspec_text = pubspec.read_text(encoding="utf-8")
if "version: 1.4.1+13" in pubspec_text:
    pubspec.write_text(
        pubspec_text.replace("version: 1.4.1+13", "version: 1.4.2+14", 1),
        encoding="utf-8",
    )
    changed.append("bump app build to 1.4.2+14")

if changed:
    print("Ultra voice patch applied:")
    for item in changed:
        print(f" - {item}")
else:
    print("Ultra voice patch already applied; no changes needed.")
