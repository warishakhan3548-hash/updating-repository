import 'dart:math';

import 'medicine_date_parser.dart';

/// One original, contiguous OCR span. Offsets refer to UTF-16 source positions;
/// neither words nor lines are cut to fit a budget (notably mg/5 ml and dates).
class LocalScanExcerpt {
  const LocalScanExcerpt({required this.start, required this.text});
  final int start;
  final String text;
  Map<String, Object> toMessage() => {'start': start, 'text': text};
}

/// A bounded evidence selection, not a rewritten/concatenated medicine label.
/// Gaps remain explicit so a quote/dose cannot bridge omitted source text.
class LocalScanEvidence {
  LocalScanEvidence._(this.excerpts, this.sourceCharacters, this.truncated);
  final List<LocalScanExcerpt> excerpts;
  final int sourceCharacters;
  final bool truncated;

  factory LocalScanEvidence.select(String source, {int limit = 7000}) {
    if (limit < 256 || limit > 7000) {
      throw const FormatException('Invalid source budget.');
    }
    if (source.length <= limit) {
      return LocalScanEvidence._(
        List.unmodifiable([
          if (source.isNotEmpty) LocalScanExcerpt(start: 0, text: source),
        ]),
        source.length,
        false,
      );
    }
    // Drafts are already bounded by the resolver. Bound this public entry too,
    // without presenting a partially cut final line as complete evidence.
    final lines = RegExp(r'[^\r\n]*(?:\r\n|\r|\n|$)')
        .allMatches(source)
        .takeWhile((line) => line.end <= 30000)
        .where((line) => line.end > line.start)
        .toList(growable: false);
    final selected = <int>{};
    var used = 0;

    void addBlock(int anchor, int allowance, {int before = 1, int after = 1}) {
      var cost = 0;
      final block = <int>[];
      bool include(int index) {
        final size = selected.contains(index)
            ? 0
            : lines[index].end - lines[index].start;
        if (used + cost + size > limit || cost + size > allowance) return false;
        cost += size;
        block.add(index);
        return true;
      }

      if (!include(anchor)) return;
      // The value following a label has priority over optional leading context.
      for (
        var i = anchor + 1;
        i <= min(lines.length - 1, anchor + after);
        i++
      ) {
        if (!include(i)) break;
      }
      for (var i = anchor - 1; i >= max(0, anchor - before); i--) {
        if (!include(i)) break;
      }
      selected.addAll(block);
      used += cost;
    }

    if (lines.isNotEmpty) {
      // Reserve heading space independently: late composition must not evict
      // every printed trade/form heading on a long multilingual wrapper.
      addBlock(0, min(400, limit ~/ 4), before: 0, after: 2);
    }
    final composition = RegExp(
      r'\b(?:composition|compositon|ingredients?|active\s+ingredient|each\s+(?:tablet|capsule|5\s*ml)|contains)\b|संघटन|संरचना',
      caseSensitive: false,
    );
    final dose = RegExp(
      r'[0-9\u0660-\u0669\u06f0-\u06f9\u0966-\u096f]\s*(?:mcg|mg|gm|g|ml|iu|units?|%)(?![a-z])',
      caseSensitive: false,
    );
    final batch = RegExp(r'\b(?:batch|lot)\b', caseSensitive: false);
    final ingredientAnchors = <int>[];
    final doseAnchors = <int>[];
    final dateAnchors = <int>[];
    for (var i = 0; i < lines.length; i++) {
      final text = lines[i][0]!;
      if (composition.hasMatch(text)) ingredientAnchors.add(i);
      if (dose.hasMatch(text)) doseAnchors.add(i);
      if (medicineManufacturingLabel.hasMatch(text) ||
          medicineExpiryLabel.hasMatch(text) ||
          batch.hasMatch(text)) {
        dateAnchors.add(i);
      }
    }
    final primary = ingredientAnchors.firstOrNull ?? doseAnchors.firstOrNull;
    if (primary != null) addBlock(primary, limit * 3 ~/ 5, after: 8);
    // Label + next line stay together when possible. Dates themselves are still
    // owned by the deterministic temporal resolver, not by this ranking policy.
    for (final anchor in dateAnchors) {
      addBlock(anchor, limit - used);
    }
    for (final anchor in [...ingredientAnchors, ...doseAnchors]) {
      addBlock(anchor, limit - used, after: 4);
    }

    final ordered = selected.toList()..sort();
    final spans = <LocalScanExcerpt>[];
    for (var i = 0; i < ordered.length;) {
      final start = lines[ordered[i]].start;
      var end = lines[ordered[i++]].end;
      while (i < ordered.length && lines[ordered[i]].start == end) {
        end = lines[ordered[i++]].end;
      }
      spans.add(
        LocalScanExcerpt(start: start, text: source.substring(start, end)),
      );
    }
    return LocalScanEvidence._(List.unmodifiable(spans), used, true);
  }
}
