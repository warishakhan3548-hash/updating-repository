import 'gs1_healthcare.dart';
import 'inventory.dart';
import 'medicine.dart';
import 'medicine_understanding.dart';

enum IntakeResolutionKind {
  exactLot,
  sameProduct,
  ambiguous,
  needsReview,
  newStock,
}

/// Deterministic resolution of one OCR/barcode draft against the authoritative
/// Medicine Database.
///
/// This object is advisory only: it never mutates stock and never copies an OCR
/// fact into an existing row. The UI may use [safeToReceive] only to offer the
/// existing revision-bound stock-receipt review; the controller and persistence
/// safety kernels remain authoritative for the eventual write.
class IntakeResolution {
  const IntakeResolution({
    required this.kind,
    required this.candidateStockIds,
    required this.reason,
    this.exactStockId,
    this.safeToReceive = false,
    this.receiveBlockReason = '',
  });

  final IntakeResolutionKind kind;
  final List<String> candidateStockIds;
  final String? exactStockId;
  final String reason;
  final bool safeToReceive;
  final String receiveBlockReason;

  bool get hasExactLot =>
      kind == IntakeResolutionKind.exactLot && exactStockId != null;
}

const _trustedIdentityConfidence = .80;
const _trustedLotConfidence = .82;

bool _trusted(
  MedicineScanDraft draft,
  String key, {
  double minimum = _trustedIdentityConfidence,
}) {
  final field = draft.field(key);
  return field.value.trim().isNotEmpty &&
      !field.conflicted &&
      field.confidence >= minimum;
}

String _trustedText(
  MedicineScanDraft draft,
  String key, {
  double minimum = _trustedIdentityConfidence,
}) => _trusted(draft, key, minimum: minimum)
    ? draft.field(key).value.trim()
    : '';

DateTime? _trustedDate(MedicineScanDraft draft, String key) {
  if (!_trusted(draft, key, minimum: _trustedLotConfidence)) return null;
  final raw = draft.field(key).value.trim();
  try {
    if (key == 'expiry') {
      return parseDate(raw, monthEnd: draft.expiryMonthOnly);
    }
    if (key == 'mfg') {
      return parseDate(raw, monthStart: draft.mfgMonthOnly);
    }
  } on FormatException {
    return null;
  }
  return null;
}

bool _sameText(String a, String b) => normalize(a) == normalize(b);

/// Canonical identity for scanner/import barcode comparisons.
///
/// GS1 DataMatrix commonly carries AI (01) as a 14-digit GTIN while older
/// inventory rows may contain the equivalent EAN-13/UPC-A/GTIN-8 representation.
/// Those are the same GS1 identifier with left zero padding, not different
/// products. Preserve non-GTIN barcodes byte-for-byte (apart from trim), but
/// collapse verified GS1 element strings and standard numeric GTIN lengths to
/// one 14-digit key. This prevents a package scanned through GS1 from being
/// misclassified as new stock merely because it was originally saved as EAN.
String _barcodeIdentity(String value) {
  final raw = value.trim();
  if (raw.isEmpty) return '';
  final gs1 = parseGs1HealthcareBarcode(raw);
  final candidate = gs1 != null && gs1.gtin.isNotEmpty ? gs1.gtin : raw;
  if (RegExp(r'^\d+$').hasMatch(candidate) &&
      const {8, 12, 13, 14}.contains(candidate.length)) {
    return candidate.padLeft(14, '0');
  }
  return candidate;
}

bool _sameBarcode(String a, String b) {
  final left = _barcodeIdentity(a);
  final right = _barcodeIdentity(b);
  return left.isNotEmpty && right.isNotEmpty && left == right;
}

bool _identityCompatible(MedicineScanDraft draft, Medicine record) {
  final name = _trustedText(draft, 'name');
  if (name.isNotEmpty && !_sameText(name, record.name)) return false;

  final strength = _trustedText(draft, 'strength');
  if (strength.isNotEmpty &&
      identityPart(strength) != identityPart(record.strength)) {
    return false;
  }

  final form = _trustedText(draft, 'form');
  if (form.isNotEmpty && normalizeForm(form) != normalizeForm(record.form)) {
    return false;
  }

  // Salt is optional. Two known, trusted values may not be silently combined;
  // one missing value remains uncertainty rather than a contradiction.
  final salt = _trustedText(draft, 'salt');
  if (salt.isNotEmpty &&
      record.salt.trim().isNotEmpty &&
      !_sameText(salt, record.salt)) {
    return false;
  }
  return true;
}

bool _hasIdentityEvidence(MedicineScanDraft draft) {
  final barcode = _trustedText(
    draft,
    'barcode',
    minimum: _trustedLotConfidence,
  );
  if (barcode.isNotEmpty) return true;
  return _trusted(draft, 'name') &&
      (_trusted(draft, 'strength') ||
          _trusted(draft, 'form') ||
          _trusted(draft, 'brand') ||
          _trusted(draft, 'salt'));
}

bool _strongIdentityConflict(MedicineScanDraft draft, Medicine record) =>
    !_identityCompatible(draft, record);

bool _sameOptionalText(
  MedicineScanDraft draft,
  String key,
  String recordValue, {
  double minimum = _trustedIdentityConfidence,
}) {
  final value = _trustedText(draft, key, minimum: minimum);
  if (value.isEmpty || recordValue.trim().isEmpty) return true;
  return _sameText(value, recordValue);
}

bool _lotFactsContradict(MedicineScanDraft draft, Medicine record) {
  final batch = _trustedText(
    draft,
    'batchNumber',
    minimum: _trustedLotConfidence,
  );
  if (batch.isNotEmpty &&
      record.batchNumber.trim().isNotEmpty &&
      !_sameText(batch, record.batchNumber)) {
    return true;
  }

  final barcode = _trustedText(
    draft,
    'barcode',
    minimum: _trustedLotConfidence,
  );
  if (barcode.isNotEmpty &&
      record.barcode.trim().isNotEmpty &&
      !_sameBarcode(barcode, record.barcode)) {
    return true;
  }

  final expiry = _trustedDate(draft, 'expiry');
  if (expiry != null &&
      record.expiry != null &&
      civilDay(expiry) != civilDay(record.expiry!)) {
    return true;
  }

  final mfg = _trustedDate(draft, 'mfg');
  if (mfg != null &&
      record.mfg != null &&
      civilDay(mfg) != civilDay(record.mfg!)) {
    return true;
  }

  if (!_sameOptionalText(draft, 'manufacturer', record.manufacturer)) {
    return true;
  }
  if (!_sameOptionalText(draft, 'brand', record.brand)) return true;
  return false;
}

bool _hasExactLotAnchor(MedicineScanDraft draft, Medicine record) {
  final batch = _trustedText(
    draft,
    'batchNumber',
    minimum: _trustedLotConfidence,
  );
  if (batch.isNotEmpty &&
      record.batchNumber.trim().isNotEmpty &&
      _sameText(batch, record.batchNumber)) {
    return true;
  }

  final barcode = _trustedText(
    draft,
    'barcode',
    minimum: _trustedLotConfidence,
  );
  if (barcode.isEmpty || !_sameBarcode(record.barcode, barcode)) return false;

  // A retail barcode is normally product-level, not batch-level. It becomes a
  // physical-lot anchor only when the pack also contributes a matching date.
  final expiry = _trustedDate(draft, 'expiry');
  if (expiry != null &&
      record.expiry != null &&
      civilDay(expiry) == civilDay(record.expiry!)) {
    return true;
  }
  final mfg = _trustedDate(draft, 'mfg');
  return mfg != null &&
      record.mfg != null &&
      civilDay(mfg) == civilDay(record.mfg!);
}

String _receiveBlock(Medicine record, MedicineScanDraft draft, DateTime today) {
  if (record.quantity == null) {
    return 'Current quantity is unknown; verify the physical count before receiving more stock.';
  }
  if (record.mfg != null && civilDay(record.mfg!).isAfter(civilDay(today))) {
    return 'The saved manufacturing date is in the future and must be corrected first.';
  }
  if (isExpiredOn(record, today)) {
    return 'This exact lot is expired; receiving into it is blocked.';
  }
  if (draft.overallConfidence < .78) {
    return 'The scan is low confidence; review the exact pack before changing stock.';
  }
  if (draft.fields.values.any(
    (field) => field.value.trim().isNotEmpty && field.conflicted,
  )) {
    return 'The scan contains conflicting OCR evidence; review it before changing stock.';
  }
  return '';
}

/// Resolves one review draft without fuzzy mutation or medical inference.
///
/// Matching policy:
/// * a trusted barcode that maps to different saved medicine identities fails
///   closed as ambiguous;
/// * an exact lot requires compatible identity plus a trusted batch match, or a
///   barcode together with a matching MFG/EXP date;
/// * product-only matches never receive stock automatically and are presented as
///   possible existing products/new batches;
/// * low-confidence evidence cannot unlock a stock-changing shortcut.
IntakeResolution resolveIntakeDraft({
  required MedicineScanDraft draft,
  required Iterable<Medicine> records,
  required DateTime today,
}) {
  final active = records
      .where((record) => !record.archived)
      .toList(growable: false);
  if (!_hasIdentityEvidence(draft)) {
    return const IntakeResolution(
      kind: IntakeResolutionKind.needsReview,
      candidateStockIds: <String>[],
      reason:
          'The scan does not contain enough trusted identity evidence to choose existing stock.',
    );
  }

  final barcode = _trustedText(
    draft,
    'barcode',
    minimum: _trustedLotConfidence,
  );
  final barcodeMatches = barcode.isEmpty
      ? const <Medicine>[]
      : active
            .where((record) => _sameBarcode(record.barcode, barcode))
            .toList();

  if (barcodeMatches.isNotEmpty) {
    final identities = barcodeMatches.map((record) => record.identity).toSet();
    if (identities.length > 1) {
      final ids = barcodeMatches.map((record) => record.id).toList()..sort();
      return IntakeResolution(
        kind: IntakeResolutionKind.ambiguous,
        candidateStockIds: List.unmodifiable(ids),
        reason:
            'This barcode is already attached to different medicine identities. Verify the physical packs before using scanner automation.',
      );
    }
    if (barcodeMatches.every((record) => _strongIdentityConflict(draft, record))) {
      final ids = barcodeMatches.map((record) => record.id).toList()..sort();
      return IntakeResolution(
        kind: IntakeResolutionKind.needsReview,
        candidateStockIds: List.unmodifiable(ids),
        reason:
            'Trusted OCR identity conflicts with the medicine currently saved for this barcode. Nothing should be updated until the pack is verified.',
      );
    }
  }

  final productMatches = <Medicine>[];
  for (final record in active) {
    if (!_identityCompatible(draft, record)) continue;
    if (barcodeMatches.isNotEmpty && !barcodeMatches.contains(record)) continue;
    productMatches.add(record);
  }

  // A batch number is a physical-lot anchor only inside a compatible product.
  // If that exact trusted batch is already saved but another trusted pack fact
  // disagrees, treating the scan as a harmless "new batch" would duplicate a
  // contradictory lot and weaken FEFO. Fail closed and make the pharmacist
  // resolve the conflict first.
  final trustedBatch = _trustedText(
    draft,
    'batchNumber',
    minimum: _trustedLotConfidence,
  );
  if (trustedBatch.isNotEmpty) {
    final conflictingSameBatch = productMatches
        .where(
          (record) =>
              record.batchNumber.trim().isNotEmpty &&
              _sameText(trustedBatch, record.batchNumber) &&
              _lotFactsContradict(draft, record),
        )
        .toList(growable: false);
    if (conflictingSameBatch.isNotEmpty) {
      final ids = conflictingSameBatch.map((record) => record.id).toList()
        ..sort();
      return IntakeResolution(
        kind: IntakeResolutionKind.needsReview,
        candidateStockIds: List.unmodifiable(ids),
        reason:
            'This trusted batch number already exists, but the scanned pack disagrees with saved lot facts such as MFG, EXP, barcode, brand or manufacturer. Verify the physical pack and correct the existing lot instead of creating or receiving stock automatically.',
      );
    }
  }

  final exact = productMatches
      .where(
        (record) =>
            !_lotFactsContradict(draft, record) &&
            _hasExactLotAnchor(draft, record),
      )
      .toList(growable: false);
  if (exact.length > 1) {
    final ids = exact.map((record) => record.id).toList()..sort();
    return IntakeResolution(
      kind: IntakeResolutionKind.ambiguous,
      candidateStockIds: List.unmodifiable(ids),
      reason:
          'More than one active row matches the same trusted physical-lot evidence. Review the duplicate rows instead of changing stock automatically.',
    );
  }
  if (exact.length == 1) {
    final record = exact.single;
    final block = _receiveBlock(record, draft, today);
    return IntakeResolution(
      kind: IntakeResolutionKind.exactLot,
      exactStockId: record.id,
      candidateStockIds: List.unmodifiable(<String>[record.id]),
      reason:
          'Trusted pack evidence resolves to one exact saved lot. Identity facts remain unchanged; any stock receipt still requires explicit review.',
      safeToReceive: block.isEmpty,
      receiveBlockReason: block,
    );
  }

  if (productMatches.isNotEmpty) {
    final ids = productMatches.map((record) => record.id).toList()..sort();
    final hasTrustedLot =
        _trusted(draft, 'batchNumber', minimum: _trustedLotConfidence) ||
        _trusted(draft, 'expiry', minimum: _trustedLotConfidence) ||
        _trusted(draft, 'mfg', minimum: _trustedLotConfidence);
    return IntakeResolution(
      kind: IntakeResolutionKind.sameProduct,
      candidateStockIds: List.unmodifiable(ids),
      reason: hasTrustedLot
          ? 'The medicine matches existing stock, but the trusted lot facts do not identify one existing batch. Review it as a possible new batch.'
          : 'The medicine matches existing stock, but the scan does not contain enough trusted lot evidence to choose one batch.',
    );
  }

  return const IntakeResolution(
    kind: IntakeResolutionKind.newStock,
    candidateStockIds: <String>[],
    reason:
        'No compatible active medicine is safely identified in the local Medicine Database. Review the draft before creating new stock.',
  );
}