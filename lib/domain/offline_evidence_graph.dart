import 'dart:math';

import 'medicine_understanding.dart';
import 'search.dart';

/// A bounded correlation graph over OCR frames.
///
/// Adjacent video frames are often almost the same observation. Counting each
/// frame as independent evidence makes long videos look more certain than one
/// good photograph. This graph connects near-duplicate text observations and
/// exposes one best representative per connected component. Downstream product
/// reasoning can then reward genuinely different views without rewarding frame
/// count itself.
class OfflineEvidenceGroup {
  const OfflineEvidenceGroup({
    required this.representative,
    required this.support,
    required this.maxQuality,
  });

  final MedicineFrameEvidence representative;
  final int support;
  final double maxQuality;
}

class OfflineEvidenceGraph {
  const OfflineEvidenceGraph({
    required this.groups,
    required this.observedFrames,
  });

  final List<OfflineEvidenceGroup> groups;
  final int observedFrames;

  int get independentObservations => groups.length;
  int get correlatedDuplicates => max(0, observedFrames - groups.length);

  /// Diagnostic only. This is not a probability and never authorizes writes.
  double get independenceRatio => observedFrames <= 0
      ? 0
      : (groups.length / observedFrames).clamp(0, 1).toDouble();
}

OfflineEvidenceGraph buildOfflineEvidenceGraph(
  Iterable<MedicineFrameEvidence> source, {
  int maxFrames = 12,
}) {
  final frames = source
      .take(max(1, maxFrames))
      .where((frame) => searchText(frame.text).isNotEmpty)
      .toList(growable: false);
  if (frames.isEmpty) {
    return const OfflineEvidenceGraph(
      groups: <OfflineEvidenceGroup>[],
      observedFrames: 0,
    );
  }

  final signatures = frames.map(_FrameSignature.fromFrame).toList();
  final parent = List<int>.generate(frames.length, (index) => index);

  int root(int value) {
    var node = value;
    while (parent[node] != node) {
      parent[node] = parent[parent[node]];
      node = parent[node];
    }
    return node;
  }

  void union(int left, int right) {
    final a = root(left);
    final b = root(right);
    if (a != b) parent[b] = a;
  }

  // O(n²) is intentional and bounded: at most twelve frames enter this graph.
  // It avoids maintaining another mutable index and keeps isolate behavior fully
  // deterministic.
  for (var left = 0; left < frames.length; left++) {
    for (var right = left + 1; right < frames.length; right++) {
      if (_frameCorrelation(signatures[left], signatures[right]) >= .74) {
        union(left, right);
      }
    }
  }

  final members = <int, List<int>>{};
  for (var index = 0; index < frames.length; index++) {
    members.putIfAbsent(root(index), () => <int>[]).add(index);
  }

  final groups = <OfflineEvidenceGroup>[];
  for (final indexes in members.values) {
    var best = indexes.first;
    var bestUtility = _frameUtility(frames[best], signatures[best]);
    var maxQuality = frames[best].quality.clamp(0, 1).toDouble();
    for (final index in indexes.skip(1)) {
      final quality = frames[index].quality.clamp(0, 1).toDouble();
      maxQuality = max(maxQuality, quality);
      final utility = _frameUtility(frames[index], signatures[index]);
      if (utility > bestUtility ||
          (utility == bestUtility &&
              frames[index].sequence < frames[best].sequence)) {
        best = index;
        bestUtility = utility;
      }
    }
    groups.add(
      OfflineEvidenceGroup(
        representative: frames[best],
        support: indexes.length,
        maxQuality: maxQuality,
      ),
    );
  }

  groups.sort((a, b) {
    final quality = b.maxQuality.compareTo(a.maxQuality);
    if (quality != 0) return quality;
    return a.representative.sequence.compareTo(b.representative.sequence);
  });
  return OfflineEvidenceGraph(
    groups: List<OfflineEvidenceGroup>.unmodifiable(groups),
    observedFrames: frames.length,
  );
}

class _FrameSignature {
  const _FrameSignature(this.tokens, this.trigrams, this.richness);

  factory _FrameSignature.fromFrame(MedicineFrameEvidence frame) {
    final normalized = searchText(frame.text);
    final tokens = normalized
        .split(' ')
        .where((value) => value.length >= 2)
        .take(48)
        .toSet();
    final compact = normalized.replaceAll(' ', '');
    final trigrams = <String>{};
    for (var index = 0;
        index + 3 <= compact.length && trigrams.length < 72;
        index++) {
      trigrams.add(compact.substring(index, index + 3));
    }
    final richness = (tokens.length / 24).clamp(0, 1).toDouble();
    return _FrameSignature(tokens, trigrams, richness);
  }

  final Set<String> tokens;
  final Set<String> trigrams;
  final double richness;
}

double _frameUtility(MedicineFrameEvidence frame, _FrameSignature signature) {
  final quality = frame.quality.clamp(0, 1).toDouble();
  return quality * .72 + signature.richness * .28;
}

double _frameCorrelation(_FrameSignature left, _FrameSignature right) {
  final tokenSimilarity = _jaccard(left.tokens, right.tokens);
  final trigramSimilarity = _jaccard(left.trigrams, right.trigrams);
  // Tokens are robust to spacing; trigrams recover small tokenization drift.
  return max(tokenSimilarity, trigramSimilarity * .96);
}

double _jaccard(Set<String> left, Set<String> right) {
  if (left.isEmpty || right.isEmpty) return 0;
  var intersection = 0;
  final smaller = left.length <= right.length ? left : right;
  final larger = identical(smaller, left) ? right : left;
  for (final value in smaller) {
    if (larger.contains(value)) intersection++;
  }
  if (intersection == 0) return 0;
  return intersection / (left.length + right.length - intersection);
}
