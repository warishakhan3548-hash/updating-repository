import 'dart:math';

import 'medicine_understanding.dart';

enum MedicineDateRole { manufacturing, expiry, unknown }

class ParsedMedicineDate {
  const ParsedMedicineDate({required this.value, required this.monthOnly});

  final String value;
  final bool monthOnly;

  DateTime get start {
    final parts = value.split('-').map(int.parse).toList(growable: false);
    return DateTime.utc(parts[0], parts[1], parts.length > 2 ? parts[2] : 1);
  }

  DateTime get end {
    if (!monthOnly) return start;
    final parts = value.split('-').map(int.parse).toList(growable: false);
    return DateTime.utc(parts[0], parts[1] + 1, 0);
  }
}

class MedicineDateEvidence {
  const MedicineDateEvidence({
    required this.date,
    required this.role,
    required this.confidence,
    required this.support,
    this.explicitLabel = false,
  });

  final ParsedMedicineDate date;
  final MedicineDateRole role;
  final double confidence;
  final int support;
  final bool explicitLabel;
}

class MedicineDateResolution {
  const MedicineDateResolution({
    this.manufacturing,
    this.expiry,
    this.conflicted = false,
    this.expired = false,
  });

  final MedicineDateEvidence? manufacturing;
  final MedicineDateEvidence? expiry;
  final bool conflicted;
  final bool expired;

  bool get isEmpty => manufacturing == null && expiry == null;
}

/// Normalizes one date-like medicine-pack string. Space-separated OCR such as
/// `04 05 2028` is intentionally supported alongside slash, dash and dot forms.
/// Common numeric OCR confusions are repaired only inside date-shaped tokens.
ParsedMedicineDate? parseMedicineDateText(String raw) {
  final matches = _extractDateMatches(raw);
  return matches.isEmpty ? null : matches.first.date;
}

/// V10 deterministic temporal reasoning. Current time is supporting evidence,
/// never the only rule: a past date may be manufacturing OR an already-expired
/// expiry. Strong labels, chronological pairs and plausible shelf-life always
/// outrank the simple past/future heuristic.
MedicineDateResolution inferMedicineDateIntelligence({
  required Iterable<MedicineFrameEvidence> frames,
  required DateTime referenceDate,
  String existingMfg = '',
  String existingExpiry = '',
  double existingMfgConfidence = 0,
  double existingExpiryConfidence = 0,
}) {
  final evidence = <MedicineDateEvidence>[];
  final grouped = <String, MedicineDateEvidence>{};

  void remember(MedicineDateEvidence item) {
    final key = '${item.role.name}|${item.date.value}';
    final old = grouped[key];
    if (old == null) {
      grouped[key] = item;
      return;
    }
    grouped[key] = MedicineDateEvidence(
      date: item.date,
      role: item.role,
      confidence: max(old.confidence, item.confidence),
      support: old.support + item.support,
      explicitLabel: old.explicitLabel || item.explicitLabel,
    );
  }

  final existingMfgDate = parseMedicineDateText(existingMfg);
  if (existingMfgDate != null) {
    remember(
      MedicineDateEvidence(
        date: existingMfgDate,
        role: MedicineDateRole.manufacturing,
        confidence: existingMfgConfidence.clamp(.50, .995).toDouble(),
        support: 1,
        explicitLabel: existingMfgConfidence >= .84,
      ),
    );
  }
  final existingExpiryDate = parseMedicineDateText(existingExpiry);
  if (existingExpiryDate != null) {
    remember(
      MedicineDateEvidence(
        date: existingExpiryDate,
        role: MedicineDateRole.expiry,
        confidence: existingExpiryConfidence.clamp(.50, .995).toDouble(),
        support: 1,
        explicitLabel: existingExpiryConfidence >= .84,
      ),
    );
  }

  for (final frame in frames.take(16)) {
    final quality = frame.quality.clamp(0, 1).toDouble();
    final lines = <String>{
      ...frame.text.split(RegExp(r'[\r\n]+')),
      ...frame.layoutLines.map((line) => line.text),
    };
    for (final line in lines.take(160)) {
      final matches = _extractDateMatches(line);
      if (matches.isEmpty) continue;
      final labels = _dateLabels(line);
      for (final match in matches.take(6)) {
        final labelled = _nearestRole(match.start, match.end, labels);
        final role = labelled?.$1 ?? MedicineDateRole.unknown;
        final distance = labelled?.$2 ?? 999;
        final explicit = labelled != null;
        final base = explicit
            ? (distance <= 20 ? .955 : .91)
            : .61;
        remember(
          MedicineDateEvidence(
            date: match.date,
            role: role,
            confidence: (base + quality * (explicit ? .035 : .055))
                .clamp(0, .99)
                .toDouble(),
            support: 1,
            explicitLabel: explicit,
          ),
        );
      }
    }
  }

  evidence.addAll(grouped.values);
  if (evidence.isEmpty) return const MedicineDateResolution();

  MedicineDateEvidence? bestFor(MedicineDateRole role) {
    final values = evidence.where((item) => item.role == role).toList()
      ..sort(_compareEvidence);
    return values.isEmpty ? null : values.first;
  }

  var manufacturing = bestFor(MedicineDateRole.manufacturing);
  var expiry = bestFor(MedicineDateRole.expiry);
  var conflicted = false;
  final today = DateTime.utc(
    referenceDate.year,
    referenceDate.month,
    referenceDate.day,
  );

  if (manufacturing != null && expiry != null) {
    if (!manufacturing.date.start.isBefore(expiry.date.end)) {
      conflicted = true;
    }
  }

  final uniqueByDate = <String, MedicineDateEvidence>{};
  for (final item in evidence) {
    final old = uniqueByDate[item.date.value];
    if (old == null || _compareEvidence(item, old) < 0) {
      uniqueByDate[item.date.value] = item;
    }
  }
  final unique = uniqueByDate.values.toList()
    ..sort((a, b) => a.date.start.compareTo(b.date.start));

  final pairs = <_DatePair>[];
  for (var i = 0; i < unique.length; i++) {
    for (var j = i + 1; j < unique.length; j++) {
      final earlier = unique[i];
      final later = unique[j];
      if (earlier.role == MedicineDateRole.expiry ||
          later.role == MedicineDateRole.manufacturing) {
        continue;
      }
      final days = later.date.end.difference(earlier.date.start).inDays;
      if (days < 21 || days > 8 * 366) continue;
      var score = .64;
      if (earlier.role == MedicineDateRole.manufacturing) score += .14;
      if (later.role == MedicineDateRole.expiry) score += .14;
      if (earlier.explicitLabel) score += .04;
      if (later.explicitLabel) score += .04;
      if (days >= 60 && days <= 5 * 366) {
        score += .10;
      } else {
        score += .04;
      }
      if (!earlier.date.start.isAfter(today.add(const Duration(days: 31)))) {
        score += .035;
      }
      // Future expiry is useful evidence, but an already-expired later date is
      // still completely valid and therefore only receives less bonus, no veto.
      score += later.date.end.isAfter(today) ? .045 : .015;
      score += min(.035, (earlier.support + later.support - 2) * .012);
      pairs.add(_DatePair(earlier, later, score.clamp(0, .99).toDouble()));
    }
  }
  pairs.sort((a, b) => b.score.compareTo(a.score));

  if ((manufacturing == null || expiry == null || conflicted) &&
      pairs.isNotEmpty) {
    final best = pairs.first;
    final runner = pairs.length > 1 ? pairs[1] : null;
    final separated = runner == null || best.score - runner.score >= .045;
    if (best.score >= .78 && separated) {
      final inferredConfidence = best.score.clamp(.78, .94).toDouble();
      if (manufacturing == null || conflicted) {
        manufacturing = MedicineDateEvidence(
          date: best.earlier.date,
          role: MedicineDateRole.manufacturing,
          confidence: max(best.earlier.confidence, inferredConfidence),
          support: best.earlier.support,
          explicitLabel: best.earlier.explicitLabel,
        );
      }
      if (expiry == null || conflicted) {
        expiry = MedicineDateEvidence(
          date: best.later.date,
          role: MedicineDateRole.expiry,
          confidence: max(best.later.confidence, inferredConfidence),
          support: best.later.support,
          explicitLabel: best.later.explicitLabel,
        );
      }
      conflicted = false;
    }
  }

  // One unlabeled future date can safely be a strong expiry candidate because
  // manufacturing in the future is temporally impossible. A single past date is
  // deliberately NOT classified: it could be MFG or an already-expired EXP.
  if (expiry == null && unique.length == 1) {
    final only = unique.single;
    final future = only.date.end.isAfter(today);
    final horizon = only.date.end.difference(today).inDays;
    if (only.role == MedicineDateRole.unknown &&
        future &&
        horizon <= 8 * 366) {
      expiry = MedicineDateEvidence(
        date: only.date,
        role: MedicineDateRole.expiry,
        confidence: max(.84, min(.90, only.confidence + .24)),
        support: only.support,
      );
    }
  }

  if (manufacturing != null && expiry != null) {
    if (!manufacturing.date.start.isBefore(expiry.date.end)) conflicted = true;
    final gap = expiry.date.end.difference(manufacturing.date.start).inDays;
    if (gap < 21 || gap > 8 * 366) conflicted = true;
  }

  final expired = expiry != null && expiry.date.end.isBefore(today);
  return MedicineDateResolution(
    manufacturing: manufacturing,
    expiry: expiry,
    conflicted: conflicted,
    expired: expired,
  );
}

class _DateMatch {
  const _DateMatch(this.start, this.end, this.date);
  final int start;
  final int end;
  final ParsedMedicineDate date;
}

class _DatePair {
  const _DatePair(this.earlier, this.later, this.score);
  final MedicineDateEvidence earlier;
  final MedicineDateEvidence later;
  final double score;
}

int _compareEvidence(MedicineDateEvidence a, MedicineDateEvidence b) {
  final explicit = (b.explicitLabel ? 1 : 0) - (a.explicitLabel ? 1 : 0);
  if (explicit != 0) return explicit;
  final confidence = b.confidence.compareTo(a.confidence);
  if (confidence != 0) return confidence;
  return b.support.compareTo(a.support);
}

List<_DateMatch> _extractDateMatches(String raw) {
  final text = _repairNumericOcr(raw);
  if (text.trim().isEmpty) return const <_DateMatch>[];
  final result = <_DateMatch>[];
  final occupied = <(int, int)>[];

  bool free(int start, int end) => !occupied.any(
    (span) => start < span.$2 && end > span.$1,
  );

  void add(RegExp pattern, ParsedMedicineDate? Function(RegExpMatch) parse) {
    for (final match in pattern.allMatches(text)) {
      if (!free(match.start, match.end)) continue;
      final date = parse(match);
      if (date == null) continue;
      result.add(_DateMatch(match.start, match.end, date));
      occupied.add((match.start, match.end));
    }
  }

  const sep = r'[\s./-]+';
  add(
    RegExp('(?<!\\d)(20\\d{2})$sep(0?[1-9]|1[0-2])$sep([0-2]?\\d|3[01])(?!\\d)'),
    (m) => _date(int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!)),
  );
  add(
    RegExp('(?<!\\d)([0-2]?\\d|3[01])$sep(0?[1-9]|1[0-2])$sep(\\d{2}|20\\d{2})(?!\\d)'),
    (m) => _date(_year(m[3]!), int.parse(m[2]!), int.parse(m[1]!)),
  );
  add(
    RegExp(
      r'(?<![A-Za-z0-9])([0-2]?\d|3[01])[\s./-]+(JAN(?:UARY)?|FEB(?:RUARY)?|MAR(?:CH)?|APR(?:IL)?|MAY|JUN(?:E)?|JUL(?:Y)?|AUG(?:UST)?|SEP(?:T(?:EMBER)?)?|OCT(?:OBER)?|NOV(?:EMBER)?|DEC(?:EMBER)?)[\s,./-]+(\d{2}|20\d{2})(?!\d)',
      caseSensitive: false,
    ),
    (m) => _date(_year(m[3]!), _month(m[2]!), int.parse(m[1]!)),
  );
  add(
    RegExp(
      r'(?<![A-Za-z0-9])(JAN(?:UARY)?|FEB(?:RUARY)?|MAR(?:CH)?|APR(?:IL)?|MAY|JUN(?:E)?|JUL(?:Y)?|AUG(?:UST)?|SEP(?:T(?:EMBER)?)?|OCT(?:OBER)?|NOV(?:EMBER)?|DEC(?:EMBER)?)[\s,./-]+(\d{2}|20\d{2})(?!\d)',
      caseSensitive: false,
    ),
    (m) => _date(_year(m[2]!), _month(m[1]!), 0),
  );
  add(
    RegExp('(?<!\\d)(0?[1-9]|1[0-2])$sep(\\d{2}|20\\d{2})(?!\\d)'),
    (m) => _date(_year(m[2]!), int.parse(m[1]!), 0),
  );

  result.sort((a, b) => a.start.compareTo(b.start));
  return result;
}

ParsedMedicineDate? _date(int year, int month, int day) {
  if (year < 2000 || year > 2099 || month < 1 || month > 12) return null;
  if (day == 0) {
    return ParsedMedicineDate(
      value: '${year.toString().padLeft(4, '0')}-${month.toString().padLeft(2, '0')}',
      monthOnly: true,
    );
  }
  if (day < 1 || day > 31) return null;
  final value = DateTime.utc(year, month, day);
  if (value.year != year || value.month != month || value.day != day) {
    return null;
  }
  return ParsedMedicineDate(
    value: '${year.toString().padLeft(4, '0')}-${month.toString().padLeft(2, '0')}-${day.toString().padLeft(2, '0')}',
    monthOnly: false,
  );
}

int _year(String raw) {
  final value = int.parse(raw);
  return raw.length == 2 ? 2000 + value : value;
}

int _month(String raw) {
  final key = raw.substring(0, 3).toLowerCase();
  const months = <String, int>{
    'jan': 1,
    'feb': 2,
    'mar': 3,
    'apr': 4,
    'may': 5,
    'jun': 6,
    'jul': 7,
    'aug': 8,
    'sep': 9,
    'oct': 10,
    'nov': 11,
    'dec': 12,
  };
  return months[key] ?? 0;
}

String _repairNumericOcr(String input) => input.replaceAllMapped(
  RegExp(r'(?<![A-Za-z0-9])([0-9OoIl]{1,4})(?![A-Za-z0-9])'),
  (match) {
    final token = match.group(1)!;
    if (!RegExp(r'[0-9]').hasMatch(token) && token.length == 1) return token;
    return token
        .replaceAll(RegExp('[Oo]'), '0')
        .replaceAll(RegExp('[Il]'), '1');
  },
);

List<(MedicineDateRole, int, int)> _dateLabels(String line) {
  final result = <(MedicineDateRole, int, int)>[];
  final expiry = RegExp(
    r'\b(?:exp|expiry|expires|expiration|use\s*before|best\s*before)\b',
    caseSensitive: false,
  );
  final mfg = RegExp(
    r'\b(?:mfg|mfd|manufactured|manufacturing(?:\s*date)?)\b',
    caseSensitive: false,
  );
  for (final match in expiry.allMatches(line)) {
    result.add((MedicineDateRole.expiry, match.start, match.end));
  }
  for (final match in mfg.allMatches(line)) {
    result.add((MedicineDateRole.manufacturing, match.start, match.end));
  }
  return result;
}

(MedicineDateRole, int)? _nearestRole(
  int start,
  int end,
  List<(MedicineDateRole, int, int)> labels,
) {
  (MedicineDateRole, int)? best;
  for (final label in labels) {
    final distance = start >= label.$3
        ? start - label.$3
        : label.$2 >= end
        ? label.$2 - end + 10
        : 0;
    if (distance > 56) continue;
    if (best == null || distance < best.$2) best = (label.$1, distance);
  }
  return best;
}
