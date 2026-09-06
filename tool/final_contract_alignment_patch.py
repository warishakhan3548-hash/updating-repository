#!/usr/bin/env python3
from pathlib import Path

path = Path('test/android_build_contract_test.dart')
text = path.read_text(encoding='utf-8')
old = "      expect(controller, contains('DiceVoiceIntentParser.isFastPartialCommand(heard)'));\n"
new = (
    "      expect(controller, contains('DiceVoiceIntentParser.selectBestHypothesis('));\n"
    "      expect(controller, contains('isFastPartialCommand(heard)'));\n"
)
if old in text:
    text = text.replace(old, new, 1)
elif "DiceVoiceIntentParser.selectBestHypothesis(" not in text:
    raise SystemExit('android build contract does not match either known architecture')
path.write_text(text, encoding='utf-8')
print('aligned Android build contract with N-best voice arbitration')
