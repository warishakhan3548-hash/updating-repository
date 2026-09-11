from pathlib import Path


def replace_once(path: Path, old: str, new: str) -> None:
    text = path.read_text()
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{path}: expected exactly one patch anchor, found {count}")
    path.write_text(text.replace(old, new, 1))


resolver = Path('lib/domain/medicine_resolution_v2.dart')

replace_once(
    resolver,
    "const double _resolverMinimumDecisionMass = .50;\n",
    "const double _resolverMinimumDecisionMass = .50;\n"
    "const double _resolverCorrelatedEvidenceDecay = .55;\n",
)

replace_once(
    resolver,
    """    final barcodeKeys = <String>{
      _canonicalBarcode(draft.barcode),
      for (final frame in frames)
        for (final barcode in frame.allBarcodes) _canonicalBarcode(barcode),
    }..remove('');
    for (final barcode in barcodeKeys) {
      vote(barcodes[barcode], 48);
    }

    final queryTerms = _queryTerms(
""",
    """    final barcodeKeys = <String>{
      _canonicalBarcode(draft.barcode),
      for (final frame in frames)
        for (final barcode in frame.allBarcodes) _canonicalBarcode(barcode),
    }..remove('');

    // V6 exact-identifier fast lane. A verified exact product identifier is
    // stronger than every fuzzy lexical channel and already has contradiction
    // checks in _scoreProduct. Once one exists, do not spend milliseconds
    // expanding unrelated fuzzy candidates. Multiple verified collisions remain
    // visible so the downstream ambiguity/conflict gates can arbitrate safely.
    final verifiedExactIndexes = <int>{};
    for (final barcode in barcodeKeys) {
      final posting = barcodes[barcode];
      if (posting == null) continue;
      for (final index in posting) {
        if (products[index].verified) verifiedExactIndexes.add(index);
      }
    }
    if (verifiedExactIndexes.isNotEmpty) {
      final rankedExact = verifiedExactIndexes.toList(growable: false)
        ..sort((a, b) {
          final source = (products[b].source == 'shop' ? 1 : 0).compareTo(
            products[a].source == 'shop' ? 1 : 0,
          );
          if (source != 0) return source;
          final prior = products[b].priorWeight.compareTo(products[a].priorWeight);
          if (prior != 0) return prior;
          return products[a].productId.compareTo(products[b].productId);
        });
      return rankedExact
          .take(_maxRetrievedProducts)
          .map((index) => products[index])
          .toList(growable: false);
    }

    // Unverified identifiers are useful retrieval evidence, but they are never
    // allowed to suppress a verified coherent lexical hypothesis.
    for (final barcode in barcodeKeys) {
      vote(barcodes[barcode], 48);
    }

    final queryTerms = _queryTerms(
""",
)

replace_once(
    resolver,
    """  final frameScores = <double>[];
  final seenFrameFingerprints = <String>{};
  var remainingIdentityLines = 32;
""",
    """  final frameScores = <double>[];
  final seenFrameFingerprints = <String>{};
  final seenFrameIdentityTokens = <Set<String>>[];
  var remainingIdentityLines = 32;
""",
)

replace_once(
    resolver,
    """    final fingerprint = searchText(rawLines.join(' ')).replaceAll(' ', '');
    if (fingerprint.isEmpty || !seenFrameFingerprints.add(fingerprint)) continue;

    // Preserve independent-frame corroboration without letting video length
""",
    """    final normalizedFrame = searchText(rawLines.join(' '));
    final fingerprint = normalizedFrame.replaceAll(' ', '');
    if (fingerprint.isEmpty || !seenFrameFingerprints.add(fingerprint)) continue;
    final identityTokens = normalizedFrame
        .split(' ')
        .where(
          (value) => value.length >= 3 && !_resolverNoise.contains(value),
        )
        .take(48)
        .toSet();
    if (seenFrameIdentityTokens.any(
      (seen) => _nearDuplicateIdentityFrame(seen, identityTokens),
    )) {
      continue;
    }
    if (identityTokens.isNotEmpty) seenFrameIdentityTokens.add(identityTokens);

    // Preserve independent-frame corroboration without letting video length
""",
)

replace_once(
    resolver,
    """class _IdentityConsensus {
""",
    """bool _nearDuplicateIdentityFrame(Set<String> left, Set<String> right) {
  // Exact fingerprints are handled before this function. This second gate
  // collapses video frames whose OCR differs only by a couple of noisy tokens,
  // preventing one physical view from manufacturing independent authority.
  // Small token sets are deliberately excluded: two different pack sides often
  // share only brand/strength and must remain independent evidence.
  if (left.length < 4 || right.length < 4) return false;
  var intersection = 0;
  final smaller = left.length <= right.length ? left : right;
  final larger = identical(smaller, left) ? right : left;
  for (final token in smaller) {
    if (larger.contains(token)) intersection++;
  }
  if (intersection < 4) return false;
  final union = left.length + right.length - intersection;
  final jaccard = intersection / max(1, union);
  final containment = intersection / min(left.length, right.length);
  return jaccard >= .72 && containment >= .84;
}

class _IdentityConsensus {
""",
)

replace_once(
    resolver,
    """  var channels = 0;
  var decisionMass = 0.0;
  var hardConflicts = 0;
""",
    """  var channels = 0;
  var exactIdentifierMass = 0.0;
  var identityMass = 0.0;
  var identityCorroborationMass = 0.0;
  var saltMass = 0.0;
  var strengthMass = 0.0;
  var manufacturerMass = 0.0;
  var hardConflicts = 0;
""",
)

replace_once(
    resolver,
    """    decisionMass += .52;
    channels++;
""",
    """    exactIdentifierMass = .52;
    channels++;
""",
)

replace_once(
    resolver,
    """      channels++;
      decisionMass += .36;
      if (identity.strongSources >= 2) decisionMass += .02;
""",
    """      channels++;
      identityMass = .36;
      if (identity.strongSources >= 2) identityCorroborationMass = .02;
""",
)

replace_once(
    resolver,
    """      channels++;
      decisionMass += .19;
""",
    """      channels++;
      saltMass = .19;
""",
)

replace_once(
    resolver,
    """      channels++;
      decisionMass += .18;
""",
    """      channels++;
      strengthMass = .18;
""",
)

replace_once(
    resolver,
    """      channels++;
      decisionMass += .05;
""",
    """      channels++;
      manufacturerMass = .05;
""",
)

replace_once(
    resolver,
    """  var score = totalWeight <= 0 ? 0.0 : weighted / totalWeight;
""",
    """  // Salt and strength usually originate from the same printed composition
  // region. Treating both as fully independent double-counts one OCR source.
  // V6 applies diminishing authority to the second composition clue while
  // preserving the historical mass of either clue alone.
  final compositionMass = max(saltMass, strengthMass) +
      min(saltMass, strengthMass) * _resolverCorrelatedEvidenceDecay;
  final decisionMass = exactIdentifierMass +
      identityMass +
      identityCorroborationMass +
      compositionMass +
      manufacturerMass;

  var score = totalWeight <= 0 ? 0.0 : weighted / totalWeight;
""",
)

old_edit = """double _weightedEditSimilarity(String left, String right) {
  if (left == right) return 1;
  if (left.isEmpty || right.isEmpty) return 0;
  if (left.length > 80) left = left.substring(0, 80);
  if (right.length > 80) right = right.substring(0, 80);
  var previous = List<double>.generate(
    right.length + 1,
    (index) => index * .82,
  );
  for (var i = 0; i < left.length; i++) {
    final current = List<double>.filled(right.length + 1, 0)
      ..[0] = (i + 1) * .82;
    for (var j = 0; j < right.length; j++) {
      final substitution =
          previous[j] + _ocrSubstitutionCost(left[i], right[j]);
      final deletion = previous[j + 1] + .82;
      final insertion = current[j] + .82;
      current[j + 1] = min(substitution, min(deletion, insertion));
    }
    previous = current;
  }
  final scale = max(left.length, right.length).toDouble();
  return (1 - previous.last / scale).clamp(0, 1).toDouble();
}
"""
new_edit = """double _weightedEditSimilarity(String left, String right) {
  if (left == right) return 1;
  if (left.isEmpty || right.isEmpty) return 0;
  if (left.length > 80) left = left.substring(0, 80);
  if (right.length > 80) right = right.substring(0, 80);

  // Weighted optimal-string-alignment Damerau-Levenshtein. Adjacent swaps are
  // a common OCR/typing failure (DLOO -> DOLO) and should cost one bounded edit,
  // not two substitutions. Memory remains O(m): only three rows are retained.
  var previousPrevious = <double>[];
  var previous = List<double>.generate(
    right.length + 1,
    (index) => index * .82,
  );
  for (var i = 0; i < left.length; i++) {
    final current = List<double>.filled(right.length + 1, 0)
      ..[0] = (i + 1) * .82;
    for (var j = 0; j < right.length; j++) {
      final substitution =
          previous[j] + _ocrSubstitutionCost(left[i], right[j]);
      final deletion = previous[j + 1] + .82;
      final insertion = current[j] + .82;
      var best = min(substitution, min(deletion, insertion));
      if (i > 0 &&
          j > 0 &&
          left[i] == right[j - 1] &&
          left[i - 1] == right[j] &&
          previousPrevious.isNotEmpty) {
        best = min(best, previousPrevious[j - 1] + .72);
      }
      current[j + 1] = best;
    }
    previousPrevious = previous;
    previous = current;
  }
  final scale = max(left.length, right.length).toDouble();
  return (1 - previous.last / scale).clamp(0, 1).toDouble();
}
"""
replace_once(resolver, old_edit, new_edit)


test_path = Path('test/medicine_resolution_v2_test.dart')
test_text = test_path.read_text()
anchor = "  });\n}\n"
if not test_text.endswith(anchor):
    raise SystemExit(f'{test_path}: unexpected group terminator')
extra_tests = r'''

    test('adjacent OCR transposition still resolves a coherent verified product', () {
      const product = CanonicalMedicineProduct(
        productId: 'in:dolo:650:tablet:v6',
        revision: 601,
        name: 'Dolo',
        brand: 'Dolo',
        salt: 'Paracetamol',
        strength: '650 mg',
        form: 'Tablet',
        verified: true,
      );
      final noisy = MedicineScanDraft(
        fields: <String, ExtractedMedicineField>{
          'name': _field('Dloo', confidence: .91),
          'brand': _field('Dloo', confidence: .91),
          'salt': _field('Paracetamol'),
          'strength': _field('650 mg'),
          'form': _field('Tablet'),
        },
        rawText: 'DLOO 650\nParacetamol Tablets IP 650 mg',
        searchKeywords: 'dloo paracetamol 650 mg tablet',
        frameSequences: const <int>[0],
        overallConfidence: .91,
      );
      final result = MedicineProductResolverV2(
        localKnowledge: const <MedicineKnowledgeEntry>[],
        catalogue: const <CanonicalMedicineProduct>[product],
      ).reconcile(
        MedicineUnderstandingResult(drafts: <MedicineScanDraft>[noisy]),
        const <MedicineFrameEvidence>[
          MedicineFrameEvidence(
            sequence: 0,
            quality: .94,
            text: 'DLOO 650\nParacetamol Tablets IP 650 mg',
          ),
        ],
      );

      final draft = result.drafts.single;
      expect(draft.name, 'Dolo');
      expect(draft.strength, '650 mg');
      expect(draft.field('name').conflicted, isFalse);
    });

    test('unverified exact code cannot suppress a verified coherent product', () {
      const unverifiedCodeMatch = CanonicalMedicineProduct(
        productId: 'local:unknown-code-owner',
        revision: 602,
        name: 'Different Medicine',
        brand: 'Different',
        salt: 'Ibuprofen',
        strength: '400 mg',
        form: 'Tablet',
        barcodes: <String>['LOCAL-CODE-42'],
        verified: false,
      );
      const verifiedDolo = CanonicalMedicineProduct(
        productId: 'in:dolo:650:tablet:v6-verified',
        revision: 603,
        name: 'Dolo',
        brand: 'Dolo',
        salt: 'Paracetamol',
        strength: '650 mg',
        form: 'Tablet',
        verified: true,
      );
      final result = MedicineProductResolverV2(
        localKnowledge: const <MedicineKnowledgeEntry>[],
        catalogue: const <CanonicalMedicineProduct>[
          unverifiedCodeMatch,
          verifiedDolo,
        ],
      ).reconcile(
        MedicineUnderstandingResult(
          drafts: <MedicineScanDraft>[
            _doloDraft(barcode: 'LOCAL-CODE-42'),
          ],
        ),
        const <MedicineFrameEvidence>[
          MedicineFrameEvidence(
            sequence: 0,
            barcode: 'LOCAL-CODE-42',
            text: 'DOLO 650\nParacetamol Tablets IP 650 mg',
          ),
        ],
      );

      final draft = result.drafts.single;
      expect(draft.name, 'Dolo');
      expect(draft.salt, 'Paracetamol');
      expect(draft.strength, '650 mg');
      expect(draft.fields.values.any((field) => field.conflicted), isFalse);
    });
'''
test_path.write_text(test_text[:-len(anchor)] + extra_tests + '\n' + anchor)


doc_path = Path('docs/OFFLINE_DECISION_ENGINE_MAP.md')
doc = doc_path.read_text()
if '## V6 correlation-aware reasoning upgrade' not in doc:
    doc += r'''

## V6 correlation-aware reasoning upgrade

V6 keeps the same authoritative pipeline and upgrades the original resolver core rather than adding a parallel wrapper.

1. **Verified exact-identifier fast lane:** when one or more verified catalogue/shop products match an observed canonical barcode exactly, fuzzy candidate expansion is skipped. Those exact candidates still pass through the existing contradiction and ambiguity gates. Unverified code matches do not suppress verified lexical hypotheses.
2. **Near-duplicate video evidence collapse:** exact duplicate frame fingerprints were already suppressed in V5. V6 additionally collapses bounded near-duplicate frame token sets, so tiny OCR drift across adjacent video frames cannot manufacture independent evidence authority.
3. **Correlation-aware decision mass:** salt and strength commonly originate from one printed composition region. The stronger composition clue keeps full authority; the second receives a bounded diminishing-return contribution instead of being counted as fully independent evidence.
4. **OCR-aware Damerau edit scoring:** the resolver now treats an adjacent character transposition as one bounded edit while retaining the existing cheap OCR-confusion substitution costs. This improves recovery such as `DLOO -> DOLO` without opening unbounded fuzzy search.
5. **No LLM dependency:** all V6 decisions remain deterministic, local, bounded and auditable. Optional on-device models remain specialists, not a correctness dependency.

### V6 decision order

```text
verified exact identifier
  -> prune to exact verified collision set
  -> contradiction check
  -> exact lock / conflict / ambiguity

otherwise
  -> rare indexed candidate retrieval
  -> bounded OCR-aware Damerau similarity
  -> near-duplicate evidence collapse
  -> semantic evidence channels
  -> correlation-aware authority mass
  -> adaptive score + margin + contradiction gates
  -> lock / review / conflict
```

This follows the same public engineering direction used by modern search and edge-inference systems: aggressively narrow candidates before expensive scoring, keep fuzzy expansion bounded, exploit hardware/on-device execution where models are useful, and preserve an explicit abstain/review state when evidence is insufficient.
'''
    doc_path.write_text(doc)

print('Aaris offline reasoning V6 surgical patch prepared successfully.')
