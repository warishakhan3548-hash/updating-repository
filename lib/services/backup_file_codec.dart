import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../domain/backup.dart';
import '../domain/medicine.dart';
import '../domain/supplier.dart';
import '../domain/tracking.dart';

const pharmacyPortableBackupSchema = 'aaris.pharmacy.portable.v5';
const previousPortableBackupSchema = 'aaris.pharmacy.portable.v4';
const olderPortableBackupSchema = 'aaris.pharmacy.portable.v3';
const portableBackupIntegrityPrefix = 'sha256-chain:';
const maxPortableBackupBytes = 1024 * 1024 * 1024;
const maxPortableBackupLineBytes = 8 * 1024 * 1024;
const maxPortableMedicineRecords = 100000;
const maxPortableSupplierRecords = 10000;
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
          (decoded['schema'] == pharmacyPortableBackupSchema ||
              decoded['schema'] == previousPortableBackupSchema ||
              decoded['schema'] == olderPortableBackupSchema);
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
    if (backup.suppliers.length > maxPortableSupplierRecords) {
      throw const FormatException(
        'This backup has too many suppliers for one portable file.',
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
    var chain = _digestSeed(pharmacyPortableBackupSchema);
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
        'supplierCount': backup.suppliers.length,
        'saleCount': backup.sales.length,
      });

      for (final supplier in backup.suppliers.values) {
        await addProtected(<String, dynamic>{
          'type': 'supplier',
          'value': supplier.toJson(),
        });
      }

      for (final record in backup.records.values) {
        await addProtected(<String, dynamic>{
          'type': 'medicine',
          'value': record.toJson(),
        });
      }

      for (final sale in backup.sales.values) {
        await addProtected(<String, dynamic>{
          'type': 'sale',
          'value': sale.toJson(),
        });
      }

      final footer = jsonEncode(<String, dynamic>{
        'type': 'end',
        'integrity': '$portableBackupIntegrityPrefix${_hex(chain)}',
        'medicineCount': backup.records.length,
        'supplierCount': backup.suppliers.length,
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
    int? expectedSuppliers;
    int? expectedSales;
    String? portableSchema;

    final records = <String, Medicine>{};
    final suppliers = <String, Supplier>{};
    final sales = <String, SaleEvent>{};
    List<int>? chain;
    var lineNumber = 0;
    var footerSeen = false;
    var medicinePhase = false;
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
        portableSchema = row['schema'] is String ? row['schema'] as String : null;
        if (type != 'header' ||
            (portableSchema != pharmacyPortableBackupSchema &&
                portableSchema != previousPortableBackupSchema &&
                portableSchema != olderPortableBackupSchema)) {
          throw const FormatException(
            'This is not a supported Aaris Pharmacy portable backup.',
          );
        }
        final hasSuppliers =
            portableSchema == pharmacyPortableBackupSchema ||
            portableSchema == previousPortableBackupSchema;
        final allowed = <String>{
          'type',
          'schema',
          'createdAt',
          'sourceRevision',
          'settings',
          'soldValue',
          'unknownSold',
          'medicineCount',
          if (hasSuppliers) 'supplierCount',
          'saleCount',
        };
        if (row.keys.any((key) => !allowed.contains(key))) {
          throw const FormatException('Backup header contains an unsupported field.');
        }

        final createdRaw = row['createdAt'];
        createdAt = createdRaw is String ? DateTime.tryParse(createdRaw) : null;
        final revisionRaw = row['sourceRevision'];
        final soldValueRaw = row['soldValue'];
        final unknownSoldRaw = row['unknownSold'];
        final medicineCountRaw = row['medicineCount'];
        final supplierCountRaw = hasSuppliers ? row['supplierCount'] : 0;
        final saleCountRaw = row['saleCount'];
        sourceRevision = revisionRaw is int ? revisionRaw : null;
        soldValue = soldValueRaw is int ? soldValueRaw : null;
        unknownSold = unknownSoldRaw is int ? unknownSoldRaw : null;
        expectedMedicines = medicineCountRaw is int ? medicineCountRaw : null;
        expectedSuppliers = supplierCountRaw is int ? supplierCountRaw : null;
        expectedSales = saleCountRaw is int ? saleCountRaw : null;
        final settingsRaw = row['settings'];

        if (createdAt == null ||
            createdAt.year < 2000 ||
            createdAt.year > 2200 ||
            sourceRevision == null ||
            sourceRevision < 0 ||
            soldValue == null ||
            soldValue < 0 ||
            soldValue > maxExactPaise ||
            unknownSold == null ||
            unknownSold < 0 ||
            expectedMedicines == null ||
            expectedMedicines < 0 ||
            expectedMedicines > maxPortableMedicineRecords ||
            expectedSuppliers == null ||
            expectedSuppliers < 0 ||
            expectedSuppliers > maxPortableSupplierRecords ||
            expectedSales == null ||
            expectedSales < 0 ||
            expectedSales > maxPortableSaleRecords ||
            settingsRaw is! Map) {
          throw const FormatException('Backup header metadata is invalid.');
        }
        settings = WarningSettings.fromJson(
          Map<String, dynamic>.from(settingsRaw),
        );
        chain = _advanceDigest(
          _digestSeed(portableSchema!),
          lineBytes,
        );
        continue;
      }

      if (footerSeen) {
        throw const FormatException('The backup contains data after its integrity footer.');
      }

      if (type == 'end') {
        final hasSuppliers =
            portableSchema == pharmacyPortableBackupSchema ||
            portableSchema == previousPortableBackupSchema;
        final allowed = <String>{
          'type',
          'integrity',
          'medicineCount',
          if (hasSuppliers) 'supplierCount',
          'saleCount',
        };
        if (row.keys.any((key) => !allowed.contains(key))) {
          throw const FormatException('Backup footer contains an unsupported field.');
        }
        final integrity = row['integrity'];
        final footerMedicines = row['medicineCount'];
        final footerSuppliers = hasSuppliers ? row['supplierCount'] : 0;
        final footerSales = row['saleCount'];
        final expectedIntegrity =
            '$portableBackupIntegrityPrefix${_hex(chain!)}';
        if (integrity is! String ||
            !RegExp(r'^sha256-chain:[a-f0-9]{64}$').hasMatch(integrity) ||
            integrity != expectedIntegrity) {
          throw const FormatException(
            'Backup integrity check failed. The file is incomplete or has changed.',
          );
        }
        if (footerMedicines != expectedMedicines ||
            footerSuppliers != expectedSuppliers ||
            footerSales != expectedSales ||
            records.length != expectedMedicines ||
            suppliers.length != expectedSuppliers ||
            sales.length != expectedSales) {
          throw const FormatException(
            'Backup record counts do not match the verified file footer.',
          );
        }
        footerSeen = true;
        continue;
      }

      chain = _advanceDigest(chain!, lineBytes);
      if (type == 'supplier') {
        if (portableSchema != pharmacyPortableBackupSchema &&
            portableSchema != previousPortableBackupSchema) {
          throw const FormatException(
            'Legacy portable backups cannot contain supplier rows.',
          );
        }
        if (medicinePhase || salePhase) {
          throw const FormatException(
            'Supplier rows must appear before medicine and sale rows.',
          );
        }
        if (row.keys.any((key) => key != 'type' && key != 'value')) {
          throw FormatException(
            'Supplier line $lineNumber has an unsupported field.',
          );
        }
        final raw = row['value'];
        if (raw is! Map) {
          throw FormatException('Supplier line $lineNumber is invalid.');
        }
        if (raw.keys.any((key) => !Supplier.storedFields.contains(key))) {
          throw FormatException(
            'Supplier line $lineNumber contains an unsupported supplier field.',
          );
        }
        final supplier = Supplier.fromJson(Map<String, dynamic>.from(raw));
        if (suppliers.containsKey(supplier.id)) {
          throw FormatException(
            'Supplier line $lineNumber repeats an existing ID.',
          );
        }
        suppliers[supplier.id] = supplier;
        if (suppliers.length > (expectedSuppliers ?? 0)) {
          throw const FormatException(
            'Backup contains more suppliers than declared.',
          );
        }
        if (lineNumber % 256 == 0) {
          await Future<void>.delayed(Duration.zero);
        }
        continue;
      }

      if (type == 'medicine') {
        medicinePhase = true;
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
        if (medicine.supplierId.isNotEmpty &&
            !suppliers.containsKey(medicine.supplierId)) {
          throw FormatException(
            'Medicine line $lineNumber points to a missing supplier.',
          );
        }
        records[medicine.id] = medicine;
        if (records.length > (expectedMedicines ?? 0)) {
          throw const FormatException('Backup contains more medicines than declared.');
        }
        if (lineNumber % 256 == 0) {
          await Future<void>.delayed(Duration.zero);
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
        if (lineNumber % 256 == 0) {
          await Future<void>.delayed(Duration.zero);
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
      suppliers: Map.unmodifiable(suppliers),
      sales: Map.unmodifiable(sales),
      soldValue: soldValue!,
      unknownSold: unknownSold!,
      integrityStatus: BackupIntegrityStatus.verified,
    );
  }

  static List<int> _digestSeed(String schema) =>
      sha256.convert(utf8.encode('$schema\n')).bytes;

  static List<int> _advanceDigest(List<int> current, List<int> bytes) {
    final merged = Uint8List(current.length + bytes.length)
      ..setRange(0, current.length, current)
      ..setRange(current.length, current.length + bytes.length, bytes);
    return sha256.convert(merged).bytes;
  }

  static String _hex(List<int> bytes) =>
      bytes.map((value) => value.toRadixString(16).padLeft(2, '0')).join();
}
