import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../lib/domain/backup.dart';
import '../lib/domain/medicine.dart';
import '../lib/domain/tracking.dart';
import '../lib/services/backup_file_codec.dart';
import 'domain_contract.dart';

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
}
