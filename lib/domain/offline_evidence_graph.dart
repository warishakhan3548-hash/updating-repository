import 'dart:math';

import 'medicine_machine_code_safety.dart';
import 'medicine_understanding.dart';
import 'regulatory_medicine_code.dart';
import 'search.dart';

/// A bounded correlation graph over OCR/barcode frames.
///
/// Adjacent video frames are often almost the same observation. Counting each
/// frame as independent evidence makes long videos look more certain than one
/// good photograph. This graph connects near-duplicate observations and exposes
/// one best representative per connected component. Machine-readable medicine
/// identifiers are first-class evidence, but a shared GTIN proves only product
/// identity — not that two different pack sides are the same visual observation.
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

/// Selects a small, information-rich evidence window before correlation.
///
/// The old first-N policy could let repeated live-preview frames consume the
/// entire graph budget before a later deliberate photo of COMPOSITION/BATCH/EXP
/// arrived. Selection now considers the whole already-bounded intake evidence
/// (at most [maxMedicineEvidenceFrames]) and preserves recency, machine anchors,
/// physical capture utility and visual-text novelty. It never invents facts,
/// rewrites OCR or turns similarity into confidence; it only decides which raw
/// observations deserve the finite downstream reasoning budget.
List<MedicineFrameEvidence> selectOfflineEvidenceFrames(
  Iterable<MedicineFrameEvidence> source, {
  required int maxFrames,
}) {
  final limit = max(1, maxFrames);
  final pool = source
      .where(_hasGraphEvidence)
      .take(maxMedicineEvidenceFrames)
      .toList(growable: false);
  if (pool.length <= limit) {
    return List<MedicineFrameEvidence>.unmodifiable(pool);
  }

  final signatures = pool.map(_FrameSignature.fromFrame).toList(growable: false);
  final selected = <int>{};

  void keep(int index) {
    if (index >= 0 && index < pool.length && selected.length < limit) {
      selected.add(index);
    }
  }

  // Always keep the newest usable observation. In live scanning this is the
  // frame/still the pharmacist just presented after receiving targeted guidance.
  keep(pool.length - 1);

  // Keep one strong witness for each bounded machine-readable identity/lot/date
  // anchor. This prevents an early run of repeated OCR frames from hiding a
  // later conflicting GTIN/lot/serial/MFG/EXP, which must remain visible to
  // fail-closed product and physical-lot reasoning.
  final anchorRepresentatives = <String, int>{};
  for (var index = 0; index < pool.length; index++) {
    final machine = signatures[index].machine;
    final key = machine.fingerprint;
    if (key.isEmpty) continue;
    final existing = anchorRepresentatives[key];
    final utility = _selectionBaseUtility(pool[index], signatures[index]);
    final existingUtility = existing == null
        ? -1.0
        : _selectionBaseUtility(pool[existing], signatures[existing]);
    if (existing == null ||
        utility > existingUtility ||
        (utility == existingUtility && index > existing)) {
      anchorRepresentatives[key] = index;
    }
  }
  final machineWitnesses = anchorRepresentatives.values.toList(growable: false)
    ..sort((a, b) {
      final utility = _selectionBaseUtility(
        pool[b],
        signatures[b],
      ).compareTo(_selectionBaseUtility(pool[a], signatures[a]));
      if (utility != 0) return utility;
      return b.compareTo(a);
    });
  // More than four distinct machine anchors inside one bounded medicine window
  // is already abnormal; four witnesses preserve a contradiction without
  // allowing barcode-heavy noise to monopolize every OCR slot.
  for (final index in machineWitnesses.take(min(4, limit))) {
    keep(index);
  }

  // Preserve the strongest ordinary frame as an anchor for identity continuity.
  var bestOverall = 0;
  var bestOverallUtility = _selectionBaseUtility(pool[0], signatures[0]);
  for (var index = 1; index < pool.length; index++) {
    final utility = _selectionBaseUtility(pool[index], signatures[index]);
    if (utility > bestOverallUtility ||
        (utility == bestOverallUtility && index > bestOverall)) {
      bestOverall = index;
      bestOverallUtility = utility;
    }
  }
  keep(bestOverall);

  while (selected.length < limit) {
    var bestIndex = -1;
    var bestScore = -double.infinity;
    for (var index = 0; index < pool.length; index++) {
      if (selected.contains(index)) continue;
      final base = _selectionBaseUtility(pool[index], signatures[index]);

      var maxCorrelation = 0.0;
      var nearestDistance = pool.length.toDouble();
      for (final kept in selected) {
        maxCorrelation = max(
          maxCorrelation,
          _frameCorrelation(signatures[index], signatures[kept]),
        );
        nearestDistance = min(nearestDistance, (index - kept).abs().toDouble());
      }
      final novelty = (1 - maxCorrelation).clamp(0, 1).toDouble();
      final temporalDiversity = (nearestDistance / max(1, pool.length - 1))
          .clamp(0, 1)
          .toDouble();
      final recency = index / max(1, pool.length - 1);

      // Novelty deliberately outranks raw sharpness here. A slightly softer
      // back-panel frame with the missing EXP/batch is usually more informative
      // than the twelfth crystal-clear copy of the same front panel.
      final score =
          base * .35 + novelty * .45 + temporalDiversity * .12 + recency * .08;
      if (score > bestScore ||
          (score == bestScore && index > bestIndex)) {
        bestIndex = index;
        bestScore = score;
      }
    }
    if (bestIndex < 0) break;
    keep(bestIndex);
  }

  final ordered = selected.toList(growable: false)..sort();
  return List<MedicineFrameEvidence>.unmodifiable(
    ordered.map((index) => pool[index]),
  );
}

OfflineEvidenceGraph buildOfflineEvidenceGraph(
  Iterable<MedicineFrameEvidence> source, {
  int maxFrames = 12,
}) {
  final frames = selectOfflineEvidenceFrames(source, maxFrames: maxFrames);
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

  // Preserve the long-standing .74 near-duplicate calibration for OCR text.
  // Machine-readable conflicts are handled inside _frameCorrelation and return
  // zero before this threshold can merge different products or physical lots.
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

bool _hasGraphEvidence(MedicineFrameEvidence frame) =>
    _frameSearchCorpus(frame).isNotEmpty || frame.allBarcodes.isNotEmpty;

/// Raw OCR text is normally authoritative, but ML Kit can occasionally retain
/// valid bounded line geometry after a merged text stream is empty. Treat those
/// lines as evidence rather than silently deleting the entire observation. This
/// fallback is used only for graph selection/correlation; it never rewrites the
/// persisted OCR payload or manufactures field values.
String _frameSearchCorpus(MedicineFrameEvidence frame) {
  final raw = frame.text.trim();
  if (raw.isNotEmpty) return raw;
  final parts = <String>[];
  var total = 0;
  for (final line in frame.layoutLines.take(160)) {
    final clean = line.text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (clean.isEmpty) continue;
    if (total + clean.length > 12000) break;
    parts.add(clean);
    total += clean.length + 1;
  }
  return parts.join('\n');
}

class _FrameSignature {
  const _FrameSignature(
    this.tokens,
    this.trigrams,
    this.richness,
    this.machine,
  );

  factory _FrameSignature.fromFrame(MedicineFrameEvidence frame) {
    final normalized = searchText(_frameSearchCorpus(frame));
    final tokens = normalized
        .split(' ')
        .where((value) => value.length >= 2)
        .take(48)
        .toSet();
    final compact = normalized.replaceAll(' ', '');
    final trigrams = <String>{};
    for (
      var index = 0;
      index + 3 <= compact.length && trigrams.length < 72;
      index++
    ) {
      trigrams.add(compact.substring(index, index + 3));
    }
    final richness = (tokens.length / 24).clamp(0, 1).toDouble();
    return _FrameSignature(
      tokens,
      trigrams,
      richness,
      _MachineAnchor.fromFrame(frame),
    );
  }

  final Set<String> tokens;
  final Set<String> trigrams;
  final double richness;
  final _MachineAnchor machine;

  bool get hasText => tokens.isNotEmpty || trigrams.isNotEmpty;
}

class _MachineAnchor {
  const _MachineAnchor({
    required this.gtins,
    required this.lots,
    required this.serials,
    required this.manufacturingDates,
    required this.expiryDates,
    required this.ambiguousProductIds,
  });

  factory _MachineAnchor.fromFrame(MedicineFrameEvidence frame) {
    final assessment = assessMedicineMachineCodes(frame.allBarcodes);
    final gtins = assessment.trustedProductKeys.toSet();
    final lots = <String>{};
    final serials = <String>{};
    final manufacturingDates = <String>{};
    final expiryDates = <String>{};
    for (final raw in frame.allBarcodes.take(8)) {
      final structured = parseRegulatoryMedicineCode(raw);
      if (structured == null) continue;
      final lot = searchText(structured.batchLot);
      if (lot.isNotEmpty) lots.add(lot);
      final serial = searchText(structured.serial);
      if (serial.isNotEmpty) serials.add(serial);
      if (structured.manufacturingYyMmDd.isNotEmpty) {
        manufacturingDates.add(structured.manufacturingYyMmDd);
      }
      if (structured.expiryYyMmDd.isNotEmpty) {
        expiryDates.add(structured.expiryYyMmDd);
      }
    }
    return _MachineAnchor(
      gtins: gtins,
      lots: lots,
      serials: serials,
      manufacturingDates: manufacturingDates,
      expiryDates: expiryDates,
      ambiguousProductIds: assessment.ambiguous,
    );
  }

  final Set<String> gtins;
  final Set<String> lots;
  final Set<String> serials;
  final Set<String> manufacturingDates;
  final Set<String> expiryDates;
  final bool ambiguousProductIds;

  bool get hasTrustedProductId => !ambiguousProductIds && gtins.length == 1;

  String get fingerprint {
    if (gtins.isEmpty &&
        lots.isEmpty &&
        serials.isEmpty &&
        manufacturingDates.isEmpty &&
        expiryDates.isEmpty) {
      return '';
    }
    String ordered(Set<String> values) => (values.toList()..sort()).join(',');
    return '${ambiguousProductIds ? 'ambiguous' : 'single'}|'
        '${ordered(gtins)}|${ordered(lots)}|${ordered(serials)}|'
        '${ordered(manufacturingDates)}|${ordered(expiryDates)}';
  }
}

double _selectionBaseUtility(
  MedicineFrameEvidence frame,
  _FrameSignature signature,
) => _frameUtility(frame, signature);

double _frameUtility(MedicineFrameEvidence frame, _FrameSignature signature) {
  final quality = frame.quality.clamp(0, 1).toDouble();
  final machineBonus = signature.machine.hasTrustedProductId ? .10 : 0.0;
  return (quality * .60 + signature.richness * .30 + machineBonus)
      .clamp(0, 1)
      .toDouble();
}

double _frameCorrelation(_FrameSignature left, _FrameSignature right) {
  final leftMachine = left.machine;
  final rightMachine = right.machine;

  if (leftMachine.gtins.isNotEmpty && rightMachine.gtins.isNotEmpty) {
    // An ambiguous multi-product observation must never correlate with one
    // singleton product merely because their GTIN sets overlap. If both frames
    // are ambiguous, only an identical product-key set may proceed to ordinary
    // visual similarity; ambiguity itself is never treated as identity proof.
    if (leftMachine.ambiguousProductIds || rightMachine.ambiguousProductIds) {
      if (!_sameSet(leftMachine.gtins, rightMachine.gtins)) return 0;
    } else if (leftMachine.gtins.intersection(rightMachine.gtins).isEmpty) {
      return 0;
    }

    // A shared product may still be a different physical lot/serial/date. GS1
    // production identifiers are physical-pack evidence, so any explicit clash
    // must remain independent instead of being hidden by near-identical artwork.
    if (_explicitAnchorConflict(leftMachine.lots, rightMachine.lots) ||
        _explicitAnchorConflict(leftMachine.serials, rightMachine.serials) ||
        _explicitAnchorConflict(
          leftMachine.manufacturingDates,
          rightMachine.manufacturingDates,
        ) ||
        _explicitAnchorConflict(leftMachine.expiryDates, rightMachine.expiryDates)) {
      return 0;
    }
  }

  final tokenSimilarity = _jaccard(left.tokens, right.tokens);
  final trigramSimilarity = _jaccard(left.trigrams, right.trigrams);
  final visualTextSimilarity = max(tokenSimilarity, trigramSimilarity * .96);

  if (leftMachine.hasTrustedProductId && rightMachine.hasTrustedProductId) {
    // Same unambiguous GTIN plus no OCR on either frame is a repeated barcode
    // observation. Ambiguous multi-product frames never enter this authority path.
    if (!left.hasText && !right.hasText) return .99;
    // Same GTIN is not sufficient to collapse front/back complementary views.
    // It only strengthens an already-similar visual observation.
    if (visualTextSimilarity >= .52) {
      return max(.90, visualTextSimilarity);
    }
  }
  return visualTextSimilarity;
}

bool _sameSet(Set<String> left, Set<String> right) =>
    left.length == right.length && left.containsAll(right);

bool _explicitAnchorConflict(Set<String> left, Set<String> right) =>
    left.isNotEmpty && right.isNotEmpty && left.intersection(right).isEmpty;

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
