import '../domain/medicine.dart';
import 'pharmacy_controller.dart';

/// Session-only exact-target memory for Aaris Brain.
///
/// This is deliberately not inventory state and is never persisted. It stores
/// only an existing stock ID that the pharmacist explicitly selected or saved.
/// Every read resolves that ID back through the authoritative inventory
/// snapshot, so removed/missing rows fail closed instead of becoming stale
/// hidden state.
final Expando<String> _operationalTargetIds = Expando<String>(
  'aaris.operationalTargetId',
);

extension PharmacyOperationalContext on PharmacyController {
  String? get operationalTargetId => _operationalTargetIds[this];

  Medicine? get operationalTarget {
    final id = _operationalTargetIds[this];
    if (id == null) return null;
    final record = snapshot.records[id];
    if (record == null || record.archived) {
      _operationalTargetIds[this] = null;
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
    _operationalTargetIds[this] = record.id;
  }

  void clearOperationalTarget([String? id]) {
    final current = _operationalTargetIds[this];
    if (id == null || current == id) _operationalTargetIds[this] = null;
  }
}
