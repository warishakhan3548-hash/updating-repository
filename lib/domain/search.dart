import 'dart:math';

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
  // OCR commonly reads a trailing zero as O when it touches a dosage unit.
  // Keep this narrow so ordinary medicine names and product codes are intact.
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
  SearchDocument(this.record) {
    for (final value in [
      record.name,
      record.brand,
      record.manufacturer,
      record.salt,
      record.strength,
      record.form,
      record.barcode,
      record.id,
      if (record.mfg != null) dateText(record.mfg!),
      if (record.expiry != null) dateText(record.expiry!),
      record.ocrText,
      record.address,
      if (record.block.isNotEmpty) 'b${record.block}',
      if (record.row.isNotEmpty) 'r${record.row}',
      if (record.vertical.isNotEmpty) 'v${record.vertical}',
      record.notes,
    ]) {
      terms.addAll(searchText(value).split(' ').where((e) => e.isNotEmpty));
    }
  }
  final Medicine record;
  final Set<String> terms = {};
}

class MedicineSearch {
  MedicineSearch(Iterable<Medicine> records) {
    for (final m in records.where((m) => !m.archived)) {
      final doc = SearchDocument(m);
      docs[m.id] = doc;
      if (m.barcode.isNotEmpty)
        barcode.putIfAbsent(m.barcode, () => {}).add(m.id);
      for (final term in doc.terms) {
        exact.putIfAbsent(term, () => {}).add(m.id);
        for (final gram in grams(term)) {
          index.putIfAbsent(gram, () => {}).add(m.id);
        }
      }
    }
  }
  final Map<String, SearchDocument> docs = {};
  final Map<String, Set<String>> index = {}, exact = {}, barcode = {};
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
  }) {
    bool allowedId(String id) =>
        inScope(docs[id]!.record, scope, settings, today);
    if (raw.trim().isEmpty) {
      final records =
          docs.values
              .map((document) => document.record)
              .where((record) => inScope(record, scope, settings, today))
              .toList()
            ..sort((a, b) => expiryOrder(a, b, today));
      return records
          .take(limit)
          .map((m) => SearchHit(m.id, 1, 'Inventory', ''))
          .toList();
    }
    // An exact product barcode can legitimately identify multiple stock entries.
    final barcodeIds = barcode[raw.trim()];
    if (barcodeIds != null) {
      final ids = barcodeIds.where(allowedId).toList()
        ..sort((a, b) => expiryOrder(docs[a]!.record, docs[b]!.record, today));
      return ids.map((id) => SearchHit(id, 1, 'Exact barcode', raw)).toList();
    }
    final allowed = {
      for (final document in docs.values)
        if (inScope(document.record, scope, settings, today))
          document.record.id,
    };
    final found = <String, SearchHit>{};
    for (final chunk in chunks(raw)) {
      final query = searchText(chunk);
      final rawTokens = query
          .split(' ')
          .where((word) => word.length >= 2 || RegExp(r'^\d$').hasMatch(word))
          .take(40)
          .toList();
      var tokens = rawTokens
          .where((word) => !noise.contains(word))
          .take(14)
          .toList();
      // A direct query such as "syrup" is useful even though form words are
      // discarded as noise inside long prescription/invoice text.
      if (tokens.isEmpty && rawTokens.isNotEmpty) {
        tokens = rawTokens.take(14).toList();
      }
      if (tokens.isEmpty) continue;
      final votes = <String, int>{};
      for (final token in tokens) {
        for (final id in exact[token] ?? <String>{}) {
          if (allowed.contains(id)) votes[id] = (votes[id] ?? 0) + 30;
        }
        for (final gram in grams(token)) {
          for (final id in index[gram] ?? <String>{}) {
            if (allowed.contains(id)) votes[id] = (votes[id] ?? 0) + 1;
          }
        }
      }
      final candidates = votes.keys.toList()
        ..sort((a, b) {
          final voteOrder = votes[b]!.compareTo(votes[a]!);
          return voteOrder != 0
              ? voteOrder
              : expiryOrder(docs[a]!.record, docs[b]!.record, today);
        });
      for (final id in candidates.take(300)) {
        final hit = rank(docs[id]!.record, query, tokens);
        if (hit.score >= .53 &&
            (found[id] == null || found[id]!.score < hit.score))
          found[id] = hit;
      }
    }
    final results = found.values.toList()
      ..sort((a, b) {
        final scoreOrder = b.score.compareTo(a.score);
        return scoreOrder != 0
            ? scoreOrder
            : expiryOrder(docs[a.id]!.record, docs[b.id]!.record, today);
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
        var sum = 0.0;
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
          sum += match;
        }
        score = sum / usable.length;
      }
      // Check numbers in the field that actually matched, not an unrelated date.
      if (numericTokens.isNotEmpty) {
        final numbers = RegExp(r'\d+(?:\.\d+)?')
            .allMatches(value).map((match) => match[0]!).toList();
        final matchesNumbers = numericTokens.every((token) => numbers.any(
          (number) => number == token ||
              (token.length > 1 && !token.contains('.') && number.startsWith(token)),
        ));
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
