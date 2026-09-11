from pathlib import Path

root = Path(__file__).resolve().parents[1]
patcher = root / 'tool/one_shot_unified_medicine_evidence_v3.py'
text = patcher.read_text(encoding='utf-8')
old = "updated, count = re.subn(pattern, replacement, text, count=1, flags=re.S)"
new = "updated, count = re.subn(pattern, lambda _: replacement, text, count=1, flags=re.S)"
if text.count(old) != 1:
    raise SystemExit('Expected one regex_once implementation to repair.')
patcher.write_text(text.replace(old, new, 1), encoding='utf-8')
Path(__file__).unlink()
