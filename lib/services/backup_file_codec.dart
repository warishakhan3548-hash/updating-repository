import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../domain/backup.dart';
import '../domain/medicine.dart';
import '../domain/tracking.dart';

const pharmacyPortableBackupSchema = 'aaris.pharmacy.portable.v3';
const portableBackupIntegrityPrefix = 'sha256-chain:';
const maxPortableBackupBytes = 1024 * 1024 * 1024;
const maxPortableBackupLineBytes = 8 * 1024 * 1024;
const maxPortableMedicineRecords = 100000;
const maxPortableSaleRecords = 500000;

class PortableBackupCodec {
  const PortableBackupCodec._();

  static bool isPortableHeader(String rawLine) {
    final line = rawLine.trim().replaceFirst('\uFEFF', '');
    if (line.isEmpty || !line.startsWith('{')) return false;
    try {
      final decoded = jsonDecode(line);
      return decoded is Map &&
          decoded['type'] == 'header' &&
          decoded['schema'] == pharmacyPortableBackupSchema;
    } catch (_) {
      return false;
    }
  }

  static Future<int> write(File target, PharmacyBackup backup) async {
    if (backup.records.length > maxPortableMedicineRecords) {
      throw const FormatException(
        'This backup has too many medicine rows for one portable file.',
      );
    }
    if (backup.sales.length > maxPortableSaleRecords) {
      throw const FormatException(
        'This backup has too many sale rows for one portable file.',
      );
    }

    await target.parent.create(recursive: true);
    final partial = File('${target.path}.partial');
    if (await partial.exists()) await partial.delete();

    final sink = partial.openWrite(mode: FileMode.writeOnly);
    var closed = false;
    var chain = _digestSeed();
    var protectedRows = 0;

    Future<void> addProtected(Map<String, dynamic> value) async {
      final line = jsonEncode(value);
      final bytes = utf8.encode('$line\n');
      if (bytes.length > maxPortableBackupLineBytes) {
        throw const FormatException(
          'One backup record is unexpectedly large. Shorten oversized notes or OCR text before exporting.',
        );
      }
      chain = _advanceDigest(chain, bytes);
      sink.add(bytes);
      protectedRows++;
      if (protectedRows % 256 == 0) {
        await sink.flush();
        await Future<void>.delayed(Duration.zero);
      }
    }

    try {
      await addProtected(<String, dynamic>{
        'type': 'header',
        'schema': pharmacyPortableBackupSchema,
        'createdAt': backup.createdAt.toIso8601String(),
        'sourceRevision': backup.sourceRevision,
        'settings': backup.settings.toJson(),
        'soldValue': backup.soldValue,
        'unknownSold': backup.unknownSold,
        'medicineCount': backup.records.length,
        'saleCount': backup.sales.length,
      });

      final medicineIds = backup.records.keys.toList(growable: false)..sort();
      for (final id in medicineIds) {
        await addProtected(<String, dynamic>{
          'type': 'medicine',
          'value': backup.records[id]!.toJson(),
        });
      }

      final saleIds = backup.sales.keys.toList(growable: false)..sort();
      for (final id in saleIds) {
        await addProtected(<String, dynamic>{
          'type': 'sale',
          'value': backup.sales[id]!.toJson(),
        });
      }

      final footer = jsonEncode(<String, dynamic>{
        'type': 'end',
        'integrity': '$portableBackupIntegrityPrefix${_hex(chain)}',
        'medicineCount': backup.records.length,
        'saleCount': backup.sales.length,
      });
      sink.add(utf8.encode('$footer\n'));
      await sink.flush();
      await sink.close();
      closed = true;

      final length = await partial.length();
      if (length <= 0 || length > maxPortableBackupBytes) {
        throw const FormatException(
          'The generated backup file is outside the supported portable size.',
        );
      }
      if (await target.exists()) await target.delete();
      await partial.rename(target.path);
      return length;
    } catch (_) {
      if (!closed) {
        try {
          await sink.close();
        } catch (_) {}
      }
      if (await partial.exists()) {
        try {
          await partial.delete();
        } catch (_) {}
      }
      rethrow;
    }
  }

  static Future<PharmacyBackup> read(File file) async {
    if (!await file.exists()) {
      throw const FormatException('The selected backup file is no longer available.');
    }
    final length = await file.length();
    if (length <= 0) {
      throw const FormatException('The selected backup file is empty.');
    }
    if (length > maxPortableBackupBytes) {
      throw const FormatException(
        'This backup file is larger than the supported 1 GB portable limit.',
      );
    }

    DateTime? createdAt;
    WarningSettings? settings;
    int? sourceRevision;
    int? soldValue;
    int? unknownSold;
    int? expectedMedicines;
    int? expectedSales;

    final records = <String, Medicine>{};
    final sales = <String, SaleEvent>{};
    var chain = _digestSeed();
    var lineNumber = 0;
    var footerSeen = false;
    var salePhase = false;

    await for (var rawLine in file
        .openRead()
        .transform(utf8.decoder)
        .transform(const LineSplitter())) {
      lineNumber++;
      if (lineNumber == 1) rawLine = rawLine.replaceFirst('\uFEFF', '');
      if (rawLine.trim().isEmpty) {
        throw FormatException('Backup line $lineNumber is empty.');
      }
      final lineBytes = utf8.encode('$rawLine\n');
      if (lineBytes.length > maxPortableBackupLineBytes) {
        throw FormatException('Backup line $lineNumber is unexpectedly large.');
      }

      final decoded = jsonDecode(rawLine);
      if (decoded is! Map) {
        throw FormatException('Backup line $lineNumber is invalid.');
      }
      final row = Map<String, dynamic>.from(decoded);
      final type = row['type'];

      if (lineNumber == 1) {
        if (type != 'header' || row['schema'] != pharmacyPortableBackupSchema) {
          throw const FormatException(
            'This is not a current Aaris Pharmacy portable backup.',
          );
        }
        const allowed = <String>{
          'type',
          'schema',
          'createdAt',
          'sourceRevision',
          'settings',
          'soldValue',
          'unknownSold',
          'medicineCount',
          'saleCount',
        };
        if (row.keys.any((key) => !allowed.contains(key))) {
          throw const FormatException('Backup header contains an unsupported field.');
        }

        final createdRaw = row['createdAt'];
        createdAt = createdRaw is String ? DateTime.tryParse(createdRaw) : null;
        sourceRevision = row['sourceRevision'] as int?;
        soldValue = row['soldValue'] as int?;
        unknownSold = row['unknownSold'] as int?;
        expectedMedicines = row['medicineCount'] as int?;
        expectedSales = row['saleCount'] as int?;
        final settingsRaw = row['settings'];

        if (createdAt == null ||
            createdAt!.year < 2000 ||
            createdAt!.year > 2200 ||
            sourceRevision == null ||
            sourceRevision! < 0 ||
            soldValue == null ||
            soldValue! < 0 ||
            soldValue! > maxExactPaise ||
            unknownSold == null ||
            unknownSold! < 0 ||
            expectedMedicines == null ||
            expectedMedicines! < 0 ||
            expectedMedicines! > maxPortableMedicineRecords ||
            expectedSales == null ||
            expectedSales! < 0 ||
            expectedSales! > maxPortableSaleRecords ||
            settingsRaw is! Map) {
          throw const FormatException('Backup header metadata is invalid.');
        }
        settings = WarningSettings.fromJson(
          Map<String, dynamic>.from(settingsRaw),
        );
        chain = _advanceDigest(chain, lineBytes);
        continue;
      }

      if (footerSeen) {
        throw const FormatException('The backup contains data after its integrity footer.');
      }

      if (type == 'end') {
        const allowed = <String>{
          'type',
          'integrity',
          'medicineCount',
          'saleCount',
        };
        if (row.keys.any((key) => !allowed.contains(key))) {
          throw const FormatException('Backup footer contains an unsupported field.');
        }
        final integrity = row['integrity'];
        final footerMedicines = row['medicineCount'];
        final footerSales = row['saleCount'];
        final expectedIntegrity =
            '$portableBackupIntegrityPrefix${_hex(chain)}';
        if (integrity is! String ||
            !RegExp(r'^sha256-chain:[a-f0-9]{64}$').hasMatch(integrity) ||
            integrity != expectedIntegrity) {
          throw const FormatException(
            'Backup integrity check failed. The file is incomplete or has changed.',
          );
        }
        if (footerMedicines != expectedMedicines ||
            footerSales != expectedSales ||
            records.length != expectedMedicines ||
            sales.length != expectedSales) {
          throw const FormatException(
            'Backup record counts do not match the verified file footer.',
          );
        }
        footerSeen = true;
        continue;
      }

      chain = _advanceDigest(chain, lineBytes);
      if (type == 'medicine') {
        if (salePhase) {
          throw const FormatException(
            'Medicine rows cannot appear after sale rows in a portable backup.',
          );
        }
        if (row.keys.any((key) => key != 'type' && key != 'value')) {
          throw FormatException('Medicine line $lineNumber has an unsupported field.');
        }
        final raw = row['value'];
        if (raw is! Map) {
          throw FormatException('Medicine line $lineNumber is invalid.');
        }
        if (raw.keys.any((key) => !Medicine.storedFields.contains(key))) {
          throw FormatException(
            'Medicine line $lineNumber contains an unsupported medicine field.',
          );
        }
        final medicine = Medicine.fromJson(Map<String, dynamic>.from(raw));
        if (records.containsKey(medicine.id)) {
          throw FormatException('Medicine line $lineNumber repeats an existing ID.');
        }
        records[medicine.id] = medicine;
        if (records.length > (expectedMedicines ?? 0)) {
          throw const FormatException('Backup contains more medicines than declared.');
        }
        continue;
      }

      if (type == 'sale') {
        salePhase = true;
        if (row.keys.any((key) => key != 'type' && key != 'value')) {
          throw FormatException('Sale line $lineNumber has an unsupported field.');
        }
        final raw = row['value'];
        if (raw is! Map) {
          throw FormatException('Sale line $lineNumber is invalid.');
        }
        if (raw.keys.any((key) => !SaleEvent.storedFields.contains(key))) {
          throw FormatException(
            'Sale line $lineNumber contains an unsupported sale field.',
          );
        }
        final sale = SaleEvent.fromJson(Map<String, dynamic>.from(raw));
        if (sales.containsKey(sale.id)) {
          throw FormatException('Sale line $lineNumber repeats an existing ID.');
        }
        if (!records.containsKey(sale.stockId)) {
          throw FormatException(
            'Sale line $lineNumber points to a missing stock entry.',
          );
        }
        sales[sale.id] = sale;
        if (sales.length > (expectedSales ?? 0)) {
          throw const FormatException('Backup contains more sales than declared.');
        }
        continue;
      }

      throw FormatException('Backup line $lineNumber has an unknown record type.');
    }

    if (lineNumber < 2 || !footerSeen) {
      throw const FormatException('The backup file is incomplete.');
    }

    return PharmacyBackup(
      createdAt: createdAt!,
      sourceRevision: sourceRevision!,
      settings: settings!,
      records: Map.unmodifiable(records),
      sales: Map.unmodifiable(sales),
      soldValue: soldValue!,
      unknownSold: unknownSold!,
      integrityStatus: BackupIntegrityStatus.verified,
    );
  }

  static List<int> _digestSeed() =>
      sha256.convert(utf8.encode('$pharmacyPortableBackupSchema\n')).bytes;

  static List<int> _advanceDigest(List<int> current, List<int> bytes) {
    final merged = Uint8List(current.length + bytes.length)
      ..setRange(0, current.length, current)
      ..setRange(current.length, current.length + bytes.length, bytes);
    return sha256.convert(merged).bytes;
  }

  static String _hex(List<int> bytes) =>
      bytes.map((value) => value.toRadixString(16).padLeft(2, '0')).join();
}
