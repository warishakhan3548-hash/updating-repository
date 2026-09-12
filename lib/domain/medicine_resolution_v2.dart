import 'dart:math';

import 'gs1_healthcare.dart';
import 'medicine.dart';
import 'medicine_confusion_firewall.dart';
import 'medicine_date_intelligence.dart';
import 'medicine_semantic_roles.dart';
import 'medicine_understanding.dart';
import 'offline_decision_reliability.dart';
import 'offline_evidence_graph.dart';
import 'regulatory_medicine_code.dart';
import 'search.dart';
import 'spatial_traceability.dart';

const int maxCanonicalMedicineCandidates = 96;
const double _resolverMinimumDecisionMass = .50;

/// Versioned identity-only product knowledge. Physical lot/stock facts are
/// deliberately excluded: MFG/EXP/batch/quantity/cost/location must come from
/// the scanned pack or pharmacist-reviewed inventory, never from a catalogue.
class CanonicalMedicineProduct {
  const CanonicalMedicineProduct({
    required this.productId,
    required this.revision,
    required this.brand,
    required this.salt,
    required this.strength,
    required this.form,
    this.name = '',
    this.manufacturer = '',
    this.aliases = const <String>[],
    this.ocrAliases = const <String>[],
    this.barcodes = const <String>[],
    this.source = 'master',
    this.verified = false,
    this.priorWeight = 0,
    this.status = 'active',
  });

  final String productId;
  final int revision;
  final String name;
  final String brand;
  final String salt;
  final String strength;
  final String form;
  final String manufacturer;
  final List<String> aliases;
  final List<String> ocrAliases;
  final List<String> barcodes;
  final String source;
  final bool verified;
  final double priorWeight;
  final String status;

  bool get active => status == 'active';

  String get displayName => name.trim().isNotEmpty ? name.trim() : brand.trim();

  String get fingerprint => <String>[
    searchText(displayName),
    searchText(brand),
    searchText(salt),
    _strengthIdentity(strength),
    normalizeForm(form).toLowerCase(),
    searchText(manufacturer),
  ].join('|');

  MedicineKnowledgeEntry get knowledgeEntry => MedicineKnowledgeEntry(
    name: displayName,
    brand: brand,
    salt: salt,
    strength: strength,
    form: form,
    manufacturer: manufacturer,
    barcode: barcodes.isEmpty ? '' : barcodes.first,
  );

  Map<String, Object?> toMessage() => <String, Object?>{
    'productId': productId,
    'revision': revision,
    'name': name,
    'brand': brand,
    'salt': salt,
    'strength': strength,
    'form': form,
    'manufacturer': manufacturer,
    'aliases': aliases.take(24).toList(growable: false),
    'ocrAliases': ocrAliases.take(24).toList(growable: false),
    'barcodes': barcodes.take(12).toList(growable: false),
    'source': source,
    'verified': verified,
    'priorWeight': priorWeight.clamp(0, 1),
    'status': status,
  };

  factory CanonicalMedicineProduct.fromMessage(Map<Object?, Object?> map) {
    String text(String key, {int maxLength = 300}) {
      final raw = map[key];
      if (raw is! String) return '';
      final value = raw.trim();
      return value.length <= maxLength ? value : value.substring(0, maxLength);
    }

    List<String> strings(String key, int limit) {
      final raw = map[key];
      if (raw is! List) return const <String>[];
      final result = <String>[];
      final seen = <String>{};
      for (final value in raw.whereType<String>().take(limit * 2)) {
        final clean = value.trim();
        if (clean.isEmpty || clean.length > 160) continue;
        final normalized = searchText(clean);
        if (normalized.isEmpty || !seen.add(normalized)) continue;
        result.add(clean);
        if (result.length >= limit) break;
      }
      return List<String>.unmodifiable(result);
    }

    final rawRevision = map['revision'];
    final rawPrior = map['priorWeight'];
    final source = text('source', maxLength: 40);
    final status = text('status', maxLength: 24);
    return CanonicalMedicineProduct(
      productId: text('productId', maxLength: 96),
      revision: rawRevision is int ? max(0, rawRevision) : 0,
      name: text('name'),
      brand: text('brand'),
      salt: text('salt'),
      strength: text('strength'),
      form: text('form'),
      manufacturer: text('manufacturer'),
      aliases: strings('aliases', 24),
      ocrAliases: strings('ocrAliases', 24),
      barcodes: strings('barcodes', 12),
      source: source.isEmpty ? 'master' : source,
      verified: map['verified'] == true,
      priorWeight: rawPrior is num
          ? rawPrior.toDouble().clamp(0, 1).toDouble()
          : 0,
      status: status.isEmpty ? 'active' : status,
    );
  }
}

/// One-compute entry point used by the Android intake queue. The existing
/// deterministic extractor remains the evidence parser; V2 then resolves a
/// coherent product hypothesis before allowing canonical identity facts to
/// replace field-by-field guesses.
Map<String, Object?> understandMedicineEvidenceV2Message(
  Map<String, Object?> message,
) {
  final rawEvidence = message['evidence'];
  final evidence = rawEvidence is List
      ? rawEvidence
            .whereType<Map>()
            .map(
              (value) => MedicineFrameEvidence.fromMessage(
                Map<Object?, Object?>.from(value),
              ),
            )
            .take(maxMedicineEvidenceFrames)
            .toList(growable: false)
      : const <MedicineFrameEvidence>[];

  final rawKnowledge = message['knowledge'];
  final localKnowledge = rawKnowledge is List
      ? rawKnowledge
            .whereType<Map>()
            .map(
              (value) => MedicineKnowledgeEntry.fromMessage(
                Map<Object?, Object?>.from(value),
              ),
            )
            .take(maxMedicineKnowledgeEntries)
            .toList(growable: false)
      : const <MedicineKnowledgeEntry>[];

  final rawCatalog = message['catalog'];
  final catalogue = rawCatalog is List
      ? rawCatalog
            .whereType<Map>()
            .map(
              (value) => CanonicalMedicineProduct.fromMessage(
                Map<Object?, Object?>.from(value),
              ),
            )
            .where(
              (value) =>
                  value.active &&
                  value.productId.isNotEmpty &&
                  value.displayName.isNotEmpty,
            )
            .take(maxCanonicalMedicineCandidates)
            .toList(growable: false)
      : const <CanonicalMedicineProduct>[];

  // Preserve the physical pack's observed fields before product resolution.
  // Canonical catalogue facts must never enter the field-by-field extractor,
  // otherwise a candidate can rewrite contradictory OCR (for example 500 mg)
  // to its own canonical strength (650 mg) before the product-level conflict
  // engine has a chance to reject the impossible hybrid. Shop-reviewed local
  // knowledge remains safe recognition memory; Tier-2 catalogue data is used
  // only by the coherent ProductHypothesis resolver below.
  final baseMessage = <String, Object?>{
    ...message,
    'knowledge': localKnowledge
        .take(maxMedicineKnowledgeEntries)
        .map((value) => value.toMessage())
        .toList(growable: false),
  };
  final baseline = MedicineUnderstandingResult.fromMessage(
    understandMedicineEvidenceMessage(baseMessage),
  );

  return MedicineProductResolverV2(
    localKnowledge: localKnowledge,
    catalogue: catalogue,
  ).reconcile(baseline, evidence).toMessage();
}

class MedicineProductResolverV2 {
  MedicineProductResolverV2({
    required Iterable<MedicineKnowledgeEntry> localKnowledge,
    required Iterable<CanonicalMedicineProduct> catalogue,
  }) : _index = _ProductIndex(<CanonicalMedicineProduct>[
         ..._collapseLocalKnowledge(localKnowledge),
         ...catalogue.where((value) => value.active),
       ]);

  final _ProductIndex _index;

  MedicineUnderstandingResult reconcile(
    MedicineUnderstandingResult baseline,
    List<MedicineFrameEvidence> evidence,
  ) {
    if (baseline.drafts.isEmpty) return baseline;
    final bySequence = <int, MedicineFrameEvidence>{
      for (final frame in evidence) frame.sequence: frame,
    };
    final drafts = <MedicineScanDraft>[];
    for (final draft in baseline.drafts) {
      final frames = draft.frameSequences
          .map((sequence) => bySequence[sequence])
          .whereType<MedicineFrameEvidence>()
          .toList(growable: false);
      final spatialSafe = _applySpatialTraceability(draft, frames);
      final regulatorySafe = _applyRegulatoryTraceability(spatialSafe, frames);
      final temporalSafe = _applyDateIntelligence(regulatorySafe, frames);
      final semanticSafe = _applySemanticMedicineRoles(temporalSafe, frames);
      drafts.add(_resolveProduct(semanticSafe, frames));
    }
    return MedicineUnderstandingResult(
      drafts: List<MedicineScanDraft>.unmodifiable(drafts),
      ignoredFrames: baseline.ignoredFrames,
    );
  }

  MedicineScanDraft _resolveProduct(
    MedicineScanDraft draft,
    List<MedicineFrameEvidence> frames,
  ) {
    final candidates = _index.candidates(draft, frames);
    if (candidates.isEmpty) return draft;

    final hypotheses =
        candidates
            .map((product) => _scoreProduct(product, draft, frames))
            // A strong candidate carrying a hard contradiction must stay visible
            // even when the contradiction penalty drops its aggregate score below
            // the ordinary retrieval threshold. Otherwise a dangerous mismatch can
            // disappear and leave a deceptively clean field-by-field draft.
            .where(
              (value) =>
                  value.score >= .42 ||
                  (value.hardConflicts > 0 &&
                      (value.exactBarcode || value.strongIdentity)),
            )
            .toList(growable: false)
          ..sort((a, b) {
            final score = b.score.compareTo(a.score);
            if (score != 0) return score;
            final mass = b.decisionMass.compareTo(a.decisionMass);
            if (mass != 0) return mass;
            final channels = b.channels.compareTo(a.channels);
            if (channels != 0) return channels;
            return a.product.productId.compareTo(b.product.productId);
          });
    if (hypotheses.isEmpty) return draft;

    final winner = hypotheses.first;
    _ProductHypothesis? runnerUp;
    for (final candidate in hypotheses.skip(1)) {
      // Tier-1 shop memory and Tier-2 master knowledge may describe the exact
      // same product. They are corroborating sources, not competing products.
      // Only a genuinely different product is allowed to shrink the ambiguity
      // margin or force YELLOW review.
      if (!_sameResolvedProductIdentity(winner.product, candidate.product)) {
        runnerUp = candidate;
        break;
      }
    }
    final margin = runnerUp == null ? 1.0 : winner.score - runnerUp.score;
    final confusion = runnerUp == null
        ? null
        : assessMedicineConfusion(
            MedicineConfusionIdentity(
              name: winner.product.displayName,
              brand: winner.product.brand,
              salt: winner.product.salt,
              strength: winner.product.strength,
              form: winner.product.form,
            ),
            MedicineConfusionIdentity(
              name: runnerUp.product.displayName,
              brand: runnerUp.product.brand,
              salt: runnerUp.product.salt,
              strength: runnerUp.product.strength,
              form: runnerUp.product.form,
            ),
          );

    if (winner.hardConflicts > 0) {
      return _markConflictAgainstProduct(draft, winner.product);
    }

    final exactBarcodeLock =
        winner.exactBarcode &&
        winner.product.verified &&
        winner.hardConflicts == 0;

    // V12 counterfactual gate: a high aggregate winner is not enough when a
    // plausible member of the same medicine family differs on a safety-critical
    // variant field that the scan never actually observed. This is deliberately
    // evaluated at the canonicalization boundary, not during retrieval: search
    // remains recall-friendly, while auto-fill must prove the distinguishing
    // salt/strength/form evidence or abstain. Verified exact barcodes retain
    // their separate highest-authority path.
    final blockingVariant = exactBarcodeLock
        ? null
        : _findUnresolvedCounterfactualVariant(draft, winner, hypotheses);
    final counterfactualSafe = blockingVariant == null;

    final evidenceQuality = _resolverDecisionEvidenceQuality(winner, draft);
    final requiredScore = _resolverRequiredLockScore(winner, evidenceQuality);
    final requiredMargin = _resolverRequiredLockMargin(winner, evidenceQuality);
    final requiredDecisionMass = _resolverRequiredDecisionMass(evidenceQuality);
    final confusionSafe =
        confusion == null ||
        !confusion.highRisk ||
        exactBarcodeLock ||
        _confusionResolvedByEvidence(
          draft,
          winner.product,
          runnerUp!.product,
          confusion,
          winner,
          margin,
        );
    final selectiveReliability = assessOfflineDecisionReliability(
      winnerScore: winner.score,
      margin: margin,
      channels: winner.channels,
      decisionMass: winner.decisionMass,
      evidenceQuality: evidenceQuality,
      verified: winner.product.verified,
      hardConflicts: winner.hardConflicts,
      exactBarcode: exactBarcodeLock,
    );
    final calibratedLock =
        winner.product.verified &&
        winner.score >= requiredScore &&
        winner.channels >= 2 &&
        winner.decisionMass >= requiredDecisionMass &&
        margin >= requiredMargin &&
        winner.hardConflicts == 0 &&
        selectiveReliability.acceptCanonicalLock &&
        confusionSafe &&
        counterfactualSafe;

    if (exactBarcodeLock || calibratedLock) {
      return _inheritCanonicalIdentity(
        draft,
        winner,
        decisionReliability: selectiveReliability.score,
      );
    }

    if (blockingVariant != null) {
      return _markProductAmbiguity(
        draft,
        winner.product,
        blockingVariant.product,
      );
    }

    if (runnerUp != null &&
        confusion != null &&
        confusion.highRisk &&
        !confusionSafe) {
      return _markProductAmbiguity(draft, winner.product, runnerUp.product);
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
  }
}

List<CanonicalMedicineProduct> _collapseLocalKnowledge(
  Iterable<MedicineKnowledgeEntry> source,
) {
  final result = <CanonicalMedicineProduct>[];
  final seen = <String>{};
  var index = 0;
  for (final entry in source.take(maxMedicineKnowledgeEntries)) {
    final name = entry.name.trim().isNotEmpty
        ? entry.name.trim()
        : entry.brand.trim();
    if (name.isEmpty) continue;
    final fingerprint = <String>[
      searchText(name),
      searchText(entry.brand),
      searchText(entry.salt),
      _strengthIdentity(entry.strength),
      normalizeForm(entry.form).toLowerCase(),
      searchText(entry.manufacturer),
    ].join('|');
    if (!seen.add(fingerprint)) continue;
    result.add(
      CanonicalMedicineProduct(
        productId: 'shop:${_stableFingerprint(fingerprint)}',
        revision: 0,
        name: name,
        brand: entry.brand,
        salt: entry.salt,
        strength: entry.strength,
        form: entry.form,
        manufacturer: entry.manufacturer,
        aliases: <String>[
          ...entry.aliases.take(24),
          if (entry.name.trim().isNotEmpty) entry.name.trim(),
          if (entry.brand.trim().isNotEmpty) entry.brand.trim(),
        ],
        ocrAliases: entry.ocrAliases.take(24).toList(growable: false),
        barcodes: <String>[
          if (entry.barcode.trim().isNotEmpty) entry.barcode.trim(),
        ],
        source: 'shop',
        verified: true,
        priorWeight: .12,
      ),
    );
    index++;
    if (index >= maxMedicineKnowledgeEntries) break;
  }
  return result;
}

String _stableFingerprint(String value) {
  var hash = 0x811c9dc5;
  for (final byte in value.codeUnits) {
    hash ^= byte;
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  return hash.toRadixString(16).padLeft(8, '0');
}

// Rarity-aware multi-stage candidate cascade. The resolver deliberately uses
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
          lexicalChannels.update(
            index,
            (value) => value + 1,
            ifAbsent: () => 1,
          );
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

    final queryTerms = _queryTerms(
      draft,
      frames,
    ).take(72).toList(growable: false);
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
          final postings =
              _resolverTrigrams(term)
                  .map((gram) => (gram: gram, ids: trigrams[gram]))
                  .where((item) => item.ids != null && item.ids!.isNotEmpty)
                  .toList(growable: false)
                ..sort((a, b) {
                  final bySize = a.ids!.length.compareTo(b.ids!.length);
                  return bySize != 0 ? bySize : a.gram.compareTo(b.gram);
                });
          for (final posting in postings.take(8)) {
            final selectivity = (1.0 / sqrt(max(1, posting.ids!.length))).clamp(
              .08,
              .55,
            );
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

Set<String> _productTerms(CanonicalMedicineProduct product) {
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
          .where(
            (value) => value.length >= 2 && !_resolverNoise.contains(value),
          )
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

Iterable<String> _deleteKeys(String value) sync* {
  if (value.length < 4 || value.length > 28) return;
  final seen = <String>{};
  for (var index = 0; index < value.length; index++) {
    final deleted = value.substring(0, index) + value.substring(index + 1);
    if (deleted.length >= 3 && seen.add(deleted)) yield deleted;
  }
}

String _ocrFoldToken(String token) {
  final value = token.toLowerCase();
  if (!RegExp(r'\d').hasMatch(value) || !RegExp(r'[a-z]').hasMatch(value)) {
    return value;
  }
  if (RegExp(r'^\d').hasMatch(value)) {
    return value
        .replaceAll('o', '0')
        .replaceAll('i', '1')
        .replaceAll('l', '1')
        .replaceAll('s', '5')
        .replaceAll('b', '8')
        .replaceAll('z', '2');
  }
  return value
      .replaceAll('0', 'o')
      .replaceAll('1', 'i')
      .replaceAll('5', 's')
      .replaceAll('8', 'b');
}

class _IdentityConsensus {
  const _IdentityConsensus({
    required this.score,
    required this.bestRawScore,
    required this.strongSources,
    required this.decisionConfidence,
    required this.graphQuality,
  });

  final double score;
  final double bestRawScore;
  final int strongSources;
  final double decisionConfidence;
  final double graphQuality;
}

_IdentityConsensus _scoreIdentityConsensus(
  MedicineScanDraft draft,
  List<MedicineFrameEvidence> frames,
  Set<String> aliases,
) {
  double bestAgainstAliases(Iterable<String> evidence) {
    var best = 0.0;
    for (final observed in evidence.where((value) => value.trim().isNotEmpty)) {
      for (final alias in aliases.take(32)) {
        best = max(best, _weightedTextSimilarity(observed, alias));
      }
    }
    return best;
  }

  final structuredRaw = bestAgainstAliases(<String>[draft.name, draft.brand]);
  var bestRaw = structuredRaw;
  var structuredScore = structuredRaw;
  if (structuredScore > 0) {
    final confidence = max(
      draft.field('name').confidence,
      draft.field('brand').confidence,
    ).clamp(0, 1).toDouble();
    structuredScore *= .90 + confidence * .10;
  }

  // V8 evidence graph: correlated video frames form one observation component.
  // Only genuinely different views can increase independent-source authority.
  final graph = buildOfflineEvidenceGraph(frames, maxFrames: 12);
  final frameScores = <double>[];
  final strongMatchedQualities = <double>[];
  var strongestMatchedFrameQuality = 0.0;
  var remainingIdentityLines = 32;
  for (final group in graph.groups.take(8)) {
    if (remainingIdentityLines <= 0) break;
    final frame = group.representative;
    final rawLines = frame.text
        .split(RegExp(r'[\r\n]+'))
        .map((value) => value.trim())
        .where((value) => value.isNotEmpty)
        .take(16)
        .toList(growable: false);
    if (rawLines.isEmpty) continue;
    final lines = rawLines
        .take(min(12, remainingIdentityLines))
        .toList(growable: false);
    remainingIdentityLines -= lines.length;
    final raw = bestAgainstAliases(lines);
    bestRaw = max(bestRaw, raw);
    if (raw < .52) continue;
    final quality = frame.quality.clamp(0, 1).toDouble();
    final frameScore = raw * (.90 + quality * .10);
    frameScores.add(frameScore);
    if (frameScore >= .78) {
      strongestMatchedFrameQuality = max(strongestMatchedFrameQuality, quality);
      strongMatchedQualities.add(quality);
    }
  }
  frameScores.sort((a, b) => b.compareTo(a));

  var score = structuredScore;
  if (frameScores.isNotEmpty) score = max(score, frameScores.first);
  final strongFrameScores = frameScores.where((value) => value >= .78).toList();
  if (strongFrameScores.length >= 2) {
    final second = strongFrameScores[1];
    score += ((second - .78) / .22).clamp(0, 1).toDouble() * .025;
  }
  if (strongFrameScores.length >= 3) {
    final third = strongFrameScores[2];
    score += ((third - .78) / .22).clamp(0, 1).toDouble() * .010;
  }

  final structuredStrong = structuredScore >= .78 ? 1 : 0;
  final strongSources = max(structuredStrong, strongFrameScores.length);
  final structuredConfidence = structuredStrong > 0
      ? max(
          draft.field('name').confidence,
          draft.field('brand').confidence,
        ).clamp(0, 1).toDouble()
      : 0.0;
  final decisionConfidence = max(
    structuredConfidence,
    strongestMatchedFrameQuality,
  ).clamp(0, 1).toDouble();
  final averageMatchedQuality = strongMatchedQualities.isEmpty
      ? 0.0
      : strongMatchedQualities.reduce((a, b) => a + b) /
            strongMatchedQualities.length;
  final independentMass = (strongFrameScores.length / 3).clamp(0, 1).toDouble();
  final graphQuality = strongFrameScores.isEmpty
      ? 0.0
      : (independentMass * .65 + averageMatchedQuality * .35)
            .clamp(0, 1)
            .toDouble();
  return _IdentityConsensus(
    score: score.clamp(0, .999).toDouble(),
    bestRawScore: bestRaw.clamp(0, 1).toDouble(),
    strongSources: strongSources,
    decisionConfidence: decisionConfidence,
    graphQuality: graphQuality,
  );
}

class _ProductHypothesis {
  const _ProductHypothesis({
    required this.product,
    required this.score,
    required this.channels,
    required this.decisionMass,
    required this.identitySources,
    required this.identityGraphQuality,
    required this.hardConflicts,
    required this.exactBarcode,
    required this.strongIdentity,
  });

  final CanonicalMedicineProduct product;
  final double score;
  final int channels;
  final double decisionMass;
  final int identitySources;
  final double identityGraphQuality;
  final int hardConflicts;
  final bool exactBarcode;
  final bool strongIdentity;
}

/// Converts parser confidence into decision authority without changing the
/// similarity score used for candidate ordering. Evidence below 0.35 is useful
/// for search/review, but it is too uncertain to authorize canonical auto-fill.
/// Above that floor, authority rises continuously instead of jumping at one
/// binary threshold.
double _resolverEvidenceReliability(double confidence) {
  final value = confidence.clamp(0, 1).toDouble();
  if (value < .35) return 0;
  return (.20 + value * .80).clamp(0, 1).toDouble();
}

/// Similarity gates still establish whether a clue agrees. Once it agrees, this
/// function gives near-threshold matches slightly less authority than exact
/// matches. The narrow 0.90..1.00 range preserves existing high-quality behavior
/// while preventing borderline fuzzy evidence from pretending to be exact.
double _resolverAgreementReliability(double similarity, double threshold) {
  if (similarity < threshold || threshold >= 1) return 0;
  final normalized = ((similarity - threshold) / (1 - threshold))
      .clamp(0, 1)
      .toDouble();
  return (.90 + normalized * .10).clamp(0, 1).toDouble();
}

_ProductHypothesis _scoreProduct(
  CanonicalMedicineProduct product,
  MedicineScanDraft draft,
  List<MedicineFrameEvidence> frames,
) {
  var weighted = 0.0;
  var totalWeight = 0.0;
  var channels = 0;
  var decisionMass = 0.0;
  var hardConflicts = 0;

  final observedBarcodes = <String>{
    _canonicalBarcode(draft.barcode),
    for (final frame in frames)
      for (final barcode in frame.allBarcodes) _canonicalBarcode(barcode),
  }..remove('');
  final productBarcodes = product.barcodes
      .map(_canonicalBarcode)
      .where((value) => value.isNotEmpty)
      .toSet();
  final exactBarcode =
      observedBarcodes.isNotEmpty &&
      productBarcodes.isNotEmpty &&
      observedBarcodes.intersection(productBarcodes).isNotEmpty;
  if (exactBarcode) {
    weighted += .995 * .52;
    totalWeight += .52;
    decisionMass += .52;
    channels++;
  } else {
    // Only verified retail/GTIN identifiers can veto a product. Packs may also
    // contain numeric proprietary Code-128 payloads in standard-looking lengths;
    // those remain exact-match evidence but are not allowed to become hard GTIN
    // contradictions unless the existing GS1 kernel validates the check digit.
    final observedStrong = observedBarcodes
        .where(_isStrongProductBarcodeKey)
        .toSet();
    final productStrong = productBarcodes
        .where(_isStrongProductBarcodeKey)
        .toSet();
    if (observedStrong.isNotEmpty && productStrong.isNotEmpty) {
      hardConflicts++;
    }
  }

  final aliases = <String>{
    product.displayName,
    product.brand,
    ...product.aliases,
    ...product.ocrAliases,
  }..removeWhere((value) => value.trim().isEmpty);
  final identity = _scoreIdentityConsensus(draft, frames, aliases);
  final bestIdentity = identity.score;
  if (bestIdentity >= .52) {
    weighted += bestIdentity * .36;
    totalWeight += .36;
    if (bestIdentity >= .78) {
      channels++;
      final identityAuthority =
          _resolverEvidenceReliability(identity.decisionConfidence) *
          _resolverAgreementReliability(bestIdentity, .78);
      decisionMass += .36 * identityAuthority;
      if (identity.strongSources >= 2) {
        decisionMass += .02 * identityAuthority;
      }
    }
  }
  final nameField = draft.field('name');
  if (!nameField.isEmpty &&
      nameField.confidence >= .86 &&
      identity.bestRawScore < .56) {
    hardConflicts++;
  }

  final salt = _fieldSimilarity(draft, 'salt', product.salt);
  if (salt != null) {
    weighted += salt * .19;
    totalWeight += .19;
    if (salt >= .88) {
      channels++;
      final saltAuthority =
          _resolverEvidenceReliability(draft.field('salt').confidence) *
          _resolverAgreementReliability(salt, .88);
      decisionMass += .19 * saltAuthority;
    }
    if (draft.field('salt').confidence >= .86 && salt < .62) hardConflicts++;
  }

  final observedStrength = draft.strength.trim();
  if (observedStrength.isNotEmpty && product.strength.trim().isNotEmpty) {
    final agrees =
        _strengthIdentity(observedStrength) ==
        _strengthIdentity(product.strength);
    weighted += (agrees ? 1.0 : 0.0) * .18;
    totalWeight += .18;
    if (agrees) {
      channels++;
      final strengthConfidence = draft.field('strength').confidence;
      final baseStrengthAuthority = _resolverEvidenceReliability(
        strengthConfidence,
      );
      // The parser already treats confidence >= .65 as trustworthy enough to
      // hard-veto a contradictory strength. Apply the same trust symmetrically
      // when the normalized strength exactly agrees with the product; otherwise
      // a correct 500 mg clue is paradoxically weaker than an incorrect one.
      final strengthAuthority = strengthConfidence >= .65
          ? max(.92, baseStrengthAuthority)
          : baseStrengthAuthority;
      decisionMass += .18 * strengthAuthority;
    } else if (draft.field('strength').confidence >= .65) {
      // Strength disagreement is a safety signal, not an auto-fill signal.
      // Use a lower threshold than the normal .78 review boundary so a
      // plausible printed dose can never be overwritten by a verified product
      // candidate merely because OCR confidence was slightly degraded.
      hardConflicts++;
    }
  }

  final observedForm = draft.form.trim();
  if (observedForm.isNotEmpty && product.form.trim().isNotEmpty) {
    final agrees = normalizeForm(observedForm) == normalizeForm(product.form);
    weighted += (agrees ? 1.0 : 0.0) * .07;
    totalWeight += .07;
    if (agrees) channels++;
    if (!agrees && draft.field('form').confidence >= .82) hardConflicts++;
  }

  final manufacturer = _fieldSimilarity(
    draft,
    'manufacturer',
    product.manufacturer,
  );
  if (manufacturer != null) {
    weighted += manufacturer * .05;
    totalWeight += .05;
    if (manufacturer >= .90) {
      channels++;
      final manufacturerAuthority =
          _resolverEvidenceReliability(draft.field('manufacturer').confidence) *
          _resolverAgreementReliability(manufacturer, .90);
      decisionMass += .05 * manufacturerAuthority;
    }
    if (draft.field('manufacturer').confidence >= .90 && manufacturer < .58) {
      hardConflicts++;
    }
  }

  var score = totalWeight <= 0 ? 0.0 : weighted / totalWeight;
  final priorCap = product.source == 'shop' ? .035 : .018;
  score += min(priorCap, product.priorWeight * priorCap);
  score -= min(.70, hardConflicts * .28);
  if (!product.verified) score = min(score, .79);
  return _ProductHypothesis(
    product: product,
    score: score.clamp(0, .999).toDouble(),
    channels: channels,
    decisionMass: decisionMass.clamp(0, 1).toDouble(),
    identitySources: identity.strongSources,
    identityGraphQuality: identity.graphQuality,
    hardConflicts: hardConflicts,
    exactBarcode: exactBarcode,
    strongIdentity: bestIdentity >= .82,
  );
}

double _resolverDecisionEvidenceQuality(
  _ProductHypothesis hypothesis,
  MedicineScanDraft draft,
) {
  final confidences = <double>[];
  for (final key in const <String>[
    'name',
    'brand',
    'salt',
    'strength',
    'form',
  ]) {
    final field = draft.field(key);
    if (field.isEmpty || field.conflicted) continue;
    confidences.add(field.confidence.clamp(0, 1).toDouble());
  }
  final fieldQuality = confidences.isEmpty
      ? draft.overallConfidence.clamp(0, 1).toDouble()
      : confidences.reduce((a, b) => a + b) / confidences.length;
  final channelQuality = (hypothesis.channels / 4).clamp(0, 1).toDouble();
  final massQuality = (hypothesis.decisionMass / .72).clamp(0, 1).toDouble();
  final sourceQuality = (hypothesis.identitySources / 3).clamp(0, 1).toDouble();
  return (fieldQuality * .58 +
          channelQuality * .18 +
          massQuality * .14 +
          sourceQuality * .04 +
          hypothesis.identityGraphQuality * .06)
      .clamp(0, 1)
      .toDouble();
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

/// V6 keeps the historical 0.50 authority target as its center, but avoids a
/// discontinuity where confidence-calibrated evidence can become safer yet miss
/// automation by only a few thousandths. High-quality coherent evidence may
/// lower the gate by at most 0.025; poor evidence raises it by at most 0.015.
/// Identity-only or identity+form hypotheses remain far below this range.
double _resolverRequiredDecisionMass(double evidenceQuality) {
  return (_resolverMinimumDecisionMass + .015 - evidenceQuality * .045)
      .clamp(.475, .515)
      .toDouble();
}

bool _confusionResolvedByEvidence(
  MedicineScanDraft draft,
  CanonicalMedicineProduct winner,
  CanonicalMedicineProduct alternative,
  MedicineConfusionAssessment assessment,
  _ProductHypothesis hypothesis,
  double margin,
) {
  if (assessment.criticalFields.isEmpty ||
      margin < .10 ||
      hypothesis.channels < 3 ||
      hypothesis.decisionMass < .52) {
    return false;
  }

  var confirmations = 0;
  for (final field in assessment.criticalFields) {
    final observed = draft.field(field);
    if (observed.isEmpty || observed.conflicted) continue;
    final minimumConfidence = field == 'strength' ? .65 : .78;
    if (observed.confidence < minimumConfidence) continue;

    bool winnerMatch;
    bool alternativeMatch;
    if (field == 'strength') {
      final key = _strengthIdentity(observed.value);
      winnerMatch = key.isNotEmpty && key == _strengthIdentity(winner.strength);
      alternativeMatch =
          key.isNotEmpty && key == _strengthIdentity(alternative.strength);
    } else if (field == 'form') {
      final key = normalizeForm(observed.value);
      winnerMatch = key.isNotEmpty && key == normalizeForm(winner.form);
      alternativeMatch =
          key.isNotEmpty && key == normalizeForm(alternative.form);
    } else {
      winnerMatch = _weightedTextSimilarity(observed.value, winner.salt) >= .88;
      alternativeMatch =
          _weightedTextSimilarity(observed.value, alternative.salt) >= .88;
    }
    if (alternativeMatch && !winnerMatch) return false;
    if (winnerMatch && !alternativeMatch) confirmations++;
  }

  final required =
      assessment.riskScore >= .88 && assessment.criticalFields.length >= 2
      ? 2
      : 1;
  return confirmations >= min(required, assessment.criticalFields.length);
}

/// Returns the strongest plausible same-family variant that the observed pack
/// evidence has not yet distinguished from [winner]. A null result means either
/// there is no material variant competitor or at least one reliable critical
/// field proves the winner over every plausible variant inspected.
///
/// Work is intentionally bounded to seven post-winner hypotheses. Candidate
/// retrieval already caps the resolver set; this additional gate therefore adds
/// constant, allocation-light work at the final decision boundary instead of a
/// second search pass.
_ProductHypothesis? _findUnresolvedCounterfactualVariant(
  MedicineScanDraft draft,
  _ProductHypothesis winner,
  List<_ProductHypothesis> hypotheses,
) {
  var inspected = 0;
  for (final candidate in hypotheses.skip(1)) {
    if (inspected >= 7) break;
    inspected++;

    if (!candidate.product.verified || candidate.hardConflicts > 0) continue;
    if (_sameResolvedProductIdentity(winner.product, candidate.product)) {
      continue;
    }

    // Only a realistically reachable alternative may block automation. The
    // bounded score window protects recall for true variants without letting a
    // remote catalogue neighbour turn every confident result into REVIEW.
    final plausibleFloor = max(.60, winner.score - .24);
    if (!candidate.strongIdentity && candidate.score < plausibleFloor) continue;

    final identitySimilarity = _counterfactualIdentitySimilarity(
      winner.product,
      candidate.product,
    );
    if (identitySimilarity < .76) continue;

    final saltDiffers = _criticalTextVariantDiffers(
      winner.product.salt,
      candidate.product.salt,
      sameThreshold: .92,
    );
    final strengthDiffers = _criticalStrengthVariantDiffers(
      winner.product.strength,
      candidate.product.strength,
    );
    final formDiffers = _criticalFormVariantDiffers(
      winner.product.form,
      candidate.product.form,
    );
    if (!saltDiffers && !strengthDiffers && !formDiffers) continue;

    var distinguished = false;
    if (saltDiffers &&
        _observedTextDiscriminatorSupportsWinner(
          draft.field('salt'),
          winner.product.salt,
          candidate.product.salt,
          minimumConfidence: .78,
          winnerThreshold: .88,
          alternativeCeiling: .82,
        )) {
      distinguished = true;
    }
    if (strengthDiffers &&
        _observedStrengthDiscriminatorSupportsWinner(
          draft.field('strength'),
          winner.product.strength,
          candidate.product.strength,
        )) {
      distinguished = true;
    }
    if (formDiffers &&
        _observedFormDiscriminatorSupportsWinner(
          draft.field('form'),
          winner.product.form,
          candidate.product.form,
        )) {
      distinguished = true;
    }

    if (!distinguished) return candidate;
  }
  return null;
}

double _counterfactualIdentitySimilarity(
  CanonicalMedicineProduct left,
  CanonicalMedicineProduct right,
) {
  var best = 0.0;
  for (final pair in <(String, String)>[
    (left.displayName, right.displayName),
    (left.displayName, right.brand),
    (left.brand, right.displayName),
    (left.brand, right.brand),
  ]) {
    if (pair.$1.trim().isEmpty || pair.$2.trim().isEmpty) continue;
    best = max(best, _weightedTextSimilarity(pair.$1, pair.$2));
  }
  return best.clamp(0, 1).toDouble();
}

bool _criticalTextVariantDiffers(
  String left,
  String right, {
  required double sameThreshold,
}) {
  if (left.trim().isEmpty || right.trim().isEmpty) return false;
  return _weightedTextSimilarity(left, right) < sameThreshold;
}

bool _criticalStrengthVariantDiffers(String left, String right) {
  final a = _strengthIdentity(left);
  final b = _strengthIdentity(right);
  return a.isNotEmpty && b.isNotEmpty && a != b;
}

bool _criticalFormVariantDiffers(String left, String right) {
  final a = normalizeForm(left);
  final b = normalizeForm(right);
  return a.isNotEmpty && b.isNotEmpty && a != b;
}

bool _observedTextDiscriminatorSupportsWinner(
  ExtractedMedicineField observed,
  String winner,
  String alternative, {
  required double minimumConfidence,
  required double winnerThreshold,
  required double alternativeCeiling,
}) {
  if (observed.isEmpty ||
      observed.conflicted ||
      observed.confidence < minimumConfidence) {
    return false;
  }
  final winnerScore = _weightedTextSimilarity(observed.value, winner);
  final alternativeScore = _weightedTextSimilarity(observed.value, alternative);
  return winnerScore >= winnerThreshold &&
      alternativeScore < alternativeCeiling &&
      winnerScore - alternativeScore >= .08;
}

bool _observedStrengthDiscriminatorSupportsWinner(
  ExtractedMedicineField observed,
  String winner,
  String alternative,
) {
  if (observed.isEmpty || observed.conflicted || observed.confidence < .65) {
    return false;
  }
  final key = _strengthIdentity(observed.value);
  return key.isNotEmpty &&
      key == _strengthIdentity(winner) &&
      key != _strengthIdentity(alternative);
}

bool _observedFormDiscriminatorSupportsWinner(
  ExtractedMedicineField observed,
  String winner,
  String alternative,
) {
  if (observed.isEmpty || observed.conflicted || observed.confidence < .82) {
    return false;
  }
  final key = normalizeForm(observed.value);
  return key.isNotEmpty &&
      key == normalizeForm(winner) &&
      key != normalizeForm(alternative);
}

bool _sameResolvedProductIdentity(
  CanonicalMedicineProduct left,
  CanonicalMedicineProduct right,
) {
  final leftStrength = left.strength.trim();
  final rightStrength = right.strength.trim();
  if (leftStrength.isEmpty || rightStrength.isEmpty) return false;
  if (_strengthIdentity(leftStrength) != _strengthIdentity(rightStrength)) {
    return false;
  }

  final leftForm = normalizeForm(left.form);
  final rightForm = normalizeForm(right.form);
  if (leftForm.isEmpty || rightForm.isEmpty || leftForm != rightForm) {
    return false;
  }

  final names = <double>[
    _weightedTextSimilarity(left.displayName, right.displayName),
    _weightedTextSimilarity(left.displayName, right.brand),
    _weightedTextSimilarity(left.brand, right.displayName),
    _weightedTextSimilarity(left.brand, right.brand),
  ];
  if (names.reduce(max) < .94) return false;

  final leftSalt = left.salt.trim();
  final rightSalt = right.salt.trim();
  if (leftSalt.isNotEmpty &&
      rightSalt.isNotEmpty &&
      _weightedTextSimilarity(leftSalt, rightSalt) < .90) {
    return false;
  }
  return true;
}

double? _fieldSimilarity(
  MedicineScanDraft draft,
  String field,
  String canonical,
) {
  final observed = draft.field(field).value.trim();
  if (observed.isEmpty || canonical.trim().isEmpty) return null;
  return _weightedTextSimilarity(observed, canonical);
}

MedicineScanDraft _inheritCanonicalIdentity(
  MedicineScanDraft draft,
  _ProductHypothesis hypothesis, {
  required double decisionReliability,
}) {
  final product = hypothesis.product;
  final fields = Map<String, ExtractedMedicineField>.of(draft.fields);
  final reliabilityCap =
      (.80 + decisionReliability.clamp(0, 1).toDouble() * .19)
          .clamp(.82, .99)
          .toDouble();
  final confidence = hypothesis.exactBarcode
      ? .995
      : min(hypothesis.score, reliabilityCap).clamp(.82, .99).toDouble();
  final support = max(1, hypothesis.channels);

  void inherit(String key, String value) {
    final clean = value.trim();
    if (clean.isEmpty) return;
    final current = fields[key];
    if (current != null && current.conflicted) return;
    fields[key] = ExtractedMedicineField(
      value: clean,
      confidence: max(current?.confidence ?? 0, confidence),
      support: max(current?.support ?? 0, support),
      conflicted: false,
    );
  }

  inherit('name', product.displayName);
  inherit('brand', product.brand.isEmpty ? product.displayName : product.brand);
  inherit('salt', product.salt);
  inherit('strength', product.strength);
  inherit('form', product.form);
  inherit('manufacturer', product.manufacturer);

  final identityConfidence =
      <String>['name', 'brand', 'salt', 'strength', 'form']
          .map((key) => fields[key])
          .whereType<ExtractedMedicineField>()
          .where((value) => !value.isEmpty)
          .map((value) => value.confidence)
          .toList(growable: false);
  final overall = identityConfidence.isEmpty
      ? draft.overallConfidence
      : identityConfidence.reduce(min).clamp(0, 1).toDouble();
  return _copyDraft(
    draft,
    fields: fields,
    overallConfidence: max(draft.overallConfidence, overall),
  );
}

MedicineScanDraft _markConflictAgainstProduct(
  MedicineScanDraft draft,
  CanonicalMedicineProduct product,
) {
  final fields = Map<String, ExtractedMedicineField>.of(draft.fields);
  void markIfDifferent(String key, String canonical) {
    final field = fields[key];
    if (field == null || field.isEmpty || canonical.trim().isEmpty) return;
    final same = key == 'strength'
        ? _strengthIdentity(field.value) == _strengthIdentity(canonical)
        : key == 'form'
        ? normalizeForm(field.value) == normalizeForm(canonical)
        : _weightedTextSimilarity(field.value, canonical) >= .78;
    if (same) return;
    fields[key] = ExtractedMedicineField(
      value: field.value,
      confidence: field.confidence * .78,
      support: field.support,
      conflicted: true,
    );
  }

  markIfDifferent('name', product.displayName);
  markIfDifferent('brand', product.brand);
  markIfDifferent('salt', product.salt);
  markIfDifferent('strength', product.strength);
  markIfDifferent('form', product.form);
  markIfDifferent('manufacturer', product.manufacturer);
  return _copyDraft(
    draft,
    fields: fields,
    overallConfidence: min(draft.overallConfidence, .77),
  );
}

MedicineScanDraft _markProductAmbiguity(
  MedicineScanDraft draft,
  CanonicalMedicineProduct first,
  CanonicalMedicineProduct second,
) {
  final fields = Map<String, ExtractedMedicineField>.of(draft.fields);
  final canonical = <String, (String, String)>{
    'name': (first.displayName, second.displayName),
    'brand': (first.brand, second.brand),
    'salt': (first.salt, second.salt),
    'strength': (first.strength, second.strength),
    'form': (first.form, second.form),
    'manufacturer': (first.manufacturer, second.manufacturer),
  };
  for (final entry in canonical.entries) {
    final field = fields[entry.key];
    if (field == null || field.isEmpty) continue;
    final left = entry.value.$1;
    final right = entry.value.$2;
    if (left.trim().isEmpty || right.trim().isEmpty) continue;
    final same = entry.key == 'strength'
        ? _strengthIdentity(left) == _strengthIdentity(right)
        : entry.key == 'form'
        ? normalizeForm(left) == normalizeForm(right)
        : _weightedTextSimilarity(left, right) >= .94;
    if (same) continue;
    fields[entry.key] = ExtractedMedicineField(
      value: field.value,
      confidence: field.confidence * .82,
      support: field.support,
      conflicted: true,
    );
  }
  return _copyDraft(
    draft,
    fields: fields,
    overallConfidence: min(draft.overallConfidence, .77),
  );
}

MedicineScanDraft _applySemanticMedicineRoles(
  MedicineScanDraft draft,
  List<MedicineFrameEvidence> frames,
) {
  final semantic = inferMedicineSemanticRoles(frames);
  if (semantic.isEmpty) return draft;
  final fields = Map<String, ExtractedMedicineField>.of(draft.fields);

  bool sameValue(String key, String left, String right) {
    if (left.trim().isEmpty || right.trim().isEmpty) return false;
    if (key == 'strength') {
      return _strengthIdentity(left) == _strengthIdentity(right);
    }
    return _weightedTextSimilarity(left, right) >= .91;
  }

  void apply(
    String key,
    String value,
    double confidence, {
    double minimum = .82,
  }) {
    final clean = value.trim();
    if (clean.isEmpty || confidence < minimum) return;
    final current = fields[key];
    if (current != null &&
        !current.isEmpty &&
        sameValue(key, current.value, clean)) {
      fields[key] = ExtractedMedicineField(
        value: current.value,
        confidence: max(current.confidence, confidence),
        support: max(current.support, 1),
        conflicted: current.conflicted,
      );
      return;
    }
    if (current != null && !current.isEmpty && current.confidence >= .88) {
      fields[key] = ExtractedMedicineField(
        value: current.value,
        confidence: min(current.confidence, .84),
        support: max(current.support, 1),
        conflicted: true,
      );
      return;
    }
    if (current == null || current.isEmpty || current.confidence < .78) {
      fields[key] = ExtractedMedicineField(
        value: clean,
        confidence: confidence.clamp(minimum, .97).toDouble(),
        support: max(current?.support ?? 0, 1),
        conflicted: false,
      );
    }
  }

  apply('salt', semantic.salt, semantic.compositionConfidence, minimum: .80);
  if (semantic.strength.trim().isNotEmpty &&
      semantic.components.every((component) => component.strength.isNotEmpty)) {
    apply(
      'strength',
      semantic.strength,
      semantic.compositionConfidence,
      minimum: .82,
    );
  }

  if (!semantic.conflicted &&
      semantic.brand.trim().isNotEmpty &&
      semantic.brandConfidence >= .82) {
    apply('brand', semantic.brand, semantic.brandConfidence, minimum: .82);
    final name = fields['name'];
    final salt = fields['salt']?.value ?? semantic.salt;
    final nameLooksGeneric =
        name != null &&
        !name.isEmpty &&
        salt.trim().isNotEmpty &&
        _weightedTextSimilarity(name.value, salt) >= .88;
    if (name == null ||
        name.isEmpty ||
        name.confidence < .76 ||
        nameLooksGeneric) {
      fields['name'] = ExtractedMedicineField(
        value: semantic.brand,
        confidence: semantic.brandConfidence.clamp(.82, .97).toDouble(),
        support: max(name?.support ?? 0, 1),
        conflicted: false,
      );
    }
  } else if (semantic.genericOnly &&
      semantic.genericName.trim().isNotEmpty &&
      semantic.genericConfidence >= .86) {
    final name = fields['name'];
    if (name == null || name.isEmpty || name.confidence < .76) {
      fields['name'] = ExtractedMedicineField(
        value: semantic.genericName,
        confidence: semantic.genericConfidence.clamp(.86, .96).toDouble(),
        support: max(name?.support ?? 0, 1),
        conflicted: false,
      );
    }
    final brand = fields['brand'];
    final salt = fields['salt']?.value ?? semantic.salt;
    if (brand != null &&
        !brand.isEmpty &&
        salt.trim().isNotEmpty &&
        _weightedTextSimilarity(brand.value, salt) >= .90 &&
        brand.confidence < .92) {
      // The legacy parser intentionally mirrored a confident Name into Brand.
      // Once composition proves this is a generic-only pack, remove that weak
      // synthetic brand instead of persisting a false trade-name distinction.
      fields.remove('brand');
    }
  }

  if (semantic.conflicted) {
    for (final key in const <String>['name', 'brand', 'salt', 'strength']) {
      final field = fields[key];
      if (field == null || field.isEmpty || field.confidence < .78) continue;
      fields[key] = ExtractedMedicineField(
        value: field.value,
        confidence: min(field.confidence, .82),
        support: field.support,
        conflicted: true,
      );
    }
  }

  return _copyDraft(
    draft,
    fields: fields,
    overallConfidence: semantic.conflicted
        ? min(draft.overallConfidence, .77)
        : draft.overallConfidence,
  );
}

MedicineScanDraft _applyDateIntelligence(
  MedicineScanDraft draft,
  List<MedicineFrameEvidence> frames,
) {
  final intelligence = inferMedicineDateIntelligence(
    frames: frames,
    referenceDate: DateTime.now(),
    existingMfg: draft.mfg,
    existingExpiry: draft.expiry,
    existingMfgConfidence: draft.field('mfg').confidence,
    existingExpiryConfidence: draft.field('expiry').confidence,
  );
  if (intelligence.isEmpty) return draft;

  final fields = Map<String, ExtractedMedicineField>.of(draft.fields);

  void apply(String key, MedicineDateEvidence? suggestion) {
    if (suggestion == null || suggestion.confidence < .78) return;
    final current = fields[key];
    final currentDate = current == null
        ? null
        : parseMedicineDateText(current.value);
    final same = currentDate?.value == suggestion.date.value;
    if (same) {
      fields[key] = ExtractedMedicineField(
        value: suggestion.date.value,
        confidence: max(current?.confidence ?? 0, suggestion.confidence),
        support: max(current?.support ?? 0, suggestion.support),
        conflicted: current?.conflicted == true,
      );
      return;
    }

    if (current != null && !current.isEmpty && current.confidence >= .86) {
      fields[key] = ExtractedMedicineField(
        value: current.value,
        confidence: min(current.confidence, .84),
        support: max(current.support, suggestion.support),
        conflicted: true,
      );
      return;
    }

    fields[key] = ExtractedMedicineField(
      value: suggestion.date.value,
      confidence: suggestion.confidence.clamp(.78, .96).toDouble(),
      support: max(current?.support ?? 0, suggestion.support),
      conflicted: false,
    );
  }

  apply('mfg', intelligence.manufacturing);
  apply('expiry', intelligence.expiry);

  if (intelligence.conflicted) {
    for (final key in const <String>['mfg', 'expiry']) {
      final field = fields[key];
      if (field == null || field.isEmpty) continue;
      fields[key] = ExtractedMedicineField(
        value: field.value,
        confidence: min(field.confidence, .80),
        support: field.support,
        conflicted: true,
      );
    }
  }

  return _copyDraft(
    draft,
    fields: fields,
    overallConfidence: intelligence.conflicted
        ? min(draft.overallConfidence, .77)
        : draft.overallConfidence,
  );
}

MedicineScanDraft _applySpatialTraceability(
  MedicineScanDraft draft,
  List<MedicineFrameEvidence> frames,
) {
  final hints = inferSpatialTraceability(frames);
  if (hints.isEmpty) return draft;
  final fields = Map<String, ExtractedMedicineField>.of(draft.fields);

  void apply(String key, SpatialTraceabilityField? hint) {
    if (hint == null || hint.value.trim().isEmpty || hint.confidence < .80) {
      return;
    }
    final current = fields[key];
    final currentIdentity = current == null
        ? ''
        : _fieldIdentity(key, current.value);
    final hintIdentity = _fieldIdentity(key, hint.value);
    final strongConflict =
        current != null &&
        !current.isEmpty &&
        current.confidence >= .90 &&
        currentIdentity.isNotEmpty &&
        hintIdentity.isNotEmpty &&
        currentIdentity != hintIdentity;
    if (strongConflict) {
      fields[key] = ExtractedMedicineField(
        value: current.value,
        confidence: min(current.confidence, .84),
        support: max(current.support, hint.support),
        conflicted: true,
      );
      return;
    }
    if (hint.conflicted) {
      fields[key] = ExtractedMedicineField(
        value: current?.value.trim().isNotEmpty == true
            ? current!.value
            : hint.value,
        confidence: min(max(current?.confidence ?? 0, hint.confidence), .82),
        support: max(current?.support ?? 0, hint.support),
        conflicted: true,
      );
      return;
    }
    if (current == null ||
        current.isEmpty ||
        hint.confidence > current.confidence + .025) {
      fields[key] = ExtractedMedicineField(
        value: hint.value,
        confidence: hint.confidence.clamp(.80, .96).toDouble(),
        support: max(current?.support ?? 0, hint.support),
        conflicted: false,
      );
    }
  }

  apply('batchNumber', hints.batch);
  apply('mfg', hints.mfg);
  apply('expiry', hints.expiry);

  final mfg = fields['mfg'];
  final expiry = fields['expiry'];
  if (mfg != null && expiry != null && !mfg.isEmpty && !expiry.isEmpty) {
    try {
      final mfgDate = parseDate(mfg.value, monthStart: true);
      final expiryDate = parseDate(expiry.value, monthEnd: true);
      if (mfgDate != null &&
          expiryDate != null &&
          mfgDate.isAfter(expiryDate)) {
        fields['mfg'] = ExtractedMedicineField(
          value: mfg.value,
          confidence: min(mfg.confidence, .80),
          support: mfg.support,
          conflicted: true,
        );
        fields['expiry'] = ExtractedMedicineField(
          value: expiry.value,
          confidence: min(expiry.confidence, .80),
          support: expiry.support,
          conflicted: true,
        );
      }
    } on FormatException {
      // Invalid spatial candidates remain non-authoritative and reviewable.
    }
  }
  return _copyDraft(draft, fields: fields);
}

MedicineScanDraft _applyRegulatoryTraceability(
  MedicineScanDraft draft,
  List<MedicineFrameEvidence> frames,
) {
  final gtins = <String>{};
  final batches = <String>{};
  final mfgs = <String>{};
  final expiries = <String>{};
  for (final frame in frames) {
    for (final raw in frame.allBarcodes) {
      final structured = parseRegulatoryMedicineCode(raw);
      if (structured == null) continue;
      if (structured.gtin.isNotEmpty) gtins.add(structured.gtin);
      if (structured.batchLot.isNotEmpty)
        batches.add(structured.batchLot.trim());
      if (structured.manufacturingYyMmDd.isNotEmpty) {
        final value = _gs1Date(structured.manufacturingYyMmDd);
        if (value.isNotEmpty) mfgs.add(value);
      }
      if (structured.expiryYyMmDd.isNotEmpty) {
        final value = _gs1Date(structured.expiryYyMmDd);
        if (value.isNotEmpty) expiries.add(value);
      }
    }
  }
  if (gtins.isEmpty && batches.isEmpty && mfgs.isEmpty && expiries.isEmpty) {
    return draft;
  }

  final fields = Map<String, ExtractedMedicineField>.of(draft.fields);
  void apply(String key, Set<String> values) {
    if (values.isEmpty) return;
    final ordered = values.toList()..sort();
    final current = fields[key];
    if (ordered.length > 1) {
      final value = current?.value.trim().isNotEmpty == true
          ? current!.value
          : ordered.first;
      fields[key] = ExtractedMedicineField(
        value: value,
        confidence: min(current?.confidence ?? .90, .90),
        support: max(current?.support ?? 0, ordered.length),
        conflicted: true,
      );
      return;
    }
    final value = ordered.single;
    final currentKey = current == null
        ? ''
        : _fieldIdentity(key, current.value);
    final structuredKey = _fieldIdentity(key, value);
    final conflict =
        current != null &&
        !current.isEmpty &&
        current.confidence >= .97 &&
        currentKey.isNotEmpty &&
        currentKey != structuredKey;
    fields[key] = ExtractedMedicineField(
      value: value,
      confidence: conflict ? .82 : .995,
      support: max(1, current?.support ?? 0),
      conflicted: conflict,
    );
  }

  apply('barcode', gtins);
  apply('batchNumber', batches);
  apply('mfg', mfgs);
  apply('expiry', expiries);
  return _copyDraft(draft, fields: fields);
}

String _gs1Date(String value) {
  if (!RegExp(r'^\d{6}$').hasMatch(value)) return '';
  final year = 2000 + int.parse(value.substring(0, 2));
  final month = int.parse(value.substring(2, 4));
  final day = int.parse(value.substring(4, 6));
  if (month < 1 || month > 12) return '';
  if (day == 0) {
    return '${year.toString().padLeft(4, '0')}-${month.toString().padLeft(2, '0')}';
  }
  final date = DateTime.utc(year, month, day);
  if (date.year != year || date.month != month || date.day != day) return '';
  return dateText(date);
}

String _fieldIdentity(String field, String value) {
  if (field == 'barcode') return _canonicalBarcode(value);
  if (field == 'strength') return _strengthIdentity(value);
  if (field == 'form') return normalizeForm(value).toLowerCase();
  return searchText(value);
}

String _canonicalBarcode(String value) {
  final raw = value.trim();
  if (raw.isEmpty) return '';
  final structured = parseRegulatoryMedicineCode(raw);
  final candidate = structured != null && structured.gtin.isNotEmpty
      ? structured.gtin
      : raw;
  if (RegExp(r'^\d+$').hasMatch(candidate) &&
      const <int>{8, 12, 13, 14}.contains(candidate.length)) {
    return candidate.padLeft(14, '0');
  }
  return candidate.replaceAll(RegExp(r'\s+'), '');
}

bool _isStrongProductBarcodeKey(String value) {
  if (!RegExp(r'^\d{14}$').hasMatch(value)) return false;
  final parsed = parseGs1HealthcareBarcode('01$value');
  return parsed != null && parsed.gtin == value;
}

String _strengthIdentity(String value) =>
    searchText(value)
        .replaceAll(' ', '')
        .replaceAll('μ', 'µ')
        .replaceAll('ug', 'mcg');

double _weightedTextSimilarity(String rawObserved, String rawCanonical) {
  final canonical = _compactForOcr(rawCanonical);
  if (canonical.length < 2) return 0;
  final observedNormalized = searchText(rawObserved);
  if (observedNormalized.isEmpty) return 0;
  final observedTokens = observedNormalized
      .split(' ')
      .where((value) => value.isNotEmpty)
      .toList();
  final windows = <String>{_compactForOcr(rawObserved)};
  final canonicalWords = max(1, searchText(rawCanonical).split(' ').length);
  for (
    var width = max(1, canonicalWords - 1);
    width <= min(observedTokens.length, canonicalWords + 1);
    width++
  ) {
    for (var start = 0; start + width <= observedTokens.length; start++) {
      windows.add(observedTokens.sublist(start, start + width).join());
    }
  }
  var best = 0.0;
  for (final observed in windows.where((value) => value.length >= 2).take(80)) {
    final folded = _ocrFoldToken(observed);
    best = max(best, _weightedEditSimilarity(observed, canonical));
    if (folded != observed) {
      best = max(best, _weightedEditSimilarity(folded, canonical));
    }
    best = max(best, orderedSimilarity(observed, canonical));
  }
  return best.clamp(0, 1).toDouble();
}

String _compactForOcr(String value) => searchText(value).replaceAll(' ', '');

double _weightedEditSimilarity(String left, String right) {
  if (left == right) return 1;
  if (left.isEmpty || right.isEmpty) return 0;
  if (left.length > 80) left = left.substring(0, 80);
  if (right.length > 80) right = right.substring(0, 80);
  var previousPrevious = List<double>.generate(
    right.length + 1,
    (index) => index * .82,
  );
  var previous = List<double>.from(previousPrevious);
  for (var i = 0; i < left.length; i++) {
    final current = List<double>.filled(right.length + 1, 0)
      ..[0] = (i + 1) * .82;
    for (var j = 0; j < right.length; j++) {
      final substitution =
          previous[j] + _ocrSubstitutionCost(left[i], right[j]);
      final deletion = previous[j + 1] + .82;
      final insertion = current[j] + .82;
      var best = min(substitution, min(deletion, insertion));
      if (i > 0 &&
          j > 0 &&
          left[i] == right[j - 1] &&
          left[i - 1] == right[j]) {
        best = min(best, previousPrevious[j - 1] + .44);
      }
      current[j + 1] = best;
    }
    previousPrevious = previous;
    previous = current;
  }
  final scale = max(left.length, right.length).toDouble();
  return (1 - previous.last / scale).clamp(0, 1).toDouble();
}

double _ocrSubstitutionCost(String a, String b) {
  if (a == b) return 0;
  final pair = '$a$b';
  if (const <String>{
    '0o',
    'o0',
    '1i',
    'i1',
    '1l',
    'l1',
    '5s',
    's5',
    '8b',
    'b8',
    '2z',
    'z2',
  }.contains(pair)) {
    return .14;
  }
  if (const <String>{'c0', '0c', 'g6', '6g', 'q0', '0q'}.contains(pair)) {
    return .38;
  }
  return 1;
}

MedicineScanDraft _copyDraft(
  MedicineScanDraft source, {
  Map<String, ExtractedMedicineField>? fields,
  double? overallConfidence,
}) => MedicineScanDraft(
  fields: Map<String, ExtractedMedicineField>.unmodifiable(
    fields ?? source.fields,
  ),
  rawText: source.rawText,
  searchKeywords: source.searchKeywords,
  frameSequences: source.frameSequences,
  expiryMonthOnly: (fields ?? source.fields)['expiry']?.value.length == 7,
  mfgMonthOnly: (fields ?? source.fields)['mfg']?.value.length == 7,
  printedPackSize: source.printedPackSize,
  printedMrp: source.printedMrp,
  overallConfidence: (overallConfidence ?? source.overallConfidence)
      .clamp(0, 1)
      .toDouble(),
);

const _resolverNoise = <String>{
  'tablet',
  'tablets',
  'capsule',
  'capsules',
  'syrup',
  'suspension',
  'injection',
  'cream',
  'ointment',
  'drops',
  'composition',
  'contains',
  'manufactured',
  'manufacturer',
  'expiry',
  'batch',
  'price',
  'mrp',
  'store',
  'children',
  'reach',
  'only',
};
