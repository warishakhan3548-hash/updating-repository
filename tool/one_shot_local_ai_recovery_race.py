from pathlib import Path

root = Path(__file__).resolve().parents[1]

path = root / 'lib/services/ai_service.dart'
text = path.read_text(encoding='utf-8')
old = '''        try {
          await local.suspend();
        } catch (_) {
          Error.throwWithStackTrace(error, stack);
        }
        _throwIfCancelled(cancelEpoch);
        _safeReset(onStreamReset);
        await Future<void>.delayed(const Duration(milliseconds: 120));
'''
new = '''        try {
          await local.suspend();
        } catch (suspendError) {
          // Another scan can legitimately acquire the shared native lease in
          // the tiny transport-failure -> suspend gap. That is scheduling
          // contention, not a second connection failure. Rejoin the same
          // event-driven lease wait instead of surfacing the stale transport
          // error or cancelling the unrelated scanner inference.
          if (_isLocalLeaseContention(suspendError)) {
            contentionSince ??= DateTime.now();
            _safeReset(onStreamReset);
            if (DateTime.now().difference(contentionSince!) >=
                _localLeaseContentionBudget) {
              throw StateError(
                'Local AI stayed occupied by other on-device work. Finish or cancel that task and send again; no inventory changes were made.',
              );
            }
            await _waitForLocalLease(local, cancelEpoch);
            await Future<void>.delayed(const Duration(milliseconds: 80));
            continue;
          }
          Error.throwWithStackTrace(error, stack);
        }
        _throwIfCancelled(cancelEpoch);
        _safeReset(onStreamReset);
        await Future<void>.delayed(const Duration(milliseconds: 120));
'''
if text.count(old) != 1:
    raise SystemExit(f'ai_service recovery anchor count={text.count(old)}')
path.write_text(text.replace(old, new, 1), encoding='utf-8')

# The final intake resolver must use the same checksum-aware GTIN identity as
# search/catalog/resolver. Invalid/proprietary numeric identifiers stay raw exact
# and therefore cannot collide merely because one value was left-zero-padded.
path = root / 'lib/domain/intake_resolution.dart'
text = path.read_text(encoding='utf-8')
old = '''String _barcodeIdentity(String value) {
  final raw = value.trim();
  if (raw.isEmpty) return '';
  final gs1 = parseGs1HealthcareBarcode(raw);
  final candidate = gs1 != null && gs1.gtin.isNotEmpty ? gs1.gtin : raw;
  if (RegExp(r'^\\d+$').hasMatch(candidate) &&
      const {8, 12, 13, 14}.contains(candidate.length)) {
    return candidate.padLeft(14, '0');
  }
  return candidate;
}
'''
new = '''String _barcodeIdentity(String value) {
  final raw = value.trim();
  if (raw.isEmpty) return '';
  final verified = verifiedGtinKey(raw);
  if (verified.isNotEmpty) return verified;
  return raw;
}
'''
if text.count(old) != 1:
    raise SystemExit(f'intake barcode identity anchor count={text.count(old)}')
path.write_text(text.replace(old, new, 1), encoding='utf-8')

Path(__file__).unlink()
