from pathlib import Path


def read(path: str) -> str:
    return Path(path).read_text()


def write(path: str, value: str) -> None:
    Path(path).write_text(value)


def replace_once(path: str, old: str, new: str) -> None:
    text = read(path)
    if new in text:
        return
    count = text.count(old)
    if count != 1:
        raise SystemExit(f'{path}: expected one anchor, found {count}: {old[:70]!r}')
    write(path, text.replace(old, new, 1))


def replace_section(path: str, start: str, end: str, new: str) -> None:
    text = read(path)
    if new.strip() in text:
        return
    a = text.find(start)
    b = text.find(end, a + len(start)) if a >= 0 else -1
    if a < 0 or b < 0:
        raise SystemExit(f'{path}: section anchors missing: {start[:50]!r} -> {end[:50]!r}')
    write(path, text[:a] + new + text[b:])


knowledge_class = '''class MedicineKnowledgeEntry {
  const MedicineKnowledgeEntry({
    this.name = '',
    this.brand = '',
    this.salt = '',
    this.strength = '',
    this.form = '',
    this.manufacturer = '',
    this.barcode = '',
    this.aliases = const <String>[],
    this.ocrAliases = const <String>[],
  });

  final String name;
  final String brand;
  final String salt;
  final String strength;
  final String form;
  final String manufacturer;
  final String barcode;
  final List<String> aliases;
  final List<String> ocrAliases;

  factory MedicineKnowledgeEntry.fromMedicine(Medicine medicine) =>
      MedicineKnowledgeEntry(
        name: medicine.name,
        brand: medicine.brand,
        salt: medicine.salt,
        strength: medicine.strength,
        form: medicine.form,
        manufacturer: medicine.manufacturer,
        barcode: medicine.barcode,
      );

  Map<String, Object?> toMessage() => <String, Object?>{
    'name': name,
    'brand': brand,
    'salt': salt,
    'strength': strength,
    'form': form,
    'manufacturer': manufacturer,
    'barcode': barcode,
    'aliases': aliases.take(24).toList(growable: false),
    'ocrAliases': ocrAliases.take(24).toList(growable: false),
  };

  factory MedicineKnowledgeEntry.fromMessage(Map<Object?, Object?> map) {
    String text(String key) {
      final raw = map[key];
      if (raw is! String) return '';
      final value = raw.trim();
      return value.length <= 300 ? value : value.substring(0, 300);
    }

    List<String> texts(String key) {
      final raw = map[key];
      if (raw is! List) return const <String>[];
      return raw
          .whereType<String>()
          .map((value) => value.trim())
          .where((value) => value.isNotEmpty && value.length <= 300)
          .take(24)
          .toList(growable: false);
    }

    return MedicineKnowledgeEntry(
      name: text('name'),
      brand: text('brand'),
      salt: text('salt'),
      strength: text('strength'),
      form: text('form'),
      manufacturer: text('manufacturer'),
      barcode: text('barcode'),
      aliases: texts('aliases'),
      ocrAliases: texts('ocrAliases'),
    );
  }

  String get _dedupeKey => <String>[
    name,
    brand,
    salt,
    strength,
    form,
    manufacturer,
    barcode,
  ].map(searchText).join('|');

  bool get _hasIdentity =>
      name.trim().isNotEmpty ||
      brand.trim().isNotEmpty ||
      salt.trim().isNotEmpty ||
      barcode.trim().isNotEmpty;
}

'''
replace_section(
    'lib/domain/medicine_understanding.dart',
    'class MedicineKnowledgeEntry {',
    '/// Builds a deterministic, bounded identity-only knowledge snapshot',
    knowledge_class,
)

replace_once(
    'lib/domain/medicine_resolution_v2.dart',
    "import 'medicine_understanding.dart';\nimport 'search.dart';",
    "import 'medicine_understanding.dart';\nimport 'offline_decision_reliability.dart';\nimport 'offline_evidence_graph.dart';\nimport 'search.dart';",
)
replace_once(
    'lib/domain/medicine_resolution_v2.dart',
    """        aliases: <String>[
          if (entry.name.trim().isNotEmpty) entry.name.trim(),
          if (entry.brand.trim().isNotEmpty) entry.brand.trim(),
        ],
        barcodes: <String>[""",
    """        aliases: <String>[
          ...entry.aliases.take(24),
          if (entry.name.trim().isNotEmpty) entry.name.trim(),
          if (entry.brand.trim().isNotEmpty) entry.brand.trim(),
        ],
        ocrAliases: entry.ocrAliases.take(24).toList(growable: false),
        barcodes: <String>[""",
)

identity_consensus = r'''class _IdentityConsensus {
  const _IdentityConsensus({
    required this.score,
    required this.bestRawScore,
    required this.strongSources,
    required this.decisionConfidence,
    required this.graphQuality,
  });

  final double score;
  final double bestRawScore;
  final int strongSources;
  final double decisionConfidence;
  final double graphQuality;
}

_IdentityConsensus _scoreIdentityConsensus(
  MedicineScanDraft draft,
  List<MedicineFrameEvidence> frames,
  Set<String> aliases,
) {
  double bestAgainstAliases(Iterable<String> evidence) {
    var best = 0.0;
    for (final observed in evidence.where((value) => value.trim().isNotEmpty)) {
      for (final alias in aliases.take(32)) {
        best = max(best, _weightedTextSimilarity(observed, alias));
      }
    }
    return best;
  }

  final structuredRaw = bestAgainstAliases(<String>[draft.name, draft.brand]);
  var bestRaw = structuredRaw;
  var structuredScore = structuredRaw;
  if (structuredScore > 0) {
    final confidence = max(
      draft.field('name').confidence,
      draft.field('brand').confidence,
    ).clamp(0, 1).toDouble();
    structuredScore *= .90 + confidence * .10;
  }

  // V8 evidence graph: correlated video frames form one observation component.
  // Only genuinely different views can increase independent-source authority.
  final graph = buildOfflineEvidenceGraph(frames, maxFrames: 12);
  final frameScores = <double>[];
  final strongMatchedQualities = <double>[];
  var strongestMatchedFrameQuality = 0.0;
  var remainingIdentityLines = 32;
  for (final group in graph.groups.take(8)) {
    if (remainingIdentityLines <= 0) break;
    final frame = group.representative;
    final rawLines = frame.text
        .split(RegExp(r'[\r\n]+'))
        .map((value) => value.trim())
        .where((value) => value.isNotEmpty)
        .take(16)
        .toList(growable: false);
    if (rawLines.isEmpty) continue;
    final lines = rawLines
        .take(min(12, remainingIdentityLines))
        .toList(growable: false);
    remainingIdentityLines -= lines.length;
    final raw = bestAgainstAliases(lines);
    bestRaw = max(bestRaw, raw);
    if (raw < .52) continue;
    final quality = frame.quality.clamp(0, 1).toDouble();
    final frameScore = raw * (.90 + quality * .10);
    frameScores.add(frameScore);
    if (frameScore >= .78) {
      strongestMatchedFrameQuality = max(strongestMatchedFrameQuality, quality);
      strongMatchedQualities.add(quality);
    }
  }
  frameScores.sort((a, b) => b.compareTo(a));

  var score = structuredScore;
  if (frameScores.isNotEmpty) score = max(score, frameScores.first);
  final strongFrameScores = frameScores.where((value) => value >= .78).toList();
  if (strongFrameScores.length >= 2) {
    final second = strongFrameScores[1];
    score += ((second - .78) / .22).clamp(0, 1).toDouble() * .025;
  }
  if (strongFrameScores.length >= 3) {
    final third = strongFrameScores[2];
    score += ((third - .78) / .22).clamp(0, 1).toDouble() * .010;
  }

  final structuredStrong = structuredScore >= .78 ? 1 : 0;
  final strongSources = max(structuredStrong, strongFrameScores.length);
  final structuredConfidence = structuredStrong > 0
      ? max(
          draft.field('name').confidence,
          draft.field('brand').confidence,
        ).clamp(0, 1).toDouble()
      : 0.0;
  final decisionConfidence = max(
    structuredConfidence,
    strongestMatchedFrameQuality,
  ).clamp(0, 1).toDouble();
  final averageMatchedQuality = strongMatchedQualities.isEmpty
      ? 0.0
      : strongMatchedQualities.reduce((a, b) => a + b) /
            strongMatchedQualities.length;
  final independentMass = (strongFrameScores.length / 3).clamp(0, 1).toDouble();
  final graphQuality = strongFrameScores.isEmpty
      ? 0.0
      : (independentMass * .65 + averageMatchedQuality * .35)
            .clamp(0, 1)
            .toDouble();
  return _IdentityConsensus(
    score: score.clamp(0, .999).toDouble(),
    bestRawScore: bestRaw.clamp(0, 1).toDouble(),
    strongSources: strongSources,
    decisionConfidence: decisionConfidence,
    graphQuality: graphQuality,
  );
}

'''
replace_section(
    'lib/domain/medicine_resolution_v2.dart',
    'class _IdentityConsensus {',
    'class _ProductHypothesis {',
    identity_consensus,
)

product_hypothesis = '''class _ProductHypothesis {
  const _ProductHypothesis({
    required this.product,
    required this.score,
    required this.channels,
    required this.decisionMass,
    required this.identitySources,
    required this.identityGraphQuality,
    required this.hardConflicts,
    required this.exactBarcode,
    required this.strongIdentity,
  });

  final CanonicalMedicineProduct product;
  final double score;
  final int channels;
  final double decisionMass;
  final int identitySources;
  final double identityGraphQuality;
  final int hardConflicts;
  final bool exactBarcode;
  final bool strongIdentity;
}

'''
replace_section(
    'lib/domain/medicine_resolution_v2.dart',
    'class _ProductHypothesis {',
    '/// Converts parser confidence into decision authority',
    product_hypothesis,
)
replace_once(
    'lib/domain/medicine_resolution_v2.dart',
    '    identitySources: identity.strongSources,\n    hardConflicts: hardConflicts,',
    '    identitySources: identity.strongSources,\n    identityGraphQuality: identity.graphQuality,\n    hardConflicts: hardConflicts,',
)

evidence_quality = '''double _resolverDecisionEvidenceQuality(
  _ProductHypothesis hypothesis,
  MedicineScanDraft draft,
) {
  final confidences = <double>[];
  for (final key in const <String>[
    'name',
    'brand',
    'salt',
    'strength',
    'form',
  ]) {
    final field = draft.field(key);
    if (field.isEmpty || field.conflicted) continue;
    confidences.add(field.confidence.clamp(0, 1).toDouble());
  }
  final fieldQuality = confidences.isEmpty
      ? draft.overallConfidence.clamp(0, 1).toDouble()
      : confidences.reduce((a, b) => a + b) / confidences.length;
  final channelQuality = (hypothesis.channels / 4).clamp(0, 1).toDouble();
  final massQuality = (hypothesis.decisionMass / .72).clamp(0, 1).toDouble();
  final sourceQuality = (hypothesis.identitySources / 3).clamp(0, 1).toDouble();
  return (fieldQuality * .58 +
          channelQuality * .18 +
          massQuality * .14 +
          sourceQuality * .04 +
          hypothesis.identityGraphQuality * .06)
      .clamp(0, 1)
      .toDouble();
}

'''
replace_section(
    'lib/domain/medicine_resolution_v2.dart',
    'double _resolverDecisionEvidenceQuality(',
    'double _resolverRequiredLockScore(',
    evidence_quality,
)

decision_block = '''    final requiredDecisionMass = _resolverRequiredDecisionMass(evidenceQuality);
    final selectiveReliability = assessOfflineDecisionReliability(
      winnerScore: winner.score,
      margin: margin,
      channels: winner.channels,
      decisionMass: winner.decisionMass,
      evidenceQuality: evidenceQuality,
      verified: winner.product.verified,
      hardConflicts: winner.hardConflicts,
      exactBarcode: exactBarcodeLock,
    );
    final calibratedLock =
        winner.product.verified &&
        winner.score >= requiredScore &&
        winner.channels >= 2 &&
        winner.decisionMass >= requiredDecisionMass &&
        margin >= requiredMargin &&
        winner.hardConflicts == 0 &&
        selectiveReliability.acceptCanonicalLock;

    if (exactBarcodeLock || calibratedLock) {
      return _inheritCanonicalIdentity(
        draft,
        winner,
        decisionReliability: selectiveReliability.score,
      );
    }
'''
replace_section(
    'lib/domain/medicine_resolution_v2.dart',
    '    final requiredDecisionMass = _resolverRequiredDecisionMass(evidenceQuality);',
    '    // Low-quality evidence requires a wider separation before automation.',
    decision_block + '\n',
)
replace_once(
    'lib/domain/medicine_resolution_v2.dart',
    '''MedicineScanDraft _inheritCanonicalIdentity(
  MedicineScanDraft draft,
  _ProductHypothesis hypothesis,
) {
  final product = hypothesis.product;
  final fields = Map<String, ExtractedMedicineField>.of(draft.fields);
  final confidence = hypothesis.exactBarcode
      ? .995
      : hypothesis.score.clamp(.82, .99).toDouble();''',
    '''MedicineScanDraft _inheritCanonicalIdentity(
  MedicineScanDraft draft,
  _ProductHypothesis hypothesis, {
  required double decisionReliability,
}) {
  final product = hypothesis.product;
  final fields = Map<String, ExtractedMedicineField>.of(draft.fields);
  final reliabilityCap = (.80 +
          decisionReliability.clamp(0, 1).toDouble() * .19)
      .clamp(.82, .99)
      .toDouble();
  final confidence = hypothesis.exactBarcode
      ? .995
      : min(hypothesis.score, reliabilityCap).clamp(.82, .99).toDouble();''',
)

replace_once(
    'lib/services/medicine_intake_service.dart',
    "import 'media_import_service.dart';\nimport 'scan_service.dart';",
    "import 'media_import_service.dart';\nimport 'offline_recognition_memory_service.dart';\nimport 'scan_service.dart';",
)
replace_once(
    'lib/services/medicine_intake_service.dart',
    '  List<Map<String, Object?>>? _knowledge;',
    '  List<MedicineKnowledgeEntry>? _knowledge;',
)
replace_once(
    'lib/services/medicine_intake_service.dart',
    '''      _knowledge = medicineKnowledgeFromRecords(_records!())
          .map((k) => k.toMessage())
          .toList();''',
    '      _knowledge = medicineKnowledgeFromRecords(_records!());',
)
replace_once(
    'lib/services/medicine_intake_service.dart',
    '''    // Tier-2 master knowledge is optional and queried before isolate work so a
    // very large canonical catalogue never crosses the isolate boundary. The
    // catalogue service is fail-open: empty/corrupt/unavailable knowledge simply
    // leaves Tier-1 pharmacist-reviewed shop memory as the authoritative fallback.
    final catalogue = await CanonicalMedicineCatalogService.instance
        .candidatesForEvidence(frames);''',
    '''    // A bounded correction memory enriches only matching current local
    // identities and fails open. Raw OCR documents are never stored in it.
    final knowledge = await OfflineRecognitionMemoryService.instance
        .enrichKnowledge(_knowledge!, frames);

    // Tier-2 master knowledge is optional and queried before isolate work so a
    // very large canonical catalogue never crosses the isolate boundary. The
    // catalogue service is fail-open: empty/corrupt/unavailable knowledge simply
    // leaves Tier-1 pharmacist-reviewed shop memory as the authoritative fallback.
    final catalogue = await CanonicalMedicineCatalogService.instance
        .candidatesForEvidence(frames);''',
)
replace_once(
    'lib/services/medicine_intake_service.dart',
    "        'knowledge': _knowledge!,",
    "        'knowledge': knowledge.map((k) => k.toMessage()).toList(growable: false),",
)

replace_once(
    'lib/ui/import_screen.dart',
    "import '../services/medicine_intake_service.dart';\nimport '../services/scan_service.dart';",
    "import '../services/medicine_intake_service.dart';\nimport '../services/offline_recognition_memory_service.dart';\nimport '../services/scan_service.dart';",
)
replace_once(
    'lib/ui/import_screen.dart',
    '''      final knowledge = medicineKnowledgeFromRecords(widget.controller.records);
      final catalogue = widget.preparedDrafts == null
          ? await CanonicalMedicineCatalogService.instance
                .candidatesForEvidence(widget.evidence)
          : const <CanonicalMedicineProduct>[];''',
    '''      final baseKnowledge = medicineKnowledgeFromRecords(widget.controller.records);
      final knowledge = widget.preparedDrafts == null
          ? await OfflineRecognitionMemoryService.instance.enrichKnowledge(
              baseKnowledge,
              widget.evidence,
            )
          : baseKnowledge;
      final catalogue = widget.preparedDrafts == null
          ? await CanonicalMedicineCatalogService.instance
                .candidatesForEvidence(widget.evidence)
          : const <CanonicalMedicineProduct>[];''',
)
text = read('lib/ui/import_screen.dart')
start = text.find('  Future<void> _confirmAndAdd(int index, _ImportDraftReview review) async {')
end = text.find('  Future<void> _receiveExactLot(', start)
if start < 0 or end < 0:
    raise SystemExit('lib/ui/import_screen.dart: human confirm function markers missing')
segment = text[start:end]
old = '''      await widget.controller.save(
        medicine,
        expectedRevision: expectedRevision,
      );
      if (!mounted) return;'''
new = '''      await widget.controller.save(
        medicine,
        expectedRevision: expectedRevision,
      );
      await OfflineRecognitionMemoryService.instance.learnFromConfirmedScan(
        review.draft,
        medicine,
      );
      if (!mounted) return;'''
if new not in segment:
    if segment.count(old) != 1:
        raise SystemExit(f'lib/ui/import_screen.dart: human save anchor count={segment.count(old)}')
    segment = segment.replace(old, new, 1)
    write('lib/ui/import_screen.dart', text[:start] + segment + text[end:])

replace_once(
    'lib/ui/medicine_intake_panel.dart',
    "import '../services/local_ai_service.dart';\nimport '../services/medicine_intake_service.dart';",
    "import '../services/local_ai_service.dart';\nimport '../services/medicine_intake_service.dart';\nimport '../services/offline_recognition_memory_service.dart';",
)
replace_once(
    'lib/ui/medicine_intake_panel.dart',
    '''      await widget.controller.save(record, expectedRevision: expectedRevision);
      if (!mounted) return;''',
    '''      await widget.controller.save(record, expectedRevision: expectedRevision);
      await OfflineRecognitionMemoryService.instance.learnFromConfirmedScan(
        draft,
        record,
      );
      if (!mounted) return;''',
)

print('Level 5 source surgery applied successfully.')
