part of 'medicine_date_intelligence.dart';

class _DatePair {
  const _DatePair(this.earlier, this.later, this.score);
  final MedicineDateEvidence earlier;
  final MedicineDateEvidence later;
  final double score;
}

final _bareFullDateSurface = RegExp(r'^[0-9०-९٠-٩۰-۹０-９OoIlL]{8}$');
final _compactDatePairSeparator = RegExp(r'^[\s|,:;./-]*$');

int _compareEvidence(MedicineDateEvidence a, MedicineDateEvidence b) {
  final explicit = (b.explicitLabel ? 1 : 0) - (a.explicitLabel ? 1 : 0);
  if (explicit != 0) return explicit;
  final confidence = b.confidence.compareTo(a.confidence);
  if (confidence != 0) return confidence;
  return b.support.compareTo(a.support);
}

List<List<String>> _dateLineStreams(MedicineFrameEvidence frame) {
  List<String> clean(Iterable<String> source) => source
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty)
      .take(120)
      .toList(growable: false);

  final raw = clean(frame.text.split(RegExp(r'[\r\n]+')));
  final layoutEvidence = frame.layoutLines.take(120).toList(growable: false);
  if (layoutEvidence.any((line) =>
      line.height > 0 || line.width > 0 || line.left != 0 || line.top != 0)) {
    layoutEvidence.sort(compareMedicineDateLayoutPosition);
  }

  // Raw RecognizedText is assembled from multiple script recognizers and does
  // not carry physical column ownership. Once detector geometry exists, it is
  // therefore unsafe to let flattened raw adjacency compete with the spatial
  // reading order: "MFG | EXP" above two dates can otherwise invert their roles.
  // Geometry is authoritative for date adjacency; raw text remains the fallback
  // only when no usable layout evidence survived the detector.
  final layout = clean(_mergeDateLayoutRows(layoutEvidence));
  if (layout.isNotEmpty) return <List<String>>[layout];
  return <List<String>>[if (raw.isNotEmpty) raw];
}

List<String> _mergeDateLayoutRows(List<MedicineTextLineEvidence> lines) {
  if (lines.isEmpty) return const <String>[];
  final hasGeometry = lines.any(
    (line) =>
        line.height > 0 || line.width > 0 || line.left != 0 || line.top != 0,
  );
  if (!hasGeometry) {
    return lines.map((line) => line.text).toList(growable: false);
  }

  final rows = <List<MedicineTextLineEvidence>>[];
  for (final line in lines) {
    if (line.text.trim().isEmpty) continue;
    if (line.height <= 0) {
      rows.add(<MedicineTextLineEvidence>[line]);
      continue;
    }
    if (rows.isEmpty) {
      rows.add(<MedicineTextLineEvidence>[line]);
      continue;
    }

    final row = rows.last;
    final geometric = row.where((item) => item.height > 0).toList(growable: false);
    if (geometric.isEmpty) {
      rows.add(<MedicineTextLineEvidence>[line]);
      continue;
    }
    final rowCenter =
        geometric
            .map((item) => item.top + item.height / 2)
            .reduce((a, b) => a + b) /
        geometric.length;
    final lineCenter = line.top + line.height / 2;
    final referenceHeight = geometric
        .map((item) => item.height)
        .reduce(min);
    final tolerance = max(3.0, min(referenceHeight, line.height) * .62);
    if ((lineCenter - rowCenter).abs() <= tolerance) {
      row.add(line);
    } else {
      rows.add(<MedicineTextLineEvidence>[line]);
    }
  }

  final result = <String>[];
  for (final row in rows.take(120)) {
    row.sort((a, b) {
      final horizontal = a.left.compareTo(b.left);
      if (horizontal != 0) return horizontal;
      final vertical = a.top.compareTo(b.top);
      if (vertical != 0) return vertical;
      return a.text.compareTo(b.text);
    });
    final text = row
        .map((item) => item.text.trim())
        .where((value) => value.isNotEmpty)
        .join('  ')
        .trim();
    if (text.isNotEmpty) result.add(text);
  }
  return result;
}

int compareMedicineDateLayoutPosition(
  MedicineTextLineEvidence left,
  MedicineTextLineEvidence right,
) {
  // Approximate row membership is not a transitive comparison: A can be close
  // to B, B close to C, while A and C are on different rows. Mixing that test
  // with horizontal ordering creates cycles and input-order-dependent dates.
  // Sort by a total spatial order first; _mergeDateLayoutRows owns row tolerance.
  final vertical = left.top.compareTo(right.top);
  if (vertical != 0) return vertical;
  final horizontal = left.left.compareTo(right.left);
  if (horizontal != 0) return horizontal;
  return left.text.compareTo(right.text);
}

MedicineDateRole? _labelOnlyRole(String line) {
  if (RegExp(r'[0-9०-९٠-٩۰-۹０-９]').hasMatch(line)) return null;
  final labels = _dateLabels(line);
  if (labels.length != 1) return null;
  final role = labels.single.$1;
  return role == MedicineDateRole.unknown ? null : role;
}

bool _labelOnlyNonDate(String line) {
  if (RegExp(r'[0-9०-९٠-٩۰-۹０-９]').hasMatch(line)) return false;
  final labels = _dateLabels(line);
  return labels.length == 1 && labels.single.$1 == MedicineDateRole.unknown;
}

bool _adjacentNonDateLabel(List<String> lines, int index) =>
    (index > 0 && _labelOnlyNonDate(lines[index - 1])) ||
    (index + 1 < lines.length && _labelOnlyNonDate(lines[index + 1]));

Set<int> _bareCompactDatePairIndexes(
  List<String> lines,
  List<List<MedicineDateMatch>> matchesByLine,
  DateTime today,
) {
  final candidates = <(int, ParsedMedicineDate)>[];
  for (var index = 0; index < lines.length; index++) {
    final matches = matchesByLine[index];

    // OCR flattening can place two otherwise standalone MMYY/MMYYYY values on
    // one physical row (for example "0426 0428"). Accept that row only when it
    // contains exactly two compact date tokens and nothing except harmless date
    // separators around them. This preserves the existing chronology gate while
    // recovering a common no-label package layout without turning batch/serial
    // numbers into dates.
    if (matches.length == 2 &&
        _isIsolatedCompactDatePairLine(lines[index], matches) &&
        !_adjacentNonDateLabel(lines, index)) {
      for (final match in matches) {
        candidates.add((index, match.date));
      }
      continue;
    }

    if (matches.length != 1) continue;
    final match = matches.single;
    final roleUnsafeBareToken =
        match.compact || _isBareSeparatorlessFullDate(lines[index], match);
    if (!roleUnsafeBareToken ||
        !_isStandaloneDateMatch(lines[index], match) ||
        _adjacentNonDateLabel(lines, index)) {
      continue;
    }
    candidates.add((index, match.date));
  }

  if (candidates.length != 2) return const <int>{};
  final first = candidates[0];
  final second = candidates[1];
  final firstBeforeSecond = first.$2.start.isBefore(second.$2.start);
  final earlier = firstBeforeSecond ? first : second;
  final later = firstBeforeSecond ? second : first;
  if (!earlier.$2.start.isBefore(later.$2.end)) return const <int>{};

  final shelfLifeDays = later.$2.end.difference(earlier.$2.start).inDays;
  if (shelfLifeDays < 60 || shelfLifeDays > 5 * 366) {
    return const <int>{};
  }
  if (earlier.$2.start.isAfter(today.add(const Duration(days: 31)))) {
    return const <int>{};
  }
  return Set<int>.unmodifiable(<int>{earlier.$1, later.$1});
}

bool _isIsolatedCompactDatePairLine(
  String line,
  List<MedicineDateMatch> matches,
) {
  if (matches.length != 2 || matches.any((match) => !match.compact)) {
    return false;
  }
  var cursor = 0;
  for (final match in matches) {
    if (match.start < cursor ||
        !_compactDatePairSeparator.hasMatch(
          line.substring(cursor, match.start),
        )) {
      return false;
    }
    cursor = match.end;
  }
  return _compactDatePairSeparator.hasMatch(line.substring(cursor));
}

bool _isStandaloneDateMatch(String line, MedicineDateMatch match) =>
    line.substring(0, match.start).trim().isEmpty &&
    line.substring(match.end).trim().isEmpty;

/// An 8-character separator-less full date is calendar-parseable but still
/// identifier-like when no MFG/EXP evidence owns it. Keep the parser's compact
/// flag unchanged (existing chronology contracts rely on it) and apply this
/// stricter role-safety classification only in the semantic date engine.
bool _isBareSeparatorlessFullDate(String line, MedicineDateMatch match) {
  if (!_isStandaloneDateMatch(line, match)) return false;
  final raw = line.substring(match.start, match.end).trim();
  return raw.length == 8 && _bareFullDateSurface.hasMatch(raw);
}

List<(MedicineDateRole, int, int)> _dateLabels(String line) {
  final result = <(MedicineDateRole, int, int)>[];
  for (final match in medicineExpiryLabel.allMatches(line)) {
    result.add((MedicineDateRole.expiry, match.start, match.end));
  }
  for (final match in medicineManufacturingLabel.allMatches(line)) {
    result.add((MedicineDateRole.manufacturing, match.start, match.end));
  }
  for (final match in medicineNonDateLabel.allMatches(line)) {
    result.add((MedicineDateRole.unknown, match.start, match.end));
  }
  result.sort((a, b) => a.$2.compareTo(b.$2));
  return result;
}

(MedicineDateRole, int)? _nearestRole(
  int start,
  int end,
  List<(MedicineDateRole, int, int)> labels,
) {
  (MedicineDateRole, int)? best;
  for (final label in labels) {
    final distance = label.$3 <= start
        ? start - label.$3
        : label.$2 >= end
        ? label.$2 - end + 10
        : 0;
    if (distance > 56) continue;
    if (best == null || distance < best.$2) {
      best = (label.$1, distance);
    }
  }
  return best;
}
