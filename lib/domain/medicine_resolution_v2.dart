import 'dart:math';

import 'gs1_healthcare.dart';
import 'medicine.dart';
import 'medicine_understanding.dart';
import 'search.dart';

const int maxCanonicalMedicineCandidates = 96;

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

  String get displayName =>
      name.trim().isNotEmpty ? name.trim() : brand.trim();

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
      final gs1Safe = _applyGs1Traceability(draft, frames);
      drafts.add(_resolveProduct(gs1Safe, frames));
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

    final hypotheses = candidates
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
    // A barcode identifies a product only when that mapping is unique, or when
    // independent printed evidence resolves the duplicate mapping. Retail and
    // legacy catalogues can contain the same GTIN against multiple variants; a
    // tie must never become a deterministic auto-fill merely because sorting
    // happened to put one product first.
    final exactBarcodeAmbiguous = winner.exactBarcode &&
        hypotheses.skip(1).any(
          (candidate) =>
              candidate.exactBarcode &&
              !_sameResolvedProductIdentity(winner.product, candidate.product),
        );

    if (winner.hardConflicts > 0) {
      return _markConflictAgainstProduct(draft, winner.product);
    }

    final exactBarcodeLock =
        winner.exactBarcode &&
        !exactBarcodeAmbiguous &&
        winner.product.verified &&
        winner.hardConflicts == 0;
    // Salt + strength + dosage form can identify a generic composition but do
    // not prove a trade product. Canonical inheritance is allowed only when a
    // printed product/name/verified OCR alias independently anchors identity.
    // This prevents a small catalogue from turning “Paracetamol 650 mg Tablet”
    // into a familiar brand merely because that brand is the only candidate.
    final calibratedLock =
        winner.product.verified &&
        winner.strongIdentity &&
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
          if (entry.name.trim().isNotEmpty) entry.name.trim(),
          if (entry.brand.trim().isNotEmpty) entry.brand.trim(),
        ],
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

class _ProductIndex {
  _ProductIndex(Iterable<CanonicalMedicineProduct> source) {
    for (final product in source) {
      if (!product.active || product.displayName.isEmpty) continue;
      final index = products.length;
      products.add(product);
      for (final rawBarcode in product.barcodes.take(12)) {
        final key = _canonicalBarcode(rawBarcode);
        if (key.isEmpty) continue;
        barcodes.putIfAbsent(key, () => <int>{}).add(index);
      }
      final terms = _productTerms(product);
      for (final term in terms) {
        exact.putIfAbsent(term, () => <int>{}).add(index);
        if (term.length >= 4 && term.length <= 28) {
          for (final deletion in _deleteKeys(term)) {
            deletes.putIfAbsent(deletion, () => <int>{}).add(index);
          }
        }
      }
    }
  }

  final List<CanonicalMedicineProduct> products = <CanonicalMedicineProduct>[];
  final Map<String, Set<int>> barcodes = <String, Set<int>>{};
  final Map<String, Set<int>> exact = <String, Set<int>>{};
  final Map<String, Set<int>> deletes = <String, Set<int>>{};

  List<CanonicalMedicineProduct> candidates(
    MedicineScanDraft draft,
    List<MedicineFrameEvidence> frames,
  ) {
    if (products.isEmpty) return const <CanonicalMedicineProduct>[];
    final votes = <int, double>{};
    void vote(Iterable<int>? indexes, double weight) {
      if (indexes == null) return;
      for (final index in indexes.take(256)) {
        votes.update(index, (value) => value + weight, ifAbsent: () => weight);
      }
    }

    final barcodeKeys = <String>{
      _canonicalBarcode(draft.barcode),
      for (final frame in frames)
        for (final barcode in frame.allBarcodes) _canonicalBarcode(barcode),
    }..remove('');
    for (final barcode in barcodeKeys) {
      vote(barcodes[barcode], 20);
    }

    final queryTerms = _queryTerms(draft, frames);
    for (final term in queryTerms.take(32)) {
      vote(exact[term], 4);
      final folded = _ocrFoldToken(term);
      if (folded != term) vote(exact[folded], 3.7);
      for (final deletion in _deleteKeys(folded).take(24)) {
        vote(deletes[deletion], 1.2);
      }
    }

    if (votes.isEmpty) return const <CanonicalMedicineProduct>[];
    final ranked = votes.entries.toList(growable: false)
      ..sort((a, b) {
        final score = b.value.compareTo(a.value);
        return score != 0 ? score : a.key.compareTo(b.key);
      });
    return ranked
        .take(maxCanonicalMedicineCandidates)
        .map((entry) => products[entry.key])
        .toList(growable: false);
  }
}

Set<String> _productTerms(CanonicalMedicineProduct product) {
  final result = <String>{};
  void add(String value) {
    final normalized = searchText(value);
    if (normalized.isEmpty) return;
    final tokens = normalized.split(' ').where((value) => value.length >= 3);
    for (final token in tokens.take(24)) {
      result.add(token);
      result.add(_ocrFoldToken(token));
    }
    final compact = normalized.replaceAll(' ', '');
    if (compact.length >= 4 && compact.length <= 28) result.add(compact);
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
  void add(String raw) {
    final normalized = searchText(raw);
    if (normalized.isEmpty) return;
    final tokens = normalized.split(' ').where((value) => value.isNotEmpty).toList();
    for (final token in tokens) {
      if (token.length >= 3 && !_resolverNoise.contains(token)) {
        result.add(token);
        result.add(_ocrFoldToken(token));
      }
    }
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
      if (buffer.length >= 3) result.add(buffer.toString());
      start = max(start + 1, end);
    }
  }

  add(draft.name);
  add(draft.brand);
  add(draft.salt);
  add(draft.manufacturer);
  for (final frame in frames) add(frame.text);
  return result;
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

class _ProductHypothesis {
  const _ProductHypothesis({
    required this.product,
    required this.score,
    required this.channels,
    required this.hardConflicts,
    required this.exactBarcode,
    required this.strongIdentity,
  });

  final CanonicalMedicineProduct product;
  final double score;
  final int channels;
  final int hardConflicts;
  final bool exactBarcode;
  final bool strongIdentity;
}

_ProductHypothesis _scoreProduct(
  CanonicalMedicineProduct product,
  MedicineScanDraft draft,
  List<MedicineFrameEvidence> frames,
) {
  var weighted = 0.0;
  var totalWeight = 0.0;
  var channels = 0;
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

  final identityEvidence = <String>[
    draft.name,
    draft.brand,
    for (final frame in frames) ...frame.text.split(RegExp(r'[\r\n]+')).take(16),
  ];
  final aliases = <String>{
    product.displayName,
    product.brand,
    ...product.aliases,
    ...product.ocrAliases,
  }..removeWhere((value) => value.trim().isEmpty);
  var bestIdentity = 0.0;
  for (final evidence
      in identityEvidence.where((value) => value.trim().isNotEmpty).take(32)) {
    for (final alias in aliases.take(32)) {
      bestIdentity = max(bestIdentity, _weightedTextSimilarity(evidence, alias));
    }
  }
  if (bestIdentity >= .52) {
    weighted += bestIdentity * .36;
    totalWeight += .36;
    if (bestIdentity >= .78) channels++;
  }
  final nameField = draft.field('name');
  if (!nameField.isEmpty && nameField.confidence >= .86 && bestIdentity < .56) {
    hardConflicts++;
  }

  final salt = _fieldSimilarity(draft, 'salt', product.salt);
  if (salt != null) {
    weighted += salt * .19;
    totalWeight += .19;
    if (salt >= .88) channels++;
    if (draft.field('salt').confidence >= .86 && salt < .62) hardConflicts++;
  }

  final observedStrength = draft.strength.trim();
  if (observedStrength.isNotEmpty && product.strength.trim().isNotEmpty) {
    final agrees =
        _strengthIdentity(observedStrength) == _strengthIdentity(product.strength);
    weighted += (agrees ? 1.0 : 0.0) * .18;
    totalWeight += .18;
    if (agrees) {
      channels++;
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
    if (manufacturer >= .90) channels++;
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
    hardConflicts: hardConflicts,
    exactBarcode: exactBarcode,
    strongIdentity: bestIdentity >= .88,
  );
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
  _ProductHypothesis hypothesis,
) {
  final product = hypothesis.product;
  final fields = Map<String, ExtractedMedicineField>.of(draft.fields);
  final confidence = hypothesis.exactBarcode
      ? .995
      : hypothesis.score.clamp(.82, .99).toDouble();
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

  final identityConfidence = <String>['name', 'brand', 'salt', 'strength', 'form']
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

MedicineScanDraft _applyGs1Traceability(
  MedicineScanDraft draft,
  List<MedicineFrameEvidence> frames,
) {
  final gtins = <String>{};
  final batches = <String>{};
  final mfgs = <String>{};
  final expiries = <String>{};
  for (final frame in frames) {
    for (final raw in frame.allBarcodes) {
      final gs1 = parseGs1HealthcareBarcode(raw);
      if (gs1 == null) continue;
      if (gs1.gtin.isNotEmpty) gtins.add(gs1.gtin);
      if (gs1.batchLot.isNotEmpty) batches.add(gs1.batchLot.trim());
      if (gs1.manufacturingYyMmDd.isNotEmpty) {
        final value = _gs1Date(gs1.manufacturingYyMmDd);
        if (value.isNotEmpty) mfgs.add(value);
      }
      if (gs1.expiryYyMmDd.isNotEmpty) {
        final value = _gs1Date(gs1.expiryYyMmDd);
        if (value.isNotEmpty) expiries.add(value);
      }
    }
  }
  if (gtins.isEmpty && batches.isEmpty && mfgs.isEmpty && expiries.isEmpty) {
    return draft;
  }

  final fields = Map<String, ExtractedMedicineField>.of(draft.fields);
  var structuredConflict = false;

  double conflictFloor(String key) => switch (key) {
    'barcode' => .82,
    'batchNumber' => .78,
    'mfg' || 'expiry' => .78,
    _ => .82,
  };

  void apply(String key, Set<String> values) {
    if (values.isEmpty) return;
    final ordered = values.toList()..sort();
    final current = fields[key];
    if (ordered.length > 1) {
      structuredConflict = true;
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
    final priorConflict = current?.conflicted == true;
    final conflict =
        current != null &&
        !current.isEmpty &&
        current.confidence >= conflictFloor(key) &&
        !_structuredFieldCompatible(key, current.value, value);
    if (priorConflict || conflict) structuredConflict = true;

    // Valid GS1 remains the displayed structured fact, but disagreement with
    // credible printed OCR is surfaced as review state rather than silently
    // erasing the contradictory observation.
    fields[key] = ExtractedMedicineField(
      value: value,
      confidence: (priorConflict || conflict) ? .82 : .995,
      support: max(1, current?.support ?? 0),
      conflicted: priorConflict || conflict,
    );
  }

  apply('barcode', gtins);
  apply('batchNumber', batches);
  apply('mfg', mfgs);
  apply('expiry', expiries);

  final mfg = fields['mfg'];
  final expiry = fields['expiry'];
  if (mfg != null &&
      expiry != null &&
      !mfg.isEmpty &&
      !expiry.isEmpty &&
      _invalidStructuredChronology(mfg.value, expiry.value)) {
    structuredConflict = true;
    for (final key in const <String>['mfg', 'expiry']) {
      final field = fields[key]!;
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
    overallConfidence: structuredConflict
        ? min(draft.overallConfidence, .77)
        : draft.overallConfidence,
  );
}

bool _structuredFieldCompatible(String field, String observed, String structured) {
  if (field == 'mfg' || field == 'expiry') {
    final pattern = RegExp(r'^(\d{4})-(\d{2})(?:-(\d{2}))?$');
    final left = pattern.firstMatch(observed.trim());
    final right = pattern.firstMatch(structured.trim());
    if (left != null &&
        right != null &&
        left.group(1) == right.group(1) &&
        left.group(2) == right.group(2)) {
      final leftDay = left.group(3);
      final rightDay = right.group(3);
      if (leftDay == null || rightDay == null || leftDay == rightDay) {
        return true;
      }
    }
  }
  return _fieldIdentity(field, observed) == _fieldIdentity(field, structured);
}

bool _invalidStructuredChronology(String mfg, String expiry) {
  final pattern = RegExp(r'^(\d{4})-(\d{2})(?:-(\d{2}))?$');
  final left = pattern.firstMatch(mfg.trim());
  final right = pattern.firstMatch(expiry.trim());
  if (left == null || right == null) return false;
  final leftMonth = int.parse(left.group(1)!) * 12 + int.parse(left.group(2)!);
  final rightMonth = int.parse(right.group(1)!) * 12 + int.parse(right.group(2)!);
  if (leftMonth != rightMonth) return leftMonth > rightMonth;
  final leftDay = int.tryParse(left.group(3) ?? '');
  final rightDay = int.tryParse(right.group(3) ?? '');
  return leftDay != null && rightDay != null && leftDay > rightDay;
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
  final gs1 = parseGs1HealthcareBarcode(raw);
  final candidate = gs1 != null && gs1.gtin.isNotEmpty ? gs1.gtin : raw;
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

String _strengthIdentity(String value) => searchText(value)
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
  var previous = List<double>.generate(
    right.length + 1,
    (index) => index * .82,
  );
  for (var i = 0; i < left.length; i++) {
    final current = List<double>.filled(right.length + 1, 0)
      ..[0] = (i + 1) * .82;
    for (var j = 0; j < right.length; j++) {
      final substitution =
          previous[j] + _ocrSubstitutionCost(left[i], right[j]);
      final deletion = previous[j + 1] + .82;
      final insertion = current[j] + .82;
      current[j + 1] = min(substitution, min(deletion, insertion));
    }
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
