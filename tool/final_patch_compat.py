#!/usr/bin/env python3
from pathlib import Path

path = Path('lib/services/voice_dice_controller.dart')
text = path.read_text(encoding='utf-8')
old = '  })  : _engine = engine ?? LudoEngine.voiceRuntimeEngine,\n'
new = '  })  : _engine = engine,\n'
if old in text:
    text = text.replace(old, new, 1)
elif new not in text:
    raise SystemExit('unknown VoiceDiceController initializer layout')
path.write_text(text, encoding='utf-8')
print('normalized VoiceDiceController engine injection')
