import 'medicine.dart';

final _medicineOcrPresentationArtifacts = RegExp(
  r'[\u00AD\u034F\u061C\u180E\u200B-\u200F\u202A-\u202E\u2060\u2066-\u2069\uFEFF]',
);
final _medicineOcrWhitespace = RegExp(r'\s+');
final _medicineOcrCompatibilitySpaces = RegExp(r'[\u00A0\u2007\u202F\u3000]');
final _medicineOcrSlashVariants = RegExp(r'[／⁄∕]');
final _medicineOcrDashVariants = RegExp(r'[‐‑‒–—−]');
final _medicineOcrDecimalVariants = RegExp(r'[٫．]');
final _medicineOcrMicroVariants = RegExp(r'[µμ]');
final _medicineOcrFullWidthAscii = RegExp(r'[\uFF01-\uFF5E]');
final _medicineOcrScriptDigits = RegExp(r'[०-९٠-٩۰-۹]');
final _medicineOcrAsciiDigit = RegExp(r'\d');
final _medicineOcrDigitO = RegExp('[Oo]');
final _medicineOcrDigitOne = RegExp('[IlL]');

const _medicineOcrNamedMonthPattern =
    r'(?:jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|jun(?:e)?|jul(?:y)?|aug(?:ust)?|sep(?:t(?:ember)?)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?)';

// OCR frequently drops the visual gap between a short packaging role and its
// value ("MFG04/2026", "EXP04/2028", "BATCHNOAB123"). Restore only known
// pharmaceutical roles. Generic alpha/digit splitting is intentionally avoided
// because medicine brands, licences and machine codes legitimately mix them.
final _medicineOcrGluedNumericRoleLabel = RegExp(
  r'(?<![A-Za-z])((?:mfg|mfd|dom|exp|expn|xpry|expiry|doe|mrp|price|pkd|pkg))(?=[0-9])',
  caseSensitive: false,
);

// A leading 0/1 in a printed month is commonly OCR'd as O/I/l. When that
// confusable glyph is fused to a strong MFG/EXP role, require a second real
// digit plus either an explicit month/year separator or a complete four-digit
// compact year. The date parser then performs its existing bounded label-adjacent
// glyph repair; this rule never changes letters into digits.
final _medicineOcrGluedConfusableMonthYearRoleLabel = RegExp(
  r'(?<![A-Za-z])((?:mfg|mfd|dom|exp|expn|xpry|expiry|doe))(?=[OoIlL][0-9](?:(?:\s*[./-]\s*|\s{1,3})(?:20[0-9]{2}|[0-9]{2})|20[0-9]{2})(?![A-Za-z0-9]))',
  caseSensitive: false,
);
final _medicineOcrGluedNamedMonthRoleLabel = RegExp(
  '(?<![A-Za-z])((?:mfg|mfd|dom|exp|expn|xpry|expiry|doe))'
  '(?=$_medicineOcrNamedMonthPattern\\s*(?:[./-]\\s*)?\\d{2,4}(?![A-Za-z0-9]))',
  caseSensitive: false,
);

// Traceability headings are frequently flattened as BATCHNUMBERAB123,
// BATCHNUMAB123 or LOTNOAB123. Recover only an exact pharmaceutical lot role;
// NUMBER/NUM are canonicalized to NO so the downstream batch grammar keeps one
// authority instead of growing a second set of aliases.
final _medicineOcrGluedTraceabilityLabel = RegExp(
  r'(?<![A-Za-z])((?:batch|lot))((?:number|num|no)\.?)?(?=[A-Za-z0-9])',
  caseSensitive: false,
);

// Strong multi-word semantic labels survive OCR in several shapes: ordinary
// spaces, punctuation separators, or completely collapsed text. Canonicalize
// only roles whose semantics are already explicit. Bare BRAND/GENERIC/SALT are
// deliberately excluded because prefix words can be legitimate product text.
final _medicineOcrExplicitSemanticLabel = RegExp(
  r'(?<![A-Za-z])('
  r'(?:brand|product|generic|proprietary|manufacturer|salt)\s*[._/-]*\s*name|'
  r'trade\s*[._/-]*\s*(?:name|mark)|'
  r'active\s*[._/-]*\s*ingredients?(?:\s*[._/-]*\s*name)?'
  r')(?=$|[^A-Za-z])',
  caseSensitive: false,
);

// Multi-word field labels are especially easy for OCR to collapse into one
// token. Longer roles are matched first so words such as NAME can never leak
// into the extracted value (ACTIVEINGREDIENTNAMEPARACETAMOL, for example).
final _medicineOcrGluedSemanticLabel = RegExp(
  r'(?<![A-Za-z])(ACTIVEINGREDIENTS?NAME|MANUFACTURERNAME|PROPRIETARYNAME|BRANDNAME|TRADENAME|TRADEMARK|PRODUCTNAME|GENERICNAME|SALTNAME|ACTIVEINGREDIENTS?|MANUFACTURER)(?=[A-Za-z][A-Za-z0-9-]{2,})',
  caseSensitive: false,
);

// Company ownership headings often arrive as MANUFACTUREDBYACME or MFG.BYACME.
// Restore the value boundary while preserving the role itself for the existing
// manufacturer/date-noise firewalls.
final _medicineOcrGluedOwnerValue = RegExp(
  r'(?<![A-Za-z])((?:manufactured|mfg|mfd|made|marketed|distributed|imported))\s*\.?\s*(by)(?=[A-Za-z]{2})',
  caseSensitive: false,
);

// "EACH10MLCONTAINS..." is a common OCR collapse on syrup/suspension packs.
// The exact EACH + numeric-volume + CONTAINS scaffold is strong enough to
// restore without guessing an ingredient or a concentration.
final _medicineOcrGluedCompositionBasis = RegExp(
  r'(?<![A-Za-z0-9])(each)([0-9OoIlL]{1,4}(?:[.,][0-9OoIlL]{1,2})?)(ml|g)contains(?=[A-Za-z])',
  caseSensitive: false,
);

// Reuse the authoritative dosage-form vocabulary rather than introducing a
// second form list. Only single-token aliases participate in glued recovery;
// multi-word forms still require visible spacing from OCR.
final _medicineOcrSingleTokenFormPattern =
    (medicineFormAliases.keys
            .where((value) => value != 'other' && !value.contains(' '))
            .toList(growable: false)
          ..sort((left, right) => right.length.compareTo(left.length)))
        .map(RegExp.escape)
        .join('|');
final _medicineOcrGluedUnitForm = RegExp(
  '([0-9OoIlL]{1,7}(?:[.,][0-9OoIlL]{1,4})?\\s*'
  '(?:mcg|ug|mg|gm|g|ml|meq|iu|i\\.u\\.|units?|%))'
  '(?=(?:$_medicineOcrSingleTokenFormPattern)(?![A-Za-z]))',
  caseSensitive: false,
);

// A dropped boundary before a printed dose is semantically recoverable because
// the numeric token is immediately owned by a pharmaceutical unit. The prefix
// still needs at least three alphabetic characters; field ownership below keeps
// batch/lot/licence/machine-code surfaces from becoming strengths without making
// every nearby packaging word poison otherwise valid medicine evidence.
final _medicineOcrGluedDose = RegExp(
  r'([A-Za-z][A-Za-z-]{2,47})([0-9OoIlL]{1,7}(?:[.,][0-9OoIlL]{1,4})?)(?=\s*(?:mcg|ug|mg|gm|g|ml|meq|iu|i\.u\.|units?|%)(?![A-Za-z]))',
  caseSensitive: false,
);
final _medicineOcrUnsafeOwningRole = RegExp(
  r'(?:^|[\s;|])(?:mrp|price|mfg|mfd|dom|exp|expn|xpry|expiry|doe|pkd|pkg|pack(?:\s*size)?)\b(?:\s*(?:date|dt|on))?\.?\s*[:._-]?\s*$|'
  r'(?:^|[\s;|])(?:batch|lot|serial|licen[cs]e|gtin|barcode|code)\b(?:\s*(?:no|number)\.?)?\s*[:._-]?\s*(?:[A-Za-z0-9-]{1,24}\s+)?$',
  caseSensitive: false,
);
final _medicineOcrGluedDoseUnsafePrefix = RegExp(
  r'^(?:batch|lot|serial|licen[cs]e|gtin|barcode|code|mrp|price|mfg|mfd|dom|exp|expn|xpry|expiry|doe|pkd|pkg|pack)',
  caseSensitive: false,
);

final _medicineOcrUnitBoundNumber = RegExp(
  r'(?<![A-Za-z0-9])([0-9OoIlL]{1,7}(?:[.,][0-9OoIlL]{1,4})?)(?=\s*(?:mcg|ug|mg|gm|g|ml|meq|iu|i\.u\.|units?|%)(?![A-Za-z]))',
  caseSensitive: false,
);
final _medicineOcrSeparatedDigitsBeforeUnit = RegExp(
  r'(?<![A-Za-z0-9])((?:[0-9]\s+){1,4}[0-9])(?=\s*(?:mcg|ug|mg|gm|g|ml|meq|iu|i\.u\.|units?|%|milligram(?:me)?s?|microgram(?:me)?s?|millilit(?:er|re)s?|gram(?:me)?s?|international\s+units?|per\s*cent|percent)(?![A-Za-z]))',
  caseSensitive: false,
);
final _medicineOcrSpacedDecimal = RegExp(
  r'(?<!\d)(\d{1,7})\s*([.,])\s*(\d{1,4})(?!\d)',
);
final _medicineOcrSpelledUnit = RegExp(
  r'(?<![A-Za-z0-9])([0-9OoIlL]{1,7}(?:[.,][0-9OoIlL]{1,4})?)\s*(milligram(?:me)?s?|microgram(?:me)?s?|millilit(?:er|re)s?|gram(?:me)?s?|international\s+units?|per\s*cent|percent)(?![A-Za-z])',
  caseSensitive: false,
);
final _medicineOcrThousandsBeforeUnit = RegExp(
  r'(?<!\d)([1-9]\d{0,2}),(\d{3})(?=\s*(?:mcg|ug|mg|gm|g|ml|meq|iu|i\.u\.|units?|%)(?![A-Za-z]))',
  caseSensitive: false,
);
final _medicineOcrMlConfusion = RegExp(
  r'(?<![A-Za-z0-9])([0-9OoIlL]{1,7}(?:[.,][0-9OoIlL]{1,4})?)\s*m[1Il](?![A-Za-z])',
  caseSensitive: false,
);

// OCR can lose the slash in a liquid concentration and return 125mg5ml (or
// 125mg5m1). Treat only an immediately fused mass/unit + numeric-volume/unit
// surface as a concentration. A visible gap between "mg" and "5 ml" remains a
// hard boundary so pack volume or an adjacent dose can never be silently joined.
final _medicineOcrFusedConcentration = RegExp(
  r'(?<![A-Za-z0-9])([0-9OoIlL]{1,7}(?:[.,][0-9OoIlL]{1,4})?)\s*(mcg|ug|mg|gm|g|meq|iu|i\.u\.|units?)([0-9OoIlL]{1,4}(?:[.,][0-9OoIlL]{1,2})?)\s*(ml|m[1Il])(?![A-Za-z])',
  caseSensitive: false,
);
final _medicineOcrPerConcentration = RegExp(
  r'(?<![A-Za-z0-9])(\d+(?:[.,]\d+)?\s*(?:mcg|ug|mg|gm|g|meq|iu|i\.u\.|units?|%))\s+per\s+(?:(\d+(?:[.,]\d+)?)\s*)?(ml|millilit(?:er|re)s?|g|gram(?:me)?s?|dose|actuation)(?![A-Za-z])',
  caseSensitive: false,
);

// V40's unlabeled-combination grammar intentionally accepts literal '+' only.
// Canonicalize common pharmaceutical separators (& / AND / WITH) into that one
// authority, but only when the separator is owned by a complete left strength
// and the right side contains an alphabetic ingredient followed by another
// pharmaceutical strength. Ordinary prose and "500 mg AND 125 mg" stay intact.
final _medicineOcrCombinationSeparator = RegExp(
  r'(\d+(?:[.,]\d+)?\s*(?:mcg|ug|mg|gm|g|ml|meq|iu|i\.u\.|units?|%)(?:\s*(?:w\s*/\s*w|w\s*/\s*v|v\s*/\s*v)|\s*/\s*(?:\d+(?:[.,]\d+)?\s*)?(?:ml|g|dose|actuation))?)\s*(?:&|\band\b|\bwith\b)\s*(?=[A-Za-z][A-Za-z .()/-]{2,72}\d+(?:[.,]\d+)?\s*(?:mcg|ug|mg|gm|g|ml|meq|iu|i\.u\.|units?|%)(?![A-Za-z]))',
  caseSensitive: false,
);
final _medicineOcrCompositionBasis = RegExp(
  r'(?<![A-Za-z0-9])(?:each\s+)?(\d+(?:[.,]\d+)?)\s*(ml|g)\s+(?:of\s+(?:(?:the|reconstituted)\s+)?(?:suspension|solution|syrup)\s+)?contains?\b',
  caseSensitive: false,
);
final _medicineOcrBasisOwnedStrength = RegExp(
  r'(?<![A-Za-z0-9/])(\d+(?:[.,]\d+)?\s*(?:mcg|ug|mg|gm|g|meq|iu|i\.u\.|units?))(?!\s*/)',
  caseSensitive: false,
);
final _medicineOcrCompositionStop = RegExp(
  r'\b(?:dosage|directions?|take|administer(?:ed|ing)?|administration|warning|caution|storage|mfg|mfd|dom|exp|expiry|doe|batch|lot|mrp|manufactured|manufacturer|marketed|distributed|pkd|pkg|packed|packing|pack\s*size|net\s+(?:qty|quantity|content)|excipients?|preservatives?|colour|color|flavou?r)\b|\bdose\s*[:.-]?\s*(?=\d)',
  caseSensitive: false,
);

String _cleanMedicineOcrLine(String value) => value
    // Unicode bidi/zero-width controls are formatting code points, not word
    // separators. Removing them keeps real medicine tokens intact while all
    // visible whitespace is still collapsed below.
    .replaceAll(_medicineOcrPresentationArtifacts, '')
    .replaceAll(_medicineOcrWhitespace, ' ')
    .trim();

String _repairMedicineOcrDigitToken(String value) => value
    .replaceAll(_medicineOcrDigitO, '0')
    .replaceAll(_medicineOcrDigitOne, '1');

String _canonicalMedicineUnitWord(String value) {
  final key = value.toLowerCase().replaceAll(_medicineOcrWhitespace, ' ').trim();
  if (key.startsWith('milligram')) return 'mg';
  if (key.startsWith('microgram')) return 'mcg';
  if (key.startsWith('millilit')) return 'ml';
  if (key.startsWith('gram')) return 'g';
  if (key.startsWith('international')) return 'iu';
  if (key == 'percent' || key == 'per cent') return '%';
  return key;
}

String _canonicalMedicineDenominatorUnit(String value) {
  final key = value.toLowerCase().replaceAll(_medicineOcrWhitespace, ' ').trim();
  if (key.startsWith('millilit')) return 'ml';
  if (key.startsWith('gram')) return 'g';
  return key;
}

String _canonicalMedicineSemanticLabel(String value) {
  final key = value
      .toUpperCase()
      .replaceAll(RegExp(r'[\s._/-]+'), '');
  switch (key) {
    case 'BRANDNAME':
      return 'BRAND NAME';
    case 'TRADENAME':
      return 'TRADE NAME';
    case 'TRADEMARK':
      return 'TRADE MARK';
    case 'PRODUCTNAME':
      return 'PRODUCT NAME';
    case 'PROPRIETARYNAME':
      return 'PROPRIETARY NAME';
    case 'GENERICNAME':
    case 'SALTNAME':
      return 'GENERIC NAME';
    case 'ACTIVEINGREDIENT':
    case 'ACTIVEINGREDIENTNAME':
      return 'ACTIVE INGREDIENT';
    case 'ACTIVEINGREDIENTS':
    case 'ACTIVEINGREDIENTSNAME':
      return 'ACTIVE INGREDIENTS';
    case 'MANUFACTURERNAME':
    case 'MANUFACTURER':
      return 'MANUFACTURER';
  }
  return value;
}

bool _medicineOcrUnsafeRoleOwnsCandidate(String value, int start) {
  final contextStart = start > 48 ? start - 48 : 0;
  return _medicineOcrUnsafeOwningRole.hasMatch(
    value.substring(contextStart, start),
  );
}

String _separateMedicineOcrGluedDose(String value) {
  return value.replaceAllMapped(_medicineOcrGluedDose, (match) {
    final prefix = match[1]!;
    final number = match[2]!;
    // Do not turn an all-letter OCR accident into a dose. At least one genuine
    // digit must survive recognition before O/0 and I/l/1 repair is allowed.
    if (!_medicineOcrAsciiDigit.hasMatch(number)) return match[0]!;

    if (_medicineOcrUnsafeRoleOwnsCandidate(value, match.start) ||
        _medicineOcrGluedDoseUnsafePrefix.hasMatch(prefix)) {
      return match[0]!;
    }
    return '$prefix $number';
  });
}

String _canonicalMedicineOcrSurface(String value) {
  var result = value
      .replaceAll(_medicineOcrCompatibilitySpaces, ' ')
      .replaceAll(_medicineOcrSlashVariants, '/')
      .replaceAll(_medicineOcrDashVariants, '-')
      .replaceAll(_medicineOcrDecimalVariants, '.')
      .replaceAll(_medicineOcrMicroVariants, 'u');

  // Normalize the full-width ASCII block before downstream field extraction.
  // This recovers full-width medicine names, Latin units and punctuation while
  // preserving the exact semantic characters (Ａ→A, ｍ→m, ５→5).
  result = result.replaceAllMapped(_medicineOcrFullWidthAscii, (match) {
    return String.fromCharCode(match[0]!.codeUnitAt(0) - 0xFEE0);
  });

  // Devanagari, Arabic-Indic and Eastern Arabic-Indic digits are ordinary
  // numeric evidence. Converting them once lets every strength/date consumer
  // operate on the same bounded ASCII representation.
  result = result.replaceAllMapped(_medicineOcrScriptDigits, (match) {
    final code = match[0]!.codeUnitAt(0);
    final zero = code >= 0x0966
        ? 0x0966
        : code >= 0x06F0
        ? 0x06F0
        : 0x0660;
    return (code - zero).toString();
  });

  // Normalize visibly separated strong labels first. Punctuation such as
  // PRODUCT-NAME or MANUFACTURER_NAME is presentation, not part of the value.
  result = result.replaceAllMapped(
    _medicineOcrExplicitSemanticLabel,
    (match) => _canonicalMedicineSemanticLabel(match[1]!),
  );

  // Recover fully collapsed strong semantic labels before any field parser sees
  // them. The replacement adds only the missing boundary; it never repairs or
  // guesses the value that follows the role.
  result = result.replaceAllMapped(
    _medicineOcrGluedSemanticLabel,
    (match) => '${_canonicalMedicineSemanticLabel(match[1]!)} ',
  );

  // Restore company-owner boundaries such as MANUFACTUREDBYACME and MFG.BYACME.
  result = result.replaceAllMapped(
    _medicineOcrGluedOwnerValue,
    (match) => '${match[1]} ${match[2]} ',
  );

  // Restore the role boundary when the first month digit itself was read as an
  // OCR-confusable O/I/l. The following real digit plus separator+year or a full
  // compact four-digit year is the safety proof; glyph-to-digit repair remains
  // owned by the date parser.
  result = result.replaceAllMapped(
    _medicineOcrGluedConfusableMonthYearRoleLabel,
    (match) => '${match[1]} ',
  );

  // Date roles can glue to a named month as well as to digits. Keep this narrow
  // to a complete month+year surface so words such as "expansion" are untouched.
  result = result.replaceAllMapped(
    _medicineOcrGluedNamedMonthRoleLabel,
    (match) => '${match[1]} ',
  );

  // Restore only role boundaries whose semantics are already known. This lets
  // the existing date/batch/price firewalls see the label instead of treating a
  // fused machine token as a possible medicine identity.
  result = result.replaceAllMapped(
    _medicineOcrGluedNumericRoleLabel,
    (match) => '${match[1]} ',
  );
  result = result.replaceAllMapped(_medicineOcrGluedTraceabilityLabel, (match) {
    // A token such as LOT100 can itself be the alphanumeric value of an already
    // explicit Batch/Lot role. Do not reinterpret an owned value as a new role.
    if (_medicineOcrUnsafeRoleOwnsCandidate(result, match.start)) {
      return match[0]!;
    }
    final qualifier = match[2];
    return qualifier == null ? '${match[1]} ' : '${match[1]} NO ';
  });

  // Recover a fully collapsed composition basis without inventing any medicine
  // fact. The printed denominator is retained and later binds only composition-
  // owned strengths through the existing bounded concentration logic.
  result = result.replaceAllMapped(_medicineOcrGluedCompositionBasis, (match) {
    final number = match[2]!;
    if (!_medicineOcrAsciiDigit.hasMatch(number)) return match[0]!;
    return '${match[1]} ${_repairMedicineOcrDigitToken(number)} ${match[3]!.toLowerCase()} contains ';
  });

  // A form can be glued immediately after the dose unit. Split only against the
  // shared pharmaceutical-form vocabulary, then let the existing dose boundary
  // recovery handle the medicine-token side. Example: CALPOL500MGTablets.
  result = result.replaceAllMapped(
    _medicineOcrGluedUnitForm,
    (match) => '${match[1]} ',
  );

  // Recover a lost boundary such as "Paracetamol5O0MG" or "CALPOL500MG".
  // Traceability context remains fused on purpose so its internal digits cannot
  // become competing strength evidence downstream.
  result = _separateMedicineOcrGluedDose(result);

  // OCR engines sometimes fragment a printed number into one-character tokens,
  // e.g. "6 5 0 mg". Join only a short digit run that is immediately owned by
  // a pharmaceutical unit, so dates, batch IDs and ordinary prose are untouched.
  result = result.replaceAllMapped(
    _medicineOcrSeparatedDigitsBeforeUnit,
    (match) => match[1]!.replaceAll(_medicineOcrWhitespace, ''),
  );

  // Preserve decimals when OCR inserts spaces around the punctuation. This is a
  // lexical cleanup only; date-role logic still decides whether a numeric value
  // is a date, and strength logic still requires a pharmaceutical unit.
  result = result.replaceAllMapped(
    _medicineOcrSpacedDecimal,
    (match) => '${match[1]}${match[2]}${match[3]}',
  );

  // Full-word units are common on labels and imported OCR. Canonicalize them
  // only when directly attached to a numeric token. Pure prose such as
  // "milligrams per tablet" is deliberately left alone.
  result = result.replaceAllMapped(_medicineOcrSpelledUnit, (match) {
    final number = match[1]!;
    if (!_medicineOcrAsciiDigit.hasMatch(number)) return match[0]!;
    final repaired = _repairMedicineOcrDigitToken(number);
    return '$repaired ${_canonicalMedicineUnitWord(match[2]!)}';
  });

  // A common ML/OCR confusion is lowercase-L in the volume unit being read as
  // digit one ("5 m1"). Repair only a numeric, unit-owned token.
  result = result.replaceAllMapped(_medicineOcrMlConfusion, (match) {
    final number = match[1]!;
    if (!_medicineOcrAsciiDigit.hasMatch(number)) return match[0]!;
    return '${_repairMedicineOcrDigitToken(number)} ml';
  });

  // Indian packaging commonly prints a thousands separator in 1,000 mg. The
  // downstream strength grammar treats comma as a decimal marker, so disambiguate
  // the unambiguous non-zero thousands shape before extraction. "0,500 mg"
  // remains a decimal-comma value.
  result = result.replaceAllMapped(
    _medicineOcrThousandsBeforeUnit,
    (match) => '${match[1]}${match[2]}',
  );

  // Restore a slash only when OCR fused two complete unit-owned numeric tokens.
  // At least one genuine digit must survive in each token before O/0-I/l repair;
  // this prevents all-letter accidents from manufacturing a concentration.
  // Explicit field ownership stays protected, but completed PACK/MRP/date text
  // elsewhere on the same OCR line no longer poisons a later medicine strength.
  result = result.replaceAllMapped(_medicineOcrFusedConcentration, (match) {
    final numerator = match[1]!;
    final denominator = match[3]!;
    if (!_medicineOcrAsciiDigit.hasMatch(numerator) ||
        !_medicineOcrAsciiDigit.hasMatch(denominator)) {
      return match[0]!;
    }
    if (_medicineOcrUnsafeRoleOwnsCandidate(result, match.start)) {
      return match[0]!;
    }
    final numeratorUnit = match[2]!.toLowerCase();
    return '${_repairMedicineOcrDigitToken(numerator)} $numeratorUnit/${_repairMedicineOcrDigitToken(denominator)} ml';
  });

  // O/0 and I/l/1 are repaired only inside a numeric token immediately owned
  // by a pharmaceutical unit. At least one real digit is required, so product
  // words such as OIL/ILL can never be converted into invented strengths.
  result = result.replaceAllMapped(_medicineOcrUnitBoundNumber, (match) {
    final token = match[1]!;
    if (!_medicineOcrAsciiDigit.hasMatch(token)) return token;
    return _repairMedicineOcrDigitToken(token);
  });

  // Normalize concentration prose into the slash grammar already consumed by
  // the deterministic extractor: "125 mg per 5 millilitres" -> "125 mg/5 ml".
  // The rewrite is intentionally impossible without a numeric pharmaceutical
  // numerator, which prevents ordinary English "per" phrases from changing.
  result = result.replaceAllMapped(_medicineOcrPerConcentration, (match) {
    final denominator = match[2];
    final unit = _canonicalMedicineDenominatorUnit(match[3]!);
    return denominator == null
        ? '${match[1]}/$unit'
        : '${match[1]}/$denominator $unit';
  });

  // Map only semantically constrained ingredient-dose separators onto the one
  // '+' grammar consumed by the unlabeled composition resolver. A machine field
  // must immediately own the candidate to veto it; a completed MRP/date/pack
  // elsewhere on a flattened OCR line is no longer treated as global poison.
  result = result.replaceAllMapped(_medicineOcrCombinationSeparator, (match) {
    if (_medicineOcrUnsafeRoleOwnsCandidate(result, match.start)) {
      return match[0]!;
    }
    return '${match[1]} + ';
  });

  // Liquid labels very often express the denominator before the ingredients:
  // "Each 5 ml contains Paracetamol 125 mg". Bind that explicit basis only to
  // the composition-owned clause. OCR sometimes flattens a following dose,
  // storage, date or legal row into the same line; letting the 5 ml basis leak
  // across that role boundary would fabricate concentrations such as a printed
  // "Dose 250 mg" becoming "250 mg/5 ml". The suffix is preserved verbatim and
  // continues through downstream evidence/review, but it cannot inherit the
  // composition denominator.
  final basis = _medicineOcrCompositionBasis.firstMatch(result);
  if (basis != null) {
    final denominator = basis[1]!;
    final denominatorUnit = basis[2]!.toLowerCase();
    final head = result.substring(0, basis.end);
    final tail = result.substring(basis.end);
    final stop = _medicineOcrCompositionStop.firstMatch(tail);
    final ownedTail = stop == null ? tail : tail.substring(0, stop.start);
    final suffix = stop == null ? '' : tail.substring(stop.start);
    var rewrites = 0;
    final boundTail = ownedTail.replaceAllMapped(
      _medicineOcrBasisOwnedStrength,
      (match) {
        if (rewrites >= 6) return match[0]!;
        final before = ownedTail.substring(0, match.start).trimRight();
        if (before.endsWith('/')) return match[0]!;
        rewrites++;
        return '${match[1]}/$denominator $denominatorUnit';
      },
    );
    result = '$head;$boundTail$suffix';
  }

  return result.replaceAll(_medicineOcrWhitespace, ' ').trim();
}

/// Canonical OCR surface consumed by both flattened text and geometry evidence.
/// The transformation is semantic-preserving and intentionally bounded.
String normalizeMedicineOcrLine(String value) =>
    _canonicalMedicineOcrSurface(_cleanMedicineOcrLine(value));

/// Preserve printed punctuation/numbers when deduplicating OCR. Fuzzy string
/// similarity is not identity: 650 vs 850 mg and 0.5 vs 5 mg can be >96% similar
/// on a long composition line. Both readings must reach the conflict resolver.
String medicineOcrLineKey(String value) =>
    normalizeMedicineOcrLine(value).toLowerCase();

List<String> mergeMedicineOcrLines(Iterable<String> raw) {
  final seen = <String>{};
  final result = <String>[];
  for (final line in raw.take(500)) {
    final value = normalizeMedicineOcrLine(line);
    if (value.length < 2 || !seen.add(value.toLowerCase())) continue;
    result.add(value);
  }
  // Do not move later dose/date lines before their intervening product headings.
  // LocalScanEvidence is responsible for bounded, explicitly separated spans.
  return result;
}

double medicineOcrLineQuality(String value) {
  final clean = normalizeMedicineOcrLine(value);
  if (clean.isEmpty) return 0;
  var useful = 0, replacement = 0, runes = 0;
  for (final code in clean.runes) {
    runes++;
    if ((code >= 48 && code <= 57) ||
        (code >= 65 && code <= 90) ||
        (code >= 97 && code <= 122) ||
        (code >= 0x0900 && code <= 0x097F)) {
      useful++;
    }
    if (code == 0xFFFD || code == 0x7C || code == 0x7B || code == 0x7D) {
      replacement++;
    }
  }
  if (runes == 0) return 0;
  // This value is consumed as a bounded quality signal. Corrupt OCR can contain
  // many replacement glyphs, so keep the public contract mathematically inside
  // [0, 1] instead of leaking a negative score into duplicate-selection logic.
  return (useful / runes - replacement * .08).clamp(0.0, 1.0).toDouble();
}
