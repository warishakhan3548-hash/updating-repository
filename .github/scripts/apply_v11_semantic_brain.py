from pathlib import Path


def read(path):
    return Path(path).read_text()


def write(path, value):
    Path(path).write_text(value)


def replace_once(path, old, new):
    text = read(path)
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{path}: expected one anchor, found {count}: {old[:120]!r}")
    write(path, text.replace(old, new, 1))


# 1) Product resolver: insert the semantic medicine pass between temporal
# traceability and canonical product resolution.
resolution = 'lib/domain/medicine_resolution_v2.dart'
replace_once(
    resolution,
    "import 'medicine_date_intelligence.dart';\nimport 'medicine_understanding.dart';",
    "import 'medicine_date_intelligence.dart';\nimport 'medicine_semantic_roles.dart';\nimport 'medicine_understanding.dart';",
)
replace_once(
    resolution,
    """      final temporalSafe = _applyDateIntelligence(regulatorySafe, frames);
      drafts.add(_resolveProduct(temporalSafe, frames));""",
    """      final temporalSafe = _applyDateIntelligence(regulatorySafe, frames);
      final semanticSafe = _applySemanticMedicineRoles(temporalSafe, frames);
      drafts.add(_resolveProduct(semanticSafe, frames));""",
)
semantic_helper = r'''MedicineScanDraft _applySemanticMedicineRoles(
  MedicineScanDraft draft,
  List<MedicineFrameEvidence> frames,
) {
  final semantic = inferMedicineSemanticRoles(frames);
  if (semantic.isEmpty) return draft;
  final fields = Map<String, ExtractedMedicineField>.of(draft.fields);

  bool sameValue(String key, String left, String right) {
    if (left.trim().isEmpty || right.trim().isEmpty) return false;
    if (key == 'strength') {
      return _strengthIdentity(left) == _strengthIdentity(right);
    }
    return _weightedTextSimilarity(left, right) >= .91;
  }

  void apply(
    String key,
    String value,
    double confidence, {
    double minimum = .82,
  }) {
    final clean = value.trim();
    if (clean.isEmpty || confidence < minimum) return;
    final current = fields[key];
    if (current != null && !current.isEmpty && sameValue(key, current.value, clean)) {
      fields[key] = ExtractedMedicineField(
        value: current.value,
        confidence: max(current.confidence, confidence),
        support: max(current.support, 1),
        conflicted: current.conflicted,
      );
      return;
    }
    if (current != null && !current.isEmpty && current.confidence >= .88) {
      fields[key] = ExtractedMedicineField(
        value: current.value,
        confidence: min(current.confidence, .84),
        support: max(current.support, 1),
        conflicted: true,
      );
      return;
    }
    if (current == null || current.isEmpty || current.confidence < .78) {
      fields[key] = ExtractedMedicineField(
        value: clean,
        confidence: confidence.clamp(minimum, .97).toDouble(),
        support: max(current?.support ?? 0, 1),
        conflicted: false,
      );
    }
  }

  apply('salt', semantic.salt, semantic.compositionConfidence, minimum: .80);
  if (semantic.strength.trim().isNotEmpty &&
      semantic.components.every((component) => component.strength.isNotEmpty)) {
    apply(
      'strength',
      semantic.strength,
      semantic.compositionConfidence,
      minimum: .82,
    );
  }

  if (!semantic.conflicted &&
      semantic.brand.trim().isNotEmpty &&
      semantic.brandConfidence >= .82) {
    apply('brand', semantic.brand, semantic.brandConfidence, minimum: .82);
    final name = fields['name'];
    final salt = fields['salt']?.value ?? semantic.salt;
    final nameLooksGeneric =
        name != null && !name.isEmpty && salt.trim().isNotEmpty &&
        _weightedTextSimilarity(name.value, salt) >= .88;
    if (name == null || name.isEmpty || name.confidence < .76 || nameLooksGeneric) {
      fields['name'] = ExtractedMedicineField(
        value: semantic.brand,
        confidence: semantic.brandConfidence.clamp(.82, .97).toDouble(),
        support: max(name?.support ?? 0, 1),
        conflicted: false,
      );
    }
  } else if (semantic.genericOnly &&
      semantic.genericName.trim().isNotEmpty &&
      semantic.genericConfidence >= .86) {
    final name = fields['name'];
    if (name == null || name.isEmpty || name.confidence < .76) {
      fields['name'] = ExtractedMedicineField(
        value: semantic.genericName,
        confidence: semantic.genericConfidence.clamp(.86, .96).toDouble(),
        support: max(name?.support ?? 0, 1),
        conflicted: false,
      );
    }
    final brand = fields['brand'];
    final salt = fields['salt']?.value ?? semantic.salt;
    if (brand != null &&
        !brand.isEmpty &&
        salt.trim().isNotEmpty &&
        _weightedTextSimilarity(brand.value, salt) >= .90 &&
        brand.confidence < .92) {
      // The legacy parser intentionally mirrored a confident Name into Brand.
      // Once composition proves this is a generic-only pack, remove that weak
      // synthetic brand instead of persisting a false trade-name distinction.
      fields.remove('brand');
    }
  }

  if (semantic.conflicted) {
    for (final key in const <String>['name', 'brand', 'salt', 'strength']) {
      final field = fields[key];
      if (field == null || field.isEmpty || field.confidence < .78) continue;
      fields[key] = ExtractedMedicineField(
        value: field.value,
        confidence: min(field.confidence, .82),
        support: field.support,
        conflicted: true,
      );
    }
  }

  return _copyDraft(
    draft,
    fields: fields,
    overallConfidence: semantic.conflicted
        ? min(draft.overallConfidence, .77)
        : draft.overallConfidence,
  );
}

'''
replace_once(
    resolution,
    'MedicineScanDraft _applyDateIntelligence(\n',
    semantic_helper + 'MedicineScanDraft _applyDateIntelligence(\n',
)

# 2) First-stage parser: actually consume pharmacist/local aliases, not only the
# later product resolver. General aliases map to canonical visible identity;
# OCR aliases are routed to whichever of Name/Brand they most closely resemble.
understanding = 'lib/domain/medicine_understanding.dart'
old_identity = r'''  void _addLocalIdentity(MedicineKnowledgeEntry entry) {
    final barcode = _barcodeKnowledgeKey(entry.barcode);
    if (barcode.length >= 4 && barcode.length <= 64) {
      _barcodes
          .putIfAbsent(barcode, () => <MedicineKnowledgeEntry>[])
          .add(entry);
    }

    _addIdentity('name', entry.name, entry.strength);
    _addIdentity('brand', entry.brand, entry.strength);
  }
'''
new_identity = r'''  void _addLocalIdentity(MedicineKnowledgeEntry entry) {
    final barcode = _barcodeKnowledgeKey(entry.barcode);
    if (barcode.length >= 4 && barcode.length <= 64) {
      _barcodes
          .putIfAbsent(barcode, () => <MedicineKnowledgeEntry>[])
          .add(entry);
    }

    _addIdentity('name', entry.name, entry.strength);
    _addIdentity('brand', entry.brand, entry.strength);
    for (final alias in entry.aliases.take(24)) {
      _addGeneralIdentityAlias(alias, entry);
    }
    for (final alias in entry.ocrAliases.take(24)) {
      _addOcrIdentityAlias(alias, entry);
    }
  }

  void _addGeneralIdentityAlias(
    String alias,
    MedicineKnowledgeEntry entry,
  ) {
    final cleanAlias = _cleanValue(alias);
    if (cleanAlias.isEmpty) return;
    final name = _cleanValue(entry.name);
    final brand = _cleanValue(entry.brand);
    if (name.isNotEmpty) {
      _addPhrase(
        indexField: 'name',
        outputField: 'name',
        alias: cleanAlias,
        value: name,
        verifiedLocal: true,
      );
      return;
    }
    if (brand.isNotEmpty) {
      _addPhrase(
        indexField: 'brand',
        outputField: 'brand',
        alias: cleanAlias,
        value: brand,
        verifiedLocal: true,
      );
    }
  }

  void _addOcrIdentityAlias(
    String alias,
    MedicineKnowledgeEntry entry,
  ) {
    final cleanAlias = _cleanValue(alias);
    final aliasKey = _knowledgeKey(cleanAlias);
    if (aliasKey.length < 2) return;
    final name = _cleanValue(entry.name);
    final brand = _cleanValue(entry.brand);
    final nameScore = name.isEmpty
        ? 0.0
        : orderedSimilarity(aliasKey, _knowledgeKey(name));
    final brandScore = brand.isEmpty
        ? 0.0
        : orderedSimilarity(aliasKey, _knowledgeKey(brand));
    if (max(nameScore, brandScore) < .52) return;
    if (brand.isNotEmpty && brandScore > nameScore + .025) {
      _addPhrase(
        indexField: 'brand',
        outputField: 'brand',
        alias: cleanAlias,
        value: brand,
        verifiedLocal: true,
      );
      return;
    }
    if (name.isNotEmpty) {
      _addPhrase(
        indexField: 'name',
        outputField: 'name',
        alias: cleanAlias,
        value: name,
        verifiedLocal: true,
      );
    }
  }
'''
replace_once(understanding, old_identity, new_identity)

# 3) Recognition memory: an alias seen against multiple medicine identities may
# no longer enrich all of them. Unique aliases work immediately; collided aliases
# require a clearly dominant pharmacist-confirmed support history.
memory = 'lib/services/offline_recognition_memory_service.dart'
replace_once(
    memory,
    "'''SELECT identity_key, alias, support, last_confirmed\n           FROM recognition_aliases",
    "'''SELECT identity_key, alias, normalized_alias, support, last_confirmed\n           FROM recognition_aliases",
)
old_learning = r'''      final learned = <String, List<String>>{};
      for (final row in rows) {
        final identity = row['identity_key'];
        final alias = row['alias'];
        if (identity is! String || alias is! String || alias.trim().isEmpty) {
          continue;
        }
        final values = learned.putIfAbsent(identity, () => <String>[]);
        if (!values.contains(alias) && values.length < 12) values.add(alias);
      }
      if (learned.isEmpty) return knowledge;
'''
new_learning = r'''      final byAlias = <String, List<Map<String, Object?>>>{};
      for (final row in rows) {
        final normalized = row['normalized_alias'];
        if (normalized is! String || normalized.isEmpty) continue;
        byAlias.putIfAbsent(normalized, () => <Map<String, Object?>>[]).add(row);
      }

      final learned = <String, List<String>>{};
      for (final collision in byAlias.values) {
        final supportByIdentity = <String, int>{};
        for (final row in collision) {
          final identity = row['identity_key'];
          final support = row['support'];
          if (identity is! String || support is! num) continue;
          supportByIdentity.update(
            identity,
            (value) => value + support.toInt(),
            ifAbsent: () => support.toInt(),
          );
        }
        if (supportByIdentity.isEmpty) continue;
        final ranked = supportByIdentity.entries.toList(growable: false)
          ..sort((a, b) {
            final support = b.value.compareTo(a.value);
            return support != 0 ? support : a.key.compareTo(b.key);
          });
        final winner = ranked.first;
        if (ranked.length > 1) {
          final runner = ranked[1];
          final dominant = winner.value >= 3 && winner.value >= runner.value * 2;
          if (!dominant) continue;
        }

        for (final row in collision) {
          if (row['identity_key'] != winner.key) continue;
          final alias = row['alias'];
          if (alias is! String || alias.trim().isEmpty) continue;
          final values = learned.putIfAbsent(winner.key, () => <String>[]);
          if (!values.contains(alias) && values.length < 12) values.add(alias);
          break;
        }
      }
      if (learned.isEmpty) return knowledge;
'''
replace_once(memory, old_learning, new_learning)

# 4) Date V11 hardening: count independent visual observations rather than
# repeated video frames when accumulating date support.
date_file = 'lib/domain/medicine_date_intelligence.dart'
replace_once(
    date_file,
    "import 'medicine_understanding.dart';",
    "import 'medicine_understanding.dart';\nimport 'offline_evidence_graph.dart';",
)
replace_once(
    date_file,
    '  for (final frame in frames.take(16)) {\n',
    '''  final graph = buildOfflineEvidenceGraph(frames, maxFrames: 16);\n  final independentFrames = graph.groups.isEmpty\n      ? frames.take(16)\n      : graph.groups.map((group) => group.representative);\n  for (final frame in independentFrames) {\n''',
)

# Add a regression proving duplicate labelled date frames cannot manufacture
# extra independent support.
date_test = 'test/offline_date_intelligence_v10_test.dart'
replace_once(
    date_test,
    """    test('impossible dates are rejected', () {
      expect(parseMedicineDateText('32 19 2028'), isNull);
      expect(parseMedicineDateText('31 02 2028'), isNull);
    });""",
    """    test('duplicate video frames do not manufacture date support', () {
      final result = inferMedicineDateIntelligence(
        frames: const <MedicineFrameEvidence>[
          MedicineFrameEvidence(text: 'EXP 05 2028', sequence: 1),
          MedicineFrameEvidence(text: 'EXP 05 2028', sequence: 2),
          MedicineFrameEvidence(text: 'EXP 05 2028', sequence: 3),
        ],
        referenceDate: DateTime.utc(2026, 9, 12),
      );
      expect(result.expiry?.support, 1);
    });

    test('impossible dates are rejected', () {
      expect(parseMedicineDateText('32 19 2028'), isNull);
      expect(parseMedicineDateText('31 02 2028'), isNull);
    });""",
)

print('V11 semantic medicine brain integration applied')
