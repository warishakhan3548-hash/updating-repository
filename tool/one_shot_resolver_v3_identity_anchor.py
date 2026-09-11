from pathlib import Path

root = Path(__file__).resolve().parents[1]
path = root / 'lib/domain/medicine_resolution_v2.dart'
text = path.read_text(encoding='utf-8')
old = '''    final calibratedLock =\n        winner.product.verified &&\n        winner.score >= .86 &&\n        winner.channels >= 2 &&\n        margin >= .10 &&\n        winner.hardConflicts == 0;\n'''
new = '''    // Salt + strength + dosage form can identify a generic composition but do\n    // not prove a trade product. Canonical inheritance is allowed only when a\n    // printed product/name/verified OCR alias independently anchors identity.\n    // This prevents a small catalogue from turning “Paracetamol 650 mg Tablet”\n    // into a familiar brand merely because that brand is the only candidate.\n    final calibratedLock =\n        winner.product.verified &&\n        winner.strongIdentity &&\n        winner.score >= .86 &&\n        winner.channels >= 2 &&\n        margin >= .10 &&\n        winner.hardConflicts == 0;\n'''
if text.count(old) != 1:
    raise SystemExit('Calibrated-lock anchor changed; refusing unsafe patch.')
path.write_text(text.replace(old, new, 1), encoding='utf-8')
Path(__file__).unlink()
