import 'dart:math';

import 'medicine.dart';
import 'medicine_discovery.dart';
import 'search.dart';

/// Immutable OCR/barcode evidence from one image or one ordered video frame.
///
/// The domain layer deliberately knows nothing about CameraImage, ML Kit, file
/// paths or Android. This keeps medicine understanding deterministic, testable
/// and safe to run in a background isolate.
class MedicineFrameEvidence {
  const MedicineFrameEvidence({
    this.barcode = '',
    this.barcodes = const <String>[],
    this.text = '',
    this.source = '',
    this.sequence = 0,
    this.timestampMs,
    this.quality = 1,
    this.startsNewItem = false,
  });

  final String barcode;
  final List<String> barcodes;
  final String text;
  final String source;
  final int sequence;
  final int? timestampMs;

  /// A bounded capture-quality hint. OCR richness is evaluated independently.
  final double quality;

  /// True only for an explicit row/paragraph boundary from a structured local
  /// import. Camera/video boundaries remain inferred from their evidence.
  final bool startsNewItem;

  List<String> get allBarcodes {
    final values = <String>{
      if (barcode.trim().isNotEmpty) barcode.trim(),
      ...barcodes
          .map((value) => value.trim())
          .where((value) => value.isNotEmpty),
    };
    return values.take(8).toList(growable: false);
  }

  Map<String, Object?> toMessage() => <String, Object?>{
    'barcode': barcode,
    'barcodes': barcodes,
    'text': text,
    'source': source,
    'sequence': sequence,
    'timestampMs': timestampMs,
    'quality': quality,
    'startsNewItem': startsNewItem,
  };

  factory MedicineFrameEvidence.fromMessage(Map<Object?, Object?> map) {
    final rawBarcodes = map['barcodes'];
    return MedicineFrameEvidence(
      barcode: map['barcode'] is String ? map['barcode']! as String : '',
      barcodes: rawBarcodes is List
          ? rawBarcodes.whereType<String>().take(8).toList(growable: false)
          : const <String>[],
      text: map['text'] is String ? map['text']! as String : '',
      source: map['source'] is String ? map['source']! as String : '',
      sequence: map['sequence'] is int ? map['sequence']! as int : 0,
      timestampMs: map['timestampMs'] is int
          ? map['timestampMs']! as int
          : null,
      quality: map['quality'] is num
          ? (map['quality']! as num).toDouble().clamp(0, 1)
          : 1,
      startsNewItem: map['startsNewItem'] == true,
    );
  }
}

const maxMedicineListCharacters = 1000000;
const maxMedicineListItems = 240;
const maxMedicineEvidenceFrames = 240;
const maxMedicineKnowledgeEntries = 12000;

/// Compact, verified identity facts used as the scanner's private on-device
/// medicine memory. Stock counts, prices, locations and notes are intentionally
/// excluded: recognition needs identity only and must not copy operational data.
class MedicineKnowledgeEntry {
  const MedicineKnowledgeEntry({
    this.name = '',
    this.brand = '',
    this.salt = '',
    this.strength = '',
    this.form = '',
    this.manufacturer = '',
    this.barcode = '',
  });

  final String name;
  final String brand;
  final String salt;
  final String strength;
  final String form;
  final String manufacturer;
  final String barcode;

  factory MedicineKnowledgeEntry.fromMedicine(Medicine medicine) =>
      MedicineKnowledgeEntry(
        name: medicine.name,
        brand: medicine.brand,
        salt: medicine.salt,
        strength: medicine.strength,
        form: medicine.form,
        manufacturer: medicine.manufacturer,
        barcode: medicine.barcode,
      );

  Map<String, Object?> toMessage() => <String, Object?>{
    'name': name,
    'brand': brand,
    'salt': salt,
    'strength': strength,
    'form': form,
    'manufacturer': manufacturer,
    'barcode': barcode,
  };

  factory MedicineKnowledgeEntry.fromMessage(Map<Object?, Object?> map) {
    String text(String key) {
      final raw = map[key];
      if (raw is! String) return '';
      final value = raw.trim();
      return value.length <= 300 ? value : value.substring(0, 300);
    }

    return MedicineKnowledgeEntry(
      name: text('name'),
      brand: text('brand'),
      salt: text('salt'),
      strength: text('strength'),
      form: text('form'),
      manufacturer: text('manufacturer'),
      barcode: text('barcode'),
    );
  }

  String get _dedupeKey => <String>[
    name,
    brand,
    salt,
    strength,
    form,
    manufacturer,
    barcode,
  ].map(searchText).join('|');

  bool get _hasIdentity =>
      name.trim().isNotEmpty ||
      brand.trim().isNotEmpty ||
      salt.trim().isNotEmpty ||
      barcode.trim().isNotEmpty;
}

/// Builds a deterministic, bounded identity-only knowledge snapshot from
/// pharmacist-reviewed local records. This is derived state, never another
/// database and never a network payload.
List<MedicineKnowledgeEntry> medicineKnowledgeFromRecords(
  Iterable<Medicine> records,
) {
  final result = <MedicineKnowledgeEntry>[];
  final seen = <String>{};
  for (final medicine in records) {
    if (medicine.archived) continue;
    final entry = MedicineKnowledgeEntry.fromMedicine(medicine);
    if (!entry._hasIdentity) continue;
    if (!seen.add(entry._dedupeKey)) continue;
    result.add(entry);
    if (result.length >= maxMedicineKnowledgeEntries) break;
  }
  return List<MedicineKnowledgeEntry>.unmodifiable(result);
}

/// Converts an explicitly pasted/uploaded medicine list into hard-bounded
/// evidence items. It never guesses quantity or price columns and never drops
/// overflow silently; every resulting draft still requires editor review.
List<MedicineFrameEvidence> medicineListEvidence(
  String input, {
  required String source,
}) {
  var text = input.trim().replaceFirst('\uFEFF', '');
  if (text.isEmpty) {
    throw const FormatException('The medicine list is empty.');
  }
  if (text.length > maxMedicineListCharacters) {
    throw const FormatException(
      'This medicine list is too large. Split it into smaller files.',
    );
  }

  final paragraphs = text
      .split(RegExp(r'\r?\n\s*\r?\n'))
      .map((value) => value.trim())
      .where((value) => value.isNotEmpty)
      .toList(growable: false);
  final paragraphRows = paragraphs
      .map((value) => value.split(RegExp(r'[\r\n]+')).length)
      .toList(growable: false);
  final useParagraphs =
      paragraphs.length > 1 && paragraphRows.every((count) => count <= 6);
  final rawItems = useParagraphs
      ? paragraphs
      : text
            .split(RegExp(r'[\r\n]+'))
            .map((value) => value.trim())
            .where((value) => value.isNotEmpty)
            .toList(growable: false);
  if (rawItems.length > maxMedicineListItems) {
    throw FormatException(
      'This list has ${rawItems.length} items. Import at most $maxMedicineListItems at a time so every medicine can be reviewed safely.',
    );
  }

  final items = rawItems
      .map(
        (value) => value
            .replaceFirst(RegExp(r'^\s*(?:[-*•]|\d{1,4}[.)])\s+'), '')
            .trim(),
      )
      .where((value) => value.isNotEmpty)
      .toList(growable: false);
  if (items.isEmpty) {
    throw const FormatException('The medicine list has no readable items.');
  }
  return <MedicineFrameEvidence>[
    for (var index = 0; index < items.length; index++)
      MedicineFrameEvidence(
        text: items[index],
        source: '$source · item ${index + 1}',
        sequence: index,
        timestampMs: index * 12000,
        startsNewItem: index > 0,
      ),
  ];
}

class ExtractedMedicineField {
  const ExtractedMedicineField({
    this.value = '',
    this.confidence = 0,
    this.support = 0,
    this.conflicted = false,
  });

  final String value;
  final double confidence;
  final int support;
  final bool conflicted;

  bool get isEmpty => value.trim().isEmpty;
  bool get needsReview => conflicted || confidence < .78;

  Map<String, Object?> toMessage() => <String, Object?>{
    'value': value,
    'confidence': confidence,
    'support': support,
    'conflicted': conflicted,
  };

  factory ExtractedMedicineField.fromMessage(Map<Object?, Object?> map) =>
      ExtractedMedicineField(
        value: map['value'] is String ? map['value']! as String : '',
        confidence: map['confidence'] is num
            ? (map['confidence']! as num).toDouble().clamp(0, 1)
            : 0,
        support: map['support'] is int ? map['support']! as int : 0,
        conflicted: map['conflicted'] == true,
      );
}

/// A reviewable stock draft produced from one temporally grouped medicine.
///
/// Printed pack size and MRP are intentionally review metadata. They never map
/// to pharmacy stock quantity or entered inventory amount.
class MedicineScanDraft {
  const MedicineScanDraft({
    required this.fields,
    required this.rawText,
    required this.searchKeywords,
    required this.frameSequences,
    this.expiryMonthOnly = false,
    this.mfgMonthOnly = false,
    this.printedPackSize = '',
    this.printedMrp = '',
    this.overallConfidence = 0,
  });

  final Map<String, ExtractedMedicineField> fields;
  final String rawText;
  final String searchKeywords;
  final List<int> frameSequences;
  final bool expiryMonthOnly;
  final bool mfgMonthOnly;
  final String printedPackSize;
  final String printedMrp;
  final double overallConfidence;

  ExtractedMedicineField field(String name) =>
      fields[name] ?? const ExtractedMedicineField();

  String get name => field('name').value;
  String get brand => field('brand').value;
  String get manufacturer => field('manufacturer').value;
  String get salt => field('salt').value;
  String get strength => field('strength').value;
  String get form => field('form').value;
  String get mfg => field('mfg').value;
  String get expiry => field('expiry').value;
  String get barcode => field('barcode').value;
  String get batchNumber => field('batchNumber').value;

  bool get needsReview =>
      name.isEmpty ||
      overallConfidence < .78 ||
      fields.values.any((value) => !value.isEmpty && value.conflicted);

  MedicineDraftSeed get identitySeed => MedicineDraftSeed(
    name: name,
    brand: brand,
    manufacturer: manufacturer,
    salt: salt,
    strength: strength,
    form: form,
    barcode: barcode,
    source: 'On-device medicine understanding',
  );

  /// Keeps raw OCR auditable while adding a compact normalized search tail.
  String get searchableOcrText {
    final raw = rawText.trim();
    final keywords = searchKeywords.trim();
    if (keywords.isEmpty || searchText(raw).contains(keywords)) return raw;
    final value = '$raw\nSearch keywords: $keywords'.trim();
    return value.length <= 30000 ? value : value.substring(0, 30000);
  }

  Map<String, Object?> toMessage() => <String, Object?>{
    'fields': <String, Object?>{
      for (final entry in fields.entries) entry.key: entry.value.toMessage(),
    },
    'rawText': rawText,
    'searchKeywords': searchKeywords,
    'frameSequences': frameSequences,
    'expiryMonthOnly': expiryMonthOnly,
    'mfgMonthOnly': mfgMonthOnly,
    'printedPackSize': printedPackSize,
    'printedMrp': printedMrp,
    'overallConfidence': overallConfidence,
  };

  factory MedicineScanDraft.fromMessage(Map<Object?, Object?> map) {
    final rawFields = map['fields'];
    return MedicineScanDraft(
      fields: rawFields is Map
          ? <String, ExtractedMedicineField>{
              for (final entry in rawFields.entries)
                if (entry.key is String && entry.value is Map)
                  entry.key! as String: ExtractedMedicineField.fromMessage(
                    entry.value! as Map<Object?, Object?>,
                  ),
            }
          : const <String, ExtractedMedicineField>{},
      rawText: map['rawText'] is String ? map['rawText']! as String : '',
      searchKeywords: map['searchKeywords'] is String
          ? map['searchKeywords']! as String
          : '',
      frameSequences: map['frameSequences'] is List
          ? (map['frameSequences']! as List).whereType<int>().toList(
              growable: false,
            )
          : const <int>[],
      expiryMonthOnly: map['expiryMonthOnly'] == true,
      mfgMonthOnly: map['mfgMonthOnly'] == true,
      printedPackSize: map['printedPackSize'] is String
          ? map['printedPackSize']! as String
          : '',
      printedMrp: map['printedMrp'] is String
          ? map['printedMrp']! as String
          : '',
      overallConfidence: map['overallConfidence'] is num
          ? (map['overallConfidence']! as num).toDouble().clamp(0, 1)
          : 0,
    );
  }
}

class MedicineUnderstandingResult {
  const MedicineUnderstandingResult({
    required this.drafts,
    this.ignoredFrames = 0,
  });

  final List<MedicineScanDraft> drafts;
  final int ignoredFrames;

  Map<String, Object?> toMessage() => <String, Object?>{
    'drafts': drafts.map((draft) => draft.toMessage()).toList(growable: false),
    'ignoredFrames': ignoredFrames,
  };

  factory MedicineUnderstandingResult.fromMessage(Map<Object?, Object?> map) {
    final rawDrafts = map['drafts'];
    return MedicineUnderstandingResult(
      drafts: rawDrafts is List
          ? rawDrafts
                .whereType<Map>()
                .map(
                  (value) => MedicineScanDraft.fromMessage(
                    Map<Object?, Object?>.from(value),
                  ),
                )
                .toList(growable: false)
          : const <MedicineScanDraft>[],
      ignoredFrames: map['ignoredFrames'] is int
          ? map['ignoredFrames']! as int
          : 0,
    );
  }
}

/// Entry point suitable for Flutter's `compute` helper.
Map<String, Object?> understandMedicineEvidenceMessage(
  Map<String, Object?> message,
) {
  final raw = message['evidence'];
  final frames = raw is List
      ? raw
            .whereType<Map>()
            .map(
              (value) => MedicineFrameEvidence.fromMessage(
                Map<Object?, Object?>.from(value),
              ),
            )
            .toList(growable: false)
      : const <MedicineFrameEvidence>[];
  final rawKnowledge = message['knowledge'];
  final knowledge = rawKnowledge is List
      ? rawKnowledge
            .whereType<Map>()
            .take(maxMedicineKnowledgeEntries)
            .map(
              (value) => MedicineKnowledgeEntry.fromMessage(
                Map<Object?, Object?>.from(value),
              ),
            )
            .toList(growable: false)
      : const <MedicineKnowledgeEntry>[];
  return MedicineUnderstandingEngine(
    knowledge: knowledge,
  ).understand(frames).toMessage();
}

/// Deterministic, offline-first medicine evidence parser and temporal grouper.
class MedicineUnderstandingEngine {
  const MedicineUnderstandingEngine({this.knowledge = const []});

  final List<MedicineKnowledgeEntry> knowledge;

  MedicineUnderstandingResult understand(
    Iterable<MedicineFrameEvidence> input,
  ) {
    final knowledgeResolver = _OfflineMedicineKnowledge(knowledge);
    final supplied = input.toList(growable: false);
    final eligible = supplied
        .where(
          (frame) =>
              frame.text.trim().isNotEmpty || frame.allBarcodes.isNotEmpty,
        )
        .toList(growable: false);
    var ignored = supplied.length - eligible.length;
    if (eligible.length > maxMedicineEvidenceFrames) {
      ignored += eligible.length - maxMedicineEvidenceFrames;
    }
    final ordered =
        eligible.take(maxMedicineEvidenceFrames).toList(growable: false)
          ..sort((a, b) {
            final sequence = a.sequence.compareTo(b.sequence);
            if (sequence != 0) return sequence;
            return (a.timestampMs ?? 0).compareTo(b.timestampMs ?? 0);
          });
    if (ordered.isEmpty) {
      return MedicineUnderstandingResult(
        drafts: const <MedicineScanDraft>[],
        ignoredFrames: ignored,
      );
    }

    final prepared = <_PreparedFrame>[];
    for (final frame in ordered) {
      final current = _prepare(frame, knowledgeResolver);
      if (current.lines.isEmpty && current.barcodes.isEmpty) {
        ignored++;
        continue;
      }
      if (prepared.isNotEmpty && _nearDuplicate(prepared.last, current)) {
        final previous = prepared.last;
        // Repeated camera frames must not vote multiple times, but dropping the
        // weaker frame can also drop the only readable barcode/date/batch. Fuse
        // complementary facts into one vote and retain the clearer frame as its
        // temporal representative.
        prepared[prepared.length - 1] = _fuseNearDuplicate(
          previous,
          current,
          knowledgeResolver,
        );
        ignored++;
        continue;
      }
      prepared.add(current);
    }
    if (prepared.isEmpty) {
      return MedicineUnderstandingResult(
        drafts: const <MedicineScanDraft>[],
        ignoredFrames: ignored,
      );
    }

    final groups = <List<_PreparedFrame>>[];
    for (final frame in prepared) {
      if (groups.isEmpty || _startsNewMedicine(groups.last, frame)) {
        groups.add(<_PreparedFrame>[frame]);
      } else {
        groups.last.add(frame);
      }
    }
    _repairWeakBoundaries(groups);

    final drafts = <MedicineScanDraft>[];
    for (final group in groups.where((value) => value.isNotEmpty)) {
      final draft = _fuse(group);
      if (draft.rawText.isNotEmpty || draft.barcode.isNotEmpty) {
        drafts.add(draft);
      } else {
        ignored += group.length;
      }
    }
    return MedicineUnderstandingResult(drafts: drafts, ignoredFrames: ignored);
  }

  _PreparedFrame _prepare(
    MedicineFrameEvidence frame,
    _OfflineMedicineKnowledge knowledgeResolver,
  ) {
    final bounded = frame.text.length <= 30000
        ? frame.text
        : frame.text.substring(0, 30000);
    final lines = <String>[];
    final seen = <String>{};
    for (final raw in bounded.split(RegExp(r'[\r\n]+')).take(240)) {
      final line = _cleanLine(raw);
      final key = searchText(line);
      if (key.length < 2 || !seen.add(key)) continue;
      lines.add(line);
    }
    final quality = frame.quality.clamp(0, 1).toDouble();
    final richness =
        (lines.fold<int>(0, (sum, line) => sum + line.length) / 180)
            .clamp(0, 1)
            .toDouble();
    final effectiveQuality = (quality * .64 + richness * .36)
        .clamp(.12, 1)
        .toDouble();
    final candidates = _extractCandidates(
      lines,
      frame,
      effectiveQuality,
      knowledgeResolver,
    );
    return _PreparedFrame(
      frame: frame,
      lines: lines,
      normalizedText: searchText(lines.join(' ')),
      barcodes: frame.allBarcodes,
      candidates: candidates,
      effectiveQuality: effectiveQuality,
    );
  }

  bool _nearDuplicate(_PreparedFrame a, _PreparedFrame b) {
    if (b.frame.startsNewItem) return false;
    if (_strongFieldConflict(a, b, 'batchNumber', similarityFloor: .72) ||
        _strongFieldConflict(a, b, 'expiry')) {
      return false;
    }
    if (a.barcodes.isNotEmpty && b.barcodes.isNotEmpty) {
      if (a.barcodes.toSet().intersection(b.barcodes.toSet()).isEmpty) {
        return false;
      }
    }
    final strengthA = _bestCandidate(<_PreparedFrame>[a], 'strength');
    final strengthB = _bestCandidate(<_PreparedFrame>[b], 'strength');
    if (strengthA != null &&
        strengthB != null &&
        _strengthKey(strengthA.value) != _strengthKey(strengthB.value)) {
      return false;
    }
    final identityA = _bestIdentity(<_PreparedFrame>[a]);
    final identityB = _bestIdentity(<_PreparedFrame>[b]);
    if (identityA != null &&
        identityB != null &&
        identityA.score >= .62 &&
        identityB.score >= .62 &&
        orderedSimilarity(
              searchText(identityA.value),
              searchText(identityB.value),
            ) >=
            .91) {
      return true;
    }
    final tokensA = _identityTokens(a.normalizedText);
    final tokensB = _identityTokens(b.normalizedText);
    if (tokensA.isEmpty || tokensB.isEmpty) return false;
    final overlap =
        tokensA.intersection(tokensB).length /
        max(tokensA.length, tokensB.length);
    return overlap >= .88;
  }

  _PreparedFrame _fuseNearDuplicate(
    _PreparedFrame a,
    _PreparedFrame b,
    _OfflineMedicineKnowledge knowledgeResolver,
  ) {
    final primary = a.effectiveQuality >= b.effectiveQuality ? a : b;
    final secondary = identical(primary, a) ? b : a;
    final lines = <String>[];
    final keys = <String>{};
    for (final line in <String>[...primary.lines, ...secondary.lines]) {
      if (keys.add(searchText(line))) lines.add(line);
    }
    final barcodes = <String>{
      ...primary.barcodes,
      ...secondary.barcodes,
    }.take(8).toList(growable: false);
    final representative = MedicineFrameEvidence(
      barcode: barcodes.isEmpty ? '' : barcodes.first,
      barcodes: barcodes,
      text: lines.join('\n'),
      source: primary.frame.source,
      sequence: primary.frame.sequence,
      timestampMs: primary.frame.timestampMs,
      quality: max(a.frame.quality, b.frame.quality),
      startsNewItem:
          primary.frame.startsNewItem || secondary.frame.startsNewItem,
    );
    final effectiveQuality = max(a.effectiveQuality, b.effectiveQuality);
    return _PreparedFrame(
      frame: representative,
      lines: lines,
      normalizedText: searchText(lines.join(' ')),
      barcodes: barcodes,
      // Re-extraction makes the fused frame one vote, while keeping facts that
      // were legible from only one angle.
      candidates: _extractCandidates(
        lines,
        representative,
        effectiveQuality,
        knowledgeResolver,
      ),
      effectiveQuality: effectiveQuality,
    );
  }

  bool _strongFieldConflict(
    _PreparedFrame a,
    _PreparedFrame b,
    String field, {
    double similarityFloor = 1,
  }) {
    final left = _bestCandidate(<_PreparedFrame>[a], field);
    final right = _bestCandidate(<_PreparedFrame>[b], field);
    if (left == null ||
        right == null ||
        left.score < .76 ||
        right.score < .76) {
      return false;
    }
    final leftKey = _candidateKey(field, left.value);
    final rightKey = _candidateKey(field, right.value);
    if (leftKey == rightKey) return false;
    return similarityFloor >= 1 ||
        orderedSimilarity(leftKey, rightKey) < similarityFloor;
  }

  bool _startsNewMedicine(List<_PreparedFrame> group, _PreparedFrame next) {
    if (next.frame.startsNewItem) return true;
    final recent = group.reversed.take(4).toList(growable: false);
    // A GTIN commonly identifies a product, not a physical batch. Therefore a
    // confidently different batch or expiry is a stronger stock boundary than
    // seeing the same barcode again.
    final recentBatch = _bestCandidate(recent, 'batchNumber');
    final nextBatch = _bestCandidate(<_PreparedFrame>[next], 'batchNumber');
    if (recentBatch != null &&
        nextBatch != null &&
        recentBatch.score >= .76 &&
        nextBatch.score >= .76 &&
        _candidateKey('batchNumber', recentBatch.value) !=
            _candidateKey('batchNumber', nextBatch.value) &&
        orderedSimilarity(
              _candidateKey('batchNumber', recentBatch.value),
              _candidateKey('batchNumber', nextBatch.value),
            ) <
            .72) {
      return true;
    }
    final recentExpiry = _bestCandidate(recent, 'expiry');
    final nextExpiry = _bestCandidate(<_PreparedFrame>[next], 'expiry');
    if (recentExpiry != null &&
        nextExpiry != null &&
        recentExpiry.score >= .84 &&
        nextExpiry.score >= .84 &&
        recentExpiry.value != nextExpiry.value) {
      return true;
    }
    final knownBarcodes = recent.expand((frame) => frame.barcodes).toSet();
    if (knownBarcodes.isNotEmpty && next.barcodes.isNotEmpty) {
      if (knownBarcodes.intersection(next.barcodes.toSet()).isNotEmpty) {
        return false;
      }
      return true;
    }

    final previousIdentity = _bestIdentity(recent);
    final nextIdentity = _bestIdentity(<_PreparedFrame>[next]);
    if (previousIdentity != null && nextIdentity != null) {
      final similarity = orderedSimilarity(
        searchText(previousIdentity.value),
        searchText(nextIdentity.value),
      );
      if (similarity >= .82) {
        final previousStrength = _bestCandidate(recent, 'strength');
        final nextStrength = _bestCandidate(<_PreparedFrame>[next], 'strength');
        if (previousStrength != null &&
            nextStrength != null &&
            _strengthKey(previousStrength.value) !=
                _strengthKey(nextStrength.value) &&
            previousStrength.score >= .72 &&
            nextStrength.score >= .72) {
          return true;
        }
        return false;
      }
      if (previousIdentity.score >= .68 &&
          nextIdentity.score >= .68 &&
          similarity < .52) {
        return true;
      }
    }

    final previousTokens = <String>{
      for (final frame in recent) ..._identityTokens(frame.normalizedText),
    };
    final nextTokens = _identityTokens(next.normalizedText);
    if (previousTokens.isNotEmpty && nextTokens.isNotEmpty) {
      final overlap =
          previousTokens.intersection(nextTokens).length /
          min(previousTokens.length, nextTokens.length);
      final lastTime = recent.first.frame.timestampMs;
      final gap = lastTime == null || next.frame.timestampMs == null
          ? 0
          : next.frame.timestampMs! - lastTime;
      if (gap > 10000 && overlap < .12 && nextTokens.length >= 2) return true;
    }
    return false;
  }

  void _repairWeakBoundaries(List<List<_PreparedFrame>> groups) {
    for (var index = groups.length - 1; index > 0; index--) {
      final current = groups[index];
      final previous = groups[index - 1];
      if (current.isEmpty || previous.isEmpty) continue;
      if (current.length == 1 && !_hasStrongIdentity(current.single)) {
        previous.addAll(current);
        current.clear();
      }
    }
    groups.removeWhere((group) => group.isEmpty);
  }

  bool _hasStrongIdentity(_PreparedFrame frame) =>
      frame.barcodes.isNotEmpty ||
      (frame.candidates['name']?.any((value) => value.score >= .68) ?? false);

  MedicineScanDraft _fuse(List<_PreparedFrame> group) {
    final candidates = <String, List<_Candidate>>{};
    for (final frame in group) {
      for (final entry in frame.candidates.entries) {
        candidates
            .putIfAbsent(entry.key, () => <_Candidate>[])
            .addAll(entry.value);
      }
      for (final barcode in frame.barcodes) {
        candidates
            .putIfAbsent('barcode', () => <_Candidate>[])
            .add(
              _Candidate(
                value: barcode,
                score: .98 * frame.effectiveQuality.clamp(.72, 1),
                sequence: frame.frame.sequence,
              ),
            );
      }
    }

    final fields = <String, ExtractedMedicineField>{};
    for (final entry in candidates.entries) {
      if (entry.key == 'packSize' || entry.key == 'mrp') continue;
      final resolved = _resolve(entry.key, entry.value);
      if (!resolved.isEmpty) fields[entry.key] = resolved;
    }

    // A labelled composition is safer than inventing a brand. If the pack has
    // no readable trade name, leave name blank so the review remains explicit.
    final name = fields['name'];
    if (name != null && name.confidence >= .70 && fields['brand'] == null) {
      fields['brand'] = ExtractedMedicineField(
        value: name.value,
        confidence: (name.confidence - .08).clamp(0, 1),
        support: name.support,
        conflicted: name.conflicted,
      );
    }

    final mfg = fields['mfg'];
    final expiry = fields['expiry'];
    if (mfg != null && expiry != null) {
      final mfgDate = _dateForComparison(mfg.value, monthEnd: false);
      final expiryDate = _dateForComparison(expiry.value, monthEnd: true);
      if (mfgDate == null ||
          expiryDate == null ||
          mfgDate.isAfter(expiryDate)) {
        fields.remove('mfg');
      }
    }

    final rawLines = <String>[];
    final rawKeys = <String>{};
    for (final frame
        in group.toList()
          ..sort((a, b) => b.effectiveQuality.compareTo(a.effectiveQuality))) {
      for (final line in frame.lines) {
        final key = searchText(line);
        if (rawKeys.add(key)) rawLines.add(line);
      }
    }
    final rawText = rawLines.join('\n');
    final safeRaw = rawText.length <= 28000
        ? rawText
        : rawText.substring(0, 28000);
    final keywords = _keywords(fields, safeRaw);
    final meaningful = fields.entries
        .where(
          (entry) =>
              !entry.value.isEmpty &&
              !const {'barcode', 'mfg', 'expiry'}.contains(entry.key),
        )
        .map((entry) => entry.value.confidence)
        .toList();
    final overall = meaningful.isEmpty
        ? 0.35
        : (meaningful.reduce((a, b) => a + b) / meaningful.length)
              .clamp(0, 1)
              .toDouble();
    final pack = _resolve(
      'packSize',
      candidates['packSize'] ?? const <_Candidate>[],
    );
    final mrp = _resolve('mrp', candidates['mrp'] ?? const <_Candidate>[]);

    return MedicineScanDraft(
      fields: Map<String, ExtractedMedicineField>.unmodifiable(fields),
      rawText: safeRaw,
      searchKeywords: keywords,
      frameSequences: group
          .map((frame) => frame.frame.sequence)
          .toList(growable: false),
      expiryMonthOnly: fields['expiry']?.value.length == 7,
      mfgMonthOnly: fields['mfg']?.value.length == 7,
      printedPackSize: pack.value,
      printedMrp: mrp.value,
      overallConfidence: overall,
    );
  }

  ExtractedMedicineField _resolve(String field, List<_Candidate> values) {
    if (values.isEmpty) return const ExtractedMedicineField();
    final buckets = <String, List<_Candidate>>{};
    for (final candidate in values) {
      final key = _candidateKey(field, candidate.value);
      if (key.isEmpty) continue;
      String? matching;
      if (field == 'name' ||
          field == 'brand' ||
          field == 'salt' ||
          field == 'manufacturer') {
        final similarityFloor = field == 'salt' ? .91 : .93;
        for (final existing in buckets.keys) {
          if (orderedSimilarity(existing, key) >= similarityFloor) {
            matching = existing;
            break;
          }
        }
      }
      buckets.putIfAbsent(matching ?? key, () => <_Candidate>[]).add(candidate);
    }
    if (buckets.isEmpty) return const ExtractedMedicineField();
    final ranked = buckets.entries.map((entry) {
      final sequences = entry.value.map((value) => value.sequence).toSet();
      final best = entry.value.reduce((a, b) => a.score >= b.score ? a : b);
      final average =
          entry.value.fold<double>(0, (sum, value) => sum + value.score) /
          entry.value.length;
      final confidence =
          (best.score * .70 +
                  average * .18 +
                  min(sequences.length - 1, 3) * .055)
              .clamp(0, .99)
              .toDouble();
      return _ResolvedCandidate(best.value, confidence, sequences.length);
    }).toList()..sort((a, b) => b.confidence.compareTo(a.confidence));
    final winner = ranked.first;
    final runnerUp = ranked.length > 1 ? ranked[1] : null;
    final conflicted =
        runnerUp != null &&
        runnerUp.confidence >= .58 &&
        winner.confidence - runnerUp.confidence < .14;
    return ExtractedMedicineField(
      value: winner.value,
      confidence: conflicted ? winner.confidence * .82 : winner.confidence,
      support: winner.support,
      conflicted: conflicted,
    );
  }

  Map<String, List<_Candidate>> _extractCandidates(
    List<String> lines,
    MedicineFrameEvidence frame,
    double quality,
    _OfflineMedicineKnowledge knowledgeResolver,
  ) {
    final result = <String, List<_Candidate>>{};
    void add(
      String field,
      String value,
      double score, {
      bool adjustForOcrQuality = true,
    }) {
      final clean = _cleanValue(value);
      if (clean.isEmpty) return;
      final calibrated = adjustForOcrQuality
          ? score * (.72 + quality * .28)
          : score;
      result
          .putIfAbsent(field, () => <_Candidate>[])
          .add(
            _Candidate(
              value: clean,
              score: calibrated.clamp(0, .99),
              sequence: frame.sequence,
            ),
          );
    }

    // A machine-read barcode is independent of OCR clarity. Only unambiguous
    // identity facts shared by every local record with that barcode are used.
    for (final hit in knowledgeResolver.barcodeFacts(frame.allBarcodes)) {
      add(hit.field, hit.value, hit.score, adjustForOcrQuality: false);
    }

    // Composition is a small labelled section, not necessarily one OCR line.
    // Keep the span together so "Paracetamol I.P." and a following "650 mg"
    // are understood as one ingredient fact, and never compete as a brand.
    final compositionLines = <int>{};
    for (var index = 0; index < lines.length; index++) {
      if (compositionLines.contains(index) ||
          !_compositionLabel.hasMatch(searchText(lines[index]))) {
        continue;
      }
      compositionLines.add(index);
      final parts = <String>[];
      final after = _afterLabel(lines[index], _compositionLabel);
      if (after.isNotEmpty) parts.add(after);
      for (
        var nextIndex = index + 1;
        nextIndex < lines.length && nextIndex <= index + 5;
        nextIndex++
      ) {
        final normalized = searchText(lines[nextIndex]);
        if (_endsCompositionScope(normalized)) break;
        compositionLines.add(nextIndex);
        parts.add(lines[nextIndex]);
        if (parts.fold<int>(0, (sum, value) => sum + value.length) > 260) {
          break;
        }
      }
      final source = parts.join(' ');
      final salt = _saltValue(source);
      if (salt.isNotEmpty) add('salt', salt, .94);
      for (final hit in knowledgeResolver.matchSalt(source)) {
        add(hit.field, hit.value, hit.score);
      }
      final strengths = _strengths(source);
      if (strengths.isNotEmpty) {
        add('strength', strengths.join(' + '), .93);
      }
    }

    for (var index = 0; index < lines.length; index++) {
      final line = lines[index];
      final lower = searchText(line);
      final next = index + 1 < lines.length ? lines[index + 1] : '';

      final mfg = _dateNearLabel(lines, index, _mfgLabel, expiry: false);
      if (mfg != null) add('mfg', mfg.value, mfg.confidence);
      final expiry = _dateNearLabel(lines, index, _expiryLabel, expiry: true);
      if (expiry != null) add('expiry', expiry.value, expiry.confidence);

      final batch = _labelValue(
        line,
        RegExp(
          r'\b(?:batch(?:\s*(?:no|number))?|b\s*\.?\s*no|lot(?:\s*(?:no|number))?)\b\s*[:#.-]*\s*([a-z0-9][a-z0-9\-/]{2,24})',
          caseSensitive: false,
        ),
      );
      if (batch.isNotEmpty && !_looksLikeDate(batch)) {
        add('batchNumber', batch.toUpperCase(), .91);
      }

      final manufacturer = _afterLabel(
        line,
        RegExp(
          r'\b(?:manufactured|mfd|made)\s+by\b|\bmanufacturer\b',
          caseSensitive: false,
        ),
      );
      if (manufacturer.isNotEmpty) {
        add('manufacturer', manufacturer, .88);
        for (final hit in knowledgeResolver.matchManufacturer(manufacturer)) {
          add(hit.field, hit.value, hit.score);
        }
      } else if (_manufacturerHeader.hasMatch(lower) && next.isNotEmpty) {
        add('manufacturer', next, .78);
        for (final hit in knowledgeResolver.matchManufacturer(next)) {
          add(hit.field, hit.value, hit.score);
        }
      }

      final explicitBrand = _afterLabel(
        line,
        RegExp(r'\b(?:brand|trade|product)\s*name\b', caseSensitive: false),
      );
      if (explicitBrand.isNotEmpty) {
        final value = _productName(explicitBrand);
        add('name', value, .94);
        add('brand', value, .96);
      }

      if (!compositionLines.contains(index) && _looksLikeGenericLine(line)) {
        final salt = _saltValue(line);
        if (salt.isNotEmpty) add('salt', salt, .76);
        for (final hit in knowledgeResolver.matchSalt(line)) {
          add(hit.field, hit.value, hit.score);
        }
      }

      if (!compositionLines.contains(index) &&
          !_priceNoise.hasMatch(lower) &&
          !_packNoise.hasMatch(lower) &&
          !_dateNoise.hasMatch(lower)) {
        final strengths = _strengths(line);
        if (strengths.isNotEmpty) add('strength', strengths.join(' + '), .88);
      }

      final form = _formValue(lower);
      if (form.isNotEmpty) add('form', form, .72);

      final pack = _packSize(line);
      if (pack.isNotEmpty) add('packSize', pack, .88);
      final mrp = _mrpValue(line);
      if (mrp.isNotEmpty) add('mrp', mrp, .92);

      if (!compositionLines.contains(index) && _eligibleNameLine(line, index)) {
        for (final hit in knowledgeResolver.matchIdentity(line)) {
          add(hit.field, hit.value, hit.score);
        }
        final name = _productName(line);
        if (name.isNotEmpty) {
          final uppercase = _uppercaseRatio(line);
          final early = index < 3 ? .10 : 0.0;
          final trademark = RegExp(r'[®™]').hasMatch(line) ? .08 : 0.0;
          add(
            'name',
            name,
            (.61 + early + trademark + min(uppercase, .25)).clamp(.55, .91),
          );
        }
      }
    }
    return result;
  }

  _Candidate? _bestIdentity(List<_PreparedFrame> frames) {
    final name = _bestCandidate(frames, 'name');
    if (name != null) return name;
    return null;
  }

  _Candidate? _bestCandidate(List<_PreparedFrame> frames, String field) {
    final values = frames
        .expand((frame) => frame.candidates[field] ?? const <_Candidate>[])
        .toList();
    if (values.isEmpty) return null;
    return values.reduce((a, b) => a.score >= b.score ? a : b);
  }
}

/// A field value supported by the pharmacist's private, verified inventory or
/// by the conservative built-in active-ingredient vocabulary.
class _KnowledgeHit {
  const _KnowledgeHit(this.field, this.value, this.score);

  final String field;
  final String value;
  final double score;
}

class _KnowledgePhrase {
  const _KnowledgePhrase({
    required this.indexField,
    required this.outputField,
    required this.value,
    required this.key,
    required this.verifiedLocal,
  });

  final String indexField;
  final String outputField;
  final String value;
  final String key;
  final bool verifiedLocal;
}

class _RankedKnowledgePhrase {
  const _RankedKnowledgePhrase(
    this.phrase,
    this.similarity,
    this.queryCoverage,
    this.rank,
  );

  final _KnowledgePhrase phrase;
  final double similarity;
  final double queryCoverage;
  final double rank;
}

class _KnowledgeWindowMatch {
  const _KnowledgeWindowMatch(this.similarity, this.queryCoverage);

  final double similarity;
  final double queryCoverage;
}

/// Bounded inverted index used directly by the core parser.
///
/// This is intentionally not a second database. It is rebuilt inside the
/// parser isolate from identity-only local records, so pharmacist corrections
/// become recognition memory on the next scan without network access or model
/// hallucination. Candidate generation is span based and field scoped; the
/// complete noisy OCR document is never matched to one arbitrary medicine.
class _OfflineMedicineKnowledge {
  _OfflineMedicineKnowledge(Iterable<MedicineKnowledgeEntry> source) {
    for (final entry in source.take(maxMedicineKnowledgeEntries)) {
      _addLocalEntry(entry);
    }
    for (final salt in _embeddedActiveIngredients) {
      _addPhrase(
        indexField: 'salt',
        outputField: 'salt',
        alias: salt,
        value: salt,
        verifiedLocal: false,
      );
    }
    for (final alias in _embeddedActiveIngredientAliases.entries) {
      _addPhrase(
        indexField: 'salt',
        outputField: 'salt',
        alias: alias.key,
        value: alias.value,
        verifiedLocal: false,
      );
    }
    _buildIndexes();
  }

  static const _maxPhrases = 60000;
  static const _maxCandidatePhrases = 64;

  final List<_KnowledgePhrase> _phrases = <_KnowledgePhrase>[];
  final Set<String> _phraseKeys = <String>{};
  final Map<String, Map<String, List<int>>> _grams =
      <String, Map<String, List<int>>>{};
  final Map<String, Map<String, List<int>>> _exact =
      <String, Map<String, List<int>>>{};
  final Map<String, List<MedicineKnowledgeEntry>> _barcodes =
      <String, List<MedicineKnowledgeEntry>>{};

  void _addLocalEntry(MedicineKnowledgeEntry entry) {
    if (!entry._hasIdentity) return;
    final barcode = _barcodeKnowledgeKey(entry.barcode);
    if (barcode.length >= 4 && barcode.length <= 64) {
      _barcodes
          .putIfAbsent(barcode, () => <MedicineKnowledgeEntry>[])
          .add(entry);
    }

    _addIdentity('name', entry.name, entry.strength);
    _addIdentity('brand', entry.brand, entry.strength);
    _addPhrase(
      indexField: 'manufacturer',
      outputField: 'manufacturer',
      alias: entry.manufacturer,
      value: entry.manufacturer,
      verifiedLocal: true,
    );
    _addSalt(entry.salt, verifiedLocal: true);
  }

  void _addIdentity(String field, String value, String strength) {
    final clean = _cleanValue(value);
    if (clean.isEmpty) return;
    _addPhrase(
      indexField: field,
      outputField: field,
      alias: clean,
      value: clean,
      verifiedLocal: true,
    );
    final strengthKey = _knowledgeStrengthKey(strength);
    if (strengthKey.isEmpty) return;
    _addPhrase(
      indexField: field,
      outputField: field,
      alias: '$clean $strengthKey',
      value: clean,
      verifiedLocal: true,
    );
    // Strength is emitted only when OCR contains a numeric identity signature;
    // a bare brand must never invent a strength from the only local record.
    _addPhrase(
      indexField: 'strengthHint',
      outputField: 'strength',
      alias: '$clean $strengthKey',
      value: strength,
      verifiedLocal: true,
    );
  }

  void _addSalt(String value, {required bool verifiedLocal}) {
    final clean = _cleanValue(value);
    if (clean.isEmpty) return;
    _addPhrase(
      indexField: 'salt',
      outputField: 'salt',
      alias: clean,
      value: clean,
      verifiedLocal: verifiedLocal,
    );
    final components = clean
        .split(RegExp(r'\s*(?:\+|;)\s*'))
        .map(_cleanValue)
        .where((part) => part.length >= 4)
        .toList(growable: false);
    if (components.length < 2) return;
    for (final component in components.take(6)) {
      _addPhrase(
        indexField: 'salt',
        outputField: 'salt',
        alias: component,
        value: component,
        verifiedLocal: verifiedLocal,
      );
    }
  }

  void _addPhrase({
    required String indexField,
    required String outputField,
    required String alias,
    required String value,
    required bool verifiedLocal,
  }) {
    if (_phrases.length >= _maxPhrases) return;
    final cleanValue = _cleanValue(value);
    final key = _knowledgeKey(alias);
    if (cleanValue.isEmpty || key.length < 2 || key.length > 160) return;
    final dedupe = '$indexField|$outputField|$key|${_knowledgeKey(cleanValue)}';
    if (!_phraseKeys.add(dedupe)) return;
    _phrases.add(
      _KnowledgePhrase(
        indexField: indexField,
        outputField: outputField,
        value: cleanValue,
        key: key,
        verifiedLocal: verifiedLocal,
      ),
    );
  }

  void _buildIndexes() {
    for (var index = 0; index < _phrases.length; index++) {
      final phrase = _phrases[index];
      _exact
          .putIfAbsent(phrase.indexField, () => <String, List<int>>{})
          .putIfAbsent(phrase.key, () => <int>[])
          .add(index);
      final fieldIndex = _grams.putIfAbsent(
        phrase.indexField,
        () => <String, List<int>>{},
      );
      for (final gram in grams(phrase.key)) {
        fieldIndex.putIfAbsent(gram, () => <int>[]).add(index);
      }
    }
  }

  List<_KnowledgeHit> barcodeFacts(Iterable<String> rawBarcodes) {
    final hits = <_KnowledgeHit>[];
    for (final raw in rawBarcodes.take(8)) {
      final entries = _barcodes[_barcodeKnowledgeKey(raw)];
      if (entries == null || entries.isEmpty) continue;
      void addConsensus(
        String field,
        String Function(MedicineKnowledgeEntry entry) read,
        double score,
      ) {
        final values = <String, String>{};
        for (final entry in entries) {
          final value = _cleanValue(read(entry));
          if (value.isEmpty || (field == 'form' && value == 'Other')) continue;
          values.putIfAbsent(_candidateKey(field, value), () => value);
        }
        // Duplicate/mistyped barcode records are treated as a conflict, not as
        // permission to select whichever medicine happened to be inserted first.
        if (values.length == 1) {
          hits.add(_KnowledgeHit(field, values.values.single, score));
        }
      }

      addConsensus('name', (entry) => entry.name, .995);
      addConsensus('brand', (entry) => entry.brand, .99);
      addConsensus('salt', (entry) => entry.salt, .99);
      addConsensus('strength', (entry) => entry.strength, .985);
      addConsensus('form', (entry) => entry.form, .98);
      addConsensus('manufacturer', (entry) => entry.manufacturer, .975);
    }
    return hits;
  }

  List<_KnowledgeHit> matchIdentity(String raw) {
    final hits = <_KnowledgeHit>[
      ..._match('name', raw),
      ..._match('brand', raw),
    ];
    if (_knowledgeKey(raw).split(' ').any(_isNumericKnowledgeToken)) {
      hits.addAll(_match('strengthHint', raw));
    }
    return hits;
  }

  List<_KnowledgeHit> matchManufacturer(String raw) =>
      _match('manufacturer', raw);

  List<_KnowledgeHit> matchSalt(String raw) {
    final whole = _match('salt', raw);
    final wholeCombination = whole
        .where((hit) => hit.value.contains('+'))
        .toList(growable: false);
    if (wholeCombination.isNotEmpty) return wholeCombination;

    final components = raw
        .split(RegExp(r'\s*(?:\+|;)\s*'))
        .map(_cleanValue)
        .where((part) => part.length >= 3)
        .take(6)
        .toList(growable: false);
    if (components.length < 2) return whole;
    final canonical = <String>[];
    var score = 1.0;
    for (final component in components) {
      final matches = _match('salt', component);
      if (matches.length != 1) return const <_KnowledgeHit>[];
      canonical.add(matches.single.value);
      score = min(score, matches.single.score);
    }
    final distinct = <String>[];
    final seen = <String>{};
    for (final value in canonical) {
      if (seen.add(_candidateKey('salt', value))) distinct.add(value);
    }
    if (distinct.length < 2) return whole;
    return <_KnowledgeHit>[_KnowledgeHit('salt', distinct.join(' + '), score)];
  }

  List<_KnowledgeHit> _match(String field, String raw) {
    final query = _knowledgeKey(raw);
    if (query.length < 2) return const <_KnowledgeHit>[];
    final candidateIndexes = _candidateIndexes(field, query);
    if (candidateIndexes.isEmpty) return const <_KnowledgeHit>[];
    final rankedByValue = <String, _RankedKnowledgePhrase>{};
    for (final index in candidateIndexes) {
      final phrase = _phrases[index];
      final match = _bestKnowledgeWindow(query, phrase.key);
      final compactLength = phrase.key.replaceAll(' ', '').length;
      if (compactLength < 4 && match.similarity < .999) continue;
      final threshold = switch (field) {
        'salt' => phrase.verifiedLocal ? .84 : .88,
        'manufacturer' => .90,
        'strengthHint' => .91,
        _ => .87,
      };
      if (match.similarity < threshold) continue;
      final rank = match.similarity * .90 + match.queryCoverage * .10;
      final key =
          '${phrase.outputField}|${_candidateKey(phrase.outputField, phrase.value)}';
      final current = rankedByValue[key];
      final candidate = _RankedKnowledgePhrase(
        phrase,
        match.similarity,
        match.queryCoverage,
        rank,
      );
      if (current == null || candidate.rank > current.rank) {
        rankedByValue[key] = candidate;
      }
    }
    final ranked = rankedByValue.values.toList(growable: false)
      ..sort((a, b) => b.rank.compareTo(a.rank));
    if (ranked.isEmpty) return const <_KnowledgeHit>[];
    final selected = <_RankedKnowledgePhrase>[ranked.first];
    if (ranked.length > 1 && ranked.first.rank - ranked[1].rank < .035) {
      selected.add(ranked[1]);
    }
    return selected
        .map((item) {
          final base = item.phrase.verifiedLocal ? .75 : .73;
          final score =
              (base +
                      item.similarity * .22 +
                      item.queryCoverage * .02 +
                      (item.phrase.verifiedLocal ? .01 : 0))
                  .clamp(0, .99)
                  .toDouble();
          return _KnowledgeHit(
            item.phrase.outputField,
            item.phrase.value,
            score,
          );
        })
        .toList(growable: false);
  }

  List<int> _candidateIndexes(String field, String query) {
    final exact = _exact[field]?[query];
    if (exact != null && exact.isNotEmpty) {
      return exact.take(_maxCandidatePhrases).toList(growable: false);
    }
    final index = _grams[field];
    if (index == null || index.isEmpty) return const <int>[];
    final postings =
        grams(query)
            .map((gram) => index[gram])
            .whereType<List<int>>()
            .toList(growable: false)
          ..sort((a, b) => a.length.compareTo(b.length));
    final votes = <int, int>{};
    for (final posting in postings.take(14)) {
      for (final phraseIndex in posting.take(768)) {
        votes.update(phraseIndex, (value) => value + 1, ifAbsent: () => 1);
      }
    }
    final ranked = votes.entries.toList(growable: false)
      ..sort((a, b) {
        final votes = b.value.compareTo(a.value);
        return votes != 0 ? votes : a.key.compareTo(b.key);
      });
    return ranked
        .take(_maxCandidatePhrases)
        .map((entry) => entry.key)
        .toList(growable: false);
  }
}

class _PreparedFrame {
  const _PreparedFrame({
    required this.frame,
    required this.lines,
    required this.normalizedText,
    required this.barcodes,
    required this.candidates,
    required this.effectiveQuality,
  });
  final MedicineFrameEvidence frame;
  final List<String> lines;
  final String normalizedText;
  final List<String> barcodes;
  final Map<String, List<_Candidate>> candidates;
  final double effectiveQuality;
}

class _Candidate {
  const _Candidate({
    required this.value,
    required this.score,
    required this.sequence,
  });
  final String value;
  final double score;
  final int sequence;
}

class _ResolvedCandidate {
  const _ResolvedCandidate(this.value, this.confidence, this.support);
  final String value;
  final double confidence;
  final int support;
}

class _ParsedDate {
  const _ParsedDate(this.value, this.confidence);
  final String value;
  final double confidence;
}

String _barcodeKnowledgeKey(String value) =>
    value.replaceAll(RegExp(r'[^A-Za-z0-9]'), '').toUpperCase();

String _knowledgeKey(String value) {
  final tokens = <String>[];
  for (final raw in searchText(value).split(' ').take(48)) {
    var token = _repairKnowledgeToken(raw);
    token = token.replaceAllMapped(
      RegExp(r'^(\d+(?:\.\d+)?)(?:mcg|mg|g|ml|iu)$'),
      (match) => match[1]!,
    );
    if (token.isEmpty || _knowledgeNoise.contains(token)) continue;
    tokens.add(token);
  }
  final joined = tokens.join(' ');
  return joined.length <= 180 ? joined : joined.substring(0, 180).trim();
}

String _repairKnowledgeToken(String token) {
  if (!RegExp(r'\d').hasMatch(token) || !RegExp(r'[a-z]').hasMatch(token)) {
    return token;
  }
  if (RegExp(r'^\d[0-9oilsbz]+$').hasMatch(token)) {
    return token
        .replaceAll('o', '0')
        .replaceAll('i', '1')
        .replaceAll('l', '1')
        .replaceAll('s', '5')
        .replaceAll('b', '8')
        .replaceAll('z', '2');
  }
  if (RegExp(r'^[a-z][a-z0-9]+$').hasMatch(token)) {
    return token
        .replaceAll('0', 'o')
        .replaceAll('1', 'i')
        .replaceAll('5', 's')
        .replaceAll('8', 'b');
  }
  return token;
}

bool _isNumericKnowledgeToken(String value) =>
    RegExp(r'^\d+(?:\.\d+)?$').hasMatch(value);

String _knowledgeStrengthKey(String value) => _knowledgeKey(
  value,
).split(' ').where(_isNumericKnowledgeToken).take(4).join(' ');

_KnowledgeWindowMatch _bestKnowledgeWindow(String query, String phrase) {
  final queryTokens = query
      .split(' ')
      .where((value) => value.isNotEmpty)
      .toList();
  final phraseTokens = phrase
      .split(' ')
      .where((value) => value.isNotEmpty)
      .toList();
  if (queryTokens.isEmpty || phraseTokens.isEmpty) {
    return const _KnowledgeWindowMatch(0, 0);
  }
  final coverage =
      min(queryTokens.length, phraseTokens.length) /
      max(queryTokens.length, phraseTokens.length);
  var best = orderedSimilarity(query, phrase);
  final smallest = max(1, phraseTokens.length - 1);
  final largest = min(queryTokens.length, phraseTokens.length + 1);
  for (var width = smallest; width <= largest; width++) {
    for (var start = 0; start + width <= queryTokens.length; start++) {
      final window = queryTokens.sublist(start, start + width).join(' ');
      best = max(best, orderedSimilarity(window, phrase));
    }
  }
  return _KnowledgeWindowMatch(best.clamp(0, 1).toDouble(), coverage);
}

const _knowledgeNoise = <String>{
  'active',
  'ingredient',
  'composition',
  'generic',
  'salt',
  'each',
  'contains',
  'equivalent',
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
  'brand',
  'trade',
  'product',
  'name',
  'ip',
  'bp',
  'usp',
  'ph',
  'eur',
  'mg',
  'mcg',
  'ml',
  'iu',
};

/// Conservative lexical anchors, not a product catalogue and not treatment
/// advice. They only canonicalize an ingredient span already visible in OCR.
const _embeddedActiveIngredients = <String>{
  'Aceclofenac',
  'Albendazole',
  'Ambroxol',
  'Amlodipine',
  'Amoxicillin',
  'Aspirin',
  'Atenolol',
  'Atorvastatin',
  'Azithromycin',
  'Bromhexine',
  'Budesonide',
  'Calcium Carbonate',
  'Cefixime',
  'Cefuroxime',
  'Cephalexin',
  'Cetirizine',
  'Chlorpheniramine Maleate',
  'Cholecalciferol',
  'Ciprofloxacin',
  'Clavulanic Acid',
  'Clotrimazole',
  'Dexamethasone',
  'Dextromethorphan',
  'Diclofenac',
  'Domperidone',
  'Doxofylline',
  'Doxycycline',
  'Esomeprazole',
  'Famotidine',
  'Ferrous Ascorbate',
  'Fexofenadine',
  'Fluconazole',
  'Folic Acid',
  'Gabapentin',
  'Glimepiride',
  'Guaifenesin',
  'Ibuprofen',
  'Ivermectin',
  'Levofloxacin',
  'Levosalbutamol',
  'Levocetirizine',
  'Levocetirizine Hydrochloride',
  'Loratadine',
  'Losartan',
  'Metformin',
  'Metoprolol',
  'Metronidazole',
  'Montelukast',
  'Montelukast Sodium',
  'Naproxen',
  'Omeprazole',
  'Ondansetron',
  'Pantoprazole',
  'Paracetamol',
  'Phenylephrine',
  'Prednisolone',
  'Pregabalin',
  'Rabeprazole',
  'Rosuvastatin',
  'Salbutamol',
  'Sitagliptin',
  'Telmisartan',
  'Terbinafine',
  'Tinidazole',
  'Vildagliptin',
};

const _embeddedActiveIngredientAliases = <String, String>{
  'Acetaminophen': 'Paracetamol',
};

final _mfgLabel = RegExp(
  r'\b(?:mfg|mfd|manufactured|manufacturing|date\s+of\s+mfg)\b(?:\s*date)?',
  caseSensitive: false,
);
final _expiryLabel = RegExp(
  r'\b(?:exp|expiry|expires|use\s*before|use\s*by|best\s*before)\b(?:\s*date)?',
  caseSensitive: false,
);
final _compositionLabel = RegExp(
  r'\b(?:composition|compositions|generic|salt|active\s+ingredient|each\s+(?:film\s+coated\s+|uncoated\s+)?(?:tablet|capsule|\d+\s*ml)\s+contains)\b',
  caseSensitive: false,
);
final _manufacturerHeader = RegExp(
  r'\b(?:manufactured|mfd|made)\s+by\b|\bmanufacturer\b',
  caseSensitive: false,
);
final _dateNoise = RegExp(
  r'\b(?:mfg|mfd|exp|expiry|expires|use\s*before|use\s*by|best\s*before)\b',
  caseSensitive: false,
);
final _priceNoise = RegExp(
  r'\b(?:mrp|price|rs|inr|inclusive|tax|₹)\b',
  caseSensitive: false,
);
final _packNoise = RegExp(
  r'\b(?:pack|strip|blister|bottle|tablets?|capsules?|sachets?)\s*(?:of|size|x)?\s*\d+|\b\d+\s*x\s*\d+\b',
  caseSensitive: false,
);
final _compositionStop = RegExp(
  r'\b(?:excipients?|colou?r|dosage|directions?|storage|warning|schedule|keep|manufactured|marketed|batch|lot|mfg|mfd|exp|expiry|mrp|price|net\s*(?:qty|content))\b',
  caseSensitive: false,
);

String _cleanLine(String value) => value
    .replaceAll(RegExp(r'[\u0000-\u0008\u000B\u000C\u000E-\u001F]'), ' ')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

String _cleanValue(String value) => _cleanLine(
  value,
).replaceAll(RegExp(r'^[\s:;,.#-]+|[\s:;,.#-]+$'), '').trim();

String _labelValue(String line, RegExp expression) =>
    expression.firstMatch(line)?.group(1)?.trim() ?? '';

String _afterLabel(String line, RegExp label) {
  final match = label.firstMatch(line);
  if (match == null) return '';
  return _cleanValue(line.substring(match.end));
}

_ParsedDate? _labelledDate(String line, RegExp label, {required bool expiry}) {
  final match = label.firstMatch(line);
  if (match == null) return null;
  var tail = line.substring(match.end);
  final other = (expiry ? _mfgLabel : _expiryLabel).firstMatch(tail);
  if (other != null) tail = tail.substring(0, other.start);
  tail = tail.replaceFirst(RegExp(r'^[\s:;,.#-]+'), '');
  final value = _canonicalPrintedDate(tail, expiry: expiry);
  if (value == null) return null;
  return _ParsedDate(value, value.length == 7 ? .91 : .94);
}

_ParsedDate? _dateNearLabel(
  List<String> lines,
  int index,
  RegExp label, {
  required bool expiry,
}) {
  final direct = _labelledDate(lines[index], label, expiry: expiry);
  if (direct != null) return direct;
  if (!label.hasMatch(searchText(lines[index]))) return null;
  final otherLabel = expiry ? _mfgLabel : _expiryLabel;
  for (
    var nextIndex = index + 1;
    nextIndex < lines.length && nextIndex <= index + 2;
    nextIndex++
  ) {
    final next = lines[nextIndex];
    final normalized = searchText(next);
    if (otherLabel.hasMatch(normalized) ||
        _compositionStop.hasMatch(normalized)) {
      break;
    }
    final value = _canonicalPrintedDate(next, expiry: expiry);
    if (value != null) {
      final base = nextIndex == index + 1 ? .89 : .84;
      return _ParsedDate(value, value.length == 7 ? base : base + .02);
    }
  }
  return null;
}

String? _canonicalPrintedDate(String raw, {required bool expiry}) {
  var value = raw
      .toLowerCase()
      .replaceAllMapped(
        RegExp(r'(?<=\d)[oO](?=\d|\b)|(?<=\b)[oO](?=\d)'),
        (_) => '0',
      )
      .replaceAll(',', '.')
      .trim();
  const months = <String, int>{
    'jan': 1,
    'january': 1,
    'feb': 2,
    'february': 2,
    'mar': 3,
    'march': 3,
    'apr': 4,
    'april': 4,
    'may': 5,
    'jun': 6,
    'june': 6,
    'jul': 7,
    'july': 7,
    'aug': 8,
    'august': 8,
    'sep': 9,
    'sept': 9,
    'september': 9,
    'oct': 10,
    'october': 10,
    'nov': 11,
    'november': 11,
    'dec': 12,
    'december': 12,
  };
  final word = RegExp(
    r'(?:(\d{1,2})[\s./-]+)?([a-z]{3,9})[\s./-]+(\d{2,4})',
  ).firstMatch(value);
  if (word != null && months.containsKey(word[2])) {
    final year = _fullYear(int.parse(word[3]!));
    final month = months[word[2]]!;
    final day = word[1] == null ? null : int.tryParse(word[1]!);
    return _validatedIso(year, month, day, expiry: expiry);
  }
  final full = RegExp(
    r'(?<!\d)(\d{1,4})\s*[./-]\s*(\d{1,2})\s*[./-]\s*(\d{1,4})(?!\d)',
  ).firstMatch(value);
  if (full != null) {
    final a = int.parse(full[1]!);
    final b = int.parse(full[2]!);
    final c = int.parse(full[3]!);
    if (a > 99) return _validatedIso(a, b, c, expiry: expiry);
    return _validatedIso(_fullYear(c), b, a, expiry: expiry);
  }
  final spacedFull = RegExp(
    r'(?<!\d)(\d{1,2})\s+(\d{1,2})\s+(\d{2,4})(?!\d)',
  ).firstMatch(value);
  if (spacedFull != null) {
    return _validatedIso(
      _fullYear(int.parse(spacedFull[3]!)),
      int.parse(spacedFull[2]!),
      int.parse(spacedFull[1]!),
      expiry: expiry,
    );
  }
  final month = RegExp(
    r'(?<!\d)(\d{1,4})\s*[./-]\s*(\d{2,4})(?!\s*[./-]\s*\d)',
  ).firstMatch(value);
  if (month == null) return null;
  final a = int.parse(month[1]!);
  final b = int.parse(month[2]!);
  if (a > 99) return _validatedIso(a, b, null, expiry: expiry);
  return _validatedIso(_fullYear(b), a, null, expiry: expiry);
}

int _fullYear(int value) =>
    value >= 100 ? value : (value <= 79 ? 2000 + value : 1900 + value);

String? _validatedIso(int year, int month, int? day, {required bool expiry}) {
  if (year < 2000 || year > 2200 || month < 1 || month > 12) return null;
  if (day == null) {
    return '${year.toString().padLeft(4, '0')}-${month.toString().padLeft(2, '0')}';
  }
  final date = DateTime.utc(year, month, day);
  if (date.year != year || date.month != month || date.day != day) return null;
  return dateText(date);
}

DateTime? _dateForComparison(String value, {required bool monthEnd}) {
  try {
    if (value.length == 7) {
      final year = int.parse(value.substring(0, 4));
      final month = int.parse(value.substring(5, 7));
      return monthEnd
          ? DateTime.utc(year, month + 1, 0)
          : DateTime.utc(year, month, 1);
    }
    return parseDate(value, monthEnd: monthEnd);
  } catch (_) {
    return null;
  }
}

bool _looksLikeDate(String value) =>
    RegExp(r'^\d{1,4}[./-]\d{1,2}(?:[./-]\d{1,4})?$').hasMatch(value);

bool _endsCompositionScope(String normalized) =>
    normalized.isEmpty ||
    _compositionStop.hasMatch(normalized) ||
    _dateNoise.hasMatch(normalized) ||
    _manufacturerHeader.hasMatch(normalized) ||
    _priceNoise.hasMatch(normalized) ||
    _packNoise.hasMatch(normalized) ||
    RegExp(
      r'\b(?:batch|lot)\b|\bb\s*\.?\s*no\b',
      caseSensitive: false,
    ).hasMatch(normalized);

List<String> _strengths(String line) {
  final normalized = line
      .replaceAll('μ', 'µ')
      .replaceAllMapped(
        RegExp(r'(?<=\d)[oO](?=\s*(?:mg|mcg|µg|ml|g)\b)'),
        (_) => '0',
      );
  final matches = RegExp(
    r'(?<![a-z0-9])\d+(?:[.,]\d+)?\s*(?:mcg|µg|mg|g|iu|i\.u\.)(?:\s*/\s*\d+(?:[.,]\d+)?\s*(?:ml|g|dose|actuation))?|(?<![a-z0-9])\d+(?:[.,]\d+)?\s*mg\s*/\s*ml',
    caseSensitive: false,
  ).allMatches(normalized);
  final values = <String>[];
  for (final match in matches.take(4)) {
    final value = match[0]!
        .replaceAll(',', '.')
        .replaceAll(RegExp(r'\s+'), ' ')
        .replaceAllMapped(
          RegExp(r'(?<=\d)(mcg|µg|mg|g|iu)\b', caseSensitive: false),
          (unit) => ' ${unit[1]!.toLowerCase()}',
        )
        .trim();
    if (!values.map(_strengthKey).contains(_strengthKey(value)))
      values.add(value);
  }
  return values;
}

String _strengthKey(String value) => searchText(value).replaceAll(' ', '');

String _saltValue(String raw) {
  var value = raw
      .replaceAll(_compositionLabel, ' ')
      .replaceAll(
        RegExp(
          r'\b(?:i\s*\.?\s*p|b\s*\.?\s*p|u\s*\.?\s*s\s*\.?\s*p|ph\s*\.?\s*eur)\s*\.?',
          caseSensitive: false,
        ),
        ' ',
      )
      .replaceAll(
        RegExp(
          r'\b(?:equivalent\s+to|eq\.?\s*to|contains?|each|film\s+coated|uncoated|tablets?|capsules?|oral|solution|suspension|excipients?|colou?r|q\.?s\.?)\b',
          caseSensitive: false,
        ),
        ' ',
      );
  for (final strength in _strengths(value)) {
    value = value.replaceAll(
      RegExp(RegExp.escape(strength), caseSensitive: false),
      ' ',
    );
  }
  value = value
      .replaceAll(RegExp(r'\s*[+;/]\s*'), ' + ')
      .replaceAll(RegExp(r'[^A-Za-z\u0900-\u097f+()\-\s]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .replaceAll(RegExp(r'(?:\s*\+\s*)+$'), '')
      .trim();
  if (value.length < 3 || value.length > 180) return '';
  return _smartTitle(value);
}

bool _looksLikeGenericLine(String line) {
  final lower = searchText(line);
  return _strengths(line).isNotEmpty &&
      RegExp(r'\b(?:ip|bp|usp|ph eur|contains|equivalent)\b').hasMatch(lower) &&
      !_dateNoise.hasMatch(lower) &&
      !_priceNoise.hasMatch(lower);
}

String _productName(String raw) {
  var value = raw
      .replaceAll(RegExp(r'[®™©]'), ' ')
      .replaceAll(
        RegExp(
          r'\b(?:tablets?|capsules?|syrup|suspension|injection|cream|ointment|drops?|sachets?|ip|bp|usp)\b',
          caseSensitive: false,
        ),
        ' ',
      )
      .replaceAll(
        RegExp(
          r'\s+\d+(?:\.\d+)?\s*(?:mg|mcg|µg|g|ml|iu)?\s*$',
          caseSensitive: false,
        ),
        ' ',
      )
      .replaceAll(RegExp(r'[^A-Za-z0-9\u0900-\u097f+\-\s]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (value.length < 2 || value.length > 70) return '';
  return _smartTitle(value);
}

bool _eligibleNameLine(String line, int index) {
  final normalized = searchText(line);
  if (normalized.length < 2 || normalized.length > 70) return false;
  if (!RegExp(
    r'[a-z\u0900-\u097f]{2}',
    caseSensitive: false,
  ).hasMatch(normalized)) {
    return false;
  }
  if (_dateNoise.hasMatch(normalized) ||
      _priceNoise.hasMatch(normalized) ||
      _packNoise.hasMatch(normalized) ||
      _compositionLabel.hasMatch(normalized) ||
      _manufacturerHeader.hasMatch(normalized) ||
      RegExp(
        r'\b(?:batch|lot)\b|\bb\s*\.?\s*no\b',
        caseSensitive: false,
      ).hasMatch(line) ||
      RegExp(
        r'\b(?:batch|b no|lot|lic|license|schedule|warning|dosage|storage|keep|children|marketed|distributed|address|pin|email|website|customer|care|net\s*(?:qty|content)|only|physician|prescription)\b',
      ).hasMatch(normalized)) {
    return false;
  }
  if (_looksLikeGenericLine(line)) return false;
  final tokens = normalized.split(' ');
  if (_looksLikeMarketingOnly(tokens)) return false;
  if (tokens.length > 6) return false;
  if (tokens.every((token) => RegExp(r'^\d').hasMatch(token))) return false;
  if (index > 8 &&
      _uppercaseRatio(line) < .45 &&
      !RegExp(r'[®™]').hasMatch(line)) {
    return false;
  }
  return true;
}

bool _looksLikeMarketingOnly(List<String> tokens) {
  const marketing = <String>{
    'new',
    'improved',
    'formula',
    'advanced',
    'effective',
    'relief',
    'fast',
    'action',
    'trusted',
    'quality',
    'better',
    'extra',
    'power',
    'care',
    'original',
  };
  final words = tokens
      .where((token) => RegExp(r'[a-z\u0900-\u097f]').hasMatch(token))
      .toList(growable: false);
  if (words.length < 2) return false;
  final hits = words.where(marketing.contains).length;
  return hits >= 2 && hits / words.length >= .66;
}

double _uppercaseRatio(String value) {
  final letters = value.runes.where(
    (code) => (code >= 65 && code <= 90) || (code >= 97 && code <= 122),
  );
  final list = letters.toList();
  if (list.isEmpty) return 0;
  final uppercase = list.where((code) => code >= 65 && code <= 90).length;
  return uppercase / list.length;
}

String _formValue(String normalized) {
  for (final entry in const <String, String>{
    'tablet': 'Tablet',
    'tablets': 'Tablet',
    'tab': 'Tablet',
    'capsule': 'Capsule',
    'capsules': 'Capsule',
    'cap': 'Capsule',
    'syrup': 'Syrup',
    'suspension': 'Syrup',
    'injection': 'Injection',
    'injectable': 'Injection',
    'cream': 'Cream',
    'ointment': 'Ointment',
    'drops': 'Drops',
    'drop': 'Drops',
    'sachet': 'Sachet',
  }.entries) {
    if (RegExp('\\b${entry.key}\\b').hasMatch(normalized)) return entry.value;
  }
  return '';
}

String _packSize(String line) {
  final patterns = <RegExp>[
    RegExp(
      r'\b\d{1,3}\s*[x×]\s*\d{1,3}\s*(?:tablets?|capsules?|tabs?|caps?)?\b',
      caseSensitive: false,
    ),
    RegExp(
      r'\b(?:pack|strip|blister|bottle)\s*(?:of|size)?\s*[:.-]?\s*\d{1,4}\s*(?:tablets?|capsules?|tabs?|caps?|ml|g|sachets?)\b',
      caseSensitive: false,
    ),
    RegExp(
      r'\b\d{1,4}\s*(?:tablets?|capsules?|tabs?|caps?|sachets?)\b',
      caseSensitive: false,
    ),
  ];
  for (final pattern in patterns) {
    final match = pattern.firstMatch(line);
    if (match != null) return _cleanValue(match[0]!);
  }
  return '';
}

String _mrpValue(String line) {
  final match = RegExp(
    r'\bmrp\b[^\d]{0,12}(?:rs\.?|inr|₹)?\s*(\d{1,7}(?:[.,]\d{1,2})?)',
    caseSensitive: false,
  ).firstMatch(line);
  return match == null ? '' : '₹${match[1]!.replaceAll(',', '.')}';
}

Set<String> _identityTokens(String normalized) => normalized
    .split(' ')
    .where((token) => token.length >= 3)
    .where((token) => !RegExp(r'^\d').hasMatch(token))
    .where((token) => !_identityNoise.contains(token))
    .take(40)
    .toSet();

const _identityNoise = <String>{
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
  'each',
  'contains',
  'composition',
  'excipients',
  'colour',
  'dosage',
  'directed',
  'physician',
  'manufactured',
  'marketed',
  'batch',
  'expiry',
  'mfg',
  'mrp',
  'inclusive',
  'taxes',
  'store',
  'below',
  'protect',
  'light',
  'children',
  'reach',
  'schedule',
  'drug',
  'retail',
  'price',
  'only',
};

String _candidateKey(String field, String value) {
  if (field == 'barcode') return value.replaceAll(RegExp(r'\D'), '');
  if (field == 'strength') return _strengthKey(value);
  if (field == 'mfg' || field == 'expiry') return value;
  if (field == 'name' ||
      field == 'brand' ||
      field == 'salt' ||
      field == 'manufacturer') {
    return _knowledgeKey(value);
  }
  return searchText(value);
}

String _keywords(Map<String, ExtractedMedicineField> fields, String raw) {
  final ordered = <String>[];
  final seen = <String>{};
  void add(String value) {
    for (final token in searchText(value).split(' ')) {
      if (token.length < 2 || _identityNoise.contains(token)) continue;
      if (seen.add(token)) ordered.add(token);
      if (ordered.length >= 80) return;
    }
  }

  for (final key in const <String>[
    'name',
    'brand',
    'salt',
    'strength',
    'form',
    'manufacturer',
    'batchNumber',
    'barcode',
  ]) {
    add(fields[key]?.value ?? '');
  }
  add(raw);
  return ordered.join(' ');
}

String _smartTitle(String value) => value
    .split(' ')
    .map((word) {
      if (word.isEmpty || RegExp(r'^\d').hasMatch(word)) return word;
      if (word.length <= 3 && word == word.toUpperCase()) return word;
      return '${word[0].toUpperCase()}${word.substring(1).toLowerCase()}';
    })
    .join(' ');
