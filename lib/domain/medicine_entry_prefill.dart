import 'medicine.dart';

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

  String? taggedText(String labels, String label, {int max = 300}) {
    final expression = RegExp(
      '(?:^|[^A-Za-z0-9\\u0900-\\u097f])(?:$labels)(?=\\s|[:=])\\s*[:=]?\\s*(?:"([^"]{1,$max})"|([A-Za-z0-9\\u0900-\\u097f+._/-]{1,$max}))',
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

  final mfgLabelPresent = hasLabel(r'mfg|manufacturing|manufactured|एमएफजी');
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
  final mfg = mfgRaw == null
      ? ''
      : _canonicalDate(mfgRaw, 'manufacturing date');
  final mfgMonthOnly = mfg.length == 7;

  final quantityLabelPresent = hasLabel(r'qty|quantity|मात्रा');
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
  final barcode = taggedText(r'barcode|बारकोड', 'barcode', max: 120) ?? '';
  final block = taggedText(r'block|ब्लॉक', 'block', max: 40) ?? '';
  final row = taggedText(r'row|पंक्ति', 'row', max: 40) ?? '';
  final vertical =
      taggedText(r'vertical|vert|वर्टिकल', 'vertical', max: 40) ?? '';
  final location =
      taggedText(
        r'location|shelf|rack|लोकेशन|शेल्फ|रैक',
        'location',
        max: 160,
      ) ??
      '';

  final brand = taggedText(r'brand|ब्रांड', 'brand', max: 120) ?? '';
  final manufacturer =
      taggedText(r'manufacturer|maker|निर्माता', 'manufacturer', max: 160) ??
      '';
  final salt = taggedText(r'salt|composition|सॉल्ट', 'salt', max: 160) ?? '';
  var strength =
      taggedText(r'strength|power|स्ट्रेंथ', 'strength', max: 80) ?? '';
  var form = taggedText(r'form|फॉर्म', 'form', max: 40) ?? '';
  if (form.isNotEmpty) {
    final normalized = normalizeForm(form);
    if (normalized == 'Other' && normalize(form) != 'other') {
      throw FormatException(
        'Unsupported medicine form “$form”. Review it manually.',
      );
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
    .replaceAll(
      RegExp(r'[^A-Za-z0-9\u0900-\u097f+./%()-]+', unicode: true),
      ' ',
    )
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
