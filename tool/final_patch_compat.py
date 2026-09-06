#!/usr/bin/env python3
from pathlib import Path

controller_path = Path('lib/services/voice_dice_controller.dart')
controller = controller_path.read_text(encoding='utf-8')
old_initializer = '  })  : _engine = engine ?? LudoEngine.voiceRuntimeEngine,\n'
new_initializer = '  })  : _engine = engine,\n'
if old_initializer in controller:
    controller = controller.replace(old_initializer, new_initializer, 1)
elif new_initializer not in controller:
    raise SystemExit('unknown VoiceDiceController initializer layout')
controller_path.write_text(controller, encoding='utf-8')
print('normalized VoiceDiceController engine injection')

engine_path = Path('lib/game/ludo_engine.dart')
engine = engine_path.read_text(encoding='utf-8')
old_dispose = """  @override
  void dispose() {
    if (identical(_voiceRuntimeEngine, this)) {
      _voiceRuntimeEngine = null;
    }
    _pendingVoiceDiceIntent = null;
"""
new_dispose = """  @override
  void dispose() {
    _pendingVoiceDiceIntent = null;
"""
if old_dispose in engine:
    engine = engine.replace(old_dispose, new_dispose, 1)
elif new_dispose not in engine:
    raise SystemExit('unknown LudoEngine dispose layout')
engine_path.write_text(engine, encoding='utf-8')
print('removed stale global voice-engine dispose cleanup')
