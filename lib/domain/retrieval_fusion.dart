/// Pure, bounded ranking primitives for the always-available offline engine.
///
/// These helpers deliberately operate on IDs and corpus document frequencies
/// only. They do not know about inventory, medicine safety, UI state, cloud AI,
/// or local LLMs. Product safety and canonicalization remain the responsibility
/// of the downstream medicine resolver.
class RankedRetrievalChannel {
  const RankedRetrievalChannel({required this.ids, this.weight = 1.0});

  final List<String> ids;
  final double weight;
}

/// Selects exact-index terms with the highest information value first.
///
/// `documentFrequency` is the number of active verified catalogue products that
/// contain a term. Rare identity terms therefore win over ubiquitous packaging
/// words. Terms absent from the exact index are intentionally excluded here;
/// they remain valuable to [selectRecoveryTerms] as possible OCR corruption.
List<String> selectInformationRichTerms(
  Iterable<String> terms,
  Map<String, int> documentFrequency, {
  int limit = 20,
}) {
  if (limit <= 0) return const <String>[];
  final unique = <String>[];
  final seen = <String>{};
  for (final raw in terms) {
    final term = raw.trim();
    if (term.isEmpty || !seen.add(term)) continue;
    if ((documentFrequency[term] ?? 0) > 0) unique.add(term);
  }

  final originalOrder = <String, int>{
    for (var index = 0; index < unique.length; index++) unique[index]: index,
  };
  unique.sort((a, b) {
    final frequency = (documentFrequency[a] ?? 0).compareTo(
      documentFrequency[b] ?? 0,
    );
    if (frequency != 0) return frequency;
    final length = b.length.compareTo(a.length);
    if (length != 0) return length;
    return (originalOrder[a] ?? 0).compareTo(originalOrder[b] ?? 0);
  });
  return List<String>.unmodifiable(unique.take(limit));
}

/// Plans typo/OCR recovery terms without letting common words monopolize work.
///
/// Unknown exact terms are tried first because they are the strongest signal of
/// a one-character OCR mutation. Known terms then follow from rarest to most
/// common. The result remains bounded before delete-neighbour expansion.
List<String> selectRecoveryTerms(
  Iterable<String> terms,
  Map<String, int> documentFrequency, {
  int limit = 18,
}) {
  if (limit <= 0) return const <String>[];
  final unique = <String>[];
  final seen = <String>{};
  for (final raw in terms) {
    final term = raw.trim();
    if (term.length < 4 || term.length > 28 || !seen.add(term)) continue;
    unique.add(term);
  }

  final originalOrder = <String, int>{
    for (var index = 0; index < unique.length; index++) unique[index]: index,
  };
  unique.sort((a, b) {
    final aFrequency = documentFrequency[a] ?? 0;
    final bFrequency = documentFrequency[b] ?? 0;
    final aUnknown = aFrequency == 0;
    final bUnknown = bFrequency == 0;
    if (aUnknown != bUnknown) return aUnknown ? -1 : 1;
    if (!aUnknown) {
      final frequency = aFrequency.compareTo(bFrequency);
      if (frequency != 0) return frequency;
    }
    final length = b.length.compareTo(a.length);
    if (length != 0) return length;
    return (originalOrder[a] ?? 0).compareTo(originalOrder[b] ?? 0);
  });
  return List<String>.unmodifiable(unique.take(limit));
}

/// Reciprocal-rank fusion for heterogeneous bounded retrievers.
///
/// RRF depends on rank rather than incomparable raw score scales, so exact-term
/// retrieval and delete-neighbour recovery can corroborate one another without
/// one channel winning merely because its numeric scoring range is larger.
/// Duplicate IDs inside one channel contribute only once.
Map<String, double> reciprocalRankFuse(
  Iterable<RankedRetrievalChannel> channels, {
  double rankConstant = 60.0,
}) {
  if (!rankConstant.isFinite || rankConstant < 1) {
    throw ArgumentError.value(rankConstant, 'rankConstant', 'must be >= 1');
  }
  final fused = <String, double>{};
  for (final channel in channels) {
    if (!channel.weight.isFinite || channel.weight <= 0) continue;
    final seen = <String>{};
    var rank = 0;
    for (final rawId in channel.ids) {
      final id = rawId.trim();
      if (id.isEmpty || !seen.add(id)) continue;
      rank++;
      final contribution = channel.weight / (rankConstant + rank);
      fused.update(
        id,
        (value) => value + contribution,
        ifAbsent: () => contribution,
      );
    }
  }
  return Map<String, double>.unmodifiable(fused);
}
