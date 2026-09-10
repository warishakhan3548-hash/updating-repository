from pathlib import Path

p = Path('lib/services/local_ai_service_stub.dart')
text = p.read_text()
old = "  Future<List<LocalModelFile>> files(String repository) async => [];\n"
new = old + "  Future<LocalModelPreflight> preflight(LocalModelFile model) async =>\n      throw UnsupportedError(status);\n"
if text.count(old) != 1:
    raise SystemExit('local_ai_service_stub.dart preflight anchor mismatch')
p.write_text(text.replace(old, new, 1))
