import 'dart:math';
import 'inventory.dart';
import 'medicine.dart';

/// Digits and strengths survive normalization. OCR alternatives are limited to words.
String searchText(String value) {
  const hindiDigits = '०१२३४५६७८९';
  var text = value.toLowerCase();
  for (var i = 0; i < 10; i++) { text = text.replaceAll(hindiDigits[i], '$i'); }
  const aliases = {
    'पैरासिटामोल': 'paracetamol', 'पेरासिटामोल': 'paracetamol', 'डोलो': 'dolo',
    'ड्रोटावेरिन': 'drotaverine', 'ड्रोटावरीन': 'drotaverine', 'सेफिक्सिम': 'cefixime',
    'अजिथ्रोमाइसिन': 'azithromycin', 'मेट्रोनिडाजोल': 'metronidazole',
    'five hundred': '500', 'six fifty': '650', 'eighty': '80', 'forty': '40',
    'पाँच सौ': '500', 'पांच सौ': '500', 'छह सौ पचास': '650', 'एमजी': 'mg',
    'milligrams': 'mg', 'milligram': 'mg', 'millilitres': 'ml',
  };
  for (final entry in aliases.entries) { text = text.replaceAll(entry.key, entry.value); }
  return text.replaceAll(RegExp(r'[^a-z0-9\u0900-\u097f.]+'), ' ').replaceAllMapped(RegExp(r'(\d)\s+(mg|ml|mcg|g)\b'), (m) => '${m[1]}${m[2]}').replaceAll(RegExp(r'\s+'), ' ').trim();
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
      current[j + 1] = a[i] == b[j] ? prev[j] + 1 : max(prev[j + 1], current[j]);
      nextEdit[j + 1] = min(min(edit[j + 1] + 1, nextEdit[j] + 1), edit[j] + (a[i] == b[j] ? 0 : 1));
    }
    prev = current; edit = nextEdit;
  }
  final lcs = prev.last;
  final sequence = lcs / a.length * .68 + lcs / b.length * .32;
  final distance = 1 - edit.last / max(a.length, b.length);
  final prefix = b.startsWith(a) ? .93 : 0.0;
  return max(prefix, max(distance, sequence * .91));
}

class SearchHit {
  const SearchHit(this.id, this.score, this.reason, this.query);
  final String id, reason, query;
  final double score;
  bool get uncertain => score < .85;
}

class SearchDocument {
  SearchDocument(this.record) {
    for (final value in [record.name, record.brand, record.salt, record.strength, record.ocrText, record.address, record.notes]) {
      terms.addAll(searchText(value).split(' ').where((e) => e.isNotEmpty));
    }
  }
  final Medicine record;
  final Set<String> terms = {};
}

class MedicineSearch {
  MedicineSearch(Iterable<Medicine> records) {
    for (final m in records.where((m) => !m.archived)) {
      final doc = SearchDocument(m); docs[m.id] = doc;
      if (m.barcode.isNotEmpty) barcode.putIfAbsent(m.barcode, () => {}).add(m.id);
      for (final term in doc.terms) {
        exact.putIfAbsent(term, () => {}).add(m.id);
        for (final gram in grams(term)) { index.putIfAbsent(gram, () => {}).add(m.id); }
      }
    }
  }
  final Map<String, SearchDocument> docs = {};
  final Map<String, Set<String>> index = {}, exact = {}, barcode = {};
  static const noise = {'tab', 'tablet', 'tablets', 'cap', 'capsule', 'syp', 'syrup', 'take', 'after', 'before', 'meal', 'meals', 'morning', 'night', 'daily', 'dose', 'dr', 'patient', 'invoice', 'total', 'qty', 'quantity', 'and', 'the', 'of', 'for', 'mg', 'ml'};

  List<String> chunks(String raw) {
    if (raw.length > 30000) raw = raw.substring(0, 30000);
    final lines = raw.split(RegExp(r'[\n,;|&]+')).map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
    final result = <String>[];
    for (final line in lines.take(80)) {
      if (line.length < 110) { result.add(line); continue; }
      final tokens = line.split(RegExp(r'\s+'));
      for (var i = 0; i < tokens.length && result.length < 80; i += 8) {
        result.add(tokens.sublist(i, min(i + 8, tokens.length)).join(' '));
      }
    }
    return result;
  }

  List<SearchHit> search(String raw, SearchScope scope, WarningSettings settings, DateTime today, {int limit = 150}) {
    final allowed = {for (final d in docs.values) if (inScope(d.record, scope, settings, today)) d.record.id};
    if (raw.trim().isEmpty) {
      final records = allowed.map((id) => docs[id]!.record).toList()..sort((a,b) => expiryOrder(a,b,today));
      return records.take(limit).map((m) => SearchHit(m.id, 1, 'Inventory', '')).toList();
    }
    // An exact product barcode can legitimately identify multiple stock entries.
    final barcodeIds = barcode[raw.trim()];
    if (barcodeIds != null) {
      final ids = barcodeIds.where(allowed.contains).toList()..sort((a,b) => expiryOrder(docs[a]!.record, docs[b]!.record,today));
      return ids.map((id) => SearchHit(id, 1, 'Exact barcode', raw)).toList();
    }
    final found = <String, SearchHit>{};
    for (final chunk in chunks(raw)) {
      final query = searchText(chunk);
      final tokens = query.split(' ').where((w) => w.length >= 2 && !noise.contains(w)).take(14).toList();
      if (tokens.isEmpty) continue;
      final votes = <String, int>{};
      for (final token in tokens) {
        for (final id in exact[token] ?? <String>{}) { if (allowed.contains(id)) votes[id] = (votes[id] ?? 0) + 30; }
        for (final gram in grams(token)) {
          for (final id in index[gram] ?? <String>{}) { if (allowed.contains(id)) votes[id] = (votes[id] ?? 0) + 1; }
        }
      }
      final candidates = votes.keys.toList()..sort((a,b) => votes[b]!.compareTo(votes[a]!));
      for (final id in candidates.take(300)) {
        final hit = rank(docs[id]!.record, query, tokens);
        if (hit.score >= .53 && (found[id] == null || found[id]!.score < hit.score)) found[id] = hit;
      }
    }
    final results = found.values.toList()..sort((a,b) {
      if ((a.score - b.score).abs() > .025) return b.score.compareTo(a.score);
      return expiryOrder(docs[a.id]!.record, docs[b.id]!.record, today);
    });
    return results.take(limit).toList();
  }

  SearchHit rank(Medicine m, String query, List<String> tokens) {
    final fields = <(String, double, String)>[
      (m.name, 1.0, 'Medicine name'), (m.brand, .99, 'Brand'), (m.salt, .98, 'Salt'),
      ('${m.name} ${m.strength}', 1.0, 'Name and strength'),
      (m.ocrText, .78, 'Scanned keywords'), (m.address, .72, 'Location'), (m.notes, .68, 'Note'),
    ];
    var best = 0.0; var reason = 'Possible match';
    final strength = RegExp(r'\b(\d+(?:\.\d+)?)(mg|ml|mcg|g)\b');
    final queryStrength = strength.allMatches(query).map((m) => m.group(0)!).toSet();
    final actualStrength = strength.allMatches(searchText('${m.strength} ${m.name}')).map((m) => m.group(0)!).toSet();
    final nameTokens = tokens.where((t) => !strength.hasMatch(t) && !RegExp(r'^\d+$').hasMatch(t)).toList();
    for (final (raw, weight, label) in fields) {
      final value = searchText(raw);
      if (value.isEmpty) continue;
      var score = 0.0;
      if (query == value) { score = 1; }
      else if (value.contains(query)) { score = .96; }
      else {
        final words = value.split(' ').where((w) => w.length >= 2).take(100).toList();
        final usable = nameTokens.isEmpty ? tokens : nameTokens;
        var sum = 0.0;
        for (final token in usable) {
          var match = 0.0;
          final corrected = RegExp(r'[a-z]').hasMatch(token) ? token.replaceAll('0','o').replaceAll('1','i') : token;
          for (final word in words) {
            match = max(match, max(orderedSimilarity(token,word), orderedSimilarity(corrected,word) * (corrected == token ? 1 : .96)));
          }
          sum += match;
        }
        score = sum / usable.length;
      }
      score *= weight;
      if (score > best) { best = score; reason = label; }
    }
    if (queryStrength.isNotEmpty && actualStrength.isNotEmpty && queryStrength.intersection(actualStrength).isEmpty) {
      best *= .48; reason = 'Different strength — check carefully';
    }
    final numericTokens = tokens.where((t) => RegExp(r'^\d+$').hasMatch(t)).toList();
    final identityText = searchText('${m.name} ${m.strength} ${m.barcode}');
    if (numericTokens.isNotEmpty && !numericTokens.every(identityText.contains)) best *= .66;
    return SearchHit(m.id, best.clamp(0,1), reason, query);
  }
}
