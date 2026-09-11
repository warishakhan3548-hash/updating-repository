from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding='utf-8')


def write(path: str, text: str) -> None:
    (ROOT / path).write_text(text, encoding='utf-8')


def replace_once(path: str, old: str, new: str) -> None:
    text = read(path)
    count = text.count(old)
    if count != 1:
        raise SystemExit(f'{path}: expected one exact match, found {count}: {old[:80]!r}')
    write(path, text.replace(old, new, 1))


def regex_once(path: str, pattern: str, replacement: str) -> None:
    text = read(path)
    updated, count = re.subn(pattern, replacement, text, count=1, flags=re.S)
    if count != 1:
        raise SystemExit(f'{path}: expected one regex match, found {count}: {pattern[:100]!r}')
    write(path, updated)


# 1) Complete OCR storage budget. The raw OCR remains data, never authority.
replace_once(
    'lib/domain/medicine.dart',
    "DateTime civilDay(DateTime value) =>\n    DateTime.utc(value.year, value.month, value.day);",
    "const maxStoredOcrTextCharacters = 120000;\n\nDateTime civilDay(DateTime value) =>\n    DateTime.utc(value.year, value.month, value.day);",
)
replace_once(
    'lib/domain/medicine.dart',
    "      ocrText: text('ocrText', 30000),",
    "      ocrText: text('ocrText', maxStoredOcrTextCharacters),",
)

# 2) Vision returns complete OCR. Medicine-focused filtering now belongs to one
# domain focus kernel and is never allowed to erase audit/search text.
replace_once(
    'lib/services/scan_service.dart',
    "import '../domain/gs1_healthcare.dart';\nimport '../domain/medicine_understanding.dart';",
    "import '../domain/gs1_healthcare.dart';\nimport '../domain/medicine_evidence_focus.dart';\nimport '../domain/medicine_understanding.dart';",
)
replace_once(
    'lib/services/scan_service.dart',
    "      final lines = _mergeLines([\n        if (latin is RecognizedText)\n          ...(latin as RecognizedText).text.split('\\n'),\n        if (hindi is RecognizedText)\n          ...(hindi as RecognizedText).text.split('\\n'),\n      ]);",
    "      final rawText = _completeOcrText([\n        if (latin is RecognizedText) (latin as RecognizedText).text,\n        if (hindi is RecognizedText) (hindi as RecognizedText).text,\n      ]);",
)
replace_once(
    'lib/services/scan_service.dart',
    "        text: lines.join('\\n'),",
    "        text: rawText,",
)
regex_once(
    'lib/services/scan_service.dart',
    r"List<String> _mergeLines\(Iterable<String> raw\) \{.*?(?=double _lineQuality\(String value\) \{)",
    '''String _completeOcrText(Iterable<String> documents) {
  final buffer = StringBuffer();
  var remaining = maxPersistedRawOcrCharacters;
  for (final document in documents) {
    for (final raw in document.split(RegExp(r'[\\r\\n]+'))) {
      final line = raw.replaceAll(RegExp(r'\\s+'), ' ').trim();
      if (line.isEmpty) continue;
      final separator = buffer.isEmpty ? '' : '\\n';
      if (remaining <= separator.length) return buffer.toString();
      buffer.write(separator);
      remaining -= separator.length;
      final take = line.length < remaining ? line.length : remaining;
      buffer.write(line.substring(0, take));
      remaining -= take;
      if (take < line.length || remaining == 0) return buffer.toString();
    }
  }
  return buffer.toString();
}

''',
)

# 3) Direct scan/photo/text imports now use the exact same V2 gateway as the
# durable intake queue. No V1 side path remains authoritative.
replace_once(
    'lib/ui/import_screen.dart',
    "import '../domain/medicine.dart';\nimport '../domain/medicine_scan_commit.dart';",
    "import '../domain/medicine.dart';\nimport '../domain/medicine_evidence_focus.dart';\nimport '../domain/medicine_scan_commit.dart';",
)
replace_once(
    'lib/ui/import_screen.dart',
    "import '../services/medicine_intake_service.dart';\nimport '../services/scan_service.dart';",
    "import '../services/medicine_intake_service.dart';\nimport '../services/medicine_resolution_service.dart';\nimport '../services/scan_service.dart';",
)
regex_once(
    'lib/ui/import_screen.dart',
    r"      final knowledge = medicineKnowledgeFromRecords\(widget\.controller\.records\);\n      final payload = widget\.preparedDrafts != null\n.*?      final understanding = MedicineUnderstandingResult\.fromMessage\(payload\);",
    '''      final understanding = widget.preparedDrafts != null
          ? MedicineUnderstandingResult(drafts: widget.preparedDrafts!)
          : await MedicineResolutionService.instance.resolve(
              evidence: widget.evidence,
              records: widget.controller.records,
            );''',
)
replace_once(
    'lib/ui/import_screen.dart',
    "          draft.rawText,\n        ].where((value) => value.trim().isNotEmpty).join('\\n');",
    "          medicineDecisionTextFromDraft(draft.rawText),\n        ].where((value) => value.trim().isNotEmpty).join('\\n');",
)

# 4) Queued photo/video/evidence intake converges on the same gateway. Remove
# the duplicate catalogue/knowledge cache so there is one resolution owner.
replace_once(
    'lib/services/medicine_intake_service.dart',
    "import '../domain/medicine_resolution_v2.dart';\n",
    '',
)
replace_once(
    'lib/services/medicine_intake_service.dart',
    "import 'canonical_medicine_catalog_service.dart';\n",
    '',
)
replace_once(
    'lib/services/medicine_intake_service.dart',
    "import 'media_import_service.dart';\nimport 'scan_service.dart';",
    "import 'media_import_service.dart';\nimport 'medicine_resolution_service.dart';\nimport 'scan_service.dart';",
)
replace_once(
    'lib/services/medicine_intake_service.dart',
    "  int Function()? _revision;\n  int? _knowledgeRevision;\n  List<Map<String, Object?>>? _knowledge;\n",
    '',
)
replace_once(
    'lib/services/medicine_intake_service.dart',
    "    _records = records;\n    _revision = revision;\n    _knowledgeRevision = null;\n    _knowledge = null;",
    "    _records = records;",
)
# Keep the public named revision parameter for source compatibility with current
# callers; the authoritative resolver derives only identity data from records.
text = read('lib/services/medicine_intake_service.dart')
text = text.replace("    _knowledge = null;\n    _knowledgeRevision = null;\n", '')
write('lib/services/medicine_intake_service.dart', text)
regex_once(
    'lib/services/medicine_intake_service.dart',
    r"  Future<MedicineUnderstandingResult> _understand\(\n    List<MedicineFrameEvidence> frames,\n  \) async \{.*?\n  \}\n\n  Future<void> _pump\(\) async \{",
    '''  Future<MedicineUnderstandingResult> _understand(
    List<MedicineFrameEvidence> frames,
  ) => MedicineResolutionService.instance.resolve(
    evidence: frames,
    records: _records!(),
  );

  Future<void> _pump() async {''',
)

# 5) Optional Local AI and final domain validators see only focused decision
# evidence. Raw OCR remains attached to the draft untouched for search/audit.
replace_once(
    'lib/domain/local_ai_protocol.dart',
    "import 'ai_protocol.dart';\nimport 'medicine.dart';",
    "import 'ai_protocol.dart';\nimport 'medicine.dart';\nimport 'medicine_evidence_focus.dart';",
)
replace_once(
    'lib/domain/local_ai_protocol.dart',
    "  final source = draft.rawText;\n  if (source.length <= limit) return source;",
    "  final source = medicineDecisionTextFromDraft(draft.rawText);\n  if (source.length <= limit) return source;",
)
replace_once(
    'lib/domain/local_scan_handoff.dart',
    "import 'local_ai_protocol.dart';\nimport 'medicine_understanding.dart';",
    "import 'local_ai_protocol.dart';\nimport 'medicine_evidence_focus.dart';\nimport 'medicine_understanding.dart';",
)
replace_once(
    'lib/domain/local_scan_handoff.dart',
    "    final truncated = draft.rawText.length > source.length;",
    "    final truncated =\n        medicineDecisionTextFromDraft(draft.rawText).length > source.length;",
)
replace_once(
    'lib/domain/medicine_scan_commit.dart',
    "import 'medicine.dart';\nimport 'medicine_understanding.dart';",
    "import 'medicine.dart';\nimport 'medicine_evidence_focus.dart';\nimport 'medicine_understanding.dart';",
)
replace_once(
    'lib/domain/medicine_scan_commit.dart',
    "  final source = normalize(draft.rawText);",
    "  final source = normalize(medicineDecisionTextFromDraft(draft.rawText));",
)
replace_once(
    'lib/domain/medicine_scan_commit.dart',
    "    ocrText: draft.searchableOcrText,",
    "    ocrText: searchableRawOcrText(draft),",
)

# 6) Live camera preview stops running a separate V1 medicine parser. It shows
# detector output only; the returned evidence is resolved by the shared gateway.
replace_once(
    'lib/ui/scanner_screen.dart',
    "import '../domain/medicine_understanding.dart';\n",
    '',
)
regex_once(
    'lib/ui/scanner_screen.dart',
    r"        final payload =\n            await compute\(understandMedicineEvidenceMessage, <String, Object\?>\{.*?        \}\);\n      \}",
    '''        setState(() {
          _evidence
            ..clear()
            ..addAll(evidence);
          _text = result.text;
          if (result.barcode.isNotEmpty) _barcode = result.barcode;
          _error = '';
        });
      }''',
)

# 7) Search keeps the hot bounded index, then uses the complete raw OCR as a
# lower-authority exact/normalized fallback inside the worker isolate. This makes
# OCR terms searchable even when they occur beyond the first indexed 176 terms.
regex_once(
    'lib/services/search_worker.dart',
    r"void _searchEntry\(SendPort main\) \{.*?(?=class SearchWorker \{)",
    r'''List<SearchHit> _withRawOcrFallback(
  List<SearchHit> primary,
  Iterable<Medicine> records,
  String query, {
  required bool Function(Medicine) allowed,
  required int limit,
}) {
  final rawQuery = query.trim();
  if (rawQuery.isEmpty || rawQuery.length > 512) return primary;

  final queryLower = rawQuery.toLowerCase();
  final normalizedQuery = searchText(rawQuery);
  final queryTokens = normalizedQuery
      .split(' ')
      .where((token) => token.length >= 2)
      .take(10)
      .toList(growable: false);
  final found = <String, SearchHit>{for (final hit in primary) hit.id: hit};

  for (final medicine in records) {
    if (!allowed(medicine) || medicine.ocrText.trim().isEmpty) continue;
    if ((found[medicine.id]?.score ?? 0) >= .85) continue;

    var score = 0.0;
    final raw = medicine.ocrText;
    if (raw.toLowerCase().contains(queryLower)) {
      score = .82;
    } else if (normalizedQuery.isNotEmpty) {
      final normalizedRaw = searchText(raw);
      if (normalizedRaw.contains(normalizedQuery)) {
        score = .79;
      } else if (queryTokens.isNotEmpty &&
          queryTokens.every((token) => normalizedRaw.contains(token))) {
        score = .74;
      }
    }
    if (score <= 0) continue;
    final existing = found[medicine.id];
    if (existing == null || existing.score < score) {
      found[medicine.id] = SearchHit(
        medicine.id,
        score,
        'Raw OCR text',
        rawQuery,
      );
    }
  }

  final result = found.values.toList(growable: false)
    ..sort((a, b) {
      final score = b.score.compareTo(a.score);
      return score != 0 ? score : a.id.compareTo(b.id);
    });
  return result.take(limit).toList(growable: false);
}

void _searchEntry(SendPort main) {
  final receive = ReceivePort();
  main.send(receive.sendPort);
  MedicineSearch? engine;
  MedicineSearch? archivedEngine;
  List<Medicine>? indexedRecords;
  var revision = -1;
  receive.listen((dynamic raw) {
    final message = raw as Map;
    final id = message['id'] as int;
    try {
      final kind = message['kind'] as String;
      if (kind == 'index') {
        indexedRecords = (message['records'] as List).cast<Medicine>();
        engine = MedicineSearch(indexedRecords!);
        archivedEngine = null;
        revision = message['revision'] as int;
        main.send({'id': id, 'result': true});
      } else {
        if (engine == null ||
            indexedRecords == null ||
            revision != message['revision']) {
          throw StateError('Search index changed. Retry this search.');
        }
        if (kind == 'searchArchived') {
          archivedEngine ??= MedicineSearch(
            indexedRecords!.where((medicine) => medicine.archived),
            includeArchived: true,
          );
          final query = message['query'] as String;
          final limit = message['limit'] as int;
          final primary = archivedEngine!.searchArchived(
            query,
            message['today'] as DateTime,
            limit: limit,
          );
          main.send({
            'id': id,
            'result': _withRawOcrFallback(
              primary,
              indexedRecords!,
              query,
              allowed: (medicine) => medicine.archived,
              limit: limit,
            ),
          });
        } else if (kind == 'search') {
          final query = message['query'] as String;
          final scope = message['scope'] as SearchScope;
          final settings = message['settings'] as WarningSettings;
          final today = message['today'] as DateTime;
          final limit = message['limit'] as int;
          final primary = engine!.search(
            query,
            scope,
            settings,
            today,
            limit: limit,
          );
          main.send({
            'id': id,
            'result': _withRawOcrFallback(
              primary,
              indexedRecords!,
              query,
              allowed: (medicine) =>
                  !medicine.archived &&
                  inScope(medicine, scope, settings, today),
              limit: limit,
            ),
          });
        } else {
          throw StateError('Unknown search operation.');
        }
      }
    } catch (e) {
      main.send({'id': id, 'error': e.toString()});
    }
  });
}

''',
)

# Restore the permanent CI workflow and remove this delivery script. The branch
# commit produced by the workflow therefore contains only product code/tests.
workflow = ROOT / '.github/workflows/flutter.yml'
workflow.write_text('''name: Pharmacy checks
on:
  push:
    branches: [main]
  pull_request:
    branches: [main]
  workflow_dispatch:
permissions:
  contents: read
concurrency:
  group: pharmacy-${{ github.ref }}
  cancel-in-progress: true
jobs:
  verify:
    runs-on: ubuntu-latest
    timeout-minutes: 30
    env:
      FLUTTER_SUPPRESS_ANALYTICS: true
      CI: true
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-java@v4
        with:
          distribution: temurin
          java-version: '17'
      - uses: subosito/flutter-action@v2
        with:
          flutter-version: '3.47.2'
          channel: stable
          cache: true
      - name: Resolve pinned dependencies
        run: flutter pub get
      - name: Static checks
        run: dart analyze lib test tool third_party/lib_llama_cpp/lib
      - name: Domain, persistence and UI checks
        run: flutter test --reporter expanded
      - name: Compile Android integration
        run: flutter build apk --debug --no-pub
      - name: Upload Android APK
        uses: actions/upload-artifact@v4
        with:
          name: Aaris-Pharmacy-debug-APK
          path: build/app/outputs/flutter-apk/app-debug.apk
          if-no-files-found: error
          retention-days: 30
      - name: Upload UI review images
        if: always()
        uses: actions/upload-artifact@v4
        with:
          name: Aaris-Pharmacy-UI-review
          path: |
            build/ui-review/*.png
          if-no-files-found: warn
          retention-days: 30
''', encoding='utf-8')
Path(__file__).unlink()
