from pathlib import Path


def replace_once(path: Path, old: str, new: str) -> None:
    text = path.read_text()
    count = text.count(old)
    if count != 1:
        raise SystemExit(f'{path}: expected exactly one patch anchor, found {count}')
    path.write_text(text.replace(old, new, 1))


resolver = Path('lib/domain/medicine_resolution_v2.dart')
replace_once(
    resolver,
    """  final exactBarcode =
      observedBarcodes.isNotEmpty &&
      productBarcodes.isNotEmpty &&
      observedBarcodes.intersection(productBarcodes).isNotEmpty;
  if (exactBarcode) {
    weighted += .995 * .52;
    totalWeight += .52;
    exactIdentifierMass = .52;
    channels++;
  } else {
    // Only verified retail/GTIN identifiers can veto a product. Packs may also
    // contain numeric proprietary Code-128 payloads in standard-looking lengths;
    // those remain exact-match evidence but are not allowed to become hard GTIN
    // contradictions unless the existing GS1 kernel validates the check digit.
    final observedStrong = observedBarcodes
        .where(_isStrongProductBarcodeKey)
        .toSet();
    final productStrong = productBarcodes
        .where(_isStrongProductBarcodeKey)
        .toSet();
    if (observedStrong.isNotEmpty && productStrong.isNotEmpty) {
      hardConflicts++;
    }
  }
""",
    """  final exactBarcode =
      observedBarcodes.isNotEmpty &&
      productBarcodes.isNotEmpty &&
      observedBarcodes.intersection(productBarcodes).isNotEmpty;
  // Compute strong retail identifiers even on the exact-match path. A video
  // cluster can accidentally contain two products; one matching GTIN must not
  // hide a second contradictory valid GTIN from another pack.
  final observedStrong = observedBarcodes
      .where(_isStrongProductBarcodeKey)
      .toSet();
  final productStrong = productBarcodes
      .where(_isStrongProductBarcodeKey)
      .toSet();
  if (exactBarcode) {
    weighted += .995 * .52;
    totalWeight += .52;
    exactIdentifierMass = .52;
    channels++;
    if (productStrong.isNotEmpty &&
        observedStrong.difference(productStrong).isNotEmpty) {
      hardConflicts++;
    }
  } else {
    // Only verified retail/GTIN identifiers can veto a product. Packs may also
    // contain numeric proprietary Code-128 payloads in standard-looking lengths;
    // those remain exact-match evidence but are not allowed to become hard GTIN
    // contradictions unless the existing GS1 kernel validates the check digit.
    if (observedStrong.isNotEmpty && productStrong.isNotEmpty) {
      hardConflicts++;
    }
  }
""",
)

test_path = Path('test/medicine_resolution_v2_test.dart')
text = test_path.read_text()
anchor = "  });\n}\n"
if not text.endswith(anchor):
    raise SystemExit(f'{test_path}: unexpected group terminator')
case = r'''

    test('second valid GTIN blocks an otherwise exact barcode auto-lock', () {
      const product = CanonicalMedicineProduct(
        productId: 'in:dolo:650:multi-gtin-guard',
        revision: 604,
        name: 'Dolo',
        brand: 'Dolo',
        salt: 'Paracetamol',
        strength: '650 mg',
        form: 'Tablet',
        barcodes: <String>['8902222222227'],
        verified: true,
      );
      final result = MedicineProductResolverV2(
        localKnowledge: const <MedicineKnowledgeEntry>[],
        catalogue: const <CanonicalMedicineProduct>[product],
      ).reconcile(
        MedicineUnderstandingResult(
          drafts: <MedicineScanDraft>[
            _doloDraft(barcode: '8902222222227'),
          ],
        ),
        const <MedicineFrameEvidence>[
          MedicineFrameEvidence(
            sequence: 0,
            barcode: '8902222222227',
            barcodes: <String>['8901111111116'],
            text: 'DOLO 650\nParacetamol Tablets IP 650 mg',
          ),
        ],
      );

      final draft = result.drafts.single;
      expect(draft.overallConfidence, lessThan(.78));
      expect(scanQuickAddDecision(draft, _newStock).allowed, isFalse);
    });
'''
test_path.write_text(text[:-len(anchor)] + case + '\n' + anchor)

print('V6 multi-GTIN contradiction guard applied.')
