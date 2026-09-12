import 'dart:math';

import 'gs1_healthcare.dart';
import 'inventory.dart';
import 'medicine.dart';

/// Digits and strengths survive normalization. OCR alternatives are limited to words.
String searchText(String value) {
  const hindiDigits = '०१२३४५६७८९';
  var text = value.toLowerCase();
  for (var i = 0; i < 10; i++) {
    text = text.replaceAll(hindiDigits[i], '$i');
  }
  const aliases = {
    'पैरासिटामोल': 'paracetamol',
    'पेरासिटामोल': 'paracetamol',
    'डोलो': 'dolo',
    'ड्रोटावेरिन': 'drotaverine',
    'ड्रोटावरीन': 'drotaverine',
    'सेफिक्सिम': 'cefixime',
    'अजिथ्रोमाइसिन': 'azithromycin',
    'मेट्रोनिडाजोल': 'metronidazole',
    'five hundred': '500',
    'six fifty': '650',
    'eighty': '80',
    'forty': '40',
    'पाँच सौ': '500',
    'पांच सौ': '500',
    'छह सौ पचास': '650',
    'एमजी': 'mg',
    'एमएल': 'ml',
    'एमसीजी': 'mcg',
    'milligrams': 'mg',
    'milligram': 'mg',
    'millilitres': 'ml',
    'milliliters': 'ml',
    'millilitre': 'ml',
    'milliliter': 'ml',
    'micrograms': 'mcg',
    'microgram': 'mcg',
  };
  for (final entry in aliases.entries) {
    text = text.replaceAll(entry.key, entry.value);
  }
  text = text.replaceAllMapped(
    RegExp(r'\b(\d+)o(?=\s*(?:mg|ml|mcg|g)\b)'),
    (match) => '${match[1]}0',
  );
  return text
      .replaceAll(RegExp(r'[^a-z0-9\u0900-\u097f.]+'), ' ')
      .replaceAllMapped(
        RegExp(r'(\d)\s+(mg|ml|mcg|g)\b'),
        (m) => '${m[1]}${m[2]}',
      )
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}

Set<String> grams(String word) {
  if (word.length < 2) return {word};
  return {for (var i = 0; i < word.length - 1; i++) word.substring(i, i + 2)};
}

Set<String> _searchTrigrams(String word) {
  if (word.length < 3) return {word};
  return {
    for (var i = 0; i < word.length - 2; i++) word.substring(i, i + 3),
  };
}

Iterable<String> _searchDeleteKeys(String word) sync* {
  if (word.length < 4 || word.length > 24) return;
  final seen = <String>{};
  for (var i = 0; i < word.length; i++) {
    final deleted = word.substring(0, i) + word.substring(i + 1);
    if (deleted.length >= 3 && seen.add(deleted)) yield deleted;
  }
}

String _searchOcrFold(String token) {
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

/// Turns OCR/voice fragmentation into bounded search atoms before retrieval.
///
/// Examples:
///   D O L O 650mg -> dolo, 650mg
///   6 5 0 mg      -> 650mg
///
/// This is intentionally conservative. We only join alphabetic single-character
/// runs of length >= 3, and numeric runs only when they terminate in a known
/// medicine unit. Arbitrary document words are never fused together.
List<String> _searchQueryTokens(String query) {
  final parts = query
      .split(' ')
      .where((value) => value.isNotEmpty)
      .take(64)
      .toList(growable: false);
  final result = <String>[];
  var index = 0;
  while (index < parts.length && result.length < 48) {
    final token = parts[index];

    if (token.length == 1 && RegExp(r'^[a-z]$').hasMatch(token)) {
      final buffer = StringBuffer();
      var end = index;
      while (end < parts.length &&
          parts[end].length == 1 &&
          RegExp(r'^[a-z]$').hasMatch(parts[end]) &&
          buffer.length < 16) {
        buffer.write(parts[end]);
        end++;
      }
      if (buffer.length >= 3) {
        result.add(_boundedSearchTerm(buffer.toString()));
        index = end;
        continue;
      }
    }

    if (token.length == 1 && RegExp(r'^\d$').hasMatch(token)) {
      final digits = StringBuffer();
      var end = index;
      while (end < parts.length &&
          parts[end].length == 1 &&
          RegExp(r'^\d$').hasMatch(parts[end]) &&
          digits.length < 4) {
        digits.write(parts[end]);
        end++;
      }
      if (digits.length >= 2 && end < parts.length) {
        final unitOnly = RegExp(r'^(mg|ml|mcg|g)$').firstMatch(parts[end]);
        final digitWithUnit = RegExp(
          r'^(\d)(mg|ml|mcg|g)$',
        ).firstMatch(parts[end]);
        if (unitOnly != null) {
          result.add('${digits.toString()}${unitOnly.group(1)}');
          index = end + 1;
          continue;
        }
        if (digitWithUnit != null && digits.length < 4) {
          result.add(
            '${digits.toString()}${digitWithUnit.group(1)}${digitWithUnit.group(2)}',
          );
          index = end + 1;
          continue;
        }
      }
    }

    if (token.length >= 2 || RegExp(r'^\d$').hasMatch(token)) {
      result.add(_boundedSearchTerm(token));
    }
    index++;
  }
  return result;
}

double orderedSimilarity(String a, String b) {
  if (a == b) return 1;
  if (a.isEmpty || b.isEmpty) return 0;
  a = a.substring(0, min(a.length, 80));
  b = b.substring(0, min(b.length, 80));
  var prev = List<int>.filled(b.length + 1, 0);
  var edit = List<int>.generate(b.length + 1, (i) => i);
  for (var i = 0; i < a.length; i++) {
    final current = List<int>.filled(b.length + 1, 0);
    final nextEdit = List<int>.filled(b.length + 1, 0)..[0] = i + 1;
    for (var j = 0; j < b.length; j++) {
      current[j + 1] = a[i] == b[j]
          ? prev[j] + 1
          : max(prev[j + 1], current[j]);
      nextEdit[j + 1] = min(
        min(edit[j + 1] + 1, nextEdit[j] + 1),
        edit[j] + (a[i] == b[j] ? 0 : 1),
      );
    }
    prev = current;
    edit = nextEdit;
  }
  final lcs = prev.last;
  final sequence = lcs / a.length * .68 + lcs / b.length * .32;
  final distance = 1 - edit.last / max(a.length, b.length);
  final prefix = b.startsWith(a) ? .93 : 0.0;
  final jaro = jaroWinkler(a, b);
  return max(prefix, max(jaro * .98, max(distance, sequence * .91)));
}

double jaroWinkler(String a, String b) {
  if (a == b) return 1;
  if (a.isEmpty || b.isEmpty) return 0;
  a = a.substring(0, min(a.length, 80));
  b = b.substring(0, min(b.length, 80));
  final distance = max(0, max(a.length, b.length) ~/ 2 - 1);
  final aMatches = List<bool>.filled(a.length, false);
  final bMatches = List<bool>.filled(b.length, false);
  var matches = 0;
  for (var i = 0; i < a.length; i++) {
    final start = max(0, i - distance);
    final end = min(i + distance + 1, b.length);
    for (var j = start; j < end; j++) {
      if (bMatches[j] || a[i] != b[j]) continue;
      aMatches[i] = true;
      bMatches[j] = true;
      matches++;
      break;
    }
  }
  if (matches == 0) return 0;
  var transpositions = 0;
  var j = 0;
  for (var i = 0; i < a.length; i++) {
    if (!aMatches[i]) continue;
    while (!bMatches[j]) {
      j++;
    }
    if (a[i] != b[j]) transpositions++;
    j++;
  }
  final jaro =
      (matches / a.length +
          matches / b.length +
          (matches - transpositions / 2) / matches) /
      3;
  var prefix = 0;
  while (prefix < min(4, min(a.length, b.length)) && a[prefix] == b[prefix]) {
    prefix++;
  }
  return jaro + prefix * .1 * (1 - jaro);
}

class SearchHit {
  const SearchHit(this.id, this.score, this.reason, this.query);
  final String id, reason, query;
  final double score;
  bool get uncertain => score < .85;
  String get confidence => score >= .85
      ? 'High'
      : score >= .68
      ? 'Medium'
      : 'Low';
}

class _SearchFieldView {
  const _SearchFieldView._({
    required this.text,
    required this.words,
    required this.weight,
    required this.label,
  });

  factory _SearchFieldView.fromRaw(
    String raw,
    double weight,
    String label,
  ) {
    final text = searchText(raw);
    return _SearchFieldView._(
      text: text,
      words: text
          .split(' ')
          .where((word) => word.length >= 2)
          .take(100)
          .toList(growable: false),
      weight: weight,
      label: label,
    );
  }

  final String text;
  final List<String> words;
  final double weight;
  final String label;
}

class SearchDocument {
  static const maxTerms = 384;
  static const maxTermLength = 96;

  SearchDocument(this.record) {
    for (final value in [
      record.name,
      record.brand,
      record.manufacturer,
      record.salt,
      record.strength,
      record.form,
      record.barcode,
      record.batchNumber,
      record.id,
      if (record.mfg != null) dateText(record.mfg!),
      if (record.expiry != null) dateText(record.expiry!),
      record.address,
      if (record.block.isNotEmpty) 'b${record.block}',
      if (record.row.isNotEmpty) 'r${record.row}',
      if (record.vertical.isNotEmpty) 'v${record.vertical}',
    ]) {
      _addTerms(value, limit: 48);
    }
    _addTerms(record.ocrText, limit: 176);
    _addTerms(record.notes, limit: 80);
    fields = _buildSearchFieldViews(record);
    identityWords = _buildIdentityWords(record);
  }

  final Medicine record;
  final Set<String> terms = {};
  late final List<_SearchFieldView> fields;
  late final List<String> identityWords;

  void _addTerms(String value, {required int limit}) {
    var added = 0;
    for (final raw in searchText(value).split(' ')) {
      if (raw.isEmpty) continue;
      final term = _boundedSearchTerm(raw);
      if (term.isEmpty) continue;
      terms.add(term);
      added++;
      if (added >= limit || terms.length >= maxTerms) return;
    }
  }
}

List<_SearchFieldView> _buildSearchFieldViews(Medicine m) => [
  _SearchFieldView.fromRaw(m.name, 1.0, 'Medicine name'),
  _SearchFieldView.fromRaw(m.brand, .99, 'Brand'),
  _SearchFieldView.fromRaw(m.salt, .98, 'Salt'),
  _SearchFieldView.fromRaw('${m.name} ${m.strength}', 1.0, 'Name and strength'),
  _SearchFieldView.fromRaw(m.barcode, .97, 'Barcode'),
  _SearchFieldView.fromRaw(m.batchNumber, .91, 'Batch number'),
  _SearchFieldView.fromRaw(m.manufacturer, .86, 'Manufacturer'),
  _SearchFieldView.fromRaw(m.form, .82, 'Medicine form'),
  _SearchFieldView.fromRaw(
    m.expiry == null ? '' : dateText(m.expiry!),
    .78,
    'Expiry date',
  ),
  _SearchFieldView.fromRaw(
    m.mfg == null ? '' : dateText(m.mfg!),
    .72,
    'Manufacturing date',
  ),
  _SearchFieldView.fromRaw(m.id, .70, 'Internal record ID'),
  _SearchFieldView.fromRaw(m.ocrText, .78, 'Scanned keywords'),
  _SearchFieldView.fromRaw(m.address, .72, 'Location'),
  _SearchFieldView.fromRaw(
    '${m.block.isEmpty ? '' : 'b${m.block}'} ${m.row.isEmpty ? '' : 'r${m.row}'} ${m.vertical.isEmpty ? '' : 'v${m.vertical}'}',
    .84,
    'Location code',
  ),
  _SearchFieldView.fromRaw(m.notes, .68, 'Note'),
];

List<String> _buildIdentityWords(Medicine m) {
  final result = <String>{};
  for (final raw in <String>[
    m.name,
    m.brand,
    m.salt,
    m.manufacturer,
    m.form,
  ]) {
    for (final word in searchText(raw).split(' ')) {
      if (word.length >= 2 && !MedicineSearch.noise.contains(word)) {
        result.add(_boundedSearchTerm(word));
      }
      if (result.length >= 128) break;
    }
    if (result.length >= 128) break;
  }
  return result.toList(growable: false);
}

String _boundedSearchTerm(String value) =>
    value.length <= SearchDocument.maxTermLength
    ? value
    : value.substring(0, SearchDocument.maxTermLength);

String _barcodeIdentity(String value) {
  final raw = value.trim();
  if (raw.isEmpty) return '';
  final gs1 = parseGs1HealthcareBarcode(raw);
  final candidate = gs1 != null && gs1.gtin.isNotEmpty ? gs1.gtin : raw;
  if (RegExp(r'^\d+$').hasMatch(candidate) &&
      const {8, 12, 13, 14}.contains(candidate.length)) {
    return candidate.padLeft(14, '0');
  }
  return candidate;
}

class MedicineSearch {
  MedicineSearch(
    Iterable<Medicine> records, {
    bool includeArchived = false,
  }) {
    // Pass 1 builds complete exact identity/text statistics and precomputes the
    // normalized field projections used by the final reranker. This moves text
    // normalization/splitting out of the keystroke hot path.
    for (final m in records.where((m) => includeArchived || !m.archived)) {
      final doc = SearchDocument(m);
      docs[m.id] = doc;
      final barcodeKey = _barcodeIdentity(m.barcode);
      if (barcodeKey.isNotEmpty) {
        barcode.putIfAbsent(barcodeKey, () => {}).add(m.id);
      }
      for (final term in doc.terms) {
        exact.putIfAbsent(term, () => {}).add(m.id);
        documentFrequency.update(term, (value) => value + 1, ifAbsent: () => 1);
      }
    }

    // Pass 2 builds bounded fuzzy indexes only from the earliest/high-signal
    // terms. SearchDocument inserts canonical identity, dates and location before
    // free OCR/notes, so this keeps typo recovery strong without multiplying RAM
    // by every low-value OCR token in a large pharmacy database.
    for (final doc in docs.values) {
      for (final term in doc.terms.take(_maxSecondaryTermsPerDocument)) {
        if (term.length > 48) continue;
        for (final gram in grams(term)) {
          index.putIfAbsent(gram, () => {}).add(doc.record.id);
        }
        if (term.length >= 5) {
          for (final gram in _searchTrigrams(term)) {
            trigramIndex.putIfAbsent(gram, () => {}).add(doc.record.id);
          }
        }
        if (term.length >= 4) {
          final prefix = term.substring(0, min(4, term.length));
          prefixIndex.putIfAbsent(prefix, () => {}).add(doc.record.id);
        }
      }

      // Delete-neighbour memory is intentionally tighter than the general fuzzy
      // indexes. Identity-bearing terms are inserted before OCR/notes, so a small
      // alphabetic slice captures names/brands/salts/manufacturers without
      // multiplying RAM by long receipts, notes, dates, IDs or arbitrary OCR.
      final deleteTerms = doc.terms
          .where(
            (term) =>
                term.length >= 4 &&
                term.length <= 24 &&
                RegExp(r'[a-z]').hasMatch(term),
          )
          .take(_maxDeleteTermsPerDocument);
      for (final term in deleteTerms) {
        for (final variant in <String>{term, _searchOcrFold(term)}) {
          for (final deletion in _searchDeleteKeys(variant)) {
            deleteIndex.putIfAbsent(deletion, () => {}).add(doc.record.id);
          }
        }
      }
    }
  }

  static const maxArchivedResults = 150;
  static const _maxRetrievalCandidates = 240;
  static const _maxSecondaryTermsPerDocument = 112;
  static const _maxDeleteTermsPerDocument = 18;
  static const _maxPlannedTokens = 18;
  final Map<String, SearchDocument> docs = {};
  final Map<String, Set<String>> index = {}, exact = {}, barcode = {};
  final Map<String, Set<String>> trigramIndex = {}, prefixIndex = {};
  final Map<String, Set<String>> deleteIndex = {};
  final Map<String, int> documentFrequency = {};
  static const noise = {
    'tab',
    'tablet',
    'tablets',
    'cap',
    'capsule',
    'capsules',
    'syp',
    'syrup',
    'take',
    'after',
    'before',
    'meal',
    'meals',
    'morning',
    'night',
    'daily',
    'dose',
    'dr',
    'patient',
    'invoice',
    'total',
    'qty',
    'quantity',
    'and',
    'the',
    'of',
    'for',
    'mg',
    'ml',
  };

  double _rarity(String term) {
    final total = max(1, docs.length);
    final frequency = documentFrequency[term] ?? 1;
    return (1 + log((total + .5) / (frequency + .5)))
        .clamp(1.0, 3.8)
        .toDouble();
  }

  /// V5 query planner. It keeps one vote per independent clue and, when a query
  /// contains more evidence than the bounded hot path can consume, selects clues
  /// by information gain instead of blindly taking the first words.
  ///
  /// The final returned order remains the user's order; priority is only used to
  /// choose the bounded subset. That preserves existing field-ranking semantics.
  List<String> _planTokens(List<String> rawTokens) {
    final filtered = rawTokens.where((word) => !noise.contains(word)).toList();
    final source = filtered.isEmpty ? rawTokens : filtered;
    final unique = <String>[];
    final seen = <String>{};
    for (final token in source) {
      if (seen.add(token)) unique.add(token);
    }
    if (unique.length <= _maxPlannedTokens) return unique;

    double priority(String token) {
      var value = _rarity(token);
      final posting = exact[token];
      if (posting != null && posting.isNotEmpty) {
        value += 1.65;
        value += (1 / sqrt(posting.length)).clamp(.05, .55).toDouble();
      }
      if (RegExp(r'^\d+(?:\.\d+)?(?:mg|ml|mcg|g)$').hasMatch(token)) {
        value += 1.45;
      } else if (RegExp(r'^\d{6,}$').hasMatch(token)) {
        value += 1.75;
      }
      if (token.length >= 6) {
        value += min(.70, (token.length - 5) * .07);
      }
      if (RegExp(r'[a-z]').hasMatch(token) && RegExp(r'\d').hasMatch(token)) {
        value += .22;
      }
      return value;
    }

    final indexes = List<int>.generate(unique.length, (i) => i)
      ..sort((a, b) {
        final score = priority(unique[b]).compareTo(priority(unique[a]));
        return score != 0 ? score : a.compareTo(b);
      });
    final keep = indexes.take(_maxPlannedTokens).toSet();
    return <String>[
      for (var i = 0; i < unique.length; i++)
        if (keep.contains(i)) unique[i],
    ];
  }

  List<String> _identityEvidenceTokens(List<String> tokens) {
    final unique = <String>[];
    final seen = <String>{};
    for (final token in tokens) {
      if (token.length < 3 ||
          !RegExp(r'[a-z\u0900-\u097f]').hasMatch(token) ||
          !seen.add(token)) {
        continue;
      }
      unique.add(token);
    }
    unique.sort((a, b) {
      final rarity = _rarity(b).compareTo(_rarity(a));
      if (rarity != 0) return rarity;
      return b.length.compareTo(a.length);
    });
    return unique.take(10).toList(growable: false);
  }

  List<String> chunks(String raw) {
    if (raw.length > 30000) raw = raw.substring(0, 30000);
    final lines = raw
        .split(RegExp(r'[\n,;|&]+'))
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    final result = <String>[];
    for (final line in lines.take(80)) {
      if (line.length < 110) {
        result.add(line);
        continue;
      }
      final tokens = line.split(RegExp(r'\s+'));
      for (var i = 0; i < tokens.length && result.length < 80; i += 8) {
        result.add(tokens.sublist(i, min(i + 8, tokens.length)).join(' '));
      }
    }
    return result;
  }

  List<SearchHit> search(
    String raw,
    SearchScope scope,
    WarningSettings settings,
    DateTime today, {
    int limit = 150,
  }) => _searchMatching(
    raw,
    allowedRecord: (record) => inScope(record, scope, settings, today),
    order: (a, b) => expiryOrder(a, b, today),
    emptyReason: 'Inventory',
    limit: limit,
  );

  List<SearchHit> searchArchived(
    String raw,
    DateTime today, {
    int limit = maxArchivedResults,
  }) => _searchMatching(
    raw,
    allowedRecord: (record) => record.archived,
    order: _archivedOrder,
    emptyReason: 'Removed stock',
    limit: min(limit, maxArchivedResults),
  );

  List<SearchHit> _searchMatching(
    String raw, {
    required bool Function(Medicine record) allowedRecord,
    required int Function(Medicine a, Medicine b) order,
    required String emptyReason,
    required int limit,
  }) {
    // Scope evaluation can involve expiry calculations. Cache it per retrieved
    // row so fuzzy search cost scales with bounded postings rather than requiring
    // a full O(N) inventory scan for every keystroke.
    final allowedCache = <String, bool>{};
    bool allowedId(String id) => allowedCache.putIfAbsent(id, () {
      final document = docs[id];
      return document != null && allowedRecord(document.record);
    });

    if (raw.trim().isEmpty) {
      final records = docs.values
          .map((document) => document.record)
          .where(allowedRecord)
          .toList()
        ..sort(order);
      return records
          .take(limit)
          .map((m) => SearchHit(m.id, 1, emptyReason, ''))
          .toList();
    }

    final barcodeKey = _barcodeIdentity(raw);
    final barcodeIds = barcodeKey.isEmpty ? null : barcode[barcodeKey];
    if (barcodeIds != null) {
      final ids = barcodeIds.where(allowedId).toList()
        ..sort((a, b) => order(docs[a]!.record, docs[b]!.record));
      return ids
          .take(limit)
          .map((id) => SearchHit(id, 1, 'Exact barcode', raw))
          .toList();
    }

    final found = <String, SearchHit>{};
    for (final chunk in chunks(raw)) {
      final query = searchText(chunk);
      final rawTokens = _searchQueryTokens(query);
      final tokens = _planTokens(rawTokens);
      if (tokens.isEmpty) continue;

      final votes = <String, double>{};
      final channels = <String, int>{};
      void vote(
        Iterable<String>? ids,
        double weight, {
        bool independentChannel = false,
        bool orderBeforeLimit = false,
        int hardLimit = 180,
      }) {
        if (ids == null || ids.isEmpty || weight <= 0) return;
        Iterable<String> eligible;
        if (orderBeforeLimit) {
          final ordered = ids.where(allowedId).toList(growable: false)
            ..sort((a, b) => order(docs[a]!.record, docs[b]!.record));
          eligible = ordered.take(hardLimit);
        } else {
          // Filter before capping. A narrow status scope must never lose valid
          // candidates merely because disallowed IDs were inserted first.
          eligible = ids.where(allowedId).take(hardLimit);
        }
        for (final id in eligible) {
          votes.update(id, (value) => value + weight, ifAbsent: () => weight);
          if (independentChannel) {
            channels.update(id, (value) => value + 1, ifAbsent: () => 1);
          }
        }
      }

      for (final token in tokens) {
        final rarity = _rarity(token);
        // Exact postings can represent hundreds of physical batches for one
        // medicine. Preserve FEFO/business ordering before the candidate cap so
        // results are deterministic and independent of database insertion order.
        vote(
          exact[token],
          18 * rarity,
          independentChannel: true,
          orderBeforeLimit: true,
          hardLimit: 160,
        );

        // A bounded deletion-neighbour channel recovers common OCR/typing edits
        // before expensive edit-distance ranking. It only nominates candidates;
        // coherent reranking and contradiction gates remain authoritative.
        for (final variant in <String>{token, _searchOcrFold(token)}) {
          if (variant.length < 4 || variant.length > 24) continue;
          final deletionPostings = _searchDeleteKeys(variant)
              .map((key) => (key: key, ids: deleteIndex[key]))
              .where((item) => item.ids != null && item.ids!.isNotEmpty)
              .toList(growable: false)
            ..sort((a, b) {
              final size = a.ids!.length.compareTo(b.ids!.length);
              return size != 0 ? size : a.key.compareTo(b.key);
            });
          for (final posting in deletionPostings.take(6)) {
            if (posting.ids!.length > max(160, docs.length ~/ 2)) continue;
            final selectivity = (1 / sqrt(max(1, posting.ids!.length)))
                .clamp(.08, .52)
                .toDouble();
            vote(
              posting.ids,
              (.78 + selectivity * 1.8) * rarity,
              independentChannel: true,
              hardLimit: 128,
            );
          }
        }

        if (token.length >= 4) {
          final prefix = token.substring(0, min(4, token.length));
          final posting = prefixIndex[prefix];
          if (posting != null && posting.length <= 120) {
            final selectivity =
                (1 / sqrt(max(1, posting.length))).clamp(.10, .55).toDouble();
            vote(
              posting,
              (2.0 + selectivity * 3.0) * rarity,
              independentChannel: true,
              hardLimit: 120,
            );
          }
        }

        var usedSelectiveTrigrams = false;
        if (token.length >= 5) {
          final postings = _searchTrigrams(token)
              .map((gram) => (gram: gram, ids: trigramIndex[gram]))
              .where((item) => item.ids != null && item.ids!.isNotEmpty)
              .toList(growable: false)
            ..sort((a, b) {
              final size = a.ids!.length.compareTo(b.ids!.length);
              return size != 0 ? size : a.gram.compareTo(b.gram);
            });
          for (final posting in postings.take(7)) {
            if (posting.ids!.length > max(180, docs.length ~/ 2)) continue;
            usedSelectiveTrigrams = true;
            final selectivity =
                (1 / sqrt(max(1, posting.ids!.length))).clamp(.08, .50).toDouble();
            vote(
              posting.ids,
              (.70 + selectivity * 2.2) * rarity,
              independentChannel: true,
              hardLimit: 150,
            );
          }
        }

        if (token.length < 5 || !usedSelectiveTrigrams) {
          final postings = grams(token)
              .map((gram) => (gram: gram, ids: index[gram]))
              .where((item) => item.ids != null && item.ids!.isNotEmpty)
              .toList(growable: false)
            ..sort((a, b) {
              final size = a.ids!.length.compareTo(b.ids!.length);
              return size != 0 ? size : a.gram.compareTo(b.gram);
            });
          for (final posting in postings.take(5)) {
            if (posting.ids!.length > max(220, docs.length * 3 ~/ 4)) continue;
            vote(posting.ids, .34 * rarity, hardLimit: 180);
          }
        }
      }

      final candidates = votes.keys.toList()
        ..sort((a, b) {
          final aScore = votes[a]! + min(2.0, (channels[a] ?? 0) * .16);
          final bScore = votes[b]! + min(2.0, (channels[b] ?? 0) * .16);
          final voteOrder = bScore.compareTo(aScore);
          return voteOrder != 0
              ? voteOrder
              : order(docs[a]!.record, docs[b]!.record);
        });
      for (final id in candidates.take(_maxRetrievalCandidates)) {
        final document = docs[id]!;
        final hit = _rankDocument(document, query, tokens);
        if (hit.score >= .53 &&
            (found[id] == null || found[id]!.score < hit.score)) {
          found[id] = hit;
        }
      }
    }
    final results = found.values.toList()
      ..sort((a, b) {
        final scoreOrder = b.score.compareTo(a.score);
        return scoreOrder != 0
            ? scoreOrder
            : order(docs[a.id]!.record, docs[b.id]!.record);
      });
    return results.take(limit).toList();
  }

  SearchHit rank(Medicine m, String query, List<String> tokens) =>
      _rankDocument(docs[m.id] ?? SearchDocument(m), query, tokens);

  SearchHit _rankDocument(
    SearchDocument document,
    String query,
    List<String> tokens,
  ) {
    final m = document.record;
    var best = 0.0;
    var reason = 'Possible match';
    final strength = RegExp(r'\b(\d+(?:\.\d+)?)(mg|ml|mcg|g)\b');
    final queryStrength = strength
        .allMatches(query)
        .map((match) => match.group(0)!)
        .toSet();
    final actualStrength = strength
        .allMatches(searchText('${m.strength} ${m.name}'))
        .map((match) => match.group(0)!)
        .toSet();
    final numericTokens = tokens
        .where((token) => RegExp(r'^\d+(?:\.\d+)?$').hasMatch(token))
        .toList(growable: false);
    final nameTokens = tokens
        .where((token) => !strength.hasMatch(token) && !numericTokens.contains(token))
        .toList(growable: false);
    final usable = nameTokens.isEmpty ? tokens : nameTokens;

    // Long internal IDs are exact authority. This cannot turn short generic
    // strings such as "1" into an authoritative target.
    final normalizedId = searchText(m.id);
    if (normalizedId.length >= 6 && query == normalizedId) {
      return SearchHit(m.id, .995, 'Exact record ID', query);
    }

    for (final field in document.fields) {
      final value = field.text;
      if (value.isEmpty) continue;
      var score = 0.0;
      if (query == value) {
        score = 1;
      } else if (value.contains(query)) {
        score = .96;
      } else {
        var weightedSum = 0.0;
        var totalTokenWeight = 0.0;
        for (final token in usable) {
          var match = 0.0;
          for (final word in field.words) {
            match = max(match, _searchTokenSimilarity(token, word));
          }
          final tokenWeight = RegExp(r'^\d').hasMatch(token)
              ? 1.15
              : _rarity(token).clamp(1.0, 2.4).toDouble();
          weightedSum += match * tokenWeight;
          totalTokenWeight += tokenWeight;
        }
        score = totalTokenWeight <= 0 ? 0 : weightedSum / totalTokenWeight;
      }
      if (numericTokens.isNotEmpty) {
        final numbers = RegExp(
          r'\d+(?:\.\d+)?',
        ).allMatches(value).map((match) => match[0]!).toList(growable: false);
        final matchesNumbers = numericTokens.every(
          (token) => numbers.any(
            (number) =>
                number == token ||
                (token.length > 1 &&
                    !token.contains('.') &&
                    number.startsWith(token)),
          ),
        );
        if (!matchesNumbers) score *= .66;
      }
      score *= field.weight;
      if (score > best) {
        best = score;
        reason = field.label;
      }
    }

    // V5 evidence fusion: multi-clue identity is ranked by information value,
    // not by arbitrary word position. Duplicate OCR/voice tokens are removed by
    // the query planner, so repetition cannot manufacture independent evidence.
    final lexicalTokens = _identityEvidenceTokens(usable);
    if (lexicalTokens.length >= 2 && document.identityWords.isNotEmpty) {
      var weightedSimilarity = 0.0;
      var totalWeight = 0.0;
      var matchedWeight = 0.0;
      var matchedClues = 0;
      var strongestRarity = 0.0;
      var strongestSimilarity = 1.0;
      for (final token in lexicalTokens) {
        var match = 0.0;
        for (final word in document.identityWords) {
          match = max(match, _searchTokenSimilarity(token, word));
        }
        final tokenWeight = _rarity(token).clamp(1.0, 2.6).toDouble();
        weightedSimilarity += match * tokenWeight;
        totalWeight += tokenWeight;
        if (match >= .80) {
          matchedWeight += tokenWeight;
          matchedClues++;
        }
        if (tokenWeight > strongestRarity) {
          strongestRarity = tokenWeight;
          strongestSimilarity = match;
        }
      }
      if (totalWeight > 0 && matchedClues >= 2) {
        final similarity = weightedSimilarity / totalWeight;
        final coverage = matchedWeight / totalWeight;
        // A very rare missing clue is a useful anti-decoy signal. It does not
        // reject the row; it only prevents the corroboration channel from
        // upgrading a weak hypothesis above the best ordinary field evidence.
        final rareClueMissing =
            strongestRarity >= 2.35 && strongestSimilarity < .52;
        if (!rareClueMissing && coverage >= .58 && similarity >= .72) {
          final coherent =
              (similarity * .80 + coverage * .20).clamp(0, 1).toDouble();
          final fused = (coherent * .985).clamp(0, .985).toDouble();
          if (fused > best) {
            best = fused;
            reason = 'Corroborated medicine identity';
          }
        }
      }
    }

    final strengthConflict = queryStrength.isNotEmpty &&
        actualStrength.isNotEmpty &&
        queryStrength.intersection(actualStrength).isEmpty;
    if (strengthConflict) {
      best *= .48;
      reason = 'Different strength — check carefully';
    }

    // Dosage form is a product-variant constraint just like strength, but weaker.
    // It is read from the original normalized query even though common form words
    // are intentionally treated as retrieval noise.
    if (!strengthConflict) {
      final requestedForms = _queryFormConstraints(query);
      final actualForm = _searchFormIdentity(m.form);
      if (requestedForms.isNotEmpty && actualForm.isNotEmpty) {
        if (!requestedForms.contains(actualForm)) {
          best *= .64;
          reason = 'Different dosage form — check carefully';
        } else if (best >= .68) {
          best = min(.995, best + .012);
        }
      }
    }

    return SearchHit(m.id, best.clamp(0, 1).toDouble(), reason, query);
  }

  double _searchTokenSimilarity(String token, String word) {
    if (token == word) return 1;
    if (token.isEmpty || word.isEmpty) return 0;
    if (word.startsWith(token)) return .93;
    final corrected = RegExp(r'[a-z]').hasMatch(token)
        ? token
              .replaceAll('0', 'o')
              .replaceAll('1', 'i')
              .replaceAll('5', 's')
              .replaceAll('8', 'b')
        : token;
    if (corrected == word) return corrected == token ? 1 : .96;
    if (word.startsWith(corrected) && corrected.length >= 3) {
      return corrected == token ? .93 : .91;
    }
    return max(
      orderedSimilarity(token, word),
      orderedSimilarity(corrected, word) * (corrected == token ? 1 : .96),
    );
  }
}

String _searchFormIdentity(String raw) {
  final tokens = searchText(raw).split(' ').where((value) => value.isNotEmpty);
  for (final token in tokens) {
    final form = _searchFormAliases[token];
    if (form != null) return form;
  }
  return '';
}

Set<String> _queryFormConstraints(String query) {
  final result = <String>{};
  for (final token in searchText(query).split(' ')) {
    final form = _searchFormAliases[token];
    if (form != null) result.add(form);
  }
  return result;
}

const Map<String, String> _searchFormAliases = {
  'tab': 'tablet',
  'tabs': 'tablet',
  'tablet': 'tablet',
  'tablets': 'tablet',
  'cap': 'capsule',
  'caps': 'capsule',
  'capsule': 'capsule',
  'capsules': 'capsule',
  'syp': 'syrup',
  'syrup': 'syrup',
  'susp': 'suspension',
  'suspension': 'suspension',
  'inj': 'injection',
  'injection': 'injection',
  'drop': 'drops',
  'drops': 'drops',
  'cream': 'cream',
  'ointment': 'ointment',
  'oint': 'ointment',
  'gel': 'gel',
  'lotion': 'lotion',
  'powder': 'powder',
  'inhaler': 'inhaler',
  'spray': 'spray',
  'sachet': 'sachet',
};

int _archivedOrder(Medicine a, Medicine b) {
  final aTime = a.archivedAt;
  final bTime = b.archivedAt;
  if (aTime == null && bTime != null) return 1;
  if (bTime == null && aTime != null) return -1;
  if (aTime != null && bTime != null) {
    final recent = bTime.compareTo(aTime);
    if (recent != 0) return recent;
  }
  var order = normalize(a.title).compareTo(normalize(b.title));
  if (order != 0) return order;
  order = normalize(a.batchNumber).compareTo(normalize(b.batchNumber));
  return order != 0 ? order : a.id.compareTo(b.id);
}
