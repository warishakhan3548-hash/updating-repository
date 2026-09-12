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
/// This is deliberately not inventory state and is never persisted. Active and
/// archived context are kept separately because they represent different
/// lifecycle states and therefore have different valid follow-up actions.
/// Every getter re-resolves the ID against the authoritative controller snapshot;
/// no quantity, price, SOLD flag, note or other mutable operational fact is
/// cached here.
final Expando<_OperationalTargetRef> _operationalTargets =
    Expando<_OperationalTargetRef>('aaris.operationalTarget');
final Expando<_OperationalTargetRef> _archivedOperationalTargets =
    Expando<_OperationalTargetRef>('aaris.archivedOperationalTarget');

String _targetFingerprint(Medicine medicine) => <String>[
  medicine.identity,
  normalize(medicine.batchNumber),
  normalize(medicine.barcode),
  normalize(medicine.manufacturer),
  normalize(medicine.brand),
  medicine.mfg == null ? '' : dateText(medicine.mfg!),
  medicine.expiry == null ? '' : dateText(medicine.expiry!),
].join('|');

String _archivedTargetFingerprint(Medicine medicine) => <String>[
  _targetFingerprint(medicine),
  normalize(medicine.archiveReason),
  medicine.archivedAt?.toUtc().toIso8601String() ?? '',
].join('|');

extension PharmacyOperationalContext on PharmacyController {
  String? get operationalTargetId => operationalTarget?.id;

  Medicine? get operationalTarget {
    final target = _operationalTargets[this];
    if (target == null) return null;
    final record = snapshot.records[target.id];
    if (record == null ||
        _targetFingerprint(record) != target.identityFingerprint) {
      _operationalTargets[this] = null;
      return null;
    }
    if (record.archived) {
      // A reviewed remove preserves the same physical row. Move the exact
      // conversational reference into the archived lifecycle instead of losing
      // it, so a follow-up “restore it” can locate that exact row without a
      // second fuzzy name search. Archive provenance becomes part of the new
      // fingerprint, so a later remove lifecycle cannot reuse stale context.
      _rememberArchivedReference(record);
      _operationalTargets[this] = null;
      return null;
    }
    return record;
  }

  /// The last exact archived row selected or archived through Aaris Brain.
  ///
  /// Archive provenance is part of the fingerprint. Restoring and removing the
  /// same stock row again therefore invalidates the old conversational target,
  /// preventing a later “restore it” from following a new lifecycle event.
  String? get archivedOperationalTargetId => archivedOperationalTarget?.id;

  Medicine? get archivedOperationalTarget {
    final target = _archivedOperationalTargets[this];
    if (target == null) return null;
    final record = snapshot.records[target.id];
    if (record == null ||
        !record.archived ||
        _archivedTargetFingerprint(record) != target.identityFingerprint) {
      _archivedOperationalTargets[this] = null;
      return null;
    }
    return record;
  }

  void rememberOperationalTarget(String id) {
    final record = snapshot.records[id];
    if (record == null || record.archived) {
      throw StateError('Aaris can remember only an exact active stock entry.');
    }
    _operationalTargets[this] = _OperationalTargetRef(
      id: record.id,
      identityFingerprint: _targetFingerprint(record),
    );
  }

  void rememberArchivedOperationalTarget(String id) {
    final record = snapshot.records[id];
    if (record == null || !record.archived) {
      throw StateError(
        'Aaris can remember archived context only for an exact removed stock entry.',
      );
    }
    _rememberArchivedReference(record);
  }

  void _rememberArchivedReference(Medicine record) {
    _archivedOperationalTargets[this] = _OperationalTargetRef(
      id: record.id,
      identityFingerprint: _archivedTargetFingerprint(record),
    );
  }

  void clearOperationalTarget([String? id]) {
    final current = _operationalTargets[this];
    if (current == null || (id != null && current.id != id)) return;

    // Brain removal flows clear the active target immediately after the commit.
    // Preserve the exact row as archived context only when the authoritative
    // snapshot proves that this very identity was just archived. No lifecycle
    // transition is inferred from names or cached facts.
    final record = snapshot.records[current.id];
    if (record != null &&
        record.archived &&
        _targetFingerprint(record) == current.identityFingerprint) {
      _rememberArchivedReference(record);
    }
    _operationalTargets[this] = null;
  }

  void clearArchivedOperationalTarget([String? id]) {
    final current = _archivedOperationalTargets[this];
    if (id == null || current?.id == id) {
      _archivedOperationalTargets[this] = null;
    }
  }
}
