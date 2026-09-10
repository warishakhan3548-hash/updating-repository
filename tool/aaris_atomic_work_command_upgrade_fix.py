#!/usr/bin/env python3
from pathlib import Path

path = Path(__file__).with_name('aaris_atomic_work_command_upgrade.py')
text = path.read_text(encoding='utf-8')
wrong = r"r'\b(?:at\s+)?(?:[01]?\d|2[0-3]):[0-5]\d(?:\s*(?:a\.?m\.?|p\.?m\.?)\b)?'"
right = r"r'\b(?:at\s+)?(?:[01]?\d|2[0-3]):[0-5]\d(?:\s*(?:a\.?m\.?|p\.?m\.?))?\b'"
count = text.count(wrong)
if count != 2:
    raise RuntimeError(f'expected two clock-regex anchors, found {count}')
text = text.replace(wrong, right)
text = text.replace("'Dolo २ घंटे बाद remove',", "'Dolo २ ghante baad remove',")
path.write_text(text, encoding='utf-8')
print('Atomic upgrade patch anchors hardened.')
