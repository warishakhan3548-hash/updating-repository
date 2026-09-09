#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

def read(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")

def write(path: str, content: str) -> None:
    target = ROOT / path
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(content, encoding="utf-8")

def replace_once(path: str, old: str, new: str) -> None:
    text = read(path)
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{path}: expected exactly one patch anchor, found {count}")
    write(path, text.replace(old, new, 1))

DOMAIN = r"""import 'medicine.dart';

/// Explicit pharmacist-entered facts extracted from an Aaris Brain "add"
/// command. This is only a review draft: it never writes inventory and never
/// supplies medical facts that the pharmacist did not type.
class MedicineEntryPrefill {
  const MedicineEntryPrefill({
    this.name = '',
    this.brand = '',
    this.manufacturer = '',
    this.salt = '',
    this.strength = '',
    this.form = '',
    this.mfg = '',
    this.mfgMonthOnly = false,
    this.expiry = '',
    this.expiryMonthOnly = false,
    this.quantity,
    this.priceText = '',
    this.barcode = '',
    this.batchNumber = '',
    this.block = '',
    this.row = '',
    this.vertical = '',
    this.location = '',
  });

  final String name;
  final String brand;
  final String manufacturer;
  final String salt;
  final String strength;
  final String form;
  final String mfg;
  final bool mfgMonthOnly;
  final String expiry;
  final bool expiryMonthOnly;
  final int? quantity;
  final String priceText;
  final String barcode;
  final String batchNumber;
  final String block;
  final String row;
  final String vertical;
  final String location;

  bool get isEmpty =>
      name.isEmpty &&
      brand.isEmpty &&
      manufacturer.isEmpty &&
      salt.isEmpty &&
      strength.isEmpty &&
      form.isEmpty &&
      mfg.isEmpty &&
      expiry.isEmpty &&
      quantity == null &&
      priceText.isEmpty &&
      barcode.isEmpty &&
      batchNumber.isEmpty &&
      block.isEmpty &&
      row.isEmpty &&
      vertical.isEmpty &&
      location.isEmpty;

  /// Values understood by the existing editor. Empty values are omitted so a
  /// future caller can safely combine an explicit command with scanner/catalog
  /// evidence without erasing stronger evidence.
  Map<String, dynamic> get editorValues => <String, dynamic>{
    if (name.isNotEmpty) 'name': name,
    if (brand.isNotEmpty) 'brand': brand,
    if (manufacturer.isNotEmpty) 'manufacturer': manufacturer,
    if (salt.isNotEmpty) 'salt': salt,
    if (strength.isNotEmpty) 'strength': strength,
    if (mfg.isNotEmpty) 'mfg': mfg,
    if (expiry.isNotEmpty) 'expiry': expiry,
    if (quantity != null) 'quantity': quantity,
    if (barcode.isNotEmpty) 'barcode': barcode,
    if (batchNumber.isNotEmpty) 'batchNumber': batchNumber,
    if (block.isNotEmpty) 'block': block,
    if (row.isNotEmpty) 'row': row,
    if (vertical.isNotEmpty) 'vertical': vertical,
    if (location.isNotEmpty) 'location': location,
  };

  String get reviewSummary {
    final locationParts = <String>[
      if (block.isNotEmpty) 'Block $block',
      if (row.isNotEmpty) 'Row $row',
      if (vertical.isNotEmpty) 'Vertical $vertical',
      if (location.isNotEmpty) location,
    ];
    return <String>[
      if (name.isNotEmpty) name,
      if (strength.isNotEmpty) strength,
      if (form.isNotEmpty) form,
      if (quantity != null) 'Qty $quantity',
      if (expiry.isNotEmpty) 'EXP $expiry',
      if (mfg.isNotEmpty) 'MFG $mfg',
      if (batchNumber.isNotEmpty) 'Batch $batchNumber',
      if (barcode.isNotEmpty) 'Barcode $barcode',
      if (locationParts.isNotEmpty) locationParts.join(' · '),
      if (priceText.isNotEmpty) 'Price ₹$priceText',
    ].join(' · ');
  }
}

const medicineAddCommandTerms = <String>[
  'add medicine',
  'new medicine',
  'medicine add',
  'add stock',
  'nayi medicine',
  'nayi dawai',
  'नई मेडिसिन',
  'नई दवा',
  'मेडिसिन जोड़',
];

bool isMedicineAddCommand(String raw) {
  final text = _normalized(raw);
  return medicineAddCommandTerms.any(
    (term) => _containsPhrase(text, _normalized(term)),
  );
}

/// Parses only values actually typed in the command. Unlabelled numbers are
/// intentionally left inside the medicine name instead of being guessed as
/// quantity/price/strength. Recognized form words and unit-bearing strengths
/// are extracted only from the remaining medicine phrase.
MedicineEntryPrefill? parseMedicineAddPrefill(String raw) {
  if (!isMedicineAddCommand(raw)) return null;
  if (raw.length > 1200 || RegExp(r'[\u0000-\u001f\u007f]').hasMatch(raw)) {
    throw const FormatException('Medicine command is too large or invalid.');
  }

  var work = raw;

  String? take(
    RegExp expression,
    String label, {
    String Function(RegExpMatch match)? value,
  }) {
    final matches = expression.allMatches(work).toList(growable: false);
    if (matches.length > 1) {
      throw FormatException('Use only one $label value in an add command.');
    }
    if (matches.isEmpty) return null;
    final match = matches.single;
    final rawValue = value?.call(match) ?? match.group(1) ?? '';
    final cleaned = _bounded(rawValue, label, 300);
    work = work.replaceRange(match.start, match.end, ' ');
    return cleaned;
  }

  String? taggedText(
    String labels,
    String label, {
    int max = 300,
  }) {
    final expression = RegExp(
      '(?:^|[^A-Za-z0-9\\u0900-\\u097f])(?:$labels)\\s*[:=]?\\s*(?:"([^"]{1,$max})"|([A-Za-z0-9\\u0900-\\u097f+._/-]{1,$max}))',
      caseSensitive: false,
      unicode: true,
    );
    return take(
      expression,
      label,
      value: (match) => match.group(1) ?? match.group(2) ?? '',
    );
  }

  bool hasLabel(String labels) => RegExp(
    '(?:^|[^A-Za-z0-9\\u0900-\\u097f])(?:$labels)(?=\\s|[:=]|\$)',
    caseSensitive: false,
    unicode: true,
  ).hasMatch(work);

  final expiryLabelPresent = hasLabel(r'exp|expiry|एक्सपायरी');
  final expiryRaw = take(
    RegExp(
      r'(?:exp|expiry|एक्सपायरी)\s*[:=]?\s*([0-9०-९]{4}[-/][0-9०-९]{2}(?:[-/][0-9०-९]{2})?)',
      caseSensitive: false,
      unicode: true,
    ),
    'expiry',
  );
  if (expiryLabelPresent && expiryRaw == null) {
    throw const FormatException(
      'Expiry must be YYYY-MM or YYYY-MM-DD. Aaris will not guess a date.',
    );
  }
  final expiry = expiryRaw == null ? '' : _canonicalDate(expiryRaw, 'expiry');
  final expiryMonthOnly = expiry.length == 7;

  final mfgLabelPresent =
      hasLabel(r'mfg|manufacturing|manufactured|एमएफजी');
  final mfgRaw = take(
    RegExp(
      r'(?:mfg|manufacturing|manufactured|एमएफजी)\s*[:=]?\s*([0-9०-९]{4}[-/][0-9०-९]{2}(?:[-/][0-9०-९]{2})?)',
      caseSensitive: false,
      unicode: true,
    ),
    'manufacturing date',
  );
  if (mfgLabelPresent && mfgRaw == null) {
    throw const FormatException(
      'Manufacturing date must be YYYY-MM or YYYY-MM-DD. Aaris will not guess a date.',
    );
  }
  final mfg =
      mfgRaw == null ? '' : _canonicalDate(mfgRaw, 'manufacturing date');
  final mfgMonthOnly = mfg.length == 7;

  final quantityLabelPresent =
      hasLabel(r'qty|quantity|मात्रा');
  final quantityRaw = take(
    RegExp(
      r'(?:(?:qty|quantity|मात्रा)\s*[:=]?\s*([0-9०-९]{1,9})(?:\s*(?:units?|pcs?|pieces?|यूनिट(?:्स)?))?|([0-9०-९]{1,9})\s*(?:units?|pcs?|pieces?|यूनिट(?:्स)?))',
      caseSensitive: false,
      unicode: true,
    ),
    'quantity',
    value: (match) => match.group(1) ?? match.group(2) ?? '',
  );
  if (quantityLabelPresent && quantityRaw == null) {
    throw const FormatException(
      'Quantity must be a whole number. Aaris will not guess stock.',
    );
  }
  final quantity = quantityRaw == null
      ? null
      : int.tryParse(_asciiDigits(quantityRaw));
  if (quantity != null && (quantity < 0 || quantity > 100000000)) {
    throw const FormatException(
      'Quantity is outside the supported 0–100000000 range.',
    );
  }

  final priceLabelPresent = hasLabel(r'unit\s+price|price|rate|कीमत|रेट');
  final priceRaw = take(
    RegExp(
      r'(?:unit\s+price|price|rate|कीमत|रेट)\s*[:=]?\s*₹?\s*(\d{1,9}(?:\.\d{1,2})?)(?![0-9.])',
      caseSensitive: false,
      unicode: true,
    ),
    'price',
  );
  if (priceLabelPresent && priceRaw == null) {
    throw const FormatException(
      'Price must be a positive amount with at most two decimal places.',
    );
  }
  final priceText = priceRaw == null ? '' : priceRaw;
  if (priceText.isNotEmpty) parseMoney(priceText);

  final batchNumber =
      taggedText(r'batch(?:\s*(?:no|number))?|बैच', 'batch number', max: 80) ??
      '';
  final barcode =
      taggedText(r'barcode|बारकोड', 'barcode', max: 120) ?? '';
  final block = taggedText(r'block|ब्लॉक', 'block', max: 40) ?? '';
  final row = taggedText(r'row|पंक्ति', 'row', max: 40) ?? '';
  final vertical =
      taggedText(r'vertical|vert|वर्टिकल', 'vertical', max: 40) ?? '';
  final location =
      taggedText(r'location|shelf|rack|लोकेशन|शेल्फ|रैक', 'location', max: 160) ??
      '';

  final brand = taggedText(r'brand|ब्रांड', 'brand', max: 120) ?? '';
  final manufacturer =
      taggedText(r'manufacturer|maker|निर्माता', 'manufacturer', max: 160) ?? '';
  final salt = taggedText(r'salt|composition|सॉल्ट', 'salt', max: 160) ?? '';
  var strength =
      taggedText(r'strength|power|स्ट्रेंथ', 'strength', max: 80) ?? '';
  var form = taggedText(r'form|फॉर्म', 'form', max: 40) ?? '';
  if (form.isNotEmpty) {
    final normalized = normalizeForm(form);
    if (normalized == 'Other' && normalize(form) != 'other') {
      throw FormatException('Unsupported medicine form “$form”. Review it manually.');
    }
    form = normalized;
  }

  for (final term in medicineAddCommandTerms) {
    work = _stripWholePhrase(work, term);
  }
  for (final filler in const [
    'please',
    'pls',
    'karo',
    'kar do',
    'करो',
    'कर दो',
    'create',
    'entry',
  ]) {
    work = _stripWholePhrase(work, filler);
  }

  // A unit-bearing strength such as 500mg is explicit typed evidence. Bare
  // numbers such as "650" remain in the name because guessing their meaning
  // could corrupt identity or stock.
  if (strength.isEmpty) {
    final matches = RegExp(
      r'(^|\s)(\d+(?:\.\d+)?\s*(?:mcg|mg|g|ml|iu|%))(?=\s|$)',
      caseSensitive: false,
    ).allMatches(work).toList(growable: false);
    if (matches.length == 1) {
      final match = matches.single;
      strength = _bounded(match.group(2) ?? '', 'strength', 80);
      work = work.replaceRange(match.start, match.end, ' ');
    }
  }

  if (form.isEmpty) {
    final matches = RegExp(
      r'(^|\s)(tablet|tablets|tab|tabs|capsule|capsules|cap|caps|syrup|syp|syr|injection|injections|inj|cream|ointment|drop|drops|sachet|sachets)(?=\s|$)',
      caseSensitive: false,
    ).allMatches(work).toList(growable: false);
    if (matches.length == 1) {
      final match = matches.single;
      form = normalizeForm(match.group(2) ?? '');
      work = work.replaceRange(match.start, match.end, ' ');
    }
  }

  var name = _cleanName(work);
  final explicitName = RegExp(
    r'^(?:name|medicine|dawai|दवा|मेडिसिन)\s*[:=]?\s*(.+)$',
    caseSensitive: false,
    unicode: true,
  ).firstMatch(name);
  if (explicitName != null) {
    name = _cleanName(explicitName.group(1) ?? '');
  }
  if (name.length > 300) {
    throw const FormatException('Medicine name is too long.');
  }

  return MedicineEntryPrefill(
    name: name,
    brand: brand,
    manufacturer: manufacturer,
    salt: salt,
    strength: strength,
    form: form,
    mfg: mfg,
    mfgMonthOnly: mfgMonthOnly,
    expiry: expiry,
    expiryMonthOnly: expiryMonthOnly,
    quantity: quantity,
    priceText: priceText,
    barcode: barcode,
    batchNumber: batchNumber,
    block: block,
    row: row,
    vertical: vertical,
    location: location,
  );
}

String _canonicalDate(String raw, String label) {
  final ascii = _asciiDigits(raw).replaceAll('/', '-');
  try {
    parseDate(
      ascii,
      monthEnd: label == 'expiry',
      monthStart: label != 'expiry',
    );
  } on FormatException {
    throw FormatException(
      '$label must be YYYY-MM or YYYY-MM-DD. Aaris will not guess a date.',
    );
  }
  return ascii;
}

String _asciiDigits(String value) {
  const devanagari = '०१२३४५६७८९';
  final result = StringBuffer();
  for (final rune in value.runes) {
    final char = String.fromCharCode(rune);
    final index = devanagari.indexOf(char);
    result.write(index < 0 ? char : index.toString());
  }
  return result.toString();
}

String _bounded(String raw, String label, int max) {
  final value = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (value.isEmpty || value.length > max) {
    throw FormatException('$label must be between 1 and $max characters.');
  }
  return value;
}

String _cleanName(String value) => value
    .replaceAll(RegExp(r'[^A-Za-z0-9\u0900-\u097f+./%()-]+', unicode: true), ' ')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

String _normalized(String value) => value
    .toLowerCase()
    .replaceAll(RegExp(r'[^a-z0-9\u0900-\u097f]+', unicode: true), ' ')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

bool _containsPhrase(String text, String phrase) =>
    text == phrase ||
    text.startsWith('$phrase ') ||
    text.endsWith(' $phrase') ||
    text.contains(' $phrase ');

String _stripWholePhrase(String source, String phrase) {
  final words = phrase
      .trim()
      .split(RegExp(r'\s+'))
      .where((word) => word.isNotEmpty)
      .map(RegExp.escape)
      .join(r'\s+');
  if (words.isEmpty) return source;
  final expression = RegExp(
    '(^|[^A-Za-z0-9\\u0900-\\u097f])($words)(?=\$|[^A-Za-z0-9\\u0900-\\u097f])',
    caseSensitive: false,
    unicode: true,
  );
  return source.replaceAllMapped(
    expression,
    (match) => '${match.group(1) ?? ''} ',
  );
}
"""

TEST = r"""import 'package:aaris_pharmacy/domain/app_brain.dart';
import 'package:aaris_pharmacy/domain/medicine_entry_prefill.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Aaris Brain reviewed medicine quick intake', () {
    test('extracts explicit stock facts into a review-only draft', () {
      final intent = parseAppBrainIntent(
        'add medicine Dolo 650 qty 20 exp 2027-05 batch AB12 shelf A1 price 12.50',
      );

      expect(intent.action, AppBrainAction.addMedicine);
      final draft = intent.addPrefill!;
      expect(draft.name, 'Dolo 650');
      expect(draft.quantity, 20);
      expect(draft.expiry, '2027-05');
      expect(draft.expiryMonthOnly, isTrue);
      expect(draft.batchNumber, 'AB12');
      expect(draft.location, 'A1');
      expect(draft.priceText, '12.50');
      expect(intent.mutatesInventory, isFalse);
    });

    test('understands Devanagari digits without guessing new facts', () {
      final draft = parseMedicineAddPrefill(
        'नई दवा Crocin qty ५ expiry २०२७-०५',
      )!;

      expect(draft.name, 'Crocin');
      expect(draft.quantity, 5);
      expect(draft.expiry, '2027-05');
      expect(draft.strength, isEmpty);
      expect(draft.salt, isEmpty);
    });

    test('extracts typed strength form and structured physical location', () {
      final draft = parseMedicineAddPrefill(
        'add medicine Amox strength 500mg form capsule qty 30 block B1 row R3 vertical V4',
      )!;

      expect(draft.name, 'Amox');
      expect(draft.strength, '500mg');
      expect(draft.form, 'Capsule');
      expect(draft.quantity, 30);
      expect(draft.block, 'B1');
      expect(draft.row, 'R3');
      expect(draft.vertical, 'V4');
    });

    test('unit-bearing strength can be extracted but bare 650 is never stock', () {
      final unitStrength = parseMedicineAddPrefill(
        'add medicine Amox 500mg capsule qty 10',
      )!;
      expect(unitStrength.name, 'Amox');
      expect(unitStrength.strength.toLowerCase(), '500mg');
      expect(unitStrength.form, 'Capsule');
      expect(unitStrength.quantity, 10);

      final bare = parseMedicineAddPrefill('add medicine Dolo 650')!;
      expect(bare.name, 'Dolo 650');
      expect(bare.quantity, isNull);
      expect(bare.strength, isEmpty);
    });

    test('explicit multi-word evidence requires quotes and remains bounded', () {
      final draft = parseMedicineAddPrefill(
        'add medicine Dolo location "Cold Cabinet 2" manufacturer "ACME Pharma"',
      )!;
      expect(draft.name, 'Dolo');
      expect(draft.location, 'Cold Cabinet 2');
      expect(draft.manufacturer, 'ACME Pharma');
    });

    test('invalid or contradictory explicit facts fail closed', () {
      expect(
        () => parseMedicineAddPrefill(
          'add medicine Dolo expiry 2027-99 qty 5',
        ),
        throwsFormatException,
      );
      expect(
        () => parseMedicineAddPrefill(
          'add medicine Dolo qty 5 quantity 6',
        ),
        throwsFormatException,
      );
      expect(
        () => parseMedicineAddPrefill(
          'add medicine Dolo price 9999999999.00',
        ),
        throwsFormatException,
      );
    });

    test('plain add command preserves the existing blank-editor workflow', () {
      final intent = parseAppBrainIntent('add medicine');
      expect(intent.action, AppBrainAction.addMedicine);
      expect(intent.addPrefill, isNotNull);
      expect(intent.addPrefill!.isEmpty, isTrue);
    });
  });
}
"""

DOC = r"""# Aaris Brain Reviewed Quick Intake — 2026-09-10

Aaris Brain now turns explicit pharmacist add commands into a pre-filled medicine
editor instead of throwing the typed facts away.

Examples:

- `add medicine Dolo 650 qty 20 exp 2027-05 batch AB12 shelf A1`
- `add medicine Amox 500mg capsule qty 30 block B1 row R3 vertical V4`
- `नई दवा Crocin qty ५ expiry २०२७-०५`

## Safety contract

This is **draft automation**, not autonomous inventory mutation.

- The parser only uses facts the pharmacist actually typed.
- Bare numbers are never guessed as stock quantity, price, or strength.
- Unit-bearing strengths and recognized dosage forms are extracted from the
  command text; no salt, indication, dose, substitution, or other medical fact
  is invented.
- Explicit dates are validated and invalid dates fail closed.
- Explicit quantity and money values use the same bounded rules as inventory.
- The existing medicine editor remains the save boundary.
- Existing duplicate/barcode/fuzzy-match confirmation still runs before a new
  stock entry can be saved.
- The global inventory revision check still rejects a stale editor save.
- The authoritative SQLite database, audit/Undo path, integrity firewall, FEFO,
  scanner/OCR review, and removed-stock recovery architecture are unchanged.

The result is less typing for pharmacists without granting natural-language AI
an unreviewed write path.
"""

write("lib/domain/medicine_entry_prefill.dart", DOMAIN)
write("test/medicine_entry_prefill_test.dart", TEST)
write("docs/AARIS_BRAIN_REVIEWED_QUICK_INTAKE_2026_09_10.md", DOC)

replace_once(
    "lib/domain/app_brain.dart",
    "import 'medicine_brief.dart';\n",
    "import 'medicine_brief.dart';\nimport 'medicine_entry_prefill.dart';\n",
)

replace_once(
    "lib/domain/app_brain.dart",
    """    this.locationPatch,
    this.removalReason,
    this.confidence = 0,
""",
    """    this.locationPatch,
    this.removalReason,
    this.addPrefill,
    this.confidence = 0,
""",
)

replace_once(
    "lib/domain/app_brain.dart",
    """  final StockLocationPatch? locationPatch;
  final RemovalReasonHint? removalReason;
  final double confidence;
""",
    """  final StockLocationPatch? locationPatch;
  final RemovalReasonHint? removalReason;
  final MedicineEntryPrefill? addPrefill;
  final double confidence;
""",
)

replace_once(
    "lib/domain/app_brain.dart",
    """  if (_containsAny(text, const [
    'add medicine',
    'new medicine',
    'medicine add',
    'add stock',
    'nayi medicine',
    'nayi dawai',
    'नई मेडिसिन',
    'नई दवा',
    'मेडिसिन जोड़',
  ])) {
    return const AppBrainIntent(
      action: AppBrainAction.addMedicine,
      confidence: .98,
    );
  }
""",
    """  final addPrefill = parseMedicineAddPrefill(raw);
  if (addPrefill != null) {
    return AppBrainIntent(
      action: AppBrainAction.addMedicine,
      addPrefill: addPrefill,
      confidence: .99,
    );
  }
""",
)

replace_once(
    "lib/ui/brain_screen.dart",
    """      case AppBrainAction.addMedicine:
        if (mounted) {
          widget.onOpenSection(AppSection.stock);
          setState(() => _reply = 'Opening a fresh medicine entry.');
          await Future<void>.delayed(Duration.zero);
          if (mounted) await openEditor(context, widget.controller);
        }
        return;
""",
    """      case AppBrainAction.addMedicine:
        if (mounted) {
          final prefill = intent.addPrefill;
          widget.onOpenSection(AppSection.stock);
          setState(
            () => _reply = prefill == null || prefill.isEmpty
                ? 'Opening a fresh medicine entry.'
                : 'Prepared a review-only medicine draft from your explicit command facts: ${prefill.reviewSummary}. Nothing is saved until you review and press Save.',
          );
          await Future<void>.delayed(Duration.zero);
          if (mounted) {
            await openEditor(
              context,
              widget.controller,
              prefill: prefill,
            );
          }
        }
        return;
""",
)

replace_once(
    "lib/ui/editor_screen.dart",
    "import '../domain/medicine_discovery.dart';\n",
    "import '../domain/medicine_discovery.dart';\nimport '../domain/medicine_entry_prefill.dart';\n",
)

replace_once(
    "lib/ui/editor_screen.dart",
    """  MedicineDraftSeed? seed,
  MedicineScanDraft? scanDraft,
  String barcode = '',
""",
    """  MedicineDraftSeed? seed,
  MedicineScanDraft? scanDraft,
  MedicineEntryPrefill? prefill,
  String barcode = '',
""",
)

replace_once(
    "lib/ui/editor_screen.dart",
    """        seed: seed,
        scanDraft: scanDraft,
        barcode: barcode,
""",
    """        seed: seed,
        scanDraft: scanDraft,
        prefill: prefill,
        barcode: barcode,
""",
)

replace_once(
    "lib/ui/editor_screen.dart",
    """    this.seed,
    this.scanDraft,
    this.barcode = '',
""",
    """    this.seed,
    this.scanDraft,
    this.prefill,
    this.barcode = '',
""",
)

replace_once(
    "lib/ui/editor_screen.dart",
    """  final MedicineDraftSeed? seed;
  final MedicineScanDraft? scanDraft;
  final String barcode, ocrText;
""",
    """  final MedicineDraftSeed? seed;
  final MedicineScanDraft? scanDraft;
  final MedicineEntryPrefill? prefill;
  final String barcode, ocrText;
""",
)

replace_once(
    "lib/ui/editor_screen.dart",
    """    final seed = widget.seed;
    final scan = widget.scanDraft;
""",
    """    final seed = widget.seed;
    final scan = widget.scanDraft;
    final prefill = widget.prefill;
""",
)

replace_once(
    "lib/ui/editor_screen.dart",
    """          'ocrText': widget.ocrText.trim().isNotEmpty
              ? widget.ocrText
              : scan?.searchableOcrText ?? '',
        };
""",
    """          'ocrText': widget.ocrText.trim().isNotEmpty
              ? widget.ocrText
              : scan?.searchableOcrText ?? '',
          ...?prefill?.editorValues,
        };
""",
)

replace_once(
    "lib/ui/editor_screen.dart",
    """    fields['price'] = TextEditingController(
      text: widget.record?.unitPricePaise == null
          ? ''
          : (widget.record!.unitPricePaise! / 100).toStringAsFixed(2),
    );
""",
    """    fields['price'] = TextEditingController(
      text: widget.record?.unitPricePaise == null
          ? prefill?.priceText ?? ''
          : (widget.record!.unitPricePaise! / 100).toStringAsFixed(2),
    );
""",
)

replace_once(
    "lib/ui/editor_screen.dart",
    """    final record = widget.record;
    _form = record?.form ?? identityValue(seed?.form, scan?.form ?? '');
    _mfgMonthOnly = record?.mfg == null
        ? scan?.mfgMonthOnly ?? false
        : record!.mfgMonthOnly;
    _expiryMonthOnly = record?.expiry == null || record!.expiryMonthOnly;
    if (record?.expiry == null && scan?.expiry.isNotEmpty == true) {
      _expiryMonthOnly = scan!.expiryMonthOnly;
      final value = parseDate(scan.expiry, monthEnd: _expiryMonthOnly);
      if (value != null) {
        fields['expiry']!.text = inputDateText(
          value,
          monthOnly: _expiryMonthOnly,
        );
      }
    }
""",
    """    final record = widget.record;
    _form = record?.form ??
        (prefill?.form.isNotEmpty == true
            ? prefill!.form
            : identityValue(seed?.form, scan?.form ?? ''));
    _mfgMonthOnly = record?.mfg != null
        ? record!.mfgMonthOnly
        : prefill?.mfg.isNotEmpty == true
        ? prefill!.mfgMonthOnly
        : scan?.mfgMonthOnly ?? false;
    _expiryMonthOnly = record?.expiry != null
        ? record!.expiryMonthOnly
        : prefill?.expiry.isNotEmpty == true
        ? prefill!.expiryMonthOnly
        : scan?.expiry.isNotEmpty == true
        ? scan!.expiryMonthOnly
        : true;
    if (record?.expiry == null && prefill?.expiry.isNotEmpty == true) {
      final value = parseDate(
        prefill!.expiry,
        monthEnd: prefill.expiryMonthOnly,
      );
      if (value != null) {
        fields['expiry']!.text = inputDateText(
          value,
          monthOnly: prefill.expiryMonthOnly,
        );
      }
    } else if (record?.expiry == null && scan?.expiry.isNotEmpty == true) {
      _expiryMonthOnly = scan!.expiryMonthOnly;
      final value = parseDate(scan.expiry, monthEnd: _expiryMonthOnly);
      if (value != null) {
        fields['expiry']!.text = inputDateText(
          value,
          monthOnly: _expiryMonthOnly,
        );
      }
    }
""",
)

replace_once(
    "lib/ui/editor_screen.dart",
    """    if (record?.mfg != null) {
      fields['mfg']!.text = inputDateText(
        record!.mfg!,
        monthOnly: record.mfgMonthOnly,
      );
    } else if (scan?.mfg.isNotEmpty == true) {
      final value = parseDate(scan!.mfg, monthStart: _mfgMonthOnly);
      if (value != null) {
        fields['mfg']!.text = inputDateText(value, monthOnly: _mfgMonthOnly);
      }
    }
""",
    """    if (record?.mfg != null) {
      fields['mfg']!.text = inputDateText(
        record!.mfg!,
        monthOnly: record.mfgMonthOnly,
      );
    } else if (prefill?.mfg.isNotEmpty == true) {
      final value = parseDate(
        prefill!.mfg,
        monthStart: prefill.mfgMonthOnly,
      );
      if (value != null) {
        fields['mfg']!.text = inputDateText(
          value,
          monthOnly: prefill.mfgMonthOnly,
        );
      }
    } else if (scan?.mfg.isNotEmpty == true) {
      final value = parseDate(scan!.mfg, monthStart: _mfgMonthOnly);
      if (value != null) {
        fields['mfg']!.text = inputDateText(value, monthOnly: _mfgMonthOnly);
      }
    }
""",
)

print("Aaris quick-intake patch applied.")
