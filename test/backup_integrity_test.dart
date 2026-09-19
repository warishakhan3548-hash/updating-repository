import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'package:flutter_test/flutter_test.dart';

import '../lib/domain/backup.dart';
import '../lib/domain/medicine.dart';
import '../lib/domain/supplier.dart';
import '../lib/domain/tracking.dart';
import 'domain_contract.dart';

PharmacyBackup _backup() {
  final medicine = stock(
    'stock-a',
    name: 'Dolo',
    strength: '650mg',
    notes: 'Rack A',
    quantity: 10,
  );
  final sale = SaleEvent(
    id: 'sale-a',
    stockId: medicine.id,
    medicineName: medicine.name,
    strength: medicine.strength,
    form: medicine.form,
    salt: medicine.salt,
    quantity: 2,
    occurredAt: contractToday,
    totalAmountPaise: 1200,
    savedUnitPricePaise: medicine.unitPricePaise,
  );
  return PharmacyBackup(
    createdAt: DateTime.utc(2026, 9, 12, 18, 30),
    sourceRevision: 7,
    settings: contractSettings,
    records: {medicine.id: medicine},
    suppliers: const {},
    sales: {sale.id: sale},
    soldValue: 1200,
    unknownSold: 0,
  );
}

void main() {
  test('v3 backup round-trips with a deterministic SHA-256 integrity proof', () {
    final encoded = _backup().encode();
    final envelope = jsonDecode(encoded) as Map<String, dynamic>;

    expect(envelope['schema'], pharmacyBackupSchema);
    expect(
      envelope['integrity'],
      matches(RegExp(r'^sha256:[a-f0-9]{64}$')),
    );

    final parsed = PharmacyBackup.parse(encoded);
    expect(parsed.sourceRevision, 7);
    expect(parsed.records.values.single.name, 'Dolo');
    expect(parsed.sales.values.single.quantity, 2);
    expect(parsed.soldValue, 1200);
    expect(parsed.integrityVerified, isTrue);
    expect(parsed.legacyFormat, isFalse);
  });

  test('v3 backup seals supplier profiles and exact stock links', () {
    const supplier = Supplier(
      id: 'supplier-backup',
      name: 'ABC Distributor',
      returnBeforeExpiryDays: 45,
      address: 'Panipat',
      drugLicenceNo: 'DL-123',
    );
    final linked = Medicine.fromJson({
      ...stock('linked-stock', name: 'Amoxicillin', expiry: '2026-11-03').toJson(),
      'supplierId': supplier.id,
    });
    final backup = PharmacyBackup(
      createdAt: contractToday,
      sourceRevision: 11,
      settings: contractSettings,
      records: <String, Medicine>{linked.id: linked},
      suppliers: <String, Supplier>{supplier.id: supplier},
      sales: const <String, SaleEvent>{},
      soldValue: 0,
      unknownSold: 0,
    );

    final parsed = PharmacyBackup.parse(backup.encode());
    expect(parsed.suppliers[supplier.id]!.returnBeforeExpiryDays, 45);
    expect(parsed.records[linked.id]!.supplierId, supplier.id);
    expect(parsed.integrityVerified, isTrue);
  });

  test('valid-looking fact edits are rejected when integrity no longer matches', () {
    final encoded = _backup().encode();
    final tampered = encoded.replaceFirst('"quantity": 10', '"quantity": 9');

    expect(tampered, isNot(encoded));
    expect(() => PharmacyBackup.parse(tampered), throwsFormatException);
  });

  test('previous v2 sealed backups remain importable', () {
    final current = jsonDecode(_backup().encode()) as Map<String, dynamic>;
    current['schema'] = previousPharmacyBackupSchema;
    current.remove('suppliers');
    for (final raw in current['medicines'] as List<dynamic>) {
      (raw as Map<String, dynamic>).remove('supplierId');
    }

    final payload = <String, dynamic>{
      'createdAt': current['createdAt'],
      'sourceRevision': current['sourceRevision'],
      'settings': current['settings'],
      'medicines': current['medicines'],
      'sales': current['sales'],
      'soldValue': current['soldValue'],
      'unknownSold': current['unknownSold'],
    };
    current['integrity'] =
        'sha256:${sha256.convert(utf8.encode(jsonEncode(payload)))}';

    final parsed = PharmacyBackup.parse(jsonEncode(current));
    expect(parsed.suppliers, isEmpty);
    expect(parsed.integrityVerified, isTrue);
  });

  test('legacy v1 backups remain importable and are marked unsealed', () {
    final legacy = jsonDecode(_backup().encode()) as Map<String, dynamic>;
    legacy['schema'] = legacyPharmacyBackupSchema;
    legacy.remove('integrity');
    legacy.remove('suppliers');

    final parsed = PharmacyBackup.parse(jsonEncode(legacy));
    expect(parsed.records.values.single.id, 'stock-a');
    expect(parsed.sales.values.single.id, 'sale-a');
    expect(parsed.integrityVerified, isFalse);
    expect(parsed.legacyFormat, isTrue);
  });

  test('JSON field reordering does not break canonical integrity verification', () {
    final envelope = jsonDecode(_backup().encode()) as Map<String, dynamic>;
    final rawMedicine = Map<String, dynamic>.from(
      (envelope['medicines'] as List).single as Map,
    );
    envelope['medicines'] = [
      Map<String, dynamic>.fromEntries(
        rawMedicine.entries.toList().reversed,
      ),
    ];

    final parsed = PharmacyBackup.parse(jsonEncode(envelope));
    expect(parsed.records.values.single.name, 'Dolo');
  });

  test('restore impact explains stock, sale and settings consequences', () {
    final incomingBase = stock(
      'stock-a',
      name: 'Dolo',
      strength: '650mg',
      notes: 'Rack A',
      quantity: 10,
    );
    final incomingReactivated = stock(
      'restore-me',
      name: 'Cefixime',
      strength: '200mg',
    );
    final incomingNew = stock('new-stock', name: 'Azithromycin');
    final incomingChangedSale = SaleEvent(
      id: 'sale-a',
      stockId: incomingBase.id,
      medicineName: incomingBase.name,
      strength: incomingBase.strength,
      form: incomingBase.form,
      quantity: 2,
      occurredAt: contractToday,
    );
    final incomingNewSale = SaleEvent(
      id: 'sale-new',
      stockId: incomingNew.id,
      medicineName: incomingNew.name,
      strength: incomingNew.strength,
      form: incomingNew.form,
      quantity: 1,
      occurredAt: contractToday,
    );
    final incoming = PharmacyBackup(
      createdAt: contractToday,
      sourceRevision: 9,
      settings: const WarningSettings(shortDays: 5, months: 3),
      records: {
        incomingBase.id: incomingBase,
        incomingReactivated.id: incomingReactivated,
        incomingNew.id: incomingNew,
      },
      suppliers: const {},
      sales: {
        incomingChangedSale.id: incomingChangedSale,
        incomingNewSale.id: incomingNewSale,
      },
      soldValue: 5000,
      unknownSold: 1,
    );

    final archived = Medicine.fromJson({
      ...incomingReactivated.toJson(),
      'archived': true,
      'archivedAt': '2026-09-10T10:00:00Z',
      'archiveReason': 'Correction',
    });
    final currentSameId = Medicine.fromJson({
      ...incomingBase.toJson(),
      'notes': 'Rack B',
      'revision': incomingBase.revision + 4,
    });
    final currentOnly = stock('current-only', name: 'Pantoprazole');
    final currentChangedSale = SaleEvent(
      id: 'sale-a',
      stockId: incomingBase.id,
      medicineName: incomingBase.name,
      strength: incomingBase.strength,
      form: incomingBase.form,
      quantity: 1,
      occurredAt: contractToday,
    );
    final currentOnlySale = SaleEvent(
      id: 'sale-old',
      stockId: currentOnly.id,
      medicineName: currentOnly.name,
      strength: currentOnly.strength,
      form: currentOnly.form,
      quantity: 1,
      occurredAt: contractToday,
    );

    final impact = BackupImpact.compare(
      backup: incoming,
      currentRecords: {
        currentSameId.id: currentSameId,
        archived.id: archived,
        currentOnly.id: currentOnly,
      },
      currentSuppliers: const {},
      currentSales: {
        currentChangedSale.id: currentChangedSale,
        currentOnlySale.id: currentOnlySale,
      },
      currentSettings: contractSettings,
      currentSoldValue: 0,
      currentUnknownSold: 0,
    );

    expect(impact.newStockEntries, 1);
    expect(impact.changedStockEntries, 2);
    expect(impact.reactivatedStockEntries, 1);
    expect(impact.activeEntriesMovingToRemoved, 1);
    expect(impact.newSaleEvents, 1);
    expect(impact.changedSaleEvents, 1);
    expect(impact.removedSaleEvents, 1);
    expect(impact.warningSettingsChange, isTrue);
    expect(impact.soldTotalsChange, isTrue);
    expect(impact.hasMaterialChange, isTrue);
  });

  test('restore impact ignores record revision churn when facts are identical', () {
    final incoming = _backup();
    final current = Medicine.fromJson({
      ...incoming.records.values.single.toJson(),
      'revision': incoming.records.values.single.revision + 50,
    });
    final impact = BackupImpact.compare(
      backup: incoming,
      currentRecords: {current.id: current},
      currentSuppliers: const {},
      currentSales: incoming.sales,
      currentSettings: incoming.settings,
      currentSoldValue: incoming.soldValue,
      currentUnknownSold: incoming.unknownSold,
    );

    expect(impact.changedStockEntries, 0);
    expect(impact.hasMaterialChange, isFalse);
  });
  test('cooperative large-backup impact matches the synchronous contract', () async {
    final incoming = _backup();
    final current = Medicine.fromJson({
      ...incoming.records.values.single.toJson(),
      'notes': 'Different rack',
    });

    final synchronous = BackupImpact.compare(
      backup: incoming,
      currentRecords: {current.id: current},
      currentSuppliers: const {},
      currentSales: incoming.sales,
      currentSettings: incoming.settings,
      currentSoldValue: incoming.soldValue,
      currentUnknownSold: incoming.unknownSold,
    );
    final cooperative = await compareBackupImpactCooperatively(
      backup: incoming,
      currentRecords: {current.id: current},
      currentSuppliers: const {},
      currentSales: incoming.sales,
      currentSettings: incoming.settings,
      currentSoldValue: incoming.soldValue,
      currentUnknownSold: incoming.unknownSold,
    );

    expect(cooperative.changedStockEntries, synchronous.changedStockEntries);
    expect(cooperative.newStockEntries, synchronous.newStockEntries);
    expect(cooperative.removedSaleEvents, synchronous.removedSaleEvents);
    expect(cooperative.hasMaterialChange, synchronous.hasMaterialChange);
  });

}
