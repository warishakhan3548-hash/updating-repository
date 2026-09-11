import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import '../domain/gs1_healthcare.dart';
import '../domain/medicine_resolution_v2.dart';
import '../domain/medicine_understanding.dart';
import '../domain/search.dart';

/// Identity-only, versioned offline master catalogue.
///
/// This database is NOT inventory and never stores quantity, price, location,
/// MFG, EXP or batch. It is an optional recognition accelerator. If it is empty,
/// unavailable or corrupt, the scanner keeps working from Tier-1 shop knowledge.
class CanonicalMedicineCatalogService {
  CanonicalMedicineCatalogService._();

  static final CanonicalMedicineCatalogService instance =
      CanonicalMedicineCatalogService._();

  static const int _schemaVersion = 1;
  static const int _maxDeltaBytes = 24 * 1024 * 1024;
  static const int _maxDeltaLines = 50000;
  static const int _maxCandidateRows = maxCanonicalMedicineCandidates;

  Database? _database;
  Future<void>? _initializing;

  Future<void> initialize() => _initializing ??= _open().catchError((Object e) {
    _initializing = null;
    throw e;
  });

  Future<void> _open() async {
    if (_database != null) return;
    final support = await getApplicationSupportDirectory();
    final db = await openDatabase(
      '${support.path}/aaris_medicine_catalog.db',
      version: _schemaVersion,
      onConfigure: (database) async {
        await database.execute('PRAGMA foreign_keys = ON');
      },
      onCreate: (database, _) async {
        await database.execute('''
CREATE TABLE catalog_meta (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL
)
''');
        await database.execute('''
CREATE TABLE catalog_products (
  product_id TEXT PRIMARY KEY,
  rev INTEGER NOT NULL,
  status TEXT NOT NULL,
  name TEXT NOT NULL,
  brand TEXT NOT NULL,
  salt TEXT NOT NULL,
  strength TEXT NOT NULL,
  form TEXT NOT NULL,
  manufacturer TEXT NOT NULL,
  source TEXT NOT NULL,
  verified INTEGER NOT NULL,
  prior_weight REAL NOT NULL
)
''');
        await database.execute('''
CREATE TABLE catalog_aliases (
  product_id TEXT NOT NULL,
  kind TEXT NOT NULL,
  value TEXT NOT NULL,
  normalized TEXT NOT NULL,
  PRIMARY KEY(product_id, kind, normalized),
  FOREIGN KEY(product_id) REFERENCES catalog_products(product_id) ON DELETE CASCADE
)
''');
        await database.execute('''
CREATE TABLE catalog_barcodes (
  product_id TEXT NOT NULL,
  value TEXT NOT NULL,
  normalized TEXT NOT NULL,
  PRIMARY KEY(product_id, normalized),
  FOREIGN KEY(product_id) REFERENCES catalog_products(product_id) ON DELETE CASCADE
)
''');
        await database.execute('''
CREATE TABLE catalog_terms (
  product_id TEXT NOT NULL,
  term TEXT NOT NULL,
  weight REAL NOT NULL,
  PRIMARY KEY(product_id, term),
  FOREIGN KEY(product_id) REFERENCES catalog_products(product_id) ON DELETE CASCADE
)
''');
        await database.execute('''
CREATE TABLE catalog_deletes (
  product_id TEXT NOT NULL,
  delete_key TEXT NOT NULL,
  weight REAL NOT NULL,
  PRIMARY KEY(product_id, delete_key),
  FOREIGN KEY(product_id) REFERENCES catalog_products(product_id) ON DELETE CASCADE
)
''');
        await database.execute(
          'CREATE INDEX idx_catalog_barcode ON catalog_barcodes(normalized)',
        );
        await database.execute(
          'CREATE INDEX idx_catalog_term ON catalog_terms(term)',
        );
        await database.execute(
          'CREATE INDEX idx_catalog_delete ON catalog_deletes(delete_key)',
        );
        await database.insert('catalog_meta', {
          'key': 'last_applied_revision',
          'value': '0',
        });
      },
    );
    _database = db;
  }

  Future<int> get lastAppliedRevision async {
    await initialize();
    final rows = await _database!.query(
      'catalog_meta',
      columns: const <String>['value'],
      where: 'key = ?',
      whereArgs: const <Object?>['last_applied_revision'],
      limit: 1,
    );
    if (rows.isEmpty) return 0;
    return int.tryParse('${rows.first['value']}') ?? 0;
  }

  /// Returns only a tiny scan-targeted candidate set. A 300k+ catalogue never
  /// gets copied into Dart memory or the medicine-understanding isolate.
  Future<List<CanonicalMedicineProduct>> candidatesForEvidence(
    List<MedicineFrameEvidence> evidence, {
    int limit = _maxCandidateRows,
  }) async {
    if (evidence.isEmpty) return const <CanonicalMedicineProduct>[];
    try {
      await initialize();
      final boundedLimit = min(max(1, limit), _maxCandidateRows);
      final votes = <String, double>{};
      final barcodeKeys = <String>{};
      for (final frame in evidence.take(maxMedicineEvidenceFrames)) {
        for (final value in frame.allBarcodes) {
          final key = _barcodeKey(value);
          if (key.isNotEmpty) barcodeKeys.add(key);
        }
      }
      if (barcodeKeys.isNotEmpty) {
        final placeholders = List.filled(barcodeKeys.length, '?').join(',');
        final rows = await _database!.rawQuery(
          'SELECT product_id FROM catalog_barcodes WHERE normalized IN ($placeholders)',
          barcodeKeys.toList(growable: false),
        );
        for (final row in rows) {
          final id = row['product_id'];
          if (id is String) votes[id] = 100;
        }
      }

      final terms = _evidenceTerms(evidence).take(28).toList(growable: false);
      if (terms.isNotEmpty) {
        final placeholders = List.filled(terms.length, '?').join(',');
        final rows = await _database!.rawQuery(
          '''SELECT product_id, SUM(weight) AS score
             FROM catalog_terms
             WHERE term IN ($placeholders)
             GROUP BY product_id
             ORDER BY score DESC
             LIMIT ${boundedLimit * 3}''',
          terms,
        );
        for (final row in rows) {
          final id = row['product_id'];
          final score = row['score'];
          if (id is! String || score is! num) continue;
          votes.update(
            id,
            (value) => value + score.toDouble(),
            ifAbsent: () => score.toDouble(),
          );
        }

        final deleteKeys = <String>{};
        for (final term in terms.where((value) => value.length >= 4).take(18)) {
          for (final value in _deleteKeys(_ocrFoldToken(term)).take(18)) {
            deleteKeys.add(value);
            if (deleteKeys.length >= 120) break;
          }
          if (deleteKeys.length >= 120) break;
        }
        if (deleteKeys.isNotEmpty) {
          final placeholders = List.filled(deleteKeys.length, '?').join(',');
          final rows = await _database!.rawQuery(
            '''SELECT product_id, SUM(weight) AS score
               FROM catalog_deletes
               WHERE delete_key IN ($placeholders)
               GROUP BY product_id
               ORDER BY score DESC
               LIMIT ${boundedLimit * 3}''',
            deleteKeys.toList(growable: false),
          );
          for (final row in rows) {
            final id = row['product_id'];
            final score = row['score'];
            if (id is! String || score is! num) continue;
            votes.update(
              id,
              (value) => value + score.toDouble() * .42,
              ifAbsent: () => score.toDouble() * .42,
            );
          }
        }
      }

      if (votes.isEmpty) return const <CanonicalMedicineProduct>[];
      final ranked = votes.entries.toList(growable: false)
        ..sort((a, b) {
          final score = b.value.compareTo(a.value);
          return score != 0 ? score : a.key.compareTo(b.key);
        });
      final ids = ranked
          .take(boundedLimit)
          .map((entry) => entry.key)
          .toList(growable: false);
      return await _loadProducts(ids);
    } catch (_) {
      return const <CanonicalMedicineProduct>[];
    }
  }

  Future<List<CanonicalMedicineProduct>> _loadProducts(List<String> ids) async {
    if (ids.isEmpty) return const <CanonicalMedicineProduct>[];
    final placeholders = List.filled(ids.length, '?').join(',');
    final rows = await _database!.rawQuery('''SELECT * FROM catalog_products
         WHERE product_id IN ($placeholders) AND status = 'active' ''', ids);
    if (rows.isEmpty) return const <CanonicalMedicineProduct>[];

    final aliases = <String, List<(String, String)>>{};
    final aliasRows = await _database!.rawQuery(
      'SELECT product_id, kind, value FROM catalog_aliases WHERE product_id IN ($placeholders)',
      ids,
    );
    for (final row in aliasRows) {
      final id = row['product_id'];
      final kind = row['kind'];
      final value = row['value'];
      if (id is String && kind is String && value is String) {
        aliases.putIfAbsent(id, () => <(String, String)>[]).add((kind, value));
      }
    }

    final barcodes = <String, List<String>>{};
    final barcodeRows = await _database!.rawQuery(
      'SELECT product_id, value FROM catalog_barcodes WHERE product_id IN ($placeholders)',
      ids,
    );
    for (final row in barcodeRows) {
      final id = row['product_id'];
      final value = row['value'];
      if (id is String && value is String) {
        barcodes.putIfAbsent(id, () => <String>[]).add(value);
      }
    }

    final byId = <String, CanonicalMedicineProduct>{};
    for (final row in rows) {
      final id = row['product_id'];
      if (id is! String) continue;
      final pairs = aliases[id] ?? const <(String, String)>[];
      String string(String key) => '${row[key] ?? ''}'.trim();
      byId[id] = CanonicalMedicineProduct(
        productId: id,
        revision: row['rev'] is int ? row['rev']! as int : 0,
        status: string('status'),
        name: string('name'),
        brand: string('brand'),
        salt: string('salt'),
        strength: string('strength'),
        form: string('form'),
        manufacturer: string('manufacturer'),
        aliases: pairs
            .where((value) => value.$1 == 'alias')
            .map((value) => value.$2)
            .take(24)
            .toList(growable: false),
        ocrAliases: pairs
            .where((value) => value.$1 == 'ocr')
            .map((value) => value.$2)
            .take(24)
            .toList(growable: false),
        barcodes: (barcodes[id] ?? const <String>[])
            .take(12)
            .toList(growable: false),
        source: string('source').isEmpty ? 'master' : string('source'),
        verified: row['verified'] == 1,
        priorWeight: row['prior_weight'] is num
            ? (row['prior_weight']! as num).toDouble().clamp(0, 1).toDouble()
            : 0,
      );
    }
    return ids
        .map((id) => byId[id])
        .whereType<CanonicalMedicineProduct>()
        .toList(growable: false);
  }

  /// Applies a trusted, already-acquired JSONL delta atomically after SHA-256
  /// integrity verification. This method performs no network I/O.
  Future<CatalogDeltaApplyResult> applyVerifiedDelta(
    Uint8List bytes, {
    required String expectedSha256,
  }) async {
    if (bytes.isEmpty || bytes.length > _maxDeltaBytes) {
      throw const FormatException(
        'Catalog delta is empty or exceeds the safety limit.',
      );
    }
    final expected = expectedSha256.trim().toLowerCase();
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(expected)) {
      throw const FormatException('Catalog delta SHA-256 is invalid.');
    }
    final actual = sha256.convert(bytes).toString();
    if (actual != expected) {
      throw const FormatException('Catalog delta checksum mismatch.');
    }
    final text = utf8.decode(bytes, allowMalformed: false);
    final rawLines = const LineSplitter().convert(text);
    if (rawLines.length > _maxDeltaLines) {
      throw const FormatException('Catalog delta has too many operations.');
    }
    final changes = <_CatalogDelta>[];
    var previousRevision = -1;
    for (final raw in rawLines) {
      final line = raw.trim();
      if (line.isEmpty) continue;
      final decoded = jsonDecode(line);
      if (decoded is! Map) {
        throw const FormatException(
          'Catalog delta line must be a JSON object.',
        );
      }
      final change = _CatalogDelta.fromJson(Map<String, dynamic>.from(decoded));
      if (previousRevision >= 0 && change.revision <= previousRevision) {
        throw const FormatException(
          'Catalog revisions must be strictly increasing.',
        );
      }
      previousRevision = change.revision;
      changes.add(change);
    }
    if (changes.isEmpty) {
      throw const FormatException('Catalog delta contains no operations.');
    }

    await initialize();
    var applied = 0;
    var skipped = 0;
    var finalRevision = await lastAppliedRevision;
    await _database!.transaction((txn) async {
      final currentRows = await txn.query(
        'catalog_meta',
        columns: const <String>['value'],
        where: 'key = ?',
        whereArgs: const <Object?>['last_applied_revision'],
        limit: 1,
      );
      var current = currentRows.isEmpty
          ? 0
          : int.tryParse('${currentRows.first['value']}') ?? 0;
      for (final change in changes) {
        if (change.revision <= current) {
          skipped++;
          continue;
        }
        switch (change.operation) {
          case 'upsert':
            await _upsert(txn, change.product!);
            break;
          case 'deprecate':
            final changed = await txn.update(
              'catalog_products',
              {'status': 'deprecated', 'rev': change.revision},
              where: 'product_id = ? AND rev < ?',
              whereArgs: <Object?>[change.productId, change.revision],
            );
            if (changed == 0) {
              await txn.insert('catalog_products', {
                'product_id': change.productId,
                'rev': change.revision,
                'status': 'deprecated',
                'name': '',
                'brand': '',
                'salt': '',
                'strength': '',
                'form': '',
                'manufacturer': '',
                'source': 'master',
                'verified': 0,
                'prior_weight': 0.0,
              }, conflictAlgorithm: ConflictAlgorithm.ignore);
            }
            break;
        }
        current = change.revision;
        applied++;
      }
      finalRevision = current;
      await txn.insert('catalog_meta', {
        'key': 'last_applied_revision',
        'value': '$current',
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      await txn.insert('catalog_meta', {
        'key': 'last_delta_sha256',
        'value': actual,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    });
    return CatalogDeltaApplyResult(
      applied: applied,
      skipped: skipped,
      lastAppliedRevision: finalRevision,
      sha256: actual,
    );
  }

  Future<void> _upsert(
    Transaction txn,
    CanonicalMedicineProduct product,
  ) async {
    if (!product.active || !product.verified) {
      throw const FormatException(
        'Upserted catalog products must be active and verified.',
      );
    }
    final current = await txn.query(
      'catalog_products',
      columns: const <String>['rev'],
      where: 'product_id = ?',
      whereArgs: <Object?>[product.productId],
      limit: 1,
    );
    if (current.isNotEmpty &&
        current.first['rev'] is int &&
        (current.first['rev']! as int) >= product.revision) {
      return;
    }

    await txn.insert('catalog_products', {
      'product_id': product.productId,
      'rev': product.revision,
      'status': product.status,
      'name': product.name,
      'brand': product.brand,
      'salt': product.salt,
      'strength': product.strength,
      'form': product.form,
      'manufacturer': product.manufacturer,
      'source': product.source,
      'verified': product.verified ? 1 : 0,
      'prior_weight': product.priorWeight.clamp(0, 1),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    for (final table in const <String>[
      'catalog_aliases',
      'catalog_barcodes',
      'catalog_terms',
      'catalog_deletes',
    ]) {
      await txn.delete(
        table,
        where: 'product_id = ?',
        whereArgs: <Object?>[product.productId],
      );
    }

    final aliases = <(String, String)>[
      for (final value in product.aliases) ('alias', value),
      for (final value in product.ocrAliases) ('ocr', value),
    ];
    for (final pair in aliases.take(48)) {
      final normalized = searchText(pair.$2);
      if (normalized.isEmpty) continue;
      await txn.insert('catalog_aliases', {
        'product_id': product.productId,
        'kind': pair.$1,
        'value': pair.$2,
        'normalized': normalized,
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
    }
    for (final value in product.barcodes.take(12)) {
      final normalized = _barcodeKey(value);
      if (normalized.isEmpty) continue;
      await txn.insert('catalog_barcodes', {
        'product_id': product.productId,
        'value': value,
        'normalized': normalized,
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
    }

    final weightedTerms = _catalogTerms(product);
    for (final entry in weightedTerms.entries.take(160)) {
      await txn.insert('catalog_terms', {
        'product_id': product.productId,
        'term': entry.key,
        'weight': entry.value,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      if (entry.key.length < 4 || entry.key.length > 28) continue;
      for (final deletion in _deleteKeys(entry.key).take(28)) {
        await txn.insert('catalog_deletes', {
          'product_id': product.productId,
          'delete_key': deletion,
          'weight': entry.value,
        }, conflictAlgorithm: ConflictAlgorithm.ignore);
      }
    }
  }
}

class CatalogDeltaApplyResult {
  const CatalogDeltaApplyResult({
    required this.applied,
    required this.skipped,
    required this.lastAppliedRevision,
    required this.sha256,
  });

  final int applied;
  final int skipped;
  final int lastAppliedRevision;
  final String sha256;
}

class _CatalogDelta {
  const _CatalogDelta({
    required this.operation,
    required this.productId,
    required this.revision,
    this.product,
  });

  final String operation;
  final String productId;
  final int revision;
  final CanonicalMedicineProduct? product;

  factory _CatalogDelta.fromJson(Map<String, dynamic> map) {
    final operation = '${map['op'] ?? ''}'.trim().toLowerCase();
    final productId = '${map['product_id'] ?? map['productId'] ?? ''}'.trim();
    final revision = map['rev'];
    if (!const <String>{'upsert', 'deprecate'}.contains(operation) ||
        productId.isEmpty ||
        productId.length > 96 ||
        revision is! int ||
        revision <= 0) {
      throw const FormatException('Invalid catalog delta envelope.');
    }
    if (operation == 'deprecate') {
      return _CatalogDelta(
        operation: operation,
        productId: productId,
        revision: revision,
      );
    }

    List<String> strings(String snake, String camel) {
      final raw = map[snake] ?? map[camel];
      if (raw is! List) return const <String>[];
      return raw
          .whereType<String>()
          .map((value) => value.trim())
          .where((value) => value.isNotEmpty && value.length <= 160)
          .take(24)
          .toList(growable: false);
    }

    String text(String snake, [String? camel]) =>
        '${map[snake] ?? (camel == null ? null : map[camel]) ?? ''}'.trim();
    final rawStrength = map['strength'];
    final rawStrengthMg = map['strength_mg'];
    final strength = rawStrength is String && rawStrength.trim().isNotEmpty
        ? rawStrength.trim()
        : rawStrengthMg is num
        ? '${rawStrengthMg.toString()} mg'
        : '';
    final barcodeList = strings('barcodes', 'barcodes');
    final singleBarcode = text('barcode');
    final product = CanonicalMedicineProduct(
      productId: productId,
      revision: revision,
      name: text('name'),
      brand: text('brand'),
      salt: text('salt'),
      strength: strength,
      form: text('form'),
      manufacturer: text('manufacturer'),
      aliases: strings('aliases', 'aliases'),
      ocrAliases: strings('aliases_ocr', 'ocrAliases'),
      barcodes: <String>[
        ...barcodeList,
        if (singleBarcode.isNotEmpty) singleBarcode,
      ],
      source: text('source').isEmpty ? 'master' : text('source'),
      verified: map['verified'] == true || map['verified'] == 1,
      priorWeight: map['prior_weight'] is num
          ? (map['prior_weight']! as num).toDouble().clamp(0, 1).toDouble()
          : 0,
      status: 'active',
    );
    if (product.displayName.isEmpty ||
        product.brand.length > 300 ||
        product.salt.length > 300 ||
        product.strength.length > 120 ||
        product.form.length > 80 ||
        product.manufacturer.length > 300 ||
        !product.verified) {
      throw const FormatException(
        'Catalog product is incomplete or unverified.',
      );
    }
    return _CatalogDelta(
      operation: operation,
      productId: productId,
      revision: revision,
      product: product,
    );
  }
}

Map<String, double> _catalogTerms(CanonicalMedicineProduct product) {
  final result = <String, double>{};
  void add(String value, double weight) {
    final normalized = searchText(value);
    if (normalized.isEmpty) return;
    final tokens = normalized
        .split(' ')
        .where((value) => value.length >= 3)
        .take(32);
    for (final token in tokens) {
      final folded = _ocrFoldToken(token);
      result[token] = max(result[token] ?? 0, weight);
      result[folded] = max(result[folded] ?? 0, weight * .98);
    }
    final compact = normalized.replaceAll(' ', '');
    if (compact.length >= 4 && compact.length <= 28) {
      result[compact] = max(result[compact] ?? 0, weight);
    }
  }

  add(product.displayName, 5.0);
  add(product.brand, 5.2);
  add(product.salt, 3.4);
  add(product.manufacturer, 1.5);
  for (final value in product.aliases.take(24)) add(value, 4.5);
  for (final value in product.ocrAliases.take(24)) add(value, 4.8);
  return result;
}

Set<String> _evidenceTerms(List<MedicineFrameEvidence> evidence) {
  final result = <String>{};
  for (final frame in evidence.take(maxMedicineEvidenceFrames)) {
    final normalized = searchText(frame.text);
    final tokens = normalized
        .split(' ')
        .where((value) => value.isNotEmpty)
        .toList();
    for (final token in tokens.take(180)) {
      if (token.length < 3 || _catalogNoise.contains(token)) continue;
      result.add(token);
      result.add(_ocrFoldToken(token));
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
  final ranked = result.toList(growable: false)
    ..sort((a, b) {
      final length = b.length.compareTo(a.length);
      return length != 0 ? length : a.compareTo(b);
    });
  return ranked.take(64).toSet();
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

String _barcodeKey(String value) {
  final raw = value.trim();
  if (raw.isEmpty) return '';
  final verified = verifiedGtinKey(raw);
  if (verified.isNotEmpty) return verified;
  // Keep proprietary/non-GTIN payloads exact across catalogue lookup too.
  return raw.replaceAll(RegExp(r'\s+'), '');
}

const _catalogNoise = <String>{
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
  'schedule',
  'only',
};
