from pathlib import Path

root = Path(__file__).resolve().parents[1]

def replace_once(path: str, old: str, new: str) -> None:
    p = root / path
    text = p.read_text(encoding='utf-8')
    count = text.count(old)
    if count != 1:
        raise SystemExit(f'{path}: expected one anchor, found {count}')
    p.write_text(text.replace(old, new, 1), encoding='utf-8')

# One authoritative verified-GTIN identity kernel. Retail representations are
# equivalent only when the checksum validates; proprietary/invalid numeric codes
# stay raw-exact identifiers instead of being silently zero-padded into GTINs.
replace_once(
    'lib/domain/gs1_healthcare.dart',
    "Gs1HealthcareData? parseGs1HealthcareBarcode(String input) {\n",
    """String verifiedGtinKey(String input) {
  final raw = input.trim();
  if (raw.isEmpty || raw.length > 512) return '';
  final structured = parseGs1HealthcareBarcode(raw);
  if (structured != null && structured.gtin.isNotEmpty) {
    return structured.gtin;
  }
  if (!RegExp(r'^\\d+$').hasMatch(raw) ||
      !const <int>{8, 12, 13, 14}.contains(raw.length)) {
    return '';
  }
  final normalized = raw.padLeft(14, '0');
  return _validGtin(normalized) ? normalized : '';
}

Gs1HealthcareData? parseGs1HealthcareBarcode(String input) {
""",
)

replace_once(
    'lib/services/scan_service.dart',
    """int _barcodeScore(String value) {
  final digits = value.replaceAll(RegExp(r'\\D'), '');
  if (digits == value && const {8, 12, 13, 14}.contains(digits.length)) {
    return _validGtin(digits) ? 4 : 3;
  }
  if (digits == value && digits.length >= 6) return 2;
  return 1;
}

bool _validGtin(String digits) {
  if (!const {8, 12, 13, 14}.contains(digits.length)) return false;
  var sum = 0;
  for (
    var index = digits.length - 2, position = 1;
    index >= 0;
    index--, position++
  ) {
    final digit = int.parse(digits[index]);
    sum += digit * (position.isOdd ? 3 : 1);
  }
  return (10 - sum % 10) % 10 == int.parse(digits[digits.length - 1]);
}
""",
    """int _barcodeScore(String value) {
  if (verifiedGtinKey(value).isNotEmpty) return 4;
  final digits = value.replaceAll(RegExp(r'\\D'), '');
  if (digits == value && const {8, 12, 13, 14}.contains(digits.length)) {
    return 3;
  }
  if (digits == value && digits.length >= 6) return 2;
  return 1;
}
""",
)

replace_once(
    'lib/domain/search.dart',
    """String _barcodeIdentity(String value) {
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
""",
    """String _barcodeIdentity(String value) {
  final raw = value.trim();
  if (raw.isEmpty) return '';
  final verified = verifiedGtinKey(raw);
  if (verified.isNotEmpty) return verified;
  // Proprietary/invalid numeric identifiers remain exact. Zero-padding them
  // would create false equivalence with a different 14-digit identifier.
  return raw;
}
""",
)

replace_once(
    'lib/services/canonical_medicine_catalog_service.dart',
    """String _barcodeKey(String value) {
  final raw = value.trim();
  if (raw.isEmpty) return '';
  final gs1 = parseGs1HealthcareBarcode(raw);
  final candidate = gs1 != null && gs1.gtin.isNotEmpty ? gs1.gtin : raw;
  if (RegExp(r'^\\d+$').hasMatch(candidate) &&
      const <int>{8, 12, 13, 14}.contains(candidate.length)) {
    return candidate.padLeft(14, '0');
  }
  return candidate.replaceAll(RegExp(r'\\s+'), '');
}
""",
    """String _barcodeKey(String value) {
  final raw = value.trim();
  if (raw.isEmpty) return '';
  final verified = verifiedGtinKey(raw);
  if (verified.isNotEmpty) return verified;
  // Keep proprietary/non-GTIN payloads exact across catalogue lookup too.
  return raw.replaceAll(RegExp(r'\\s+'), '');
}
""",
)

replace_once(
    'lib/domain/medicine_resolution_v2.dart',
    """String _canonicalBarcode(String value) {
  final raw = value.trim();
  if (raw.isEmpty) return '';
  final gs1 = parseGs1HealthcareBarcode(raw);
  final candidate = gs1 != null && gs1.gtin.isNotEmpty ? gs1.gtin : raw;
  if (RegExp(r'^\\d+$').hasMatch(candidate) &&
      const <int>{8, 12, 13, 14}.contains(candidate.length)) {
    return candidate.padLeft(14, '0');
  }
  return candidate.replaceAll(RegExp(r'\\s+'), '');
}

bool _isStrongProductBarcodeKey(String value) {
  if (!RegExp(r'^\\d{14}$').hasMatch(value)) return false;
  final parsed = parseGs1HealthcareBarcode('01$value');
  return parsed != null && parsed.gtin == value;
}
""",
    """String _canonicalBarcode(String value) {
  final raw = value.trim();
  if (raw.isEmpty) return '';
  final verified = verifiedGtinKey(raw);
  if (verified.isNotEmpty) return verified;
  return raw.replaceAll(RegExp(r'\\s+'), '');
}

bool _isStrongProductBarcodeKey(String value) =>
    verifiedGtinKey(value).isNotEmpty;
""",
)

# If one physical observation contains more than one different verified GTIN,
# a candidate matching just one code must not receive a clean exact-barcode lock.
replace_once(
    'lib/domain/medicine_resolution_v2.dart',
    """  final productBarcodes = product.barcodes
      .map(_canonicalBarcode)
      .where((value) => value.isNotEmpty)
      .toSet();
  final exactBarcode =
      observedBarcodes.isNotEmpty &&
      productBarcodes.isNotEmpty &&
      observedBarcodes.intersection(productBarcodes).isNotEmpty;
  if (exactBarcode) {
    weighted += .995 * .52;
    totalWeight += .52;
    channels++;
  } else {
    // Only verified retail/GTIN identifiers can veto a product. Packs may also
    // contain numeric proprietary Code-128 payloads in standard-looking lengths;
    // those remain exact-match evidence but are not allowed to become hard GTIN
    // contradictions unless the existing GS1 kernel validates the check digit.
    final observedStrong = observedBarcodes
        .where(_isStrongProductBarcodeKey)
        .toSet();
    final productStrong = productBarcodes
        .where(_isStrongProductBarcodeKey)
        .toSet();
    if (observedStrong.isNotEmpty && productStrong.isNotEmpty) {
      hardConflicts++;
    }
  }
""",
    """  final productBarcodes = product.barcodes
      .map(_canonicalBarcode)
      .where((value) => value.isNotEmpty)
      .toSet();
  final observedStrong = observedBarcodes
      .where(_isStrongProductBarcodeKey)
      .toSet();
  final productStrong = productBarcodes
      .where(_isStrongProductBarcodeKey)
      .toSet();
  final exactBarcode =
      observedBarcodes.isNotEmpty &&
      productBarcodes.isNotEmpty &&
      observedBarcodes.intersection(productBarcodes).isNotEmpty;
  // One pack can legitimately expose multiple encodings of the SAME GTIN, but
  // two distinct checksum-valid GTIN identities mean the visual evidence is
  // multi-product/contaminated unless this canonical product explicitly owns all
  // of them. Matching only one code is not enough to auto-lock a medicine.
  final unexplainedStrongGtins = observedStrong.difference(productStrong);
  if (exactBarcode) {
    weighted += .995 * .52;
    totalWeight += .52;
    channels++;
    if (productStrong.isNotEmpty && unexplainedStrongGtins.isNotEmpty) {
      hardConflicts++;
    }
  } else if (observedStrong.isNotEmpty && productStrong.isNotEmpty) {
    // Only verified retail/GTIN identifiers can veto a product. Proprietary
    // numeric Code-128 payloads remain exact-match evidence, never hard GTIN
    // contradictions.
    hardConflicts++;
  }
""",
)

# Preserve complete raw OCR even if the untrusted OCR itself contains our marker.
# The controlled delimiter appended by composeRawAndFocusedOcr is always the last.
replace_once(
    'lib/domain/medicine_evidence_focus.dart',
    'final marker = value.indexOf(medicineEvidenceFocusMarker);',
    'final marker = value.lastIndexOf(medicineEvidenceFocusMarker);',
)
replace_once(
    'lib/domain/medicine_evidence_focus.dart',
    'final marker = value.indexOf(medicineEvidenceFocusMarker);',
    'final marker = value.lastIndexOf(medicineEvidenceFocusMarker);',
)

# Saved queue recovery: if foreground chat wins the lease exactly while a failed
# scan transport is being retired, propagate CONTEN­TION, not the stale transport
# error. The queue scheduler then keeps the same draft/index in reasoning state.
replace_once(
    'lib/services/medicine_intake_service.dart',
    """      try {
        await local.suspend();
      } catch (_) {
        Error.throwWithStackTrace(error, stack);
      }
""",
    """      try {
        await local.suspend();
      } catch (suspendError, suspendStack) {
        if (_localLeaseContention(suspendError)) {
          Error.throwWithStackTrace(suspendError, suspendStack);
        }
        Error.throwWithStackTrace(error, stack);
      }
""",
)

# Live direct scanner: bind retained frames to one verified product-barcode epoch.
# A new single strong GTIN starts a fresh evidence segment; ambiguous multi-GTIN
# frames are retained for review and never silently switch the active identity.
replace_once(
    'lib/ui/scanner_screen.dart',
    """import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

import '../services/media_import_service.dart';
""",
    """import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

import '../domain/gs1_healthcare.dart';
import '../services/media_import_service.dart';
""",
)
replace_once(
    'lib/ui/scanner_screen.dart',
    """  String _text = '', _barcode = '', _error = '';
  final List<ScanEvidence> _evidence = <ScanEvidence>[];
""",
    """  String _text = '', _barcode = '', _error = '';
  String? _activeStrongGtin;
  final List<ScanEvidence> _evidence = <ScanEvidence>[];
""",
)
replace_once(
    'lib/ui/scanner_screen.dart',
    """      if (result.text.isNotEmpty || result.barcode.isNotEmpty) {
        final evidence = <ScanEvidence>[..._evidence, result];
""",
    """      if (result.text.isNotEmpty || result.barcode.isNotEmpty) {
        final incomingStrongGtins = result.allBarcodes
            .map(verifiedGtinKey)
            .where((value) => value.isNotEmpty)
            .toSet();
        if (incomingStrongGtins.length == 1) {
          final incoming = incomingStrongGtins.single;
          final priorStrongGtins = <String>{
            for (final frame in _evidence)
              for (final raw in frame.allBarcodes)
                if (verifiedGtinKey(raw).isNotEmpty) verifiedGtinKey(raw),
          };
          final changedProduct =
              _activeStrongGtin != null && _activeStrongGtin != incoming;
          final resolvesAmbiguousScene =
              _activeStrongGtin == null && priorStrongGtins.length > 1;
          if (changedProduct || resolvesAmbiguousScene) {
            _evidence.clear();
            _text = '';
            _barcode = '';
          }
          _activeStrongGtin = incoming;
        }
        final evidence = <ScanEvidence>[..._evidence, result];
""",
)
replace_once(
    'lib/ui/scanner_screen.dart',
    """        if (widget.autoSubmit) {
          _evidence.clear();
          _text = '';
          _barcode = '';
        }
""",
    """        if (widget.autoSubmit) {
          _evidence.clear();
          _text = '';
          _barcode = '';
          _activeStrongGtin = null;
        }
""",
)

# Self-delete: no surgery helper remains in production history diff after bot commit.
Path(__file__).unlink()
