import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'medicine.dart';
import 'tracking.dart';

const pharmacyBackupSchema = 'aaris.pharmacy.backup.v2';
const legacyPharmacyBackupSchema = 'aaris.pharmacy.backup.v1';
const maxBackupCharacters = 64000000;
const _backupIntegrityPrefix = 'sha256:';

enum BackupIntegrityStatus { verified, legacyUnsealed }

class PharmacyBackup {
  const PharmacyBackup({
    required this.createdAt,
    required this.sourceRevision,
    required this.settings,
    required this.records,
    required this.sales,
    required this.soldValue,
    required this.unknownSold,
    this.integrityStatus = BackupIntegrityStatus.verified,
  });

  final DateTime createdAt;
  final int sourceRevision;
  final WarningSettings settings;
  final Map<String, Medicine> records;
  final Map<String, SaleEvent> sales;
  final int soldValue;
  final int unknownSold;

  /// Current-format exports are content-sealed with SHA-256. Legacy v1 files
  /// remain importable so a pharmacist is never locked out of an older local
  /// backup, but review surfaces that they predate the integrity proof.
  final BackupIntegrityStatus integrityStatus;
  bool get integrityVerified =>
      integrityStatus == BackupIntegrityStatus.verified;
  bool get legacyFormat =>
      integrityStatus == BackupIntegrityStatus.legacyUnsealed;

  Map<String, dynamic> _canonicalPayload() {
    final medicines = records.values.toList(growable: false)
      ..sort((a, b) => a.id.compareTo(b.id));
    final saleEvents = sales.values.toList(growable: false)
      ..sort((a, b) => a.id.compareTo(b.id));
    return <String, dynamic>{
      'createdAt': createdAt.toIso8601String(),
      'sourceRevision': sourceRevision,
      'settings': settings.toJson(),
      'medicines': medicines.map((record) => record.toJson()).toList(),
      'sales': saleEvents.map((sale) => sale.toJson()).toList(),
      'soldValue': soldValue,
      'unknownSold': unknownSold,
    };
  }

  String _integrityDigest(Map<String, dynamic> payload) => sha256
      .convert(utf8.encode(jsonEncode(payload)))
      .toString();

  /// Version 2 adds a deterministic SHA-256 integrity proof over validated,
  /// canonical pharmacy facts. This detects truncation/accidental edits before
  /// restore. It is deliberately not described as an authenticity signature:
  /// there is no secret key and legacy v1 files remain importable.
  String encode() {
    final payload = _canonicalPayload();
    final integrity = '$_backupIntegrityPrefix${_integrityDigest(payload)}';
    return const JsonEncoder.withIndent('  ').convert({
      'schema': pharmacyBackupSchema,
      'integrity': integrity,
      ...payload,
    });
  }

  String get fileName =>
      'Aaris_Pharmacy_Backup_${dateText(createdAt)}.aaris.json';

  factory PharmacyBackup.parse(String input) {
    var text = input.trim().replaceFirst('\uFEFF', '');
    if (text.length > maxBackupCharacters) {
      throw const FormatException(
        'Backup is too large. Split imports or use a newer full backup.',
      );
    }
    if (text.startsWith('```')) {
      final firstLine = text.indexOf('\n');
      final end = text.lastIndexOf('```');
      if (firstLine < 0 || end <= firstLine) {
        throw const FormatException('The backup code block is incomplete.');
      }
      text = text.substring(firstLine + 1, end).trim();
    }
    final decoded = jsonDecode(text);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Choose a complete Aaris Pharmacy backup.');
    }

    final schema = decoded['schema'];
    final current = schema == pharmacyBackupSchema;
    final legacy = schema == legacyPharmacyBackupSchema;
    if (!current && !legacy) {
      throw const FormatException(
        'This is not a supported Aaris Pharmacy backup.',
      );
    }
    const payloadFields = {
      'createdAt',
      'sourceRevision',
      'settings',
      'medicines',
      'sales',
      'soldValue',
      'unknownSold',
    };
    final allowed = <String>{
      'schema',
      ...payloadFields,
      if (current) 'integrity',
    };
    if (decoded.keys.any((key) => !allowed.contains(key))) {
      throw const FormatException(
        'This backup contains an unsupported field.',
      );
    }
    final integrity = decoded['integrity'];
    if (current &&
        (integrity is! String ||
            !RegExp(r'^sha256:[a-f0-9]{64}$').hasMatch(integrity))) {
      throw const FormatException(
        'Backup integrity proof is missing or invalid.',
      );
    }

    final createdRaw = decoded['createdAt'];
    final createdAt = createdRaw is String
        ? DateTime.tryParse(createdRaw)
        : null;
    final revision = decoded['sourceRevision'];
    final medicinesRaw = decoded['medicines'];
    final salesRaw = decoded['sales'];
    final soldValue = decoded['soldValue'];
    final unknownSold = decoded['unknownSold'];
    if (createdAt == null ||
        createdAt.year < 2000 ||
        createdAt.year > 2200 ||
        revision is! int ||
        revision < 0 ||
        medicinesRaw is! List ||
        medicinesRaw.length > 50000 ||
        salesRaw is! List ||
        salesRaw.length > 200000 ||
        soldValue is! int ||
        soldValue < 0 ||
        soldValue > maxExactPaise ||
        unknownSold is! int ||
        unknownSold < 0) {
      throw const FormatException('The backup metadata is invalid.');
    }
    final settingsRaw = decoded['settings'];
    if (settingsRaw is! Map) {
      throw const FormatException('Backup settings are missing.');
    }
    final parsedSettings = WarningSettings.fromJson(
      Map<String, dynamic>.from(settingsRaw),
    );
    final records = <String, Medicine>{};
    for (var index = 0; index < medicinesRaw.length; index++) {
      final raw = medicinesRaw[index];
      if (raw is! Map) {
        throw FormatException('Medicine ${index + 1} is invalid.');
      }
      if (raw.keys.any((key) => !Medicine.storedFields.contains(key))) {
        throw FormatException(
          'Medicine ${index + 1} contains an unsupported field.',
        );
      }
      final record = Medicine.fromJson(Map<String, dynamic>.from(raw));
      if (records.containsKey(record.id)) {
        throw FormatException('Medicine ${index + 1} repeats an existing ID.');
      }
      records[record.id] = record;
    }
    final sales = <String, SaleEvent>{};
    for (var index = 0; index < salesRaw.length; index++) {
      final raw = salesRaw[index];
      if (raw is! Map) {
        throw FormatException('Sale ${index + 1} is invalid.');
      }
      if (raw.keys.any((key) => !SaleEvent.storedFields.contains(key))) {
        throw FormatException(
          'Sale ${index + 1} contains an unsupported field.',
        );
      }
      final sale = SaleEvent.fromJson(Map<String, dynamic>.from(raw));
      if (sales.containsKey(sale.id)) {
        throw FormatException('Sale ${index + 1} repeats an existing ID.');
      }
      if (!records.containsKey(sale.stockId)) {
        throw FormatException(
          'Sale ${index + 1} points to a missing stock entry.',
        );
      }
      sales[sale.id] = sale;
    }

    final backup = PharmacyBackup(
      createdAt: createdAt,
      sourceRevision: revision,
      settings: parsedSettings,
      records: Map.unmodifiable(records),
      sales: Map.unmodifiable(sales),
      soldValue: soldValue,
      unknownSold: unknownSold,
      integrityStatus: current
          ? BackupIntegrityStatus.verified
          : BackupIntegrityStatus.legacyUnsealed,
    );
    if (current) {
      final payload = backup._canonicalPayload();
      final expected =
          '$_backupIntegrityPrefix${backup._integrityDigest(payload)}';
      if (integrity != expected) {
        throw const FormatException(
          'Backup integrity check failed. The file is incomplete or has changed.',
        );
      }
    }
    return backup;
  }
}

class BackupImpact {
  const BackupImpact({
    required this.newStockEntries,
    required this.changedStockEntries,
    required this.reactivatedStockEntries,
    required this.activeEntriesMovingToRemoved,
    required this.newSaleEvents,
    required this.changedSaleEvents,
    required this.removedSaleEvents,
    required this.warningSettingsChange,
    required this.soldTotalsChange,
  });

  const BackupImpact.none()
    : newStockEntries = 0,
      changedStockEntries = 0,
      reactivatedStockEntries = 0,
      activeEntriesMovingToRemoved = 0,
      newSaleEvents = 0,
      changedSaleEvents = 0,
      removedSaleEvents = 0,
      warningSettingsChange = false,
      soldTotalsChange = false;

  factory BackupImpact.compare({
    required PharmacyBackup backup,
    required Map<String, Medicine> currentRecords,
    required Map<String, SaleEvent> currentSales,
    required WarningSettings currentSettings,
    required int currentSoldValue,
    required int currentUnknownSold,
  }) {
    var newStock = 0;
    var changedStock = 0;
    var reactivated = 0;
    final incomingIds = backup.records.keys.toSet();
    for (final incoming in backup.records.values) {
      final current = currentRecords[incoming.id];
      if (current == null) {
        newStock++;
      } else {
        if (!_sameMedicineRestoreFacts(current, incoming)) changedStock++;
        if (current.archived && !incoming.archived) reactivated++;
      }
    }

    var movingToRemoved = 0;
    for (final current in currentRecords.values) {
      if (!current.archived && !incomingIds.contains(current.id)) {
        movingToRemoved++;
      }
    }

    var newSales = 0;
    var changedSales = 0;
    for (final incoming in backup.sales.values) {
      final current = currentSales[incoming.id];
      if (current == null) {
        newSales++;
      } else if (!_sameSaleFacts(current, incoming)) {
        changedSales++;
      }
    }
    final removedSales = currentSales.keys
        .where((id) => !backup.sales.containsKey(id))
        .length;

    return BackupImpact(
      newStockEntries: newStock,
      changedStockEntries: changedStock,
      reactivatedStockEntries: reactivated,
      activeEntriesMovingToRemoved: movingToRemoved,
      newSaleEvents: newSales,
      changedSaleEvents: changedSales,
      removedSaleEvents: removedSales,
      warningSettingsChange:
          currentSettings.shortDays != backup.settings.shortDays ||
          currentSettings.months != backup.settings.months,
      soldTotalsChange:
          currentSoldValue != backup.soldValue ||
          currentUnknownSold != backup.unknownSold,
    );
  }

  final int newStockEntries;
  final int changedStockEntries;
  final int reactivatedStockEntries;
  final int activeEntriesMovingToRemoved;
  final int newSaleEvents;
  final int changedSaleEvents;
  final int removedSaleEvents;
  final bool warningSettingsChange;
  final bool soldTotalsChange;

  bool get hasMaterialChange =>
      newStockEntries > 0 ||
      changedStockEntries > 0 ||
      reactivatedStockEntries > 0 ||
      activeEntriesMovingToRemoved > 0 ||
      newSaleEvents > 0 ||
      changedSaleEvents > 0 ||
      removedSaleEvents > 0 ||
      warningSettingsChange ||
      soldTotalsChange;
}

Future<BackupImpact> compareBackupImpactCooperatively({
    required PharmacyBackup backup,
    required Map<String, Medicine> currentRecords,
    required Map<String, SaleEvent> currentSales,
    required WarningSettings currentSettings,
    required int currentSoldValue,
    required int currentUnknownSold,
  }) async {
    var newStock = 0;
    var changedStock = 0;
    var reactivated = 0;
    var processed = 0;

    final incomingIds = backup.records.keys.toSet();
    for (final incoming in backup.records.values) {
      final current = currentRecords[incoming.id];
      if (current == null) {
        newStock++;
      } else {
        if (!_sameMedicineRestoreFacts(current, incoming)) changedStock++;
        if (current.archived && !incoming.archived) reactivated++;
      }
      if (++processed % 512 == 0) {
        await Future<void>.delayed(Duration.zero);
      }
    }

    var movingToRemoved = 0;
    for (final current in currentRecords.values) {
      if (!current.archived && !incomingIds.contains(current.id)) {
        movingToRemoved++;
      }
      if (++processed % 512 == 0) {
        await Future<void>.delayed(Duration.zero);
      }
    }

    var newSales = 0;
    var changedSales = 0;
    for (final incoming in backup.sales.values) {
      final current = currentSales[incoming.id];
      if (current == null) {
        newSales++;
      } else if (!_sameSaleFacts(current, incoming)) {
        changedSales++;
      }
      if (++processed % 512 == 0) {
        await Future<void>.delayed(Duration.zero);
      }
    }

    var removedSales = 0;
    for (final id in currentSales.keys) {
      if (!backup.sales.containsKey(id)) removedSales++;
      if (++processed % 512 == 0) {
        await Future<void>.delayed(Duration.zero);
      }
    }

    return BackupImpact(
      newStockEntries: newStock,
      changedStockEntries: changedStock,
      reactivatedStockEntries: reactivated,
      activeEntriesMovingToRemoved: movingToRemoved,
      newSaleEvents: newSales,
      changedSaleEvents: changedSales,
      removedSaleEvents: removedSales,
      warningSettingsChange:
          currentSettings.shortDays != backup.settings.shortDays ||
          currentSettings.months != backup.settings.months,
      soldTotalsChange:
          currentSoldValue != backup.soldValue ||
          currentUnknownSold != backup.unknownSold,
    );
}

bool _sameMedicineRestoreFacts(Medicine a, Medicine b) =>
    a.id == b.id &&
    a.name == b.name &&
    a.brand == b.brand &&
    a.manufacturer == b.manufacturer &&
    a.salt == b.salt &&
    a.strength == b.strength &&
    a.form == b.form &&
    a.mfg == b.mfg &&
    a.mfgMonthOnly == b.mfgMonthOnly &&
    a.expiry == b.expiry &&
    a.expiryMonthOnly == b.expiryMonthOnly &&
    a.quantity == b.quantity &&
    a.unitPricePaise == b.unitPricePaise &&
    a.barcode == b.barcode &&
    a.batchNumber == b.batchNumber &&
    a.block == b.block &&
    a.row == b.row &&
    a.vertical == b.vertical &&
    a.location == b.location &&
    a.notes == b.notes &&
    a.ocrText == b.ocrText &&
    a.sold == b.sold &&
    a.archived == b.archived &&
    a.archivedAt == b.archivedAt &&
    a.archiveReason == b.archiveReason &&
    a.soldAt == b.soldAt &&
    a.soldQuantity == b.soldQuantity &&
    a.soldUnitPricePaise == b.soldUnitPricePaise;

bool _sameSaleFacts(SaleEvent a, SaleEvent b) =>
    a.id == b.id &&
    a.stockId == b.stockId &&
    a.medicineName == b.medicineName &&
    a.strength == b.strength &&
    a.form == b.form &&
    a.salt == b.salt &&
    a.quantity == b.quantity &&
    a.occurredAt == b.occurredAt &&
    a.totalAmountPaise == b.totalAmountPaise &&
    a.savedUnitPricePaise == b.savedUnitPricePaise;

class BackupReview {
  const BackupReview({
    required this.backup,
    required this.currentRevision,
    this.impact = const BackupImpact.none(),
  });

  final PharmacyBackup backup;
  final int currentRevision;
  final BackupImpact impact;

  int get activeMedicines =>
      backup.records.values.where((record) => !record.archived).length;
  int get removedMedicines =>
      backup.records.values.where((record) => record.archived).length;
  int get sales => backup.sales.length;
  bool get integrityVerified => backup.integrityVerified;
  bool get legacyFormat => backup.legacyFormat;
}
