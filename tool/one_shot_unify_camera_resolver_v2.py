from pathlib import Path


def read(path: str) -> str:
    return Path(path).read_text(encoding='utf-8')


def write(path: str, text: str) -> None:
    Path(path).write_text(text, encoding='utf-8')


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f'{label}: expected exactly one anchor, found {count}')
    return text.replace(old, new, 1)


path = 'lib/ui/import_screen.dart'
text = read(path)
text = replace_once(
    text,
    "import '../domain/medicine_scan_commit.dart';\n",
    "import '../domain/medicine_resolution_v2.dart';\nimport '../domain/medicine_scan_commit.dart';\n",
    'import resolver v2',
)
text = replace_once(
    text,
    "import '../services/backup_service.dart';\n",
    "import '../services/backup_service.dart';\nimport '../services/canonical_medicine_catalog_service.dart';\n",
    'import canonical catalogue',
)
old = """      final knowledge = medicineKnowledgeFromRecords(widget.controller.records);
      final payload = widget.preparedDrafts != null
          ? MedicineUnderstandingResult(drafts: widget.preparedDrafts!)
                .toMessage()
          : await compute(understandMedicineEvidenceMessage, <String, Object?>{
              'evidence': widget.evidence
                  .map((item) => item.toMessage())
                  .toList(growable: false),
              'knowledge': knowledge
                  .map((entry) => entry.toMessage())
                  .toList(growable: false),
            });
"""
new = """      final knowledge = medicineKnowledgeFromRecords(widget.controller.records);
      final catalogue = widget.preparedDrafts == null
          ? await CanonicalMedicineCatalogService.instance.candidatesForEvidence(
              widget.evidence,
            )
          : const <CanonicalMedicineProduct>[];
      if (!mounted || generation != _generation) return;

      // Direct camera and durable photo/video must resolve the same physical
      // pack with the same product-first engine. Tier-2 catalogue lookup stays
      // local and bounded; only identity candidates cross the isolate boundary.
      // Prepared durable drafts have already crossed Resolver V2, so they are
      // never reinterpreted a second time here.
      final payload = widget.preparedDrafts != null
          ? MedicineUnderstandingResult(drafts: widget.preparedDrafts!)
                .toMessage()
          : await compute(understandMedicineEvidenceV2Message, <String, Object?>{
              'evidence': widget.evidence
                  .map((item) => item.toMessage())
                  .toList(growable: false),
              'knowledge': knowledge
                  .map((entry) => entry.toMessage())
                  .toList(growable: false),
              'catalog': catalogue
                  .map((entry) => entry.toMessage())
                  .toList(growable: false),
            });
"""
text = replace_once(text, old, new, 'unify direct camera onto resolver v2')

# Guard against future drift back to the legacy resolver inside the normal inbox.
if 'understandMedicineEvidenceMessage, <String, Object?>{' in text:
    raise SystemExit('legacy direct-camera resolver still wired in import_screen.dart')
write(path, text)

path = 'test/scan_ingestion_privacy_contract_test.dart'
text = read(path)
text = replace_once(
    text,
    """    expect(normal, isNot(contains('CloudScanAiService')));
    expect(normal, isNot(contains("../services/cloud_scan_ai_service.dart")));
""",
    """    expect(normal, isNot(contains('CloudScanAiService')));
    expect(normal, isNot(contains("../services/cloud_scan_ai_service.dart")));
    expect(normal, contains('understandMedicineEvidenceV2Message'));
    expect(normal, contains('CanonicalMedicineCatalogService.instance'));
    expect(normal, contains("'catalog': catalogue"));
""",
    'assert direct camera resolver parity',
)
write(path, text)

path = 'docs/SCAN_INGESTION_HARDENING_2026_09_11.md'
text = read(path)
text += """

## Camera / Photo / Video resolver parity

The fast direct-camera inbox previously stopped at the legacy deterministic understanding function while durable Photo/Video already used `Medicine Resolver V2` with a bounded identity-only canonical catalogue candidate set. The same physical pack could therefore rank differently depending on how it entered the app.

Normal direct camera now performs the same local `CanonicalMedicineCatalogService.candidatesForEvidence(...)` lookup and calls `understandMedicineEvidenceV2Message`. Durable prepared drafts are not re-resolved. This gives Camera/Photo/Video one product-first identity policy, one contradiction model and one variant-safety model without changing the explicit cloud review lane.
"""
write(path, text)

print('Aaris direct-camera resolver parity applied successfully.')
