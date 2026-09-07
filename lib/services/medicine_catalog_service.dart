import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;

import '../domain/medicine.dart';
import '../domain/medicine_discovery.dart';
import '../domain/search.dart';

abstract interface class MedicineCatalogProvider {
  Future<List<MedicineCatalogCandidate>> search({
    required String barcode,
    required String text,
    required int limit,
  });
}

/// Public-catalog discovery used only after the local pharmacy database cannot
/// confidently identify a scan.
///
/// The service intentionally returns identity metadata only. Expiry, MFG,
/// quantity, price and pharmacy location are never sourced from the internet.
class MedicineCatalogService {
  MedicineCatalogService({
    http.Client? client,
    List<MedicineCatalogProvider>? providers,
  }) : _client = client ?? http.Client(),
       _ownsClient = client == null,
       _providers = providers ?? [] {
    if (_providers.isEmpty) {
      _providers.addAll([
        OpenFdaNdcProvider(_client),
        RxNormProvider(_client),
      ]);
    }
  }

  final http.Client _client;
  final bool _ownsClient;
  final List<MedicineCatalogProvider> _providers;

  Future<List<MedicineCatalogCandidate>> search({
    String barcode = '',
    String text = '',
    int limit = 12,
  }) async {
    final cleanBarcode = barcode.trim();
    final cleanText = _catalogQuery(text);
    if (cleanBarcode.isEmpty && cleanText.isEmpty) return const [];

    final jobs = _providers.map((provider) async {
      try {
        return await provider
            .search(
              barcode: cleanBarcode,
              text: cleanText,
              limit: min(limit, 12),
            )
            .timeout(const Duration(seconds: 5));
      } catch (_) {
        // One catalog being unavailable must not block another provider or the
        // local-first pharmacy workflow.
        return <MedicineCatalogCandidate>[];
      }
    });

    final groups = await Future.wait(jobs);
    final best = <String, MedicineCatalogCandidate>{};
    for (final candidate in groups.expand((items) => items)) {
      if (candidate.seed.name.trim().isEmpty) continue;
      final key = candidate.seed.identityKey;
      final previous = best[key];
      if (previous == null || candidate.score > previous.score) {
        best[key] = candidate;
      }
    }

    final results = best.values.toList()
      ..sort((a, b) {
        final score = b.score.compareTo(a.score);
        if (score != 0) return score;
        return searchText(a.seed.name).compareTo(searchText(b.seed.name));
      });
    return results.take(limit).toList(growable: false);
  }

  void close() {
    if (_ownsClient) _client.close();
  }
}

class OpenFdaNdcProvider implements MedicineCatalogProvider {
  OpenFdaNdcProvider(this.client);

  final http.Client client;

  @override
  Future<List<MedicineCatalogCandidate>> search({
    required String barcode,
    required String text,
    required int limit,
  }) async {
    if (barcode.isNotEmpty) {
      final exact = await _query(
        'openfda.upc:"${_queryLiteral(barcode)}"',
        limit,
        queryText: text,
        barcode: barcode,
        barcodeExact: true,
      );
      if (exact.isNotEmpty) return exact;
    }

    final terms = _searchTerms(text);
    if (terms.isEmpty) return const [];
    for (final term in terms.take(3)) {
      final expression = [
        'brand_name:$term*',
        'generic_name:$term*',
        'active_ingredients.name:$term*',
      ].join(' ');
      final found = await _query(
        expression,
        limit,
        queryText: text,
        barcode: barcode,
      );
      if (found.isNotEmpty) return found;
    }
    return const [];
  }

  Future<List<MedicineCatalogCandidate>> _query(
    String search,
    int limit, {
    required String queryText,
    required String barcode,
    bool barcodeExact = false,
  }) async {
    final uri = Uri.https('api.fda.gov', '/drug/ndc.json', {
      'search': search,
      'limit': '${min(limit, 12)}',
    });
    final response = await client.get(uri).timeout(const Duration(seconds: 4));
    if (response.statusCode == 404) return const [];
    if (response.statusCode != 200) {
      throw StateError('openFDA returned ${response.statusCode}.');
    }
    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) return const [];
    final raw = decoded['results'];
    if (raw is! List) return const [];
    return parseResults(
      raw,
      queryText: queryText,
      barcode: barcode,
      barcodeExact: barcodeExact,
    );
  }

  static List<MedicineCatalogCandidate> parseResults(
    List<dynamic> rows, {
    required String queryText,
    required String barcode,
    bool barcodeExact = false,
  }) {
    final results = <MedicineCatalogCandidate>[];
    for (final value in rows) {
      if (value is! Map) continue;
      final row = Map<String, dynamic>.from(value);
      String string(String key) => (row[key] is String ? row[key] as String : '').trim();

      final brand = string('brand_name');
      final generic = string('generic_name');
      final manufacturer = string('labeler_name');
      final form = normalizeForm(string('dosage_form'));
      final productNdc = string('product_ndc');
      final ingredients = <String>[];
      final strengths = <String>[];
      final active = row['active_ingredients'];
      if (active is List) {
        for (final item in active) {
          if (item is! Map) continue;
          final map = Map<String, dynamic>.from(item);
          final name = map['name'];
          final strength = map['strength'];
          if (name is String && name.trim().isNotEmpty) ingredients.add(name.trim());
          if (strength is String && strength.trim().isNotEmpty) strengths.add(strength.trim());
        }
      }

      final salt = ingredients.isNotEmpty ? ingredients.join(' + ') : generic;
      final strength = strengths.join(' + ');
      final name = brand.isNotEmpty ? brand : (generic.isNotEmpty ? generic : salt);
      if (name.isEmpty) continue;
      final seed = MedicineDraftSeed(
        name: name,
        brand: brand,
        manufacturer: manufacturer,
        salt: salt,
        strength: strength,
        form: form,
        barcode: barcodeExact ? barcode : '',
        source: 'openFDA NDC',
        sourceId: productNdc,
      );
      final score = barcodeExact
          ? 1.0
          : _candidateScore(seed, queryText, providerFloor: .64);
      results.add(
        MedicineCatalogCandidate(
          seed: seed,
          score: score,
          provider: 'openFDA',
          reason: barcodeExact ? 'Exact catalog barcode' : 'Public product catalog',
        ),
      );
    }
    return results;
  }
}

class RxNormProvider implements MedicineCatalogProvider {
  RxNormProvider(this.client);

  final http.Client client;

  @override
  Future<List<MedicineCatalogCandidate>> search({
    required String barcode,
    required String text,
    required int limit,
  }) async {
    if (text.trim().isEmpty) return const [];
    final uri = Uri.https('rxnav.nlm.nih.gov', '/REST/approximateTerm.json', {
      'term': text,
      'maxEntries': '${min(limit, 10)}',
      'option': '1',
    });
    final response = await client.get(uri).timeout(const Duration(seconds: 4));
    if (response.statusCode != 200) {
      throw StateError('RxNorm returned ${response.statusCode}.');
    }
    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) return const [];
    final group = decoded['approximateGroup'];
    if (group is! Map) return const [];
    final raw = group['candidate'];
    if (raw is! List) return const [];
    return parseResults(raw, queryText: text);
  }

  static List<MedicineCatalogCandidate> parseResults(
    List<dynamic> rows, {
    required String queryText,
  }) {
    final results = <MedicineCatalogCandidate>[];
    for (final value in rows) {
      if (value is! Map) continue;
      final row = Map<String, dynamic>.from(value);
      final rawName = row['name'];
      if (rawName is! String || rawName.trim().isEmpty) continue;
      final parsed = _rxSeed(rawName.trim(), '${row['rxcui'] ?? ''}');
      final rank = int.tryParse('${row['rank'] ?? ''}') ?? 99;
      final lexical = double.tryParse('${row['score'] ?? ''}') ?? 0;
      final normalizedLexical = lexical <= 0 ? 0.0 : lexical / (lexical + 8);
      final localScore = _candidateScore(parsed, queryText, providerFloor: .60);
      final score = (localScore + normalizedLexical * .08 - min(rank - 1, 5) * .015)
          .clamp(.55, .95)
          .toDouble();
      results.add(
        MedicineCatalogCandidate(
          seed: parsed,
          score: score,
          provider: 'RxNorm',
          reason: 'Normalized medicine concept',
        ),
      );
    }
    return results;
  }
}

MedicineDraftSeed _rxSeed(String raw, String rxcui) {
  final brandMatch = RegExp(r'\[([^\]]+)\]').firstMatch(raw);
  final brand = brandMatch?.group(1)?.trim() ?? '';
  var withoutBrand = raw.replaceAll(RegExp(r'\s*\[[^\]]+\]\s*'), ' ').trim();
  final strengthMatch = RegExp(
    r'\b\d+(?:\.\d+)?\s*(?:mcg|mg|g|ml)(?:\s*/\s*(?:mcg|mg|g|ml|dose|actuation|tablet|capsule|1))?\b',
    caseSensitive: false,
  ).firstMatch(withoutBrand);
  final strength = strengthMatch?.group(0)?.replaceAll(RegExp(r'\s+'), ' ').trim() ?? '';

  String form = '';
  final lower = withoutBrand.toLowerCase();
  for (final entry in const <String, String>{
    'tablet': 'Tablet',
    'capsule': 'Capsule',
    'oral suspension': 'Syrup',
    'oral solution': 'Syrup',
    'syrup': 'Syrup',
    'injection': 'Injection',
    'injectable': 'Injection',
    'cream': 'Cream',
    'ointment': 'Ointment',
    'ophthalmic': 'Drops',
    'otic': 'Drops',
    'drops': 'Drops',
  }.entries) {
    if (lower.contains(entry.key)) {
      form = entry.value;
      break;
    }
  }

  var generic = withoutBrand;
  if (strengthMatch != null) generic = generic.substring(0, strengthMatch.start).trim();
  generic = generic
      .replaceAll(
        RegExp(
          r'\b(oral|tablet|capsule|solution|suspension|injection|injectable|cream|ointment|ophthalmic|otic|extended release|delayed release)\b',
          caseSensitive: false,
        ),
        ' ',
      )
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (generic.isEmpty) generic = withoutBrand;
  final name = brand.isNotEmpty ? brand : generic;
  return MedicineDraftSeed(
    name: name,
    brand: brand,
    salt: generic,
    strength: strength,
    form: form,
    source: 'RxNorm',
    sourceId: rxcui,
  );
}

double _candidateScore(
  MedicineDraftSeed seed,
  String queryText, {
  required double providerFloor,
}) {
  final query = searchText(queryText);
  if (query.isEmpty) return providerFloor;
  final document = searchText([
    seed.name,
    seed.brand,
    seed.salt,
    seed.strength,
    seed.form,
    seed.manufacturer,
  ].join(' '));
  final queryTokens = query.split(' ').where((token) => token.length >= 2).toList();
  final docTokens = document.split(' ').where((token) => token.isNotEmpty).toList();
  if (queryTokens.isEmpty || docTokens.isEmpty) return providerFloor;

  var exact = 0;
  var best = 0.0;
  for (final token in queryTokens.take(12)) {
    if (docTokens.contains(token)) exact++;
    for (final candidate in docTokens.take(28)) {
      best = max(best, orderedSimilarity(token, candidate));
    }
  }
  final exactFraction = exact / queryTokens.length;
  return (providerFloor + exactFraction * .20 + best * .13)
      .clamp(providerFloor, .97)
      .toDouble();
}

String _catalogQuery(String raw) {
  var value = searchText(raw);
  if (value.isEmpty) return '';
  const noise = {
    'exp',
    'expiry',
    'expires',
    'mfg',
    'mfd',
    'manufactured',
    'batch',
    'batchno',
    'lot',
    'mrp',
    'price',
    'rs',
    'inr',
    'use',
    'before',
    'after',
    'schedule',
    'store',
    'storage',
    'keep',
    'away',
    'children',
    'tablets',
    'tablet',
    'capsules',
    'capsule',
  };
  final tokens = value
      .split(' ')
      .where((token) => token.isNotEmpty)
      .where((token) => !noise.contains(token))
      .where((token) => !RegExp(r'^\d{1,2}[./-]\d{1,4}$').hasMatch(token))
      .take(14)
      .toList();
  return tokens.join(' ');
}

List<String> _searchTerms(String value) {
  final tokens = searchText(value)
      .split(' ')
      .where((token) => RegExp(r'^[a-z][a-z0-9]{2,}$').hasMatch(token))
      .where(
        (token) =>
            !const {
              'tablet',
              'tablets',
              'capsule',
              'capsules',
              'syrup',
              'injection',
              'cream',
              'ointment',
              'medicine',
              'mg',
              'ml',
              'manufactured',
              'manufacturer',
            }.contains(token),
      )
      .toList();
  tokens.sort((a, b) => b.length.compareTo(a.length));
  return tokens;
}

String _queryLiteral(String value) =>
    value.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '');
