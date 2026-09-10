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
    availableMemory: 400 * 1024 * 1024,
  );
  check(
    tight.contextTokens == 512 && tight.memoryWarning,
    'Context can fall back to 512 and warn instead of hard-blocking under pressure',
  );
  check(
    tight.outputTokens == 160 &&
        tight.inventoryRows == 1 &&
        tight.evidenceCharacters == 700,
    'Tiny context also reduces output, read pages and OCR source',
  );
'''
if text.count(old) != 1:
    raise SystemExit('tool/check_model_preflight.dart adaptive expectation anchor mismatch')
text = text.replace(old, new, 1)

old = '''  rejects(
    () => planLocalExecution(
      weightBytes: 2 * gib,
      metadata: model,
      totalMemory: 16 * gib,
      availableMemory: gib,
    ),
  );
  rejects(
    () =>
        planLocalExecution(weightBytes: gib, metadata: model, lowMemory: true),
  );
  rejects(
    () => planLocalExecution(
      weightBytes: gib,
      metadata: inspectGgufPrefix(fixture(context: 1024), fileBytes: 4096),
    ),
  );
'''
new = '''  final constrainedDesktop = planLocalExecution(
    weightBytes: 2 * gib,
    metadata: model,
    totalMemory: 16 * gib,
    availableMemory: gib,
  );
  check(
    constrainedDesktop.contextTokens == 512 && constrainedDesktop.memoryWarning,
    'Tight RAM becomes a warning and minimum-context native attempt, not a blind block',
  );
  final lowMemoryPlan = planLocalExecution(
    weightBytes: gib,
    metadata: model,
    lowMemory: true,
    phone: true,
  );
  check(
    lowMemoryPlan.contextTokens == 512 && lowMemoryPlan.memoryWarning,
    'Android low-memory state keeps an explicit warned low-context attempt available',
  );
  final shortContextPlan = planLocalExecution(
    weightBytes: gib,
    metadata: inspectGgufPrefix(fixture(context: 1024), fileBytes: 4096),
    phone: true,
  );
  check(
    shortContextPlan.contextTokens == 1024,
    'Valid 1024-token models are supported instead of being rejected by policy',
  );
'''
if text.count(old) != 1:
    raise SystemExit('tool/check_model_preflight.dart soft-admission block mismatch')
text = text.replace(old, new, 1)
p.write_text(text)
