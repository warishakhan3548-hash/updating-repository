part of 'medicine_date_intelligence.dart';

MedicineDateResolution inferMedicineDateIntelligence({
  required Iterable<MedicineFrameEvidence> frames,
  required DateTime referenceDate,
  String existingMfg = '',
  String existingExpiry = '',
  double existingMfgConfidence = 0,
  double existingExpiryConfidence = 0,
}) {
  final sourceFrames = selectOfflineEvidenceFrames(
    frames,
    maxFrames: 16,
  ).toList(growable: false);
  final evidence = <MedicineDateEvidence>[];
  final grouped = <String, MedicineDateEvidence>{};
  final today = DateTime.utc(
    referenceDate.year,
    referenceDate.month,
    referenceDate.day,
  );

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

  final spatial = inferSpatialTraceability(sourceFrames);
  void rememberSpatial(
    SpatialTraceabilityField? hint,
    MedicineDateRole role,
  ) {
    if (hint == null ||
        hint.conflicted ||
        hint.value.trim().isEmpty ||
        hint.confidence < .80) {
      return;
    }
    final parsed = parseMedicineDateText(hint.value);
    if (parsed == null) return;
    remember(
      MedicineDateEvidence(
        date: parsed,
        role: role,
        confidence: hint.confidence.clamp(.80, .99).toDouble(),
        support: max(1, hint.support),
        explicitLabel: true,
      ),
    );
  }

  rememberSpatial(spatial.mfg, MedicineDateRole.manufacturing);
  rememberSpatial(spatial.expiry, MedicineDateRole.expiry);

  final graph = buildOfflineEvidenceGraph(sourceFrames, maxFrames: 16);
  final independentFrames = graph.groups.isEmpty
      ? sourceFrames
      : graph.groups.map((group) => group.representative);
  for (final frame in independentFrames) {
    final quality = frame.quality.clamp(0, 1).toDouble();
    final observed = <String>{};
    for (final orderedLines in _dateLineStreams(frame)) {
      // Tokenize each bounded line once. Pair discovery and adjacency checks
      // reuse the same offsets and calendar decisions as role assignment.
      final matchesByLine = orderedLines
          .map((line) => extractMedicineDateMatches(line, allowCompact: true))
          .toList(growable: false);
      final acceptedBareCompact = _bareCompactDatePairIndexes(
        orderedLines,
        matchesByLine,
        today,
      );
      for (var index = 0; index < orderedLines.length; index++) {
        final line = orderedLines[index];
        final matches = matchesByLine[index];
        if (matches.isEmpty) continue;
        final labels = _dateLabels(line);
        for (final match in matches.take(6)) {
          var labelled = _nearestRole(match.start, match.end, labels);
          final standalone =
              matches.length == 1 && _isStandaloneDateMatch(line, match);

          if (labelled == null && labels.isEmpty && standalone) {
            if (index > 0) {
              final previousLine = orderedLines[index - 1];
              final previousRole = _labelOnlyRole(previousLine);
              if (previousRole != null) {
                labelled = (previousRole, 24);
              } else if (_labelOnlyNonDate(previousLine)) {
                continue;
              }
            }
            if (labelled == null && index + 1 < orderedLines.length) {
              final followingRole = _labelOnlyRole(orderedLines[index + 1]);
              final followedByAnotherDate =
                  index + 2 < orderedLines.length &&
                  matchesByLine[index + 2].length == 1 &&
                  _isStandaloneDateMatch(
                    orderedLines[index + 2],
                    matchesByLine[index + 2].single,
                  );
              if (followingRole != null && !followedByAnotherDate) {
                labelled = (followingRole, 30);
              }
            }
            if (labelled == null &&
                _adjacentNonDateLabel(orderedLines, index)) {
              continue;
            }
          }

          final role = labelled?.$1 ?? MedicineDateRole.unknown;
          if (labelled != null && role == MedicineDateRole.unknown) continue;
          // A separator-less 8-digit full date is syntactically valid but can
          // still be a batch/serial number. Without an owning date label, only
          // a coherent two-date chronology may promote that identifier-like
          // surface. Spaced/slashed full dates keep the existing future-expiry
          // hint behaviour because their presentation itself supplies context.
          final roleUnsafeBareToken =
              match.compact ||
              (standalone && _isBareSeparatorlessFullDate(line, match));
          if (roleUnsafeBareToken &&
              labelled == null &&
              !acceptedBareCompact.contains(index)) {
            continue;
          }
          if (!observed.add('${role.name}|${match.date.value}')) continue;
          final distance = labelled?.$2 ?? 999;
          final explicit = labelled != null;
          final base = explicit ? (distance <= 20 ? .955 : .91) : .61;
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
  final labelConflict =
      <MedicineDateRole>[
        MedicineDateRole.manufacturing,
        MedicineDateRole.expiry,
      ].any((role) {
        DateTime? latestStart, earliestEnd;
        for (final item in evidence.where(
          (item) =>
              item.role == role && item.explicitLabel && item.confidence >= .84,
        )) {
          final start = item.date.start, end = item.date.end;
          if (latestStart == null || start.isAfter(latestStart)) {
            latestStart = start;
          }
          if (earliestEnd == null || end.isBefore(earliestEnd)) {
            earliestEnd = end;
          }
        }
        return latestStart != null && latestStart.isAfter(earliestEnd!);
      });
  var conflicted = labelConflict;

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
      conflicted = labelConflict;
    }
  }

  if (expiry == null && unique.length == 1) {
    final only = unique.single;
    final future = only.date.end.isAfter(today);
    final horizon = only.date.end.difference(today).inDays;
    if (only.role == MedicineDateRole.unknown && future && horizon <= 8 * 366) {
      expiry = MedicineDateEvidence(
        date: only.date,
        role: MedicineDateRole.expiry,
        confidence: .70,
        support: only.support,
      );
    }
  }

  if (manufacturing != null && expiry != null) {
    if (!manufacturing.date.start.isBefore(expiry.date.end)) conflicted = true;
    final gap = expiry.date.end.difference(manufacturing.date.start).inDays;
    if (gap < 21 || gap > 8 * 366) conflicted = true;
  }
  if (manufacturing != null && manufacturing.date.start.isAfter(today)) {
    conflicted = true;
  }

  final expired = expiry != null && expiry.date.end.isBefore(today);
  return MedicineDateResolution(
    manufacturing: manufacturing,
    expiry: expiry,
    conflicted: conflicted,
    expired: expired,
  );
}
