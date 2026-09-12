import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import '../domain/medicine.dart';
import '../domain/medicine_understanding.dart';
import '../domain/search.dart';

/// Private, bounded learning memory for recurring OCR identity mistakes.
///
/// Only explicit pharmacist-confirmed saves may teach this store. It never
/// stores the full OCR document, dates, batch, price, quantity or location. A
/// learned alias can only enrich an already active pharmacist-reviewed local
/// identity; it cannot create a new medicine identity by itself.
class OfflineRecognitionMemoryService {
  OfflineRecognitionMemoryService._();

  static final OfflineRecognitionMemoryService instance =
      OfflineRecognitionMemoryService._();

  static const _schemaVersion = 1;
  static const _maxRows = 16000;
  Database? _database;
  Future<void>? _initializing;

  Future<void> _initialize() =>
      _initializing ??= _open().catchError((Object error) {
        _initializing = null;
        throw error;
      });

  Future<void> _open() async {
    if (_database != null) return;
    final support = await getApplicationSupportDirectory();
    _database = await openDatabase(
      '${support.path}/aaris_offline_recognition_memory.db',
      version: _schemaVersion,
      onCreate: (db, _) async {
        await db.execute('''
CREATE TABLE recognition_aliases (
  identity_key TEXT NOT NULL,
  alias TEXT NOT NULL,
  normalized_alias TEXT NOT NULL,
  support INTEGER NOT NULL,
  last_confirmed INTEGER NOT NULL,
  PRIMARY KEY(identity_key, normalized_alias)
)
''');
        await db.execute(
          'CREATE INDEX idx_recognition_alias ON recognition_aliases(normalized_alias)',
        );
        await db.execute(
          'CREATE INDEX idx_recognition_recent ON recognition_aliases(last_confirmed)',
        );
      },
    );
  }

  /// Learns only compact name/brand OCR variants after an explicit human save.
  /// Recognition-memory failure is intentionally non-authoritative: inventory
  /// save has already succeeded and callers should keep operating normally.
  Future<void> learnFromConfirmedScan(
    MedicineScanDraft draft,
    Medicine confirmed,
  ) async {
    final aliases = deriveLearnableIdentityAliases(draft, confirmed);
    if (aliases.isEmpty) return;
    try {
      await _initialize();
      final db = _database;
      if (db == null) return;
      final identityKey = recognitionIdentityKey(
        name: confirmed.name,
        brand: confirmed.brand,
        salt: confirmed.salt,
        strength: confirmed.strength,
        form: confirmed.form,
      );
      if (identityKey.isEmpty) return;
      final now = DateTime.now().millisecondsSinceEpoch;
      await db.transaction((txn) async {
        for (final alias in aliases.take(8)) {
          final normalized = searchText(alias);
          if (normalized.length < 3 || normalized.length > 40) continue;
          await txn.rawInsert(
            '''INSERT INTO recognition_aliases
               (identity_key, alias, normalized_alias, support, last_confirmed)
               VALUES (?, ?, ?, 1, ?)
               ON CONFLICT(identity_key, normalized_alias) DO UPDATE SET
                 alias=excluded.alias,
                 support=MIN(recognition_aliases.support + 1, 1000000),
                 last_confirmed=excluded.last_confirmed''',
            <Object?>[identityKey, alias, normalized, now],
          );
        }
        final countRows = await txn.rawQuery(
          'SELECT COUNT(*) AS count FROM recognition_aliases',
        );
        final count = countRows.isEmpty
            ? 0
            : (countRows.first['count'] as num?)?.toInt() ?? 0;
        final overflow = max(0, count - _maxRows);
        if (overflow > 0) {
          await txn.rawDelete(
            '''DELETE FROM recognition_aliases WHERE rowid IN (
                 SELECT rowid FROM recognition_aliases
                 ORDER BY last_confirmed ASC, support ASC
                 LIMIT ?
               )''',
            <Object?>[overflow],
          );
        }
      });
    } catch (_) {
      // A local-learning accelerator must never make capture/review unavailable.
    }
  }

  /// Adds previously confirmed OCR aliases only to matching current local
  /// medicine identities. If the memory DB is absent/corrupt/unavailable, the
  /// exact original knowledge list is returned.
  Future<List<MedicineKnowledgeEntry>> enrichKnowledge(
    List<MedicineKnowledgeEntry> knowledge,
    List<MedicineFrameEvidence> evidence,
  ) async {
    if (knowledge.isEmpty || evidence.isEmpty) return knowledge;
    try {
      await _initialize();
      final db = _database;
      if (db == null) return knowledge;
      final keys = _evidenceAliasKeys(evidence)
          .take(96)
          .toList(growable: false);
      if (keys.isEmpty) return knowledge;
      final placeholders = List.filled(keys.length, '?').join(',');
      final rows = await db.rawQuery(
        '''SELECT identity_key, alias, normalized_alias, support, last_confirmed
           FROM recognition_aliases
           WHERE normalized_alias IN ($placeholders)
           ORDER BY support DESC, last_confirmed DESC
           LIMIT 128''',
        keys,
      );
      if (rows.isEmpty) return knowledge;

      final byAlias = <String, List<Map<String, Object?>>>{};
      for (final row in rows) {
        final normalized = row['normalized_alias'];
        if (normalized is! String || normalized.isEmpty) continue;
        byAlias
            .putIfAbsent(normalized, () => <Map<String, Object?>>[])
            .add(row);
      }

      final learned = <String, List<String>>{};
      for (final collision in byAlias.values) {
        final supportByIdentity = <String, int>{};
        for (final row in collision) {
          final identity = row['identity_key'];
          final support = row['support'];
          if (identity is! String || support is! num) continue;
          supportByIdentity.update(
            identity,
            (value) => value + support.toInt(),
            ifAbsent: () => support.toInt(),
          );
        }
        if (supportByIdentity.isEmpty) continue;
        final ranked = supportByIdentity.entries.toList(growable: false)
          ..sort((a, b) {
            final support = b.value.compareTo(a.value);
            return support != 0 ? support : a.key.compareTo(b.key);
          });
        final winner = ranked.first;
        if (ranked.length > 1) {
          final runner = ranked[1];
          final dominant =
              winner.value >= 3 && winner.value >= runner.value * 2;
          if (!dominant) continue;
        }

        for (final row in collision) {
          if (row['identity_key'] != winner.key) continue;
          final alias = row['alias'];
          if (alias is! String || alias.trim().isEmpty) continue;
          final values = learned.putIfAbsent(winner.key, () => <String>[]);
          if (!values.contains(alias) && values.length < 12) values.add(alias);
          break;
        }
      }
      if (learned.isEmpty) return knowledge;

      var changed = false;
      final result = <MedicineKnowledgeEntry>[];
      for (final entry in knowledge) {
        final identity = recognitionIdentityKey(
          name: entry.name,
          brand: entry.brand,
          salt: entry.salt,
          strength: entry.strength,
          form: entry.form,
        );
        final aliases = learned[identity];
        if (aliases == null || aliases.isEmpty) {
          result.add(entry);
          continue;
        }
        final merged = <String>{
          ...entry.ocrAliases,
          ...aliases,
        }.take(24).toList(growable: false);
        result.add(
          MedicineKnowledgeEntry(
            name: entry.name,
            brand: entry.brand,
            salt: entry.salt,
            strength: entry.strength,
            form: entry.form,
            manufacturer: entry.manufacturer,
            barcode: entry.barcode,
            aliases: entry.aliases,
            ocrAliases: merged,
          ),
        );
        changed = true;
      }
      return changed
          ? List<MedicineKnowledgeEntry>.unmodifiable(result)
          : knowledge;
    } catch (_) {
      return knowledge;
    }
  }
}

/// Stable privacy-safe identity key. Raw OCR is never part of this digest.
String recognitionIdentityKey({
  required String name,
  required String brand,
  required String salt,
  required String strength,
  required String form,
}) {
  final parts = <String>[
    name,
    brand,
    salt,
    strength,
    form,
  ].map(searchText).toList(growable: false);
  if (parts.every((value) => value.isEmpty)) return '';
  return sha256.convert(parts.join('|').codeUnits).toString();
}

/// Extracts bounded OCR variants that are demonstrably close to the confirmed
/// human-reviewed Name/Brand. Salt, strength and lot text are intentionally not
/// learned as identity aliases, preventing a common ingredient or dose from
/// becoming a shortcut to the wrong product.
List<String> deriveLearnableIdentityAliases(
  MedicineScanDraft draft,
  Medicine confirmed,
) {
  final targets = <String>{
    confirmed.name,
    confirmed.brand,
  }.map(searchText).where((value) => value.length >= 3).toSet();
  if (targets.isEmpty || draft.rawText.trim().isEmpty) return const <String>[];

  final observed = <String>{};
  for (final rawLine in draft.rawText.split(RegExp(r'[\r\n]+')).take(32)) {
    final line = searchText(rawLine);
    if (line.isEmpty) continue;
    final tokens = line
        .split(' ')
        .where((value) => value.isNotEmpty)
        .take(16)
        .toList(growable: false);
    for (final token in tokens) {
      if (token.length >= 3 && token.length <= 28) observed.add(token);
    }
    for (var width = 2; width <= min(3, tokens.length); width++) {
      for (var start = 0; start + width <= tokens.length; start++) {
        final phrase = tokens.sublist(start, start + width).join(' ');
        if (phrase.length >= 4 && phrase.length <= 32) observed.add(phrase);
      }
    }
    if (line.length <= 32) observed.add(line);
  }

  final ranked = <(String, double)>[];
  for (final candidate in observed) {
    if (targets.contains(candidate)) continue;
    if (RegExp(r'^\d+(?:[ ./:+-]\d+)*$').hasMatch(candidate)) continue;
    var best = 0.0;
    for (final target in targets) {
      final ratio =
          min(candidate.length, target.length) /
          max(candidate.length, target.length);
      if (ratio < .58) continue;
      best = max(best, _identitySimilarity(candidate, target));
    }
    if (best >= .74) ranked.add((candidate, best));
  }
  ranked.sort((a, b) {
    final score = b.$2.compareTo(a.$2);
    if (score != 0) return score;
    final length = a.$1.length.compareTo(b.$1.length);
    return length != 0 ? length : a.$1.compareTo(b.$1);
  });
  return ranked.map((value) => value.$1).take(8).toList(growable: false);
}

Set<String> _evidenceAliasKeys(List<MedicineFrameEvidence> evidence) {
  final result = <String>{};
  for (final frame in evidence.take(12)) {
    for (final rawLine in frame.text.split(RegExp(r'[\r\n]+')).take(24)) {
      final line = searchText(rawLine);
      if (line.isEmpty) continue;
      final tokens = line
          .split(' ')
          .where((value) => value.isNotEmpty)
          .take(16)
          .toList(growable: false);
      for (final token in tokens) {
        if (token.length >= 3 && token.length <= 28) result.add(token);
      }
      for (var width = 2; width <= min(3, tokens.length); width++) {
        for (var start = 0; start + width <= tokens.length; start++) {
          final phrase = tokens.sublist(start, start + width).join(' ');
          if (phrase.length >= 4 && phrase.length <= 40) result.add(phrase);
        }
      }
      if (line.length <= 40) result.add(line);
      if (result.length >= 128) return result;
    }
  }
  return result;
}

double _identitySimilarity(String left, String right) {
  final raw = _editSimilarity(
    left.replaceAll(' ', ''),
    right.replaceAll(' ', ''),
  );
  final folded = _editSimilarity(
    _ocrFoldIdentity(left).replaceAll(' ', ''),
    _ocrFoldIdentity(right).replaceAll(' ', ''),
  );
  return max(raw, folded);
}

String _ocrFoldIdentity(String value) => value
    .toLowerCase()
    .replaceAll('0', 'o')
    .replaceAll('1', 'i')
    .replaceAll('5', 's')
    .replaceAll('8', 'b');

double _editSimilarity(String left, String right) {
  if (left == right) return 1;
  if (left.isEmpty || right.isEmpty) return 0;
  final previous = List<int>.generate(right.length + 1, (index) => index);
  final current = List<int>.filled(right.length + 1, 0);
  for (var i = 1; i <= left.length; i++) {
    current[0] = i;
    for (var j = 1; j <= right.length; j++) {
      final cost = left.codeUnitAt(i - 1) == right.codeUnitAt(j - 1) ? 0 : 1;
      current[j] = min(
        min(current[j - 1] + 1, previous[j] + 1),
        previous[j - 1] + cost,
      );
    }
    for (var j = 0; j <= right.length; j++) {
      previous[j] = current[j];
    }
  }
  final distance = previous[right.length];
  return (1 - distance / max(left.length, right.length)).clamp(0, 1).toDouble();
}
