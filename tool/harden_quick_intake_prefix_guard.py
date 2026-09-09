#!/usr/bin/env python3
from pathlib import Path

root = Path(__file__).resolve().parents[1]
path = root / 'lib/domain/medicine_entry_prefill.dart'
text = path.read_text(encoding='utf-8')
old = "      '(?:^|[^A-Za-z0-9\\\\u0900-\\\\u097f])(?:$labels)\\\\s*[:=]?\\\\s*(?:\"([^\"]{1,$max})\"|([A-Za-z0-9\\\\u0900-\\\\u097f+._/-]{1,$max}))',\n"
new = "      '(?:^|[^A-Za-z0-9\\\\u0900-\\\\u097f])(?:$labels)(?=\\\\s|[:=])\\\\s*[:=]?\\\\s*(?:\"([^\"]{1,$max})\"|([A-Za-z0-9\\\\u0900-\\\\u097f+._/-]{1,$max}))',\n"
count = text.count(old)
if count != 1:
    raise SystemExit(f'Expected exactly one tagged-field boundary anchor, found {count}')
path.write_text(text.replace(old, new, 1), encoding='utf-8')
print('Hardened quick-intake tagged-field boundaries.')
