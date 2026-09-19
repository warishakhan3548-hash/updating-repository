import 'intake_resolution.dart';
import 'search.dart';

enum IntakeMatchKind { exactStock, sameMedicine, possible }

class IntakeMatchCandidate {
  const IntakeMatchCandidate({
    required this.id,
    required this.kind,
    required this.score,
  });

  final String id;
  final IntakeMatchKind kind;
  final double score;
}

/// Converts authoritative intake resolution plus fuzzy search hits into one
/// deterministic presentation order.
///
/// Exact-lot and same-product facts come only from [IntakeResolution]. A high
/// fuzzy search score can nominate a useful related row, but it can never grant
/// itself a "same medicine" badge. That semantic boundary keeps the simple UI
/// honest while allowing broad typo/OCR search underneath it.
List<IntakeMatchCandidate> rankIntakeMatches(
  IntakeResolution resolution,
  Iterable<SearchHit> hits, {
  int limit = 8,
}) {
  final boundedLimit = limit.clamp(1, 24).toInt();
  final hitById = <String, SearchHit>{};
  for (final hit in hits) {
    final current = hitById[hit.id];
    if (current == null || current.score < hit.score) hitById[hit.id] = hit;
  }

  final candidates = <String, IntakeMatchCandidate>{};
  final deterministicIds = resolution.candidateStockIds.toSet();

  for (final id in resolution.candidateStockIds) {
    final kind = resolution.kind == IntakeResolutionKind.exactLot &&
            resolution.exactStockId == id
        ? IntakeMatchKind.exactStock
        : resolution.kind == IntakeResolutionKind.sameProduct
        ? IntakeMatchKind.sameMedicine
        : IntakeMatchKind.possible;
    final witness = hitById[id];
    final floor = switch (kind) {
      IntakeMatchKind.exactStock => 1.20,
      IntakeMatchKind.sameMedicine => 1.10,
      IntakeMatchKind.possible => 1.00,
    };
    candidates[id] = IntakeMatchCandidate(
      id: id,
      kind: kind,
      score: witness == null ? floor : floor + witness.score / 100,
    );
  }

  for (final hit in hitById.values) {
    if (deterministicIds.contains(hit.id)) continue;
    candidates[hit.id] = IntakeMatchCandidate(
      id: hit.id,
      kind: IntakeMatchKind.possible,
      score: hit.score,
    );
  }

  final ranked = candidates.values.toList(growable: false)
    ..sort((a, b) {
      int priority(IntakeMatchKind kind) => switch (kind) {
        IntakeMatchKind.exactStock => 3,
        IntakeMatchKind.sameMedicine => 2,
        IntakeMatchKind.possible => 1,
      };
      final semantic = priority(b.kind).compareTo(priority(a.kind));
      if (semantic != 0) return semantic;
      final score = b.score.compareTo(a.score);
      if (score != 0) return score;
      return a.id.compareTo(b.id);
    });
  return List<IntakeMatchCandidate>.unmodifiable(
    ranked.take(boundedLimit),
  );
}
