/// Returns true when arbitrary imported text advertises itself as an Aaris
/// Pharmacy full-backup envelope.
///
/// Medicine-list import is intentionally more conservative than backup parsing:
/// any schema in the `aaris.pharmacy.backup.*` family is routed away from the
/// medicine-list pipeline, including future versions the current app may not yet
/// understand. This prevents backup JSON from being fragmented into fake OCR
/// medicine rows while keeping ordinary invoices/lists untouched.
bool isAarisPharmacyBackupText(String input) => RegExp(
  r'"schema"\s*:\s*"aaris\.pharmacy\.backup\.[^"]+"',
  caseSensitive: false,
).hasMatch(input);
