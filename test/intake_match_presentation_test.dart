import 'package:flutter_test/flutter_test.dart';

import '../lib/domain/intake_match_presentation.dart';
import '../lib/domain/intake_resolution.dart';
import '../lib/domain/search.dart';

void main() {
  test('exact stock stays authoritative above stronger fuzzy hits', () {
    const resolution = IntakeResolution(
      kind: IntakeResolutionKind.exactLot,
      candidateStockIds: ['exact'],
      exactStockId: 'exact',
      reason: 'exact',
    );
    final ranked = rankIntakeMatches(resolution, const [
      SearchHit('similar', .99, 'fuzzy', 'q'),
      SearchHit('exact', .80, 'identity', 'q'),
    ]);

    expect(ranked.first.id, 'exact');
    expect(ranked.first.kind, IntakeMatchKind.exactStock);
    expect(ranked[1].id, 'similar');
    expect(ranked[1].kind, IntakeMatchKind.possible);
  });

  test('same-product rows are ranked by search witness but keep semantics', () {
    const resolution = IntakeResolution(
      kind: IntakeResolutionKind.sameProduct,
      candidateStockIds: ['batch-a', 'batch-b'],
      reason: 'same product',
    );
    final ranked = rankIntakeMatches(resolution, const [
      SearchHit('batch-a', .82, 'match', 'q'),
      SearchHit('batch-b', .96, 'match', 'q'),
    ]);

    expect(ranked.map((item) => item.id), ['batch-b', 'batch-a']);
    expect(
      ranked.every((item) => item.kind == IntakeMatchKind.sameMedicine),
      isTrue,
    );
  });

  test('high fuzzy score can never promote itself to same medicine', () {
    const resolution = IntakeResolution(
      kind: IntakeResolutionKind.newStock,
      candidateStockIds: [],
      reason: 'new',
    );
    final ranked = rankIntakeMatches(resolution, const [
      SearchHit('lookalike', 1, 'Exact OCR keyword', 'q'),
    ]);

    expect(ranked.single.kind, IntakeMatchKind.possible);
  });

  test('ambiguous deterministic candidates remain possible, not confirmed', () {
    const resolution = IntakeResolution(
      kind: IntakeResolutionKind.ambiguous,
      candidateStockIds: ['one', 'two'],
      reason: 'ambiguous',
    );
    final ranked = rankIntakeMatches(resolution, const []);

    expect(ranked.length, 2);
    expect(
      ranked.every((item) => item.kind == IntakeMatchKind.possible),
      isTrue,
    );
  });
}
