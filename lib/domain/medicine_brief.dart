import 'inventory.dart';
import 'medicine.dart';

enum MedicineBriefFocus { summary, stock, expiry, location, fefo }

/// Read-only, deterministic operational intelligence for one medicine identity.
///
/// This object never mutates inventory and never infers clinical facts. It only
/// summarizes saved stock rows that already exist in the authoritative medicine
/// database. Any missing or contradictory fact remains explicit instead of being
/// guessed.
class MedicineOperationalBrief {
  MedicineOperationalBrief._({
    required this.productKey,
    required this.title,
    required this.activeBatchCount,
    required this.fefoEligibleBatchCount,
    required this.knownUsableUnits,
    required this.unknownQuantityBatchCount,
    required this.expiredBatchCount,
    required this.futureManufactureBatchCount,
    required this.zeroQuantityBatchCount,
    required this.unknownExpiryBatchCount,
    required this.unlocatedBatchCount,
    required this.locations,
    required this.batchNumbers,
    required this.nextFefo,
    required this.conflictingSaltFacts,
  });

  factory MedicineOperationalBrief.build({
    required Iterable<Medicine> records,
    required Medicine anchor,
    required DateTime today,
  }) {
    final day = civilDay(today);
    final productRows = records
        .where((record) => record.identity == anchor.identity)
        .toList(growable: false);
    final active = productRows
        .where((record) => !record.archived && !record.sold)
        .toList(growable: false);
    final candidates = dispensingCandidates(productRows, anchor, day);

    var knownUsableUnits = 0;
    var unknownQuantity = 0;
    var unknownExpiry = 0;
    var unlocated = 0;
    final locations = <String>{};
    final batches = <String>{};
    for (final record in candidates) {
      final quantity = record.quantity;
      if (quantity == null) {
        unknownQuantity++;
      } else {
        knownUsableUnits += quantity;
      }
      if (record.expiry == null) unknownExpiry++;
      final address = record.address.trim();
      if (address.isEmpty) {
        unlocated++;
      } else {
        locations.add(address);
      }
      final batch = record.batchNumber.trim();
      if (batch.isNotEmpty) batches.add(batch);
    }

    final saltFacts = active
        .map((record) => normalize(record.salt))
        .where((value) => value.isNotEmpty)
        .toSet();

    final orderedLocations = locations.toList()
      ..sort((a, b) => normalize(a).compareTo(normalize(b)));
    final orderedBatches = batches.toList()
      ..sort((a, b) => normalize(a).compareTo(normalize(b)));

    return MedicineOperationalBrief._(
      productKey: anchor.identity,
      title: anchor.title,
      activeBatchCount: active.length,
      fefoEligibleBatchCount: candidates.length,
      knownUsableUnits: knownUsableUnits,
      unknownQuantityBatchCount: unknownQuantity,
      expiredBatchCount: active
          .where((record) => isExpiredOn(record, day))
          .length,
      futureManufactureBatchCount: active
          .where(
            (record) =>
                record.mfg != null && civilDay(record.mfg!).isAfter(day),
          )
          .length,
      zeroQuantityBatchCount: active
          .where(
            (record) => isDispensableOn(record, day) && record.quantity == 0,
          )
          .length,
      unknownExpiryBatchCount: unknownExpiry,
      unlocatedBatchCount: unlocated,
      locations: List.unmodifiable(orderedLocations),
      batchNumbers: List.unmodifiable(orderedBatches),
      nextFefo: candidates.isEmpty ? null : candidates.first,
      conflictingSaltFacts: saltFacts.length > 1,
    );
  }

  final String productKey;
  final String title;
  final int activeBatchCount;
  final int fefoEligibleBatchCount;
  final int knownUsableUnits;
  final int unknownQuantityBatchCount;
  final int expiredBatchCount;
  final int futureManufactureBatchCount;
  final int zeroQuantityBatchCount;
  final int unknownExpiryBatchCount;
  final int unlocatedBatchCount;
  final List<String> locations;
  final List<String> batchNumbers;
  final Medicine? nextFefo;

  /// Multiple non-empty saved salt facts under one name/strength/form identity
  /// make product-level aggregation unsafe. Aaris fails closed instead of
  /// combining those rows into a misleading total or FEFO recommendation.
  final bool conflictingSaltFacts;

  bool get exactUsableQuantityKnown => unknownQuantityBatchCount == 0;
  bool get hasCurrentFefoStock => fefoEligibleBatchCount > 0;

  String describe(MedicineBriefFocus focus) {
    if (conflictingSaltFacts) {
      return '$title needs identity review. Saved active rows with the same name, strength and form contain conflicting salt facts, so Aaris will not combine their stock, expiry or FEFO result. Choose the exact stock row and correct the conflicting facts first.';
    }
    return switch (focus) {
      MedicineBriefFocus.stock => _stockDescription(),
      MedicineBriefFocus.expiry => _expiryDescription(),
      MedicineBriefFocus.location => _locationDescription(),
      MedicineBriefFocus.fefo => _fefoDescription(),
      MedicineBriefFocus.summary => _summaryDescription(),
    };
  }

  String _stockDescription() {
    final buffer = StringBuffer('$title: ');
    if (!hasCurrentFefoStock) {
      buffer.write('no current FEFO-eligible stock batch is recorded.');
    } else if (exactUsableQuantityKnown) {
      buffer.write(
        '$knownUsableUnits known unit${knownUsableUnits == 1 ? '' : 's'} across $fefoEligibleBatchCount current batch${fefoEligibleBatchCount == 1 ? '' : 'es'}.',
      );
    } else {
      buffer.write(
        '$knownUsableUnits known unit${knownUsableUnits == 1 ? '' : 's'} plus $unknownQuantityBatchCount current batch${unknownQuantityBatchCount == 1 ? '' : 'es'} with unknown quantity. Aaris will not guess the exact total.',
      );
    }
    _appendSafetyNotes(buffer);
    return buffer.toString();
  }

  String _expiryDescription() {
    final knownExpiry = nextFefo?.expiry;
    final buffer = StringBuffer('$title: ');
    if (!hasCurrentFefoStock) {
      buffer.write(
        'no current FEFO-eligible batch is available for an expiry answer.',
      );
    } else if (knownExpiry == null) {
      buffer.write(
        'the next current FEFO candidate has no recorded expiry. Verify the physical pack; Aaris will not invent an EXP date.',
      );
    } else {
      buffer.write(
        'earliest recorded valid expiry is ${_expiryText(nextFefo!)}${_batchCue(nextFefo!)}.',
      );
    }
    if (unknownExpiryBatchCount > 0) {
      buffer.write(
        ' $unknownExpiryBatchCount current batch${unknownExpiryBatchCount == 1 ? ' has' : 'es have'} no recorded expiry.',
      );
    }
    if (expiredBatchCount > 0) {
      buffer.write(
        ' $expiredBatchCount expired active row${expiredBatchCount == 1 ? ' is' : 's are'} excluded from current FEFO stock.',
      );
    }
    if (futureManufactureBatchCount > 0) {
      buffer.write(
        ' $futureManufactureBatchCount future-MFG row${futureManufactureBatchCount == 1 ? ' is' : 's are'} excluded until its recorded manufacturing date.',
      );
    }
    return buffer.toString();
  }

  String _locationDescription() {
    final buffer = StringBuffer('$title: ');
    if (!hasCurrentFefoStock) {
      buffer.write('no current FEFO-eligible stock location is available.');
      _appendSafetyNotes(buffer);
      return buffer.toString();
    }
    if (locations.isEmpty) {
      buffer.write(
        'none of the current FEFO-eligible batches has a recorded storage location.',
      );
    } else {
      final visible = locations.take(4).toList(growable: false);
      buffer.write(
        'current stock location${visible.length == 1 ? '' : 's'}: ${visible.join(' · ')}.',
      );
      if (locations.length > visible.length) {
        buffer.write(
          ' ${locations.length - visible.length} more recorded location${locations.length - visible.length == 1 ? '' : 's'} exist.',
        );
      }
    }
    if (unlocatedBatchCount > 0) {
      buffer.write(
        ' $unlocatedBatchCount current batch${unlocatedBatchCount == 1 ? ' has' : 'es have'} no recorded location.',
      );
    }
    return buffer.toString();
  }

  String _fefoDescription() {
    final next = nextFefo;
    if (next == null) {
      final buffer = StringBuffer(
        '$title: no current FEFO-eligible batch is available. Expired, SOLD, removed, future-MFG and known zero-quantity rows are not selected.',
      );
      _appendSafetyNotes(buffer);
      return buffer.toString();
    }

    final parts = <String>[
      next.batchNumber.trim().isEmpty
          ? 'batch number not recorded'
          : 'Batch ${next.batchNumber.trim()}',
      next.expiry == null ? 'EXP not recorded' : 'EXP ${_expiryText(next)}',
      next.quantity == null ? 'quantity unknown' : '${next.quantity} units',
      next.address.trim().isEmpty
          ? 'location not recorded'
          : next.address.trim(),
    ];
    final buffer = StringBuffer(
      '$title · next FEFO candidate: ${parts.join(' · ')}.',
    );
    if (next.quantity == null) {
      buffer.write(
        ' Verify this physical batch quantity before dispensing; Aaris will not skip an earlier-priority unknown batch or guess its stock.',
      );
    }
    if (next.expiry == null) {
      buffer.write(
        ' Verify the physical expiry before relying on FEFO because this batch has no saved EXP.',
      );
    }
    return buffer.toString();
  }

  String _summaryDescription() {
    final buffer = StringBuffer(_stockDescription());
    final next = nextFefo;
    if (next != null) {
      buffer.write(' Next FEFO: ');
      buffer.write(
        '${next.batchNumber.trim().isEmpty ? 'batch not recorded' : 'Batch ${next.batchNumber.trim()}'} · ${next.expiry == null ? 'EXP unknown' : 'EXP ${_expiryText(next)}'} · ${next.address.trim().isEmpty ? 'location not recorded' : next.address.trim()}.',
      );
    }
    return buffer.toString();
  }

  void _appendSafetyNotes(StringBuffer buffer) {
    if (expiredBatchCount > 0) {
      buffer.write(
        ' $expiredBatchCount expired active row${expiredBatchCount == 1 ? ' is' : 's are'} excluded.',
      );
    }
    if (futureManufactureBatchCount > 0) {
      buffer.write(
        ' $futureManufactureBatchCount future-MFG row${futureManufactureBatchCount == 1 ? ' is' : 's are'} excluded.',
      );
    }
    if (zeroQuantityBatchCount > 0) {
      buffer.write(
        ' $zeroQuantityBatchCount active row${zeroQuantityBatchCount == 1 ? ' has' : 's have'} 0 units but is not marked SOLD.',
      );
    }
  }

  String _expiryText(Medicine record) {
    final expiry = record.expiry!;
    return record.expiryMonthOnly
        ? dateText(expiry).substring(0, 7)
        : dateText(expiry);
  }

  String _batchCue(Medicine record) {
    final batch = record.batchNumber.trim();
    final address = record.address.trim();
    final parts = <String>[
      if (batch.isNotEmpty) 'Batch $batch',
      if (address.isNotEmpty) address,
    ];
    return parts.isEmpty ? '' : ' · ${parts.join(' · ')}';
  }
}
