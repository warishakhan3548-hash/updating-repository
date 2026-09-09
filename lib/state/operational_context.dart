import '../domain/medicine.dart';
import 'pharmacy_controller.dart';

class _OperationalTargetRef {
  const _OperationalTargetRef({
    required this.id,
    required this.identityFingerprint,
  });

  final String id;
  final String identityFingerprint;
}

/// Session-only exact-target memory for Aaris Brain.
///
/// This is deliberately not inventory state and is never persisted. It stores
/// only an existing stock ID that the pharmacist explicitly selected or saved,
/// plus a compact fingerprint of the physical identity facts that made that
/// selection meaningful.
///
/// Quantity, price, SOLD state and notes may change while the same row remains
/// the active conversational target; every action re-reads those live facts from
/// the authoritative inventory. If medicine identity, batch, barcode, MFG or
/// expiry changes, however, the old conversational reference fails closed and
/// the pharmacist must choose the exact row again. This prevents a stale “isko”
/// or “same one” command from silently following an identity-changing edit.
final Expando<_OperationalTargetRef> _operationalTargets =
    Expando<_OperationalTargetRef>('aaris.operationalTarget');

String _targetFingerprint(Medicine medicine) => <String>[
  medicine.identity,
  normalize(medicine.batchNumber),
  normalize(medicine.barcode),
  normalize(medicine.manufacturer),
  normalize(medicine.brand),
  medicine.mfg == null ? '' : dateText(medicine.mfg!),
  medicine.expiry == null ? '' : dateText(medicine.expiry!),
].join('|');

extension PharmacyOperationalContext on PharmacyController {
  String? get operationalTargetId => operationalTarget?.id;

  Medicine? get operationalTarget {
    final target = _operationalTargets[this];
    if (target == null) return null;
    final record = snapshot.records[target.id];
    if (record == null ||
        record.archived ||
        _targetFingerprint(record) != target.identityFingerprint) {
      _operationalTargets[this] = null;
      return null;
    }
    return record;
  }

  void rememberOperationalTarget(String id) {
    final record = snapshot.records[id];
    if (record == null || record.archived) {
      throw StateError(
        'Aaris can remember only an exact active stock entry.',
      );
    }
    _operationalTargets[this] = _OperationalTargetRef(
      id: record.id,
      identityFingerprint: _targetFingerprint(record),
    );
  }

  void clearOperationalTarget([String? id]) {
    final current = _operationalTargets[this];
    if (id == null || current?.id == id) _operationalTargets[this] = null;
  }
}
