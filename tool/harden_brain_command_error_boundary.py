#!/usr/bin/env python3
from pathlib import Path

root = Path(__file__).resolve().parents[1]
path = root / 'lib/ui/brain_screen.dart'
text = path.read_text(encoding='utf-8')
old = """    final intent = parseAppBrainIntent(raw);
    setState(() {
      _busy = true;
      _reply = 'Understanding command…';
      if (supplied != null) _command.text = supplied;
    });
    try {
      await _execute(intent, raw);
"""
new = """    setState(() {
      _busy = true;
      _reply = 'Understanding command…';
      if (supplied != null) _command.text = supplied;
    });
    try {
      final intent = parseAppBrainIntent(raw);
      await _execute(intent, raw);
"""
count = text.count(old)
if count != 1:
    raise SystemExit(f'Expected one Brain command error-boundary anchor, found {count}')
path.write_text(text.replace(old, new, 1), encoding='utf-8')
print('Moved Brain intent parsing inside the guarded execution boundary.')
