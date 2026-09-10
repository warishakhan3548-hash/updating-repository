from pathlib import Path

p = Path('tool/check_model_preflight.dart')
text = p.read_text()
old = '''  final tight = planLocalExecution(
    weightBytes: gib,
    metadata: model,
    phone: true,
    totalMemory: 4 * gib,
    availableMemory: 2500 * 1024 * 1024,
  );
  check(tight.contextTokens == 2048, 'Context falls back to fit available RAM');
  check(
    tight.outputTokens == 512 &&
        tight.inventoryRows == 1 &&
        tight.evidenceCharacters == 1800,
    'Small context also reduces output, read pages and OCR source',
  );
'''
new = '''  final healthy = planLocalExecution(
    weightBytes: gib,
    metadata: model,
    phone: true,
    totalMemory: 4 * gib,
    availableMemory: 2500 * 1024 * 1024,
  );
  check(
    healthy.contextTokens == 4096 && !healthy.memoryWarning,
    'Mmap-aware planner keeps useful context when reclaimable RAM is healthy',
  );
  final tight = planLocalExecution(
    weightBytes: gib,
    metadata: model,
    phone: true,
    totalMemory: 4 * gib,
    availableMemory: 512 * 1024 * 1024,
  );
  check(tight.contextTokens == 512, 'Context can fall back to 512 under pressure');
  check(
    tight.outputTokens == 160 &&
        tight.inventoryRows == 1 &&
        tight.evidenceCharacters == 700,
    'Tiny context also reduces output, read pages and OCR source',
  );
'''
if text.count(old) != 1:
    raise SystemExit('tool/check_model_preflight.dart adaptive expectation anchor mismatch')
p.write_text(text.replace(old, new, 1))
