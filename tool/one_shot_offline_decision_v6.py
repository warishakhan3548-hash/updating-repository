from pathlib import Path


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f'{label}: expected exactly one anchor, found {count}')
    return text.replace(old, new, 1)


source_path = Path('lib/domain/medicine_resolution_v2.dart')
source = source_path.read_text()

anchor = """  final bool strongIdentity;
}

_ProductHypothesis _scoreProduct(
"""
helpers = """  final bool strongIdentity;
}

/// Converts parser confidence into decision authority without changing the
/// similarity score used for candidate ordering. Evidence below 0.35 is useful
/// for search/review, but it is too uncertain to authorize canonical auto-fill.
/// Above that floor, authority rises continuously instead of jumping at one
/// binary threshold.
double _resolverEvidenceReliability(double confidence) {
  final value = confidence.clamp(0, 1).toDouble();
  if (value < .35) return 0;
  return (.20 + value * .80).clamp(0, 1).toDouble();
}

/// Similarity gates still establish whether a clue agrees. Once it agrees, this
/// function gives near-threshold matches slightly less authority than exact
/// matches. The narrow 0.90..1.00 range preserves existing high-quality behavior
/// while preventing borderline fuzzy evidence from pretending to be exact.
double _resolverAgreementReliability(double similarity, double threshold) {
  if (similarity < threshold || threshold >= 1) return 0;
  final normalized = ((similarity - threshold) / (1 - threshold))
      .clamp(0, 1)
      .toDouble();
  return (.90 + normalized * .10).clamp(0, 1).toDouble();
}

_ProductHypothesis _scoreProduct(
"""
source = replace_once(source, anchor, helpers, 'helper insertion')

old_identity = """    if (bestIdentity >= .78) {
      channels++;
      decisionMass += .36;
      if (identity.strongSources >= 2) decisionMass += .02;
    }
"""
new_identity = """    if (bestIdentity >= .78) {
      channels++;
      final identityConfidence = max(
        draft.field('name').confidence,
        draft.field('brand').confidence,
      );
      final identityAuthority =
          _resolverEvidenceReliability(identityConfidence) *
          _resolverAgreementReliability(bestIdentity, .78);
      decisionMass += .36 * identityAuthority;
      if (identity.strongSources >= 2) {
        decisionMass += .02 * identityAuthority;
      }
    }
"""
source = replace_once(source, old_identity, new_identity, 'identity authority')

old_salt = """    if (salt >= .88) {
      channels++;
      decisionMass += .19;
    }
"""
new_salt = """    if (salt >= .88) {
      channels++;
      final saltAuthority =
          _resolverEvidenceReliability(draft.field('salt').confidence) *
          _resolverAgreementReliability(salt, .88);
      decisionMass += .19 * saltAuthority;
    }
"""
source = replace_once(source, old_salt, new_salt, 'salt authority')

old_strength = """    if (agrees) {
      channels++;
      decisionMass += .18;
    } else if (draft.field('strength').confidence >= .65) {
"""
new_strength = """    if (agrees) {
      channels++;
      decisionMass +=
          .18 * _resolverEvidenceReliability(draft.field('strength').confidence);
    } else if (draft.field('strength').confidence >= .65) {
"""
source = replace_once(source, old_strength, new_strength, 'strength authority')

old_manufacturer = """    if (manufacturer >= .90) {
      channels++;
      decisionMass += .05;
    }
"""
new_manufacturer = """    if (manufacturer >= .90) {
      channels++;
      final manufacturerAuthority =
          _resolverEvidenceReliability(draft.field('manufacturer').confidence) *
          _resolverAgreementReliability(manufacturer, .90);
      decisionMass += .05 * manufacturerAuthority;
    }
"""
source = replace_once(
    source,
    old_manufacturer,
    new_manufacturer,
    'manufacturer authority',
)
source_path.write_text(source)

test_path = Path('test/medicine_resolution_v2_test.dart')
tests = test_path.read_text()
test_anchor = """  });
}
"""
new_tests = r"""
    test('low-confidence salt cannot manufacture canonical auto-fill authority', () {
      const product = CanonicalMedicineProduct(
        productId: 'in:dolo:650:tablet',
        revision: 600,
        name: 'Dolo',
        brand: 'Dolo',
        salt: 'Paracetamol',
        strength: '650 mg',
        form: 'Tablet',
        manufacturer: 'Micro Labs Limited',
        verified: true,
      );
      final uncertainDraft = MedicineScanDraft(
        fields: <String, ExtractedMedicineField>{
          'name': _field('Dolo', confidence: .95),
          'brand': _field('Dolo', confidence: .95),
          'salt': _field('Paracetamol', confidence: .31),
          'form': _field('Tablet', confidence: .95),
        },
        rawText: 'DOLO\nParacetamol\nTABLETS',
        searchKeywords: 'dolo paracetamol tablet',
        frameSequences: const <int>[0],
        overallConfidence: .72,
      );

      final result = MedicineProductResolverV2(
        localKnowledge: const <MedicineKnowledgeEntry>[],
        catalogue: const <CanonicalMedicineProduct>[product],
      ).reconcile(
        MedicineUnderstandingResult(
          drafts: <MedicineScanDraft>[uncertainDraft],
        ),
        const <MedicineFrameEvidence>[
          MedicineFrameEvidence(
            sequence: 0,
            quality: .95,
            text: 'DOLO\nParacetamol\nTABLETS',
          ),
        ],
      );

      final draft = result.drafts.single;
      expect(draft.strength, isEmpty);
      expect(draft.manufacturer, isEmpty);
      expect(scanQuickIdentityReady(draft), isFalse);
    });

    test('independent medium-confidence clues still unlock verified identity', () {
      const product = CanonicalMedicineProduct(
        productId: 'in:dolo:650:tablet',
        revision: 601,
        name: 'Dolo',
        brand: 'Dolo',
        salt: 'Paracetamol',
        strength: '650 mg',
        form: 'Tablet',
        manufacturer: 'Micro Labs Limited',
        verified: true,
      );
      final supportedDraft = MedicineScanDraft(
        fields: <String, ExtractedMedicineField>{
          'name': _field('Dolo', confidence: .82),
          'brand': _field('Dolo', confidence: .82),
          'salt': _field('Paracetamol', confidence: .82),
          'strength': _field('650 mg', confidence: .82),
          'form': _field('Tablet', confidence: .90),
        },
        rawText: 'DOLO 650\nParacetamol Tablets IP 650 mg\nTABLETS',
        searchKeywords: 'dolo paracetamol 650 mg tablet',
        frameSequences: const <int>[0],
        overallConfidence: .82,
      );

      final result = MedicineProductResolverV2(
        localKnowledge: const <MedicineKnowledgeEntry>[],
        catalogue: const <CanonicalMedicineProduct>[product],
      ).reconcile(
        MedicineUnderstandingResult(
          drafts: <MedicineScanDraft>[supportedDraft],
        ),
        const <MedicineFrameEvidence>[
          MedicineFrameEvidence(
            sequence: 0,
            quality: .90,
            text: 'DOLO 650\nParacetamol Tablets IP 650 mg\nTABLETS',
          ),
        ],
      );

      final draft = result.drafts.single;
      expect(draft.manufacturer, 'Micro Labs Limited');
      expect(draft.needsReview, isFalse);
    });
"""
if tests.count(test_anchor) != 1:
    raise SystemExit(
        f'test insertion: expected one closing anchor, found {tests.count(test_anchor)}'
    )
tests = tests.replace(test_anchor, new_tests + test_anchor, 1)
test_path.write_text(tests)

doc_path = Path('docs/OFFLINE_DECISION_ENGINE_MAP.md')
doc = doc_path.read_text()
doc = replace_once(
    doc,
    'MedicineProductResolverV2 (Tier 1 coherent product resolver, V5 policy)',
    'MedicineProductResolverV2 (Tier 1 coherent product resolver, V6 policy)',
    'map version label',
)
performance_anchor = '## Performance model\n'
v6 = """## V6 reliability-calibrated decision authority

V5 separated normalized similarity from decision-grade evidence mass. V6 makes
that authority continuous: a clue may be good enough to retrieve/rank a product
without automatically receiving full permission to canonicalize identity.

The original `MedicineProductResolverV2` core now calibrates authority from both
agreement and parser confidence:

1. verified exact barcode/GTIN remains the separate highest-authority lock path;
2. name/brand identity, salt, strength and manufacturer keep their existing
   similarity/contradiction rules, but their decision-mass contribution is now
   multiplied by bounded evidence reliability;
3. field confidence below `0.35` contributes zero automation authority while
   remaining available for search, ranking and human review;
4. confidence above the floor increases authority smoothly rather than through a
   binary jump;
5. near-threshold fuzzy agreements receive slightly less authority than
   near-exact agreements;
6. strength/form/GS1 contradictions retain the existing hard veto behavior;
7. the existing `0.50` minimum decision-mass, winner score and runner-up margin
   gates remain in force, so reliability calibration tightens evidence quality
   without replacing the established resolver.

Example consequence:

```text
high-confidence identity + very-low-confidence salt -> rank candidate, REVIEW
high-confidence identity + high-confidence salt     -> eligible if score/margin pass
medium identity + salt + exact strength             -> eligible if combined mass passes
verified exact GTIN                                 -> exact lock path
```

This closes a specific failure mode where a low-confidence OCR field could cross
a similarity threshold and previously receive the same automation authority as a
high-confidence field.

"""
doc = replace_once(
    doc,
    performance_anchor,
    v6 + performance_anchor,
    'V6 map section',
)
doc_path.write_text(doc)
