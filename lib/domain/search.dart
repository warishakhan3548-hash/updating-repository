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
    'milligrams': 'mg',
    'milligram': 'mg',
    'millilitres': 'ml',
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
  }
  final Medicine record;
  final Set<String> terms = {};

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
    // Pass 1 builds complete exact identity/text statistics. Exact lookups keep
    // full coverage even when a record has large OCR or notes payloads.
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
      final rawTokens = query
          .split(' ')
          .where((word) => word.length >= 2 || RegExp(r'^\d$').hasMatch(word))
          .map(_boundedSearchTerm)
          .take(40)
          .toList();
      var tokens = rawTokens
          .where((word) => !noise.contains(word))
          .take(14)
          .toList();
      if (tokens.isEmpty && rawTokens.isNotEmpty) {
        tokens = rawTokens.take(14).toList();
      }
      if (tokens.isEmpty) continue;

      final votes = <String, double>{};
      final channels = <String, int>{};
      void vote(
        Iterable<String>? ids,
        double weight, {
        bool independentChannel = false,
        int hardLimit = 180,
      }) {
        if (ids == null || ids.isEmpty || weight <= 0) return;
        for (final id in ids.take(hardLimit)) {
          if (!allowedId(id)) continue;
          votes.update(id, (value) => value + weight, ifAbsent: () => weight);
          if (independentChannel) {
            channels.update(id, (value) => value + 1, ifAbsent: () => 1);
          }
        }
      }

      for (final token in tokens) {
        final rarity = _rarity(token);
        vote(exact[token], 18 * rarity, independentChannel: true, hardLimit: 160);

        // A bounded deletion-neighbour channel recovers common OCR/typing edits
        // before expensive edit-distance ranking. This mirrors the product
        // resolver's search-engine-style cascade while keeping false authority
        // impossible: it only nominates candidates; rank() and strength conflict
        // gates remain authoritative.
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
        final hit = rank(docs[id]!.record, query, tokens);
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

  SearchHit rank(Medicine m, String query, List<String> tokens) {
    final fields = <(String, double, String)>[
      (m.name, 1.0, 'Medicine name'),
      (m.brand, .99, 'Brand'),
      (m.salt, .98, 'Salt'),
      ('${m.name} ${m.strength}', 1.0, 'Name and strength'),
      (m.barcode, .97, 'Barcode'),
      (m.batchNumber, .91, 'Batch number'),
      (m.manufacturer, .86, 'Manufacturer'),
      (m.form, .82, 'Medicine form'),
      (m.expiry == null ? '' : dateText(m.expiry!), .78, 'Expiry date'),
      (m.mfg == null ? '' : dateText(m.mfg!), .72, 'Manufacturing date'),
      (m.id, .70, 'Internal record ID'),
      (m.ocrText, .78, 'Scanned keywords'),
      (m.address, .72, 'Location'),
      (
        '${m.block.isEmpty ? '' : 'b${m.block}'} ${m.row.isEmpty ? '' : 'r${m.row}'} ${m.vertical.isEmpty ? '' : 'v${m.vertical}'}',
        .84,
        'Location code',
      ),
      (m.notes, .68, 'Note'),
    ];
    var best = 0.0;
    var reason = 'Possible match';
    final strength = RegExp(r'\b(\d+(?:\.\d+)?)(mg|ml|mcg|g)\b');
    final queryStrength = strength
        .allMatches(query)
        .map((m) => m.group(0)!)
        .toSet();
    final actualStrength = strength
        .allMatches(searchText('${m.strength} ${m.name}'))
        .map((m) => m.group(0)!)
        .toSet();
    final numericTokens = tokens
        .where((t) => RegExp(r'^\d+(?:\.\d+)?$').hasMatch(t))
        .toList();
    final nameTokens = tokens
        .where((t) => !strength.hasMatch(t) && !numericTokens.contains(t))
        .toList();
    for (final (raw, weight, label) in fields) {
      final value = searchText(raw);
      if (value.isEmpty) continue;
      var score = 0.0;
      if (query == value) {
        score = 1;
      } else if (value.contains(query)) {
        score = .96;
      } else {
        final words = value
            .split(' ')
            .where((w) => w.length >= 2)
            .take(100)
            .toList();
        final usable = nameTokens.isEmpty ? tokens : nameTokens;
        var weightedSum = 0.0;
        var totalTokenWeight = 0.0;
        for (final token in usable) {
          var match = 0.0;
          final corrected = RegExp(r'[a-z]').hasMatch(token)
              ? token
                    .replaceAll('0', 'o')
                    .replaceAll('1', 'i')
                    .replaceAll('5', 's')
                    .replaceAll('8', 'b')
              : token;
          for (final word in words) {
            match = max(
              match,
              max(
                orderedSimilarity(token, word),
                orderedSimilarity(corrected, word) *
                    (corrected == token ? 1 : .96),
              ),
            );
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
        ).allMatches(value).map((match) => match[0]!).toList();
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
      score *= weight;
      if (score > best) {
        best = score;
        reason = label;
      }
    }
    if (queryStrength.isNotEmpty &&
        actualStrength.isNotEmpty &&
        queryStrength.intersection(actualStrength).isEmpty) {
      best *= .48;
      reason = 'Different strength — check carefully';
    }
    return SearchHit(m.id, best.clamp(0, 1), reason, query);
  }
}

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
