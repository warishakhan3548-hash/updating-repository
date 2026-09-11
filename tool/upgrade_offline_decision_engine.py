#!/usr/bin/env python3
from pathlib import Path

TARGET = Path('lib/domain/medicine_resolution_v2.dart')
SENTINEL = 'Rarity-aware multi-stage candidate cascade'


def replace_between(text: str, start_marker: str, end_marker: str, replacement: str) -> str:
    start = text.find(start_marker)
    if start < 0:
        raise SystemExit(f'missing start marker: {start_marker!r}')
    end = text.find(end_marker, start)
    if end < 0:
        raise SystemExit(f'missing end marker: {end_marker!r}')
    return text[:start] + replacement + text[end:]


def main() -> None:
    text = TARGET.read_text(encoding='utf-8')
    if SENTINEL in text:
        print('offline decision engine is already upgraded')
        return

    product_index = r'''// Rarity-aware multi-stage candidate cascade. The resolver deliberately uses
// bounded deterministic indexes instead of an LLM: exact identifiers first,
// then rare lexical evidence, edit-neighbour recovery, prefix anchors and
// trigrams. Expensive weighted edit scoring still runs only on the tiny final
// candidate set below.
class _ProductIndex {
  _ProductIndex(Iterable<CanonicalMedicineProduct> source) {
    for (final product in source) {
      if (!product.active || product.displayName.isEmpty) continue;
      final productIndex = products.length;
      products.add(product);
      for (final rawBarcode in product.barcodes.take(12)) {
        final key = _canonicalBarcode(rawBarcode);
        if (key.isEmpty) continue;
        barcodes.putIfAbsent(key, () => <int>{}).add(productIndex);
      }

      final terms = _productTerms(product).take(192).toSet();
      for (final term in terms) {
        exact.putIfAbsent(term, () => <int>{}).add(productIndex);
        _termDocumentFrequency.update(
          term,
          (value) => value + 1,
          ifAbsent: () => 1,
        );
        if (term.length >= 4 && term.length <= 28) {
          for (final deletion in _deleteKeys(term)) {
            deletes.putIfAbsent(deletion, () => <int>{}).add(productIndex);
          }
        }
        if (term.length >= 6) {
          final prefix = _resolverPrefix(term);
          if (prefix.isNotEmpty) {
            prefixes.putIfAbsent(prefix, () => <int>{}).add(productIndex);
          }
          for (final gram in _resolverTrigrams(term).take(28)) {
            trigrams.putIfAbsent(gram, () => <int>{}).add(productIndex);
          }
        }
      }
    }
  }

  static const int _maxRetrievedProducts = maxCanonicalMedicineCandidates;
  final List<CanonicalMedicineProduct> products = <CanonicalMedicineProduct>[];
  final Map<String, Set<int>> barcodes = <String, Set<int>>{};
  final Map<String, Set<int>> exact = <String, Set<int>>{};
  final Map<String, Set<int>> deletes = <String, Set<int>>{};
  final Map<String, Set<int>> prefixes = <String, Set<int>>{};
  final Map<String, Set<int>> trigrams = <String, Set<int>>{};
  final Map<String, int> _termDocumentFrequency = <String, int>{};

  double _rarityBoost(String term) {
    final total = max(1, products.length);
    final frequency = _termDocumentFrequency[term] ?? 1;
    // BM25/IDF-inspired bounded rarity prior: rare medicine identity terms may
    // outrank ubiquitous words, but can never acquire barcode-like authority.
    return (1.0 + log((total + 1) / (frequency + 1)))
        .clamp(1.0, 3.6)
        .toDouble();
  }

  List<CanonicalMedicineProduct> candidates(
    MedicineScanDraft draft,
    List<MedicineFrameEvidence> frames,
  ) {
    if (products.isEmpty) return const <CanonicalMedicineProduct>[];
    final votes = <int, double>{};
    final lexicalChannels = <int, int>{};

    void vote(
      Iterable<int>? indexes,
      double weight, {
      bool lexicalChannel = false,
      int hardLimit = 256,
    }) {
      if (indexes == null || weight <= 0) return;
      for (final index in indexes.take(hardLimit)) {
        votes.update(index, (value) => value + weight, ifAbsent: () => weight);
        if (lexicalChannel) {
          lexicalChannels.update(index, (value) => value + 1, ifAbsent: () => 1);
        }
      }
    }

    final barcodeKeys = <String>{
      _canonicalBarcode(draft.barcode),
      for (final frame in frames)
        for (final barcode in frame.allBarcodes) _canonicalBarcode(barcode),
    }..remove('');
    for (final barcode in barcodeKeys) {
      vote(barcodes[barcode], 48);
    }

    final queryTerms = _queryTerms(draft, frames).take(72).toList(growable: false);
    for (final rawTerm in queryTerms) {
      if (rawTerm.length < 3) continue;
      final folded = _ocrFoldToken(rawTerm);
      final variants = <String>{rawTerm, folded};

      for (final term in variants) {
        final rarity = _rarityBoost(term);
        vote(exact[term], 4.5 * rarity, lexicalChannel: true);

        if (term.length >= 4 && term.length <= 28) {
          for (final deletion in _deleteKeys(term).take(24)) {
            vote(
              deletes[deletion],
              1.05 * rarity,
              lexicalChannel: true,
              hardLimit: 160,
            );
          }
        }

        if (term.length >= 6) {
          final prefix = _resolverPrefix(term);
          final prefixPosting = prefixes[prefix];
          if (prefixPosting != null && prefixPosting.length <= 96) {
            vote(
              prefixPosting,
              .72 * rarity,
              lexicalChannel: true,
              hardLimit: 96,
            );
          }

          // A rare-trigram cascade recovers two-character OCR damage without a
          // quadratic scan or a huge two-deletion dictionary. Inspect the rarest
          // postings first, mirroring search-engine candidate pruning.
          final postings = _resolverTrigrams(term)
              .map((gram) => (gram: gram, ids: trigrams[gram]))
              .where((item) => item.ids != null && item.ids!.isNotEmpty)
              .toList(growable: false)
            ..sort((a, b) {
              final bySize = a.ids!.length.compareTo(b.ids!.length);
              return bySize != 0 ? bySize : a.gram.compareTo(b.gram);
            });
          for (final posting in postings.take(8)) {
            final selectivity =
                (1.0 / sqrt(max(1, posting.ids!.length))).clamp(.08, .55);
            vote(
              posting.ids,
              (.45 + selectivity) * rarity,
              lexicalChannel: true,
              hardLimit: 128,
            );
          }
        }
      }
    }

    if (votes.isEmpty) return const <CanonicalMedicineProduct>[];
    final ranked = votes.entries.toList(growable: false)
      ..sort((a, b) {
        // A candidate supported by independent lexical clues gets a small,
        // bounded corroboration lift. Repeated noisy grams cannot dominate.
        final aScore = a.value + min(2.4, (lexicalChannels[a.key] ?? 0) * .12);
        final bScore = b.value + min(2.4, (lexicalChannels[b.key] ?? 0) * .12);
        final score = bScore.compareTo(aScore);
        return score != 0 ? score : a.key.compareTo(b.key);
      });
    return ranked
        .take(_maxRetrievedProducts)
        .map((entry) => products[entry.key])
        .toList(growable: false);
  }
}

'''
    text = replace_between(text, 'class _ProductIndex {', 'Set<String> _productTerms(', product_index)

    term_logic = r'''Set<String> _productTerms(CanonicalMedicineProduct product) {
  final result = <String>{};

  void add(String value) {
    final normalized = searchText(value);
    if (normalized.isEmpty) return;
    final tokens = normalized
        .split(' ')
        .where((value) => value.length >= 2 && !_resolverNoise.contains(value))
        .take(24)
        .toList(growable: false);
    for (final token in tokens) {
      if (token.length < 3) continue;
      result.add(token);
      result.add(_ocrFoldToken(token));
    }
    // Phrase shingles preserve product identity such as "montek lc" while
    // avoiding full-document fuzzy comparison.
    for (var width = 2; width <= min(3, tokens.length); width++) {
      for (var start = 0; start + width <= tokens.length; start++) {
        final phrase = tokens.sublist(start, start + width).join('');
        if (phrase.length >= 4 && phrase.length <= 28) {
          result.add(phrase);
          result.add(_ocrFoldToken(phrase));
        }
      }
    }
    final compact = normalized.replaceAll(' ', '');
    if (compact.length >= 4 && compact.length <= 28) {
      result.add(compact);
      result.add(_ocrFoldToken(compact));
    }
  }

  add(product.displayName);
  add(product.brand);
  add(product.salt);
  add(product.manufacturer);
  for (final value in product.aliases.take(24)) add(value);
  for (final value in product.ocrAliases.take(24)) add(value);
  return result.where((value) => value.length >= 3).toSet();
}

Set<String> _queryTerms(
  MedicineScanDraft draft,
  List<MedicineFrameEvidence> frames,
) {
  final result = <String>{};

  void add(String raw, {bool phrases = true}) {
    final normalized = searchText(raw);
    if (normalized.isEmpty) return;
    final tokens = normalized
        .split(' ')
        .where((value) => value.isNotEmpty)
        .take(24)
        .toList(growable: false);
    for (final token in tokens) {
      if (token.length >= 3 && !_resolverNoise.contains(token)) {
        result.add(token);
        result.add(_ocrFoldToken(token));
      }
    }
    if (phrases) {
      final useful = tokens
          .where((value) => value.length >= 2 && !_resolverNoise.contains(value))
          .take(10)
          .toList(growable: false);
      for (var width = 2; width <= min(3, useful.length); width++) {
        for (var start = 0; start + width <= useful.length; start++) {
          final phrase = useful.sublist(start, start + width).join('');
          if (phrase.length >= 4 && phrase.length <= 28) {
            result.add(phrase);
            result.add(_ocrFoldToken(phrase));
          }
        }
      }
    }

    // OCR occasionally spaces a brand as D O L O. Join only bounded runs of
    // alphabetic single-character tokens; never fuse arbitrary document text.
    for (var start = 0; start < tokens.length;) {
      if (tokens[start].length != 1 ||
          !RegExp(r'^[a-z]$').hasMatch(tokens[start])) {
        start++;
        continue;
      }
      var end = start;
      final buffer = StringBuffer();
      while (end < tokens.length &&
          tokens[end].length == 1 &&
          RegExp(r'^[a-z]$').hasMatch(tokens[end]) &&
          buffer.length < 16) {
        buffer.write(tokens[end]);
        end++;
      }
      if (buffer.length >= 3) {
        final joined = buffer.toString();
        result.add(joined);
        result.add(_ocrFoldToken(joined));
      }
      start = max(start + 1, end);
    }
  }

  // High-signal structured fields are inserted first because Set iteration
  // order is stable and downstream retrieval is deliberately bounded.
  add(draft.name);
  add(draft.brand);
  add(draft.salt);
  add(draft.manufacturer);
  for (final frame in frames.take(12)) {
    for (final line in frame.text.split(RegExp(r'[\r\n]+')).take(24)) {
      add(line);
      if (result.length >= 160) break;
    }
    if (result.length >= 160) break;
  }
  return result;
}

String _resolverPrefix(String value) {
  final compact = value.replaceAll(' ', '');
  if (compact.length < 6) return '';
  return compact.substring(0, min(5, compact.length));
}

Iterable<String> _resolverTrigrams(String value) sync* {
  final compact = value.replaceAll(' ', '');
  if (compact.length < 3) return;
  final seen = <String>{};
  for (var index = 0; index + 3 <= compact.length; index++) {
    final gram = compact.substring(index, index + 3);
    if (seen.add(gram)) yield gram;
  }
}

'''
    text = replace_between(text, 'Set<String> _productTerms(', 'Iterable<String> _deleteKeys(', term_logic)

    old_decision = r'''    final exactBarcodeLock =
        winner.exactBarcode && winner.product.verified && winner.hardConflicts == 0;
    final calibratedLock =
        winner.product.verified &&
        winner.score >= .86 &&
        winner.channels >= 2 &&
        margin >= .10 &&
        winner.hardConflicts == 0;

    if (exactBarcodeLock || calibratedLock) {
      return _inheritCanonicalIdentity(draft, winner);
    }

    if (runnerUp != null &&
        winner.score >= .72 &&
        runnerUp.score >= .68 &&
        margin < .10) {
      return _markProductAmbiguity(draft, winner.product, runnerUp.product);
    }
    return draft;
'''
    new_decision = r'''    final exactBarcodeLock =
        winner.exactBarcode && winner.product.verified && winner.hardConflicts == 0;
    final evidenceQuality = _resolverDecisionEvidenceQuality(winner, draft);
    final requiredScore = _resolverRequiredLockScore(winner, evidenceQuality);
    final requiredMargin = _resolverRequiredLockMargin(winner, evidenceQuality);
    final calibratedLock =
        winner.product.verified &&
        winner.score >= requiredScore &&
        winner.channels >= 2 &&
        margin >= requiredMargin &&
        winner.hardConflicts == 0;

    if (exactBarcodeLock || calibratedLock) {
      return _inheritCanonicalIdentity(draft, winner);
    }

    // Low-quality evidence requires a wider separation before automation. High
    // quality evidence stays compatible with the historical .10 ambiguity gate.
    final ambiguityMargin = max(.10, requiredMargin);
    if (runnerUp != null &&
        winner.score >= .72 &&
        runnerUp.score >= .68 &&
        margin < ambiguityMargin) {
      return _markProductAmbiguity(draft, winner.product, runnerUp.product);
    }
    return draft;
'''
    if old_decision not in text:
        raise SystemExit('decision block changed; refusing unsafe patch')
    text = text.replace(old_decision, new_decision, 1)

    helpers = r'''double _resolverDecisionEvidenceQuality(
  _ProductHypothesis hypothesis,
  MedicineScanDraft draft,
) {
  final confidences = <double>[];
  for (final key in const <String>['name', 'brand', 'salt', 'strength', 'form']) {
    final field = draft.field(key);
    if (field.isEmpty || field.conflicted) continue;
    confidences.add(field.confidence.clamp(0, 1).toDouble());
  }
  final fieldQuality = confidences.isEmpty
      ? draft.overallConfidence.clamp(0, 1).toDouble()
      : confidences.reduce((a, b) => a + b) / confidences.length;
  final channelQuality = (hypothesis.channels / 4).clamp(0, 1).toDouble();
  return (fieldQuality * .72 + channelQuality * .28).clamp(0, 1).toDouble();
}

double _resolverRequiredLockScore(
  _ProductHypothesis hypothesis,
  double evidenceQuality,
) {
  // Strong independent evidence can decide slightly earlier; weak evidence is
  // deliberately stricter than the previous global .86 threshold.
  final channelRelief = hypothesis.channels >= 3 ? .012 : 0.0;
  return (.915 - evidenceQuality * .055 - channelRelief)
      .clamp(.845, .915)
      .toDouble();
}

double _resolverRequiredLockMargin(
  _ProductHypothesis hypothesis,
  double evidenceQuality,
) {
  final channelRelief = hypothesis.channels >= 3 ? .008 : 0.0;
  return (.145 - evidenceQuality * .05 - channelRelief)
      .clamp(.082, .145)
      .toDouble();
}

'''
    marker = 'bool _sameResolvedProductIdentity('
    pos = text.find(marker)
    if pos < 0:
        raise SystemExit('missing hypothesis helper insertion marker')
    text = text[:pos] + helpers + text[pos:]

    TARGET.write_text(text, encoding='utf-8')
    print('upgraded deterministic offline decision engine')


if __name__ == '__main__':
    main()
