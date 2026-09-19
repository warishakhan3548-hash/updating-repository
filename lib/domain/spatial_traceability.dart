import 'dart:math';

import 'medicine_date_parser.dart';
import 'medicine_understanding.dart';
import 'offline_evidence_graph.dart';
import 'search.dart';

class SpatialTraceabilityField {
  const SpatialTraceabilityField({
    required this.value,
    required this.confidence,
    required this.support,
    required this.conflicted,
  });

  final String value;
  final double confidence;
  final int support;
  final bool conflicted;
}

class SpatialTraceabilityHints {
  const SpatialTraceabilityHints({this.batch, this.mfg, this.expiry});

  final SpatialTraceabilityField? batch;
  final SpatialTraceabilityField? mfg;
  final SpatialTraceabilityField? expiry;

  bool get isEmpty => batch == null && mfg == null && expiry == null;
}

/// Uses OCR geometry as evidence, not as authority. Labels such as MFG/EXP/BATCH
/// are bound to nearby values inside each independently observed frame. Near-
/// duplicate video frames are collapsed by the V8 evidence graph first, so a
/// long video cannot manufacture support for one mistaken label/value pairing.
SpatialTraceabilityHints inferSpatialTraceability(
  Iterable<MedicineFrameEvidence> source,
) {
  final graph = buildOfflineEvidenceGraph(source, maxFrames: 12);
  if (graph.groups.isEmpty) return const SpatialTraceabilityHints();
  final observations = <_SpatialObservation>[];
  // The evidence graph is already hard-bounded to 12 diverse observations.
  // A second top-8 quality cut could discard a unique, deliberately captured
  // low-light EXP/BATCH side after the selector had correctly preserved it.
  for (final group in graph.groups) {
    observations.addAll(_frameObservations(group.representative));
  }
  return SpatialTraceabilityHints(
    batch: _resolveField('batchNumber', observations),
    mfg: _resolveField('mfg', observations),
    expiry: _resolveField('expiry', observations),
  );
}

enum _TraceKind { batch, mfg, expiry }

class _SpatialObservation {
  const _SpatialObservation({
    required this.field,
    required this.value,
    required this.confidence,
  });

  final String field;
  final String value;
  final double confidence;
}

class _SpatialValueCandidate {
  const _SpatialValueCandidate({
    required this.value,
    required this.start,
    required this.end,
    required this.anchor,
  });

  final String value;
  final int start;
  final int end;
  final MedicineTextLineEvidence anchor;
}

class _SpatialProposal {
  const _SpatialProposal({
    required this.labelId,
    required this.candidateId,
    required this.observation,
  });

  final int labelId;
  final String candidateId;
  final _SpatialObservation observation;
}

final _labelPattern = RegExp(
  '${medicineManufacturingLabel.pattern}|${medicineExpiryLabel.pattern}|${medicineNonDateLabel.pattern}',
  caseSensitive: false,
);

const _maxAssignedSpatialLabelsPerKind = 8;
const _maxSpatialProposalsPerLabel = 12;

List<_SpatialObservation> _frameObservations(MedicineFrameEvidence frame) {
  final lines = frame.layoutLines
      .where(
        (line) =>
            line.text.trim().isNotEmpty &&
            line.width > 0 &&
            line.height > 0 &&
            line.left.isFinite &&
            line.top.isFinite,
      )
      .take(160)
      .toList(growable: false);
  if (lines.length < 2) return const <_SpatialObservation>[];

  final result = <_SpatialObservation>[];
  final proposals = <_SpatialProposal>[];
  final quality = frame.quality.clamp(0, 1).toDouble();
  final lineHasLabel = List<bool>.generate(
    lines.length,
    (index) => _labelPattern.hasMatch(lines[index].text),
    growable: false,
  );

  // Candidate parsing is deliberately cached per physical OCR line. MFG and
  // EXP share the same date candidates, so repeatedly running the date parser
  // once per label multiplied work on label-dense packs and videos.
  final dateCandidatesByLine = <int, List<_SpatialValueCandidate>>{};
  final batchCandidatesByLine = <int, List<_SpatialValueCandidate>>{};
  for (var index = 0; index < lines.length; index++) {
    if (lineHasLabel[index]) continue;
    final line = lines[index];
    final dates = _valueCandidates(_TraceKind.mfg, line);
    if (dates.isNotEmpty) dateCandidatesByLine[index] = dates;
    final batches = _valueCandidates(_TraceKind.batch, line);
    if (batches.isNotEmpty) batchCandidatesByLine[index] = batches;
  }

  final assignedLabelsByKind = <_TraceKind, int>{};
  var nextLabelId = 0;

  for (var labelIndex = 0; labelIndex < lines.length; labelIndex++) {
    final labelLine = lines[labelIndex];
    final matches = _labelPattern.allMatches(labelLine.text).take(12).toList();
    if (matches.isEmpty) continue;
    for (var markerIndex = 0; markerIndex < matches.length; markerIndex++) {
      final match = matches[markerIndex];
      final kind = _kind(match.group(0) ?? '');
      if (kind == null) continue;
      final labelId = nextLabelId++;
      final segmentEnd = markerIndex + 1 < matches.length
          ? matches[markerIndex + 1].start
          : labelLine.text.length;
      final inline = labelLine.text.substring(match.end, segmentEnd).trim();
      final inlineValue = _extractValue(kind, inline);
      if (inlineValue.isNotEmpty) {
        result.add(
          _SpatialObservation(
            field: _field(kind),
            value: inlineValue,
            confidence: (.94 + quality * .04).clamp(0, .98).toDouble(),
          ),
        );
        continue;
      }

      // Bound only labels that actually have plausible geometry proposals.
      // Inline evidence above is never discarded by this adversarial-work cap.
      final acceptedForKind = assignedLabelsByKind[kind] ?? 0;
      if (acceptedForKind >= _maxAssignedSpatialLabelsPerKind) continue;

      // Bind geometry to the actual marker span instead of the whole OCR line.
      // ML Kit may merge "MFG     EXP" into one line; using the full box makes
      // both labels appear to occupy the same place and can swap their values.
      final labelAnchor = _sliceAnchor(
        labelLine,
        match.start,
        match.end,
        match.group(0) ?? '',
      );
      final candidatesByLine = kind == _TraceKind.batch
          ? batchCandidatesByLine
          : dateCandidatesByLine;
      final localProposals = <_SpatialProposal>[];

      for (final entry in candidatesByLine.entries) {
        final candidateIndex = entry.key;
        if (candidateIndex == labelIndex) continue;
        for (final candidate in entry.value) {
          final geometry = _geometryScore(labelAnchor, candidate.anchor);
          if (geometry < .78) continue;
          final confidence = (geometry * (.92 + quality * .08))
              .clamp(0, .95)
              .toDouble();
          localProposals.add(
            _SpatialProposal(
              labelId: labelId,
              // A printed substring is a finite piece of evidence. Do not let
              // MFG and EXP independently consume the exact same OCR token.
              candidateId:
                  '$candidateIndex:${candidate.start}:${candidate.end}',
              observation: _SpatialObservation(
                field: _field(kind),
                value: candidate.value,
                confidence: confidence,
              ),
            ),
          );
        }
      }

      if (localProposals.isEmpty) continue;
      localProposals.sort(_compareSpatialProposal);
      proposals.addAll(localProposals.take(_maxSpatialProposalsPerLabel));
      assignedLabelsByKind[kind] = acceptedForKind + 1;
    }
  }

  // Resolve all non-inline labels as a true maximum-weight one-to-one
  // assignment. A descending greedy pass can consume the locally strongest
  // token for the wrong label and force the remaining MFG/EXP label onto a
  // globally worse date. Exact bipartite assignment maximizes total geometric
  // confidence while dummy columns let weak labels abstain safely.
  for (final proposal in _selectSpatialProposals(proposals)) {
    result.add(proposal.observation);
  }

  // Repeated printing inside one image is correlated evidence, not independent
  // frame support. Keep the strongest same-value observation once per frame;
  // distinct competing values survive so the resolver can still flag conflict.
  return _collapseFrameObservations(result);
}

int _compareSpatialProposal(_SpatialProposal a, _SpatialProposal b) {
  final confidence = b.observation.confidence.compareTo(
    a.observation.confidence,
  );
  if (confidence != 0) return confidence;
  final candidate = a.candidateId.compareTo(b.candidateId);
  if (candidate != 0) return candidate;
  return a.labelId.compareTo(b.labelId);
}

List<_SpatialProposal> _selectSpatialProposals(
  List<_SpatialProposal> proposals,
) {
  if (proposals.isEmpty) return const <_SpatialProposal>[];

  final labelIds = proposals.map((value) => value.labelId).toSet().toList()
    ..sort();
  final candidateIds = proposals.map((value) => value.candidateId).toSet().toList()
    ..sort();
  if (labelIds.isEmpty || candidateIds.isEmpty) {
    return const <_SpatialProposal>[];
  }

  final labelIndex = <int, int>{
    for (var index = 0; index < labelIds.length; index++) labelIds[index]: index,
  };
  final candidateIndex = <String, int>{
    for (var index = 0; index < candidateIds.length; index++)
      candidateIds[index]: index,
  };
  final bestByPair = <(int, String), _SpatialProposal>{};
  for (final proposal in proposals) {
    final key = (proposal.labelId, proposal.candidateId);
    final current = bestByPair[key];
    if (current == null ||
        proposal.observation.confidence > current.observation.confidence) {
      bestByPair[key] = proposal;
    }
  }

  final rowCount = labelIds.length;
  final realColumnCount = candidateIds.length;
  // One dummy column per label guarantees columns >= rows and gives every label
  // a zero-score abstention path without stealing a real OCR token.
  final columnCount = realColumnCount + rowCount;
  final weights = List<List<double>>.generate(
    rowCount,
    (_) => List<double>.filled(columnCount, 0),
    growable: false,
  );
  for (final proposal in bestByPair.values) {
    final row = labelIndex[proposal.labelId];
    final column = candidateIndex[proposal.candidateId];
    if (row == null || column == null) continue;
    weights[row][column] = proposal.observation.confidence;
  }

  // Hungarian algorithm, expressed as minimum cost where cost = 1 - weight.
  // With the hard bounds above this is small (<=24 label rows) and deterministic.
  final u = List<double>.filled(rowCount + 1, 0);
  final v = List<double>.filled(columnCount + 1, 0);
  final matching = List<int>.filled(columnCount + 1, 0);
  final way = List<int>.filled(columnCount + 1, 0);
  const epsilon = 1e-12;

  for (var row = 1; row <= rowCount; row++) {
    matching[0] = row;
    var column0 = 0;
    final minimum = List<double>.filled(
      columnCount + 1,
      double.infinity,
    );
    final used = List<bool>.filled(columnCount + 1, false);

    do {
      used[column0] = true;
      final row0 = matching[column0];
      var delta = double.infinity;
      var column1 = 0;
      for (var column = 1; column <= columnCount; column++) {
        if (used[column]) continue;
        final cost = 1 - weights[row0 - 1][column - 1];
        final reduced = cost - u[row0] - v[column];
        if (reduced < minimum[column] - epsilon) {
          minimum[column] = reduced;
          way[column] = column0;
        }
        if (minimum[column] < delta - epsilon ||
            ((minimum[column] - delta).abs() <= epsilon &&
                (column1 == 0 || column < column1))) {
          delta = minimum[column];
          column1 = column;
        }
      }

      for (var column = 0; column <= columnCount; column++) {
        if (used[column]) {
          u[matching[column]] += delta;
          v[column] -= delta;
        } else if (column > 0) {
          minimum[column] -= delta;
        }
      }
      column0 = column1;
    } while (matching[column0] != 0);

    do {
      final column1 = way[column0];
      matching[column0] = matching[column1];
      column0 = column1;
    } while (column0 != 0);
  }

  final selected = <_SpatialProposal>[];
  for (var column = 1; column <= realColumnCount; column++) {
    final row = matching[column];
    if (row == 0) continue;
    final proposal = bestByPair[(labelIds[row - 1], candidateIds[column - 1])];
    if (proposal != null) selected.add(proposal);
  }
  selected.sort((a, b) {
    final label = a.labelId.compareTo(b.labelId);
    return label != 0 ? label : _compareSpatialProposal(a, b);
  });
  return selected;
}

List<_SpatialObservation> _collapseFrameObservations(
  List<_SpatialObservation> observations,
) {
  if (observations.length < 2) return observations;
  final best = <(String, String), _SpatialObservation>{};
  for (final observation in observations) {
    final valueKey = observation.field == 'batchNumber'
        ? searchText(observation.value)
        : observation.value.trim().toLowerCase();
    if (valueKey.isEmpty) continue;
    final key = (observation.field, valueKey);
    final current = best[key];
    if (current == null || observation.confidence > current.confidence) {
      best[key] = observation;
    }
  }
  final collapsed = best.values.toList(growable: false)
    ..sort((a, b) {
      final field = a.field.compareTo(b.field);
      if (field != 0) return field;
      return a.value.compareTo(b.value);
    });
  return collapsed;
}

_TraceKind? _kind(String raw) {
  if (medicineManufacturingLabel.hasMatch(raw)) return _TraceKind.mfg;
  if (medicineExpiryLabel.hasMatch(raw)) return _TraceKind.expiry;
  final key = searchText(raw).replaceAll(' ', '');
  if (key.startsWith('batch') || key == 'bno' || key.startsWith('lot')) {
    return _TraceKind.batch;
  }
  return null;
}

String _field(_TraceKind kind) => switch (kind) {
  _TraceKind.batch => 'batchNumber',
  _TraceKind.mfg => 'mfg',
  _TraceKind.expiry => 'expiry',
};

String _extractValue(_TraceKind kind, String text) => switch (kind) {
  _TraceKind.batch => _extractBatch(text),
  _TraceKind.mfg || _TraceKind.expiry => _extractDate(text),
};

List<_SpatialValueCandidate> _valueCandidates(
  _TraceKind kind,
  MedicineTextLineEvidence line,
) {
  if (kind == _TraceKind.batch) {
    final match = RegExp(
      r'[A-Za-z0-9][A-Za-z0-9._/-]{2,19}',
    ).firstMatch(line.text);
    if (match == null) return const <_SpatialValueCandidate>[];
    final value = match.group(0) ?? '';
    if (!_isSafeBatchValue(value)) return const <_SpatialValueCandidate>[];
    return <_SpatialValueCandidate>[
      _SpatialValueCandidate(
        value: value,
        start: match.start,
        end: match.end,
        anchor: _sliceAnchor(line, match.start, match.end, value),
      ),
    ];
  }

  final matches = extractMedicineDateMatches(
    line.text,
    allowCompact: true,
  ).take(6);
  return matches
      .map(
        (match) => _SpatialValueCandidate(
          value: match.date.value,
          start: match.start,
          end: match.end,
          anchor: _sliceAnchor(
            line,
            match.start,
            match.end,
            line.text.substring(match.start, match.end),
          ),
        ),
      )
      .toList(growable: false);
}

MedicineTextLineEvidence _sliceAnchor(
  MedicineTextLineEvidence line,
  int start,
  int end,
  String text,
) {
  final length = max(1, line.text.length);
  final boundedStart = start.clamp(0, length).toInt();
  final boundedEnd = end.clamp(boundedStart, length).toInt();
  final leftRatio = boundedStart / length;
  final widthRatio = max(1, boundedEnd - boundedStart) / length;
  return MedicineTextLineEvidence(
    text: text,
    left: line.left + line.width * leftRatio,
    top: line.top,
    width: max(.5, line.width * widthRatio),
    height: line.height,
  );
}

String _extractBatch(String raw) {
  var value = raw
      .replaceAll(
        RegExp(r'\b(?:batch|no|number|b\s*no|lot)\b', caseSensitive: false),
        ' ',
      )
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (value.isEmpty) return '';
  final match = RegExp(r'[A-Za-z0-9][A-Za-z0-9._/-]{2,19}').firstMatch(value);
  if (match == null) return '';
  value = match.group(0) ?? '';
  return _isSafeBatchValue(value) ? value : '';
}

bool _isSafeBatchValue(String value) {
  if (!RegExp(r'\d').hasMatch(value)) return false;
  if (RegExp(r'^\d{1,2}[-/.]\d{2,4}$').hasMatch(value) ||
      RegExp(r'^\d{1,2}[-/.]\d{1,2}[-/.]\d{2,4}$').hasMatch(value)) {
    return false;
  }
  return true;
}

String _extractDate(String raw) {
  final parsed = parseMedicineDateText(raw);
  return parsed?.value ?? '';
}

double _geometryScore(
  MedicineTextLineEvidence label,
  MedicineTextLineEvidence candidate,
) {
  final labelCenterY = label.top + label.height / 2;
  final candidateCenterY = candidate.top + candidate.height / 2;
  final height = max(1.0, max(label.height, candidate.height));
  final vertical = (labelCenterY - candidateCenterY).abs() / height;
  final labelRight = label.left + label.width;
  final candidateRight = candidate.left + candidate.width;
  final labelCenterX = label.left + label.width / 2;
  final candidateCenterX = candidate.left + candidate.width / 2;

  // Same-row value to the right of the label is the strongest geometric cue.
  if (vertical <= .72 && candidateCenterX >= labelCenterX - height * .25) {
    final gap = max(0.0, candidate.left - labelRight) / height;
    return (.95 - min(.13, gap * .025)).clamp(0, 1).toDouble();
  }

  // Reverse same-row layouts ("04/2028  EXP") are common on narrow blister
  // strips. They are useful, but slightly weaker than conventional label→value.
  if (vertical <= .72 && candidateCenterX < labelCenterX) {
    final reverseGap = max(0.0, label.left - candidateRight) / height;
    if (reverseGap <= 4.8) {
      return (.89 - min(.10, reverseGap * .02)).clamp(0, 1).toDouble();
    }
  }

  final horizontalOverlap =
      max(
        0.0,
        min(labelRight, candidateRight) - max(label.left, candidate.left),
      ) /
      max(1.0, min(label.width, candidate.width));
  final centerDelta = (labelCenterX - candidateCenterX).abs() / height;
  final aligned = horizontalOverlap >= .12 || centerDelta <= 1.8;
  final belowGap = (candidate.top - (label.top + label.height)) / height;
  if (belowGap >= -.25 && belowGap <= 2.6 && aligned) {
    return (.88 - max(0.0, belowGap) * .035 - min(.04, centerDelta * .01))
        .clamp(0, 1)
        .toDouble();
  }

  // Some packs print the value directly above a compact MFG/EXP label. Treat
  // this reverse vertical layout as valid geometric evidence, but slightly
  // weaker than the conventional below-label layout so nearby unrelated dates
  // cannot outrank a normal same-row/below association.
  final aboveGap = (label.top - (candidate.top + candidate.height)) / height;
  if (aboveGap >= -.25 && aboveGap <= 2.1 && aligned) {
    return (.86 - max(0.0, aboveGap) * .035 - min(.04, centerDelta * .01))
        .clamp(0, 1)
        .toDouble();
  }
  return 0;
}

SpatialTraceabilityField? _resolveField(
  String field,
  List<_SpatialObservation> observations,
) {
  final relevant = observations.where((value) => value.field == field).toList();
  if (relevant.isEmpty) return null;
  final groups = <String, List<_SpatialObservation>>{};
  for (final item in relevant) {
    final key = field == 'batchNumber' ? searchText(item.value) : item.value;
    if (key.isEmpty) continue;
    groups.putIfAbsent(key, () => <_SpatialObservation>[]).add(item);
  }
  if (groups.isEmpty) return null;

  final ranked =
      groups.entries.map((entry) {
        final maxConfidence = entry.value
            .map((value) => value.confidence)
            .reduce(max);
        final support = entry.value.length;
        final score = (maxConfidence + min(.06, (support - 1) * .025))
            .clamp(0, .98)
            .toDouble();
        return (entry.value.first.value, score, support, maxConfidence);
      }).toList()..sort((a, b) {
        final score = b.$2.compareTo(a.$2);
        if (score != 0) return score;
        final support = b.$3.compareTo(a.$3);
        return support != 0 ? support : a.$1.compareTo(b.$1);
      });
  final best = ranked.first;
  if (best.$2 < .80) return null;
  final conflict =
      ranked.length > 1 && ranked[1].$4 >= .84 && best.$2 - ranked[1].$2 < .09;
  return SpatialTraceabilityField(
    value: best.$1,
    confidence: conflict ? min(best.$2, .82) : best.$2,
    support: best.$3,
    conflicted: conflict,
  );
}
