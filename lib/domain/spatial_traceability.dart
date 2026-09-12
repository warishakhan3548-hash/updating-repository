import 'dart:math';

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
  for (final group in graph.groups.take(8)) {
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

final _labelPattern = RegExp(
  r'\b(batch(?:\s*(?:no|number))?|b\s*no|lot(?:\s*no)?|mfg|mfd|manufacturing(?:\s*date)?|exp|expiry|expires|expiration(?:\s*date)?)\b',
  caseSensitive: false,
);

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
  final quality = frame.quality.clamp(0, 1).toDouble();
  for (var labelIndex = 0; labelIndex < lines.length; labelIndex++) {
    final labelLine = lines[labelIndex];
    final matches = _labelPattern.allMatches(labelLine.text).toList();
    if (matches.isEmpty) continue;
    for (var markerIndex = 0; markerIndex < matches.length; markerIndex++) {
      final match = matches[markerIndex];
      final kind = _kind(match.group(1) ?? '');
      if (kind == null) continue;
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

      _SpatialObservation? best;
      for (var candidateIndex = 0;
          candidateIndex < lines.length;
          candidateIndex++) {
        if (candidateIndex == labelIndex) continue;
        final candidate = lines[candidateIndex];
        if (_labelPattern.hasMatch(candidate.text)) continue;
        final value = _extractValue(kind, candidate.text);
        if (value.isEmpty) continue;
        final geometry = _geometryScore(labelLine, candidate);
        if (geometry < .78) continue;
        final confidence = (geometry * (.92 + quality * .08))
            .clamp(0, .95)
            .toDouble();
        final observation = _SpatialObservation(
          field: _field(kind),
          value: value,
          confidence: confidence,
        );
        if (best == null || observation.confidence > best.confidence) {
          best = observation;
        }
      }
      if (best != null) result.add(best);
    }
  }
  return result;
}

_TraceKind? _kind(String raw) {
  final key = searchText(raw).replaceAll(' ', '');
  if (key.startsWith('batch') || key == 'bno' || key.startsWith('lot')) {
    return _TraceKind.batch;
  }
  if (key == 'mfg' || key == 'mfd' || key.startsWith('manufacturing')) {
    return _TraceKind.mfg;
  }
  if (key == 'exp' ||
      key.startsWith('expiry') ||
      key.startsWith('expires') ||
      key.startsWith('expiration')) {
    return _TraceKind.expiry;
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

String _extractBatch(String raw) {
  var value = raw
      .replaceAll(
        RegExp(
          r'\b(?:batch|no|number|b\s*no|lot)\b',
          caseSensitive: false,
        ),
        ' ',
      )
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (value.isEmpty) return '';
  final match = RegExp(r'[A-Za-z0-9][A-Za-z0-9._/-]{2,19}').firstMatch(value);
  if (match == null) return '';
  value = match.group(0) ?? '';
  if (!RegExp(r'\d').hasMatch(value)) return '';
  if (RegExp(r'^\d{1,2}[-/.]\d{2,4}$').hasMatch(value) ||
      RegExp(r'^\d{1,2}[-/.]\d{1,2}[-/.]\d{2,4}$').hasMatch(value)) {
    return '';
  }
  return value;
}

String _extractDate(String raw) {
  final value = raw.trim();
  if (value.isEmpty) return '';

  final yearFirst = RegExp(
    r'(?<!\d)(20\d{2})[-/.](0?[1-9]|1[0-2])(?:[-/.]([0-2]?\d|3[01]))?(?!\d)',
  ).firstMatch(value);
  if (yearFirst != null) {
    final year = int.parse(yearFirst.group(1)!);
    final month = int.parse(yearFirst.group(2)!);
    final dayText = yearFirst.group(3);
    return _isoDate(year, month, dayText == null ? 0 : int.parse(dayText));
  }

  final full = RegExp(
    r'(?<!\d)([0-2]?\d|3[01])[-/.](0?[1-9]|1[0-2])[-/.](\d{2}|20\d{2})(?!\d)',
  ).firstMatch(value);
  if (full != null) {
    final day = int.parse(full.group(1)!);
    final month = int.parse(full.group(2)!);
    final rawYear = int.parse(full.group(3)!);
    final year = full.group(3)!.length == 2 ? 2000 + rawYear : rawYear;
    return _isoDate(year, month, day);
  }

  final monthYear = RegExp(
    r'(?<!\d)(0?[1-9]|1[0-2])[-/.](\d{2}|20\d{2})(?!\d)',
  ).firstMatch(value);
  if (monthYear != null) {
    final month = int.parse(monthYear.group(1)!);
    final rawYear = int.parse(monthYear.group(2)!);
    final year = monthYear.group(2)!.length == 2 ? 2000 + rawYear : rawYear;
    return _isoDate(year, month, 0);
  }
  return '';
}

String _isoDate(int year, int month, int day) {
  if (year < 2000 || year > 2099 || month < 1 || month > 12) return '';
  if (day == 0) {
    return '${year.toString().padLeft(4, '0')}-${month.toString().padLeft(2, '0')}';
  }
  final date = DateTime.utc(year, month, day);
  if (date.year != year || date.month != month || date.day != day) return '';
  return '${year.toString().padLeft(4, '0')}-${month.toString().padLeft(2, '0')}-${day.toString().padLeft(2, '0')}';
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

  // Same-row value to the right of the label is the strongest geometric cue.
  if (vertical <= .72 && candidate.left >= label.left - height * .3) {
    final gap = max(0.0, candidate.left - labelRight) / height;
    return (.94 - min(.12, gap * .025)).clamp(0, 1).toDouble();
  }

  final horizontalOverlap =
      max(0.0, min(labelRight, candidateRight) - max(label.left, candidate.left)) /
      max(1.0, min(label.width, candidate.width));
  final belowGap = (candidate.top - (label.top + label.height)) / height;
  if (belowGap >= -.25 && belowGap <= 2.6 && horizontalOverlap >= .12) {
    return (.88 - max(0.0, belowGap) * .035).clamp(0, 1).toDouble();
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

  final ranked = groups.entries.map((entry) {
    final maxConfidence = entry.value
        .map((value) => value.confidence)
        .reduce(max);
    final support = entry.value.length;
    final score = (maxConfidence + min(.06, (support - 1) * .025))
        .clamp(0, .98)
        .toDouble();
    return (entry.value.first.value, score, support, maxConfidence);
  }).toList()
    ..sort((a, b) {
      final score = b.$2.compareTo(a.$2);
      if (score != 0) return score;
      final support = b.$3.compareTo(a.$3);
      return support != 0 ? support : a.$1.compareTo(b.$1);
    });
  final best = ranked.first;
  if (best.$2 < .80) return null;
  final conflict = ranked.length > 1 &&
      ranked[1].$4 >= .84 &&
      best.$2 - ranked[1].$2 < .09;
  return SpatialTraceabilityField(
    value: best.$1,
    confidence: conflict ? min(best.$2, .82) : best.$2,
    support: best.$3,
    conflicted: conflict,
  );
}
