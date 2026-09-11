from pathlib import Path

root = Path(__file__).resolve().parents[1]

path = root / 'lib/services/medicine_intake_service.dart'
text = path.read_text(encoding='utf-8')
old = '''    // Identity-only derived knowledge can be rebuilt cheaply after resume and
    // need not occupy memory while the app is backgrounded. Do not rewrite the
    // user's explicit/manual pause state here.
    if (!active) {
      _knowledge = null;
      _knowledgeRevision = null;
      notifyListeners();
      return;
    }
'''
new = '''    // Durable queue state survives backgrounding. Resolution knowledge is now
    // owned by the shared gateway and has no queue-local cache to retire here.
    if (!active) {
      notifyListeners();
      return;
    }
'''
if text.count(old) != 1:
    raise SystemExit('Expected one stale intake knowledge lifecycle block.')
path.write_text(text.replace(old, new, 1), encoding='utf-8')

path = root / 'lib/ui/import_screen.dart'
text = path.read_text(encoding='utf-8')
text = text.replace("import 'package:flutter/foundation.dart';\n", '', 1)
path.write_text(text, encoding='utf-8')

Path(__file__).unlink()
