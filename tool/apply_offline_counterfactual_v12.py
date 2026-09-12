from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RESOLVER = ROOT / 'lib/domain/medicine_resolution_v2.dart'
DOC = ROOT / 'docs/OFFLINE_DECISION_ENGINE_MAP.md'
TEST = ROOT / 'test/offline_counterfactual_v12_test.dart'


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f'{label}: expected exactly one anchor, found {count}')
    return text.replace(old, new, 1)


resolver = RESOLVER.read_text()

resolver = replace_once(
    resolver,
    """    final exactBarcodeLock =
        winner.exactBarcode &&
        winner.product.verified &&
        winner.hardConflicts == 0;
    final evidenceQuality = _resolverDecisionEvidenceQuality(winner, draft);
""",
    """    final exactBarcodeLock =
        winner.exactBarcode &&
        winner.product.verified &&
        winner.hardConflicts == 0;

    // V12 counterfactual gate: a high aggregate winner is not enough when a
    // plausible member of the same medicine family differs on a safety-critical
    // variant field that the scan never actually observed. This is deliberately
    // evaluated at the canonicalization boundary, not during retrieval: search
    // remains recall-friendly, while auto-fill must prove the distinguishing
    // salt/strength/form evidence or abstain. Verified exact barcodes retain
    // their separate highest-authority path.
    final blockingVariant = exactBarcodeLock
        ? null
        : _findUnresolvedCounterfactualVariant(draft, winner, hypotheses);
    final counterfactualSafe = blockingVariant == null;

    final evidenceQuality = _resolverDecisionEvidenceQuality(winner, draft);
""",
    'insert V12 counterfactual decision gate',
)

resolver = replace_once(
    resolver,
    """        selectiveReliability.acceptCanonicalLock &&
        confusionSafe;

    if (exactBarcodeLock || calibratedLock) {
""",
    """        selectiveReliability.acceptCanonicalLock &&
        confusionSafe &&
        counterfactualSafe;

    if (exactBarcodeLock || calibratedLock) {
""",
    'bind V12 gate into calibrated lock',
)

resolver = replace_once(
    resolver,
    """    if (runnerUp != null &&
        confusion != null &&
        confusion.highRisk &&
        !confusionSafe) {
""",
    """    if (blockingVariant != null) {
      return _markProductAmbiguity(
        draft,
        winner.product,
        blockingVariant.product,
      );
    }

    if (runnerUp != null &&
        confusion != null &&
        confusion.highRisk &&
        !confusionSafe) {
""",
    'route unresolved counterfactual to review',
)

helper_anchor = """bool _sameResolvedProductIdentity(
  CanonicalMedicineProduct left,
  CanonicalMedicineProduct right,
) {
"""
helper_code = r"""
/// Returns the strongest plausible same-family variant that the observed pack
/// evidence has not yet distinguished from [winner]. A null result means either
/// there is no material variant competitor or at least one reliable critical
/// field proves the winner over every plausible variant inspected.
///
/// Work is intentionally bounded to seven post-winner hypotheses. Candidate
/// retrieval already caps the resolver set; this additional gate therefore adds
/// constant, allocation-light work at the final decision boundary instead of a
/// second search pass.
_ProductHypothesis? _findUnresolvedCounterfactualVariant(
  MedicineScanDraft draft,
  _ProductHypothesis winner,
  List<_ProductHypothesis> hypotheses,
) {
  var inspected = 0;
  for (final candidate in hypotheses.skip(1)) {
    if (inspected >= 7) break;
    inspected++;

    if (!candidate.product.verified || candidate.hardConflicts > 0) continue;
    if (_sameResolvedProductIdentity(winner.product, candidate.product)) {
      continue;
    }

    // Only a realistically reachable alternative may block automation. The
    // bounded score window protects recall for true variants without letting a
    // remote catalogue neighbour turn every confident result into REVIEW.
    final plausibleFloor = max(.60, winner.score - .24);
    if (!candidate.strongIdentity && candidate.score < plausibleFloor) continue;

    final identitySimilarity = _counterfactualIdentitySimilarity(
      winner.product,
      candidate.product,
    );
    if (identitySimilarity < .76) continue;

    final saltDiffers = _criticalTextVariantDiffers(
      winner.product.salt,
      candidate.product.salt,
      sameThreshold: .92,
    );
    final strengthDiffers = _criticalStrengthVariantDiffers(
      winner.product.strength,
      candidate.product.strength,
    );
    final formDiffers = _criticalFormVariantDiffers(
      winner.product.form,
      candidate.product.form,
    );
    if (!saltDiffers && !strengthDiffers && !formDiffers) continue;

    var distinguished = false;
    if (saltDiffers &&
        _observedTextDiscriminatorSupportsWinner(
          draft.field('salt'),
          winner.product.salt,
          candidate.product.salt,
          minimumConfidence: .78,
          winnerThreshold: .88,
          alternativeCeiling: .82,
        )) {
      distinguished = true;
    }
    if (strengthDiffers &&
        _observedStrengthDiscriminatorSupportsWinner(
          draft.field('strength'),
          winner.product.strength,
          candidate.product.strength,
        )) {
      distinguished = true;
    }
    if (formDiffers &&
        _observedFormDiscriminatorSupportsWinner(
          draft.field('form'),
          winner.product.form,
          candidate.product.form,
        )) {
      distinguished = true;
    }

    if (!distinguished) return candidate;
  }
  return null;
}

double _counterfactualIdentitySimilarity(
  CanonicalMedicineProduct left,
  CanonicalMedicineProduct right,
) {
  var best = 0.0;
  for (final pair in <(String, String)>[
    (left.displayName, right.displayName),
    (left.displayName, right.brand),
    (left.brand, right.displayName),
    (left.brand, right.brand),
  ]) {
    if (pair.$1.trim().isEmpty || pair.$2.trim().isEmpty) continue;
    best = max(best, _weightedTextSimilarity(pair.$1, pair.$2));
  }
  return best.clamp(0, 1).toDouble();
}

bool _criticalTextVariantDiffers(
  String left,
  String right, {
  required double sameThreshold,
}) {
  if (left.trim().isEmpty || right.trim().isEmpty) return false;
  return _weightedTextSimilarity(left, right) < sameThreshold;
}

bool _criticalStrengthVariantDiffers(String left, String right) {
  final a = _strengthIdentity(left);
  final b = _strengthIdentity(right);
  return a.isNotEmpty && b.isNotEmpty && a != b;
}

bool _criticalFormVariantDiffers(String left, String right) {
  final a = normalizeForm(left);
  final b = normalizeForm(right);
  return a.isNotEmpty && b.isNotEmpty && a != b;
}

bool _observedTextDiscriminatorSupportsWinner(
  ExtractedMedicineField observed,
  String winner,
  String alternative, {
  required double minimumConfidence,
  required double winnerThreshold,
  required double alternativeCeiling,
}) {
  if (observed.isEmpty ||
      observed.conflicted ||
      observed.confidence < minimumConfidence) {
    return false;
  }
  final winnerScore = _weightedTextSimilarity(observed.value, winner);
  final alternativeScore = _weightedTextSimilarity(observed.value, alternative);
  return winnerScore >= winnerThreshold &&
      alternativeScore < alternativeCeiling &&
      winnerScore - alternativeScore >= .08;
}

bool _observedStrengthDiscriminatorSupportsWinner(
  ExtractedMedicineField observed,
  String winner,
  String alternative,
) {
  if (observed.isEmpty || observed.conflicted || observed.confidence < .65) {
    return false;
  }
  final key = _strengthIdentity(observed.value);
  return key.isNotEmpty &&
      key == _strengthIdentity(winner) &&
      key != _strengthIdentity(alternative);
}

bool _observedFormDiscriminatorSupportsWinner(
  ExtractedMedicineField observed,
  String winner,
  String alternative,
) {
  if (observed.isEmpty || observed.conflicted || observed.confidence < .82) {
    return false;
  }
  final key = normalizeForm(observed.value);
  return key.isNotEmpty &&
      key == normalizeForm(winner) &&
      key != normalizeForm(alternative);
}

"""
resolver = replace_once(
    resolver,
    helper_anchor,
    helper_code + helper_anchor,
    'insert V12 counterfactual helpers',
)

RESOLVER.write_text(resolver)


test_content = r"""import 'package:aaris_pharmacy/domain/medicine_resolution_v2.dart';
import 'package:aaris_pharmacy/domain/medicine_understanding.dart';
import 'package:flutter_test/flutter_test.dart';

ExtractedMedicineField _field(String value, {double confidence = .95}) =>
    ExtractedMedicineField(value: value, confidence: confidence, support: 2);

MedicineScanDraft _draft({
  required String name,
  required String salt,
  String strength = '',
  String form = 'Tablet',
  String barcode = '',
}) {
  final fields = <String, ExtractedMedicineField>{
    'name': _field(name, confidence: .97),
    if (salt.isNotEmpty) 'salt': _field(salt, confidence: .94),
    if (strength.isNotEmpty) 'strength': _field(strength, confidence: .94),
    if (form.isNotEmpty) 'form': _field(form, confidence: .93),
    if (barcode.isNotEmpty) 'barcode': _field(barcode, confidence: .99),
  };
  return MedicineScanDraft(
    fields: fields,
    rawText: [name, salt, strength, form, barcode]
        .where((value) => value.isNotEmpty)
        .join('\n'),
    searchKeywords: [name, salt, strength, form]
        .where((value) => value.isNotEmpty)
        .join(' '),
    frameSequences: const <int>[0],
    overallConfidence: .95,
  );
}

MedicineUnderstandingResult _resolve(
  MedicineScanDraft draft,
  List<CanonicalMedicineProduct> catalogue,
) {
  return MedicineProductResolverV2(
    localKnowledge: const <MedicineKnowledgeEntry>[],
    catalogue: catalogue,
  ).reconcile(
    MedicineUnderstandingResult(drafts: <MedicineScanDraft>[draft]),
    <MedicineFrameEvidence>[
      MedicineFrameEvidence(
        sequence: 0,
        quality: .96,
        text: draft.rawText,
        barcodes: draft.barcode.isEmpty
            ? const <String>[]
            : <String>[draft.barcode],
      ),
    ],
  );
}

void main() {
  group('Aaris Offline V12 counterfactual variant reasoning', () {
    const base = CanonicalMedicineProduct(
      productId: 'rx:cardibeta:25',
      revision: 1,
      name: 'Cardibeta',
      brand: 'Cardibeta',
      salt: 'Metoprolol Succinate',
      strength: '25 mg',
      form: 'Tablet',
      barcodes: <String>['08901234567895'],
      verified: true,
    );
    const plus = CanonicalMedicineProduct(
      productId: 'rx:cardibeta-plus:50',
      revision: 1,
      name: 'Cardibeta Plus',
      brand: 'Cardibeta Plus',
      salt: 'Metoprolol Succinate',
      strength: '50 mg',
      form: 'Tablet',
      barcodes: <String>['08901234567901'],
      verified: true,
    );

    test('missing strength cannot canonicalize a plausible same-family variant', () {
      final resolved = _resolve(
        _draft(name: 'Cardibeta', salt: 'Metoprolol Succinate'),
        const <CanonicalMedicineProduct>[base, plus],
      );

      final draft = resolved.drafts.single;
      expect(draft.strength, isEmpty);
      expect(draft.overallConfidence, lessThanOrEqualTo(.77));
    });

    test('reliable discriminating strength unlocks the correct variant', () {
      final resolved = _resolve(
        _draft(
          name: 'Cardibeta',
          salt: 'Metoprolol Succinate',
          strength: '25 mg',
        ),
        const <CanonicalMedicineProduct>[base, plus],
      );

      final draft = resolved.drafts.single;
      expect(draft.strength, '25 mg');
      expect(draft.brand.toLowerCase(), 'cardibeta');
      expect(draft.overallConfidence, greaterThan(.80));
    });

    test('verified exact barcode remains the highest-authority bypass', () {
      final resolved = _resolve(
        _draft(
          name: 'Cardibeta',
          salt: 'Metoprolol Succinate',
          barcode: '08901234567895',
        ),
        const <CanonicalMedicineProduct>[base, plus],
      );

      expect(resolved.drafts.single.strength, '25 mg');
    });

    test('missing salt cannot choose between same-family composition variants', () {
      const mono = CanonicalMedicineProduct(
        productId: 'rx:neurocalm:mono',
        revision: 1,
        name: 'Neurocalm',
        brand: 'Neurocalm',
        salt: 'Pregabalin',
        strength: '75 mg',
        form: 'Capsule',
        verified: true,
      );
      const combo = CanonicalMedicineProduct(
        productId: 'rx:neurocalm-plus',
        revision: 1,
        name: 'Neurocalm Plus',
        brand: 'Neurocalm Plus',
        salt: 'Pregabalin + Methylcobalamin',
        strength: '75 mg',
        form: 'Capsule',
        verified: true,
      );

      final resolved = _resolve(
        _draft(
          name: 'Neurocalm',
          salt: '',
          strength: '75 mg',
          form: 'Capsule',
        ),
        const <CanonicalMedicineProduct>[mono, combo],
      );

      expect(resolved.drafts.single.salt, isEmpty);
      expect(resolved.drafts.single.overallConfidence, lessThanOrEqualTo(.77));
    });
  });
}
"""
TEST.write_text(test_content)


doc = DOC.read_text()
section_anchor = '## Performance model\n'
section = r"""## V12 counterfactual variant-discrimination gate

V11 made the parser semantically stronger and the reliability layer compensation-resistant. The remaining high-value failure mode was **missing discriminator evidence**: a winner can be globally coherent while a plausible product from the same medicine family differs in a safety-critical variant field that the pack scan never actually observed.

The original `MedicineProductResolverV2` canonicalization boundary now performs one bounded counterfactual check before auto-fill:

```text
ranked winner
  -> inspect at most 7 post-winner hypotheses
  -> ignore unverified / already contradicted / remote alternatives
  -> keep only plausible same-family identities
  -> detect material salt / strength / dosage-form differences
  -> ask: did reliable observed pack evidence distinguish winner from variant?
       YES -> existing score + margin + authority + reliability gates continue
       NO  -> REVIEW / ambiguity; do not invent the missing canonical field
  -> verified exact barcode/GTIN keeps its separate highest-authority lock path
```

This is not another wrapper or another model. It changes the original lock boundary itself. Retrieval stays permissive for recall; canonicalization becomes **counterfactual**: before the engine fills a missing critical field, it must be able to explain why the strongest realistic variant is not the scanned product.

The extra cost is constant and bounded: no new database scan, no network call, no LLM, and at most seven already-scored hypotheses are inspected using cached normalized product fields.

"""
if '## V12 counterfactual variant-discrimination gate' not in doc:
    if section_anchor not in doc:
        raise SystemExit('documentation insertion anchor missing')
    doc = doc.replace(section_anchor, section + section_anchor, 1)
DOC.write_text(doc)

print('V12 surgical patch applied successfully')
