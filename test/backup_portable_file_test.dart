import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/domain/backup.dart';
import '../lib/domain/medicine.dart';
import '../lib/domain/supplier.dart';
import '../lib/domain/tracking.dart';
import '../lib/services/backup_file_codec.dart';
import 'domain_contract.dart';

String _hex(List<int> bytes) =>
    bytes.map((value) => value.toRadixString(16).padLeft(2, '0')).join();

List<int> _advanceDigest(List<int> current, List<int> bytes) {
  final merged = Uint8List(current.length + bytes.length)
    ..setRange(0, current.length, current)
    ..setRange(current.length, current.length + bytes.length, bytes);
  return sha256.convert(merged).bytes;
}

Future<void> _rewritePortableSchema(
  File file,
  String schema, {
  required bool suppliersSupported,
}) async {
  final source = await file.readAsLines();
  final protectedLines = <String>[];
  for (var index = 0; index < source.length - 1; index++) {
    final row = Map<String, dynamic>.from(jsonDecode(source[index]) as Map);
    if (index == 0) {
      row['schema'] = schema;
      if (!suppliersSupported) row.remove('supplierCount');
    }
    if (!suppliersSupported && row['type'] == 'supplier') continue;
    protectedLines.add(jsonEncode(row));
  }

  final footer = Map<String, dynamic>.from(jsonDecode(source.last) as Map);
  if (!suppliersSupported) footer.remove('supplierCount');
  var chain = sha256.convert(utf8.encode('$schema\n')).bytes;
  for (final line in protectedLines) {
    chain = _advanceDigest(chain, utf8.encode('$line\n'));
  }
  footer['integrity'] = '$portableBackupIntegrityPrefix${_hex(chain)}';
  await file.writeAsString(
    '${[...protectedLines, jsonEncode(footer)].join('\n')}\n',
    flush: true,
  );
}

PharmacyBackup _portableBackup() {
  final first = stock(
    'portable-a',
    name: 'Paracetamol',
    strength: '500mg',
    quantity: 250,
  );
  final second = Medicine.fromJson({
    ...stock(
      'portable-b',
      name: 'Cetirizine',
      strength: '10mg',
      quantity: 40,
    ).toJson(),
    'archived': true,
    'archivedAt': '2026-09-18T10:00:00Z',
    'archiveReason': 'Damaged pack',
  });
  final sale = SaleEvent(
    id: 'portable-sale',
    stockId: first.id,
    medicineName: first.name,
    strength: first.strength,
    form: first.form,
    salt: first.salt,
    quantity: 3,
    occurredAt: contractToday,
    totalAmountPaise: 900,
    savedUnitPricePaise: first.unitPricePaise,
  );
  return PharmacyBackup(
    createdAt: DateTime.utc(2026, 9, 19, 12, 30),
    sourceRevision: 22,
    settings: contractSettings,
    records: <String, Medicine>{
      first.id: first,
      second.id: second,
    },
    suppliers: const {},
    sales: <String, SaleEvent>{sale.id: sale},
    soldValue: 900,
    unknownSold: 0,
  );
}

void main() {
  test('portable txt backup round-trips without one giant JSON envelope', () async {
    final directory = await Directory.systemTemp.createTemp('aaris_backup_test_');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/Aaris_Pharmacy_Full_Backup.txt');

    final written = await PortableBackupCodec.write(file, _portableBackup());
    expect(written, greaterThan(0));

    final lines = await file.readAsLines();
    expect(lines.length, 5);
    expect(PortableBackupCodec.isPortableHeader(lines.first), isTrue);
    expect(lines.first, contains(pharmacyPortableBackupSchema));
    expect(lines.last, contains(portableBackupIntegrityPrefix));

    final parsed = await PortableBackupCodec.read(file);
    expect(parsed.sourceRevision, 22);
    expect(parsed.records.length, 2);
    expect(parsed.records['portable-b']!.archived, isTrue);
    expect(parsed.sales.values.single.quantity, 3);
    expect(parsed.integrityVerified, isTrue);
  });

  test('portable txt integrity rejects an edited medicine line', () async {
    final directory = await Directory.systemTemp.createTemp('aaris_backup_tamper_');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/backup.txt');
    await PortableBackupCodec.write(file, _portableBackup());

    final lines = await file.readAsLines();
    lines[1] = lines[1].replaceFirst('"quantity":250', '"quantity":249');
    await file.writeAsString('${lines.join('\n')}\n', flush: true);

    expect(
      PortableBackupCodec.read(file),
      throwsA(isA<FormatException>()),
    );
  });
  test('portable v5 streams supplier before its linked medicine', () async {
    const supplier = Supplier(
      id: 'supplier-portable',
      name: 'XYZ Distributor',
      returnBeforeExpiryDays: 30,
      drugLicenceNo: 'DL-PORTABLE',
    );
    final productKey = medicineIdentity('Paracetamol', '500mg', 'Tablet');
    final medicine = Medicine.fromJson({
      ...stock(
        'portable-linked',
        name: 'Paracetamol',
        strength: '500mg',
        expiry: '2026-11-03',
      ).toJson(),
      'supplierId': supplier.id,
      'batchNumber': 'PORT-1',
      'intakeHistory': <Map<String, dynamic>>[
        <String, dynamic>{
          'productKey': productKey,
          'supplierId': supplier.id,
          'quantity': 25,
          'receivedAt': '2026-09-01T09:00:00Z',
          'expiry': '2026-11-03',
          'source': 'receive',
          'unitCostPaise': 200,
          'batchNumber': 'PORT-1',
        },
      ],
    });
    final backup = PharmacyBackup(
      createdAt: contractToday,
      sourceRevision: 30,
      settings: contractSettings,
      records: <String, Medicine>{medicine.id: medicine},
      suppliers: <String, Supplier>{supplier.id: supplier},
      sales: const <String, SaleEvent>{},
      soldValue: 0,
      unknownSold: 0,
    );

    final directory =
        await Directory.systemTemp.createTemp('aaris_supplier_portable_');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/supplier.txt');
    await PortableBackupCodec.write(file, backup);

    final lines = await file.readAsLines();
    expect(lines[1], contains('"type":"supplier"'));
    expect(lines[2], contains('"type":"medicine"'));

    final parsed = await PortableBackupCodec.read(file);
    expect(parsed.suppliers[supplier.id]!.name, supplier.name);
    expect(parsed.records[medicine.id]!.supplierId, supplier.id);
    expect(parsed.records[medicine.id]!.intakeHistory, hasLength(1));
    expect(
      parsed.records[medicine.id]!.intakeHistory.single.batchNumber,
      'PORT-1',
    );
  });

  test('previous portable v4 with supplier rows remains importable', () async {
    const supplier = Supplier(
      id: 'supplier-v4',
      name: 'Legacy V4 Supplier',
      returnBeforeExpiryDays: 30,
    );
    final medicine = Medicine.fromJson({
      ...stock('portable-v4', expiry: '2027-01-31').toJson(),
      'supplierId': supplier.id,
    });
    final backup = PharmacyBackup(
      createdAt: contractToday,
      sourceRevision: 31,
      settings: contractSettings,
      records: <String, Medicine>{medicine.id: medicine},
      suppliers: <String, Supplier>{supplier.id: supplier},
      sales: const <String, SaleEvent>{},
      soldValue: 0,
      unknownSold: 0,
    );
    final directory = await Directory.systemTemp.createTemp('aaris_v4_portable_');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/v4.txt');
    await PortableBackupCodec.write(file, backup);
    await _rewritePortableSchema(
      file,
      previousPortableBackupSchema,
      suppliersSupported: true,
    );

    expect(
      PortableBackupCodec.isPortableHeader((await file.readAsLines()).first),
      isTrue,
    );
    final parsed = await PortableBackupCodec.read(file);
    expect(parsed.suppliers[supplier.id]!.name, supplier.name);
    expect(parsed.records[medicine.id]!.supplierId, supplier.id);
  });

  test('older portable v3 without supplier rows remains importable', () async {
    final directory = await Directory.systemTemp.createTemp('aaris_v3_portable_');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/v3.txt');
    await PortableBackupCodec.write(file, _portableBackup());
    await _rewritePortableSchema(
      file,
      olderPortableBackupSchema,
      suppliersSupported: false,
    );

    expect(
      PortableBackupCodec.isPortableHeader((await file.readAsLines()).first),
      isTrue,
    );
    final parsed = await PortableBackupCodec.read(file);
    expect(parsed.records.length, 2);
    expect(parsed.suppliers, isEmpty);
    expect(parsed.sales.values.single.quantity, 3);
  });
}
