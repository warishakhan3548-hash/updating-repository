final medicineManufacturingLabel = RegExp(
  r'(?<![A-Za-z])(?:m[.\s]*f[.\s]*[gd](?![.\s]*(?:by|at)\b)\.?(?:[\s.:_-]*(?:date|dt|on))?|d[.\s]*o[.\s]*m\.?(?:[\s.:_-]*(?:date|dt|on))?|(?:date\s*of\s*)?manufactur(?:e|ed|ing)(?![A-Za-z]|\s+(?:by|at)\b)(?:\s*(?:date|dt|on))?|prod(?:uction)?\.?\s*(?:date|dt)|date\s+of\s+m[.\s]*f[.\s]*[gd]\.?|mfr\.?\s*(?:date|dt)|निर्माण\s*(?:तिथि|दिनांक)?)(?=$|[^A-Za-z]|[OoIlL०-९٠-٩۰-۹０-９](?=[0-9०-९٠-٩۰-۹０-９OoIlL]{3,}(?:$|[^A-Za-z0-9])))',
  caseSensitive: false,
);
final medicineExpiryLabel = RegExp(
  r'(?<![A-Za-z])(?:e[.\s]*x[.\s]*p\.?(?:iry|ires|iration)?(?:[\s.:_-]*(?:date|dt|on))?|d[.\s]*o[.\s]*e\.?(?:[\s.:_-]*(?:date|dt|on))?|date\s+of\s+(?:expiry|expiration)|b[.\s]*b[.\s]*e\.?(?:[\s.:_-]*(?:date|dt|on))?|e[.\s]*[./-][.\s]*d\.?(?:[\s.:_-]*(?:date|dt|on))?|xpry(?:[\s.:_-]*(?:date|dt|on))?|expn\.?(?:[\s.:_-]*(?:date|dt|on))?|use\s*(?:before|by|till|until|up\s*to|upto)|best\s*before(?:\s*end)?|valid\s*(?:till|until|upto|up\s*to)|समाप्ति\s*(?:तिथि|दिनांक)?)(?=$|[^A-Za-z]|[OoIlL०-९٠-٩۰-۹０-９](?=[0-9०-९٠-٩۰-۹０-９OoIlL]{3,}(?:$|[^A-Za-z0-9])))',
  caseSensitive: false,
);
final medicineNonDateLabel = RegExp(
  r'(?<![A-Za-z])(?:batch(?:[\s.:_-]*(?:no|number)\.?)?|lot(?:[\s.:_-]*no\.?)?|b[.\s]*no\.?|serial|barcode|gtin|mrp|price|licen[cs]e|pack\s*size|p[.\s]*k[.\s]*(?:d|g)\.?(?:[\s.:_-]*(?:date|dt|on))?|date\s+of\s+packing|pack(?:ed|ing)?\s*(?:date|dt|on)|m[.\s]*f[.\s]*[gd][.\s]*(?:by|at)|manufactur(?:ed|er)\s+(?:by|at)|marketed\s+by|distributed\s+by|imported\s+by)(?=$|[^A-Za-z]|[OoIlL०-९٠-٩۰-۹０-９](?=[0-9०-९٠-٩۰-۹０-９OoIlL]{3,}(?:$|[^A-Za-z0-9])))',
  caseSensitive: false,
);

final _medicineCompactDatePrefix = RegExp(
  r'(?:m[.\s]*f[.\s]*[gd]\.?|e[.\s]*x[.\s]*p\.?(?:iry|ires|iration)?|d[.\s]*o[.\s]*[me]\.?|b[.\s]*b[.\s]*e\.?|e[.\s]*[./-][.\s]*d\.?|xpry|expn\.?|prod(?:uction)?\.?\s*(?:date|dt)|date\s+of\s+m[.\s]*f[.\s]*[gd]\.?|mfr\.?\s*(?:date|dt)|use\s*(?:before|by|till|until|up\s*to|upto)|best\s*before(?:\s*end)?|valid\s*(?:till|until|upto|up\s*to))'
  r'(?:[\s.:_-]*(?:date|dt|on))?[\s.:_-]*$',
  caseSensitive: false,
);

/// Calendar parsing shared by OCR extraction, spatial labels and date reasoning.
/// Parsing a value does not decide whether it is MFG, EXP, a batch or a barcode.
class ParsedMedicineDate {
  const ParsedMedicineDate({required this.value, required this.monthOnly});

  final String value;
  final bool monthOnly;

  DateTime get start {
    final parts = value.split('-').map(int.parse).toList(growable: false);
    return DateTime.utc(parts[0], parts[1], parts.length > 2 ? parts[2] : 1);
  }

  DateTime get end {
    if (!monthOnly) return start;
    final parts = value.split('-').map(int.parse).toList(growable: false);
    return DateTime.utc(parts[0], parts[1] + 1, 0);
  }
}

class MedicineDateMatch {
  const MedicineDateMatch(
    this.start,
    this.end,
    this.date, {
    this.compact = false,
  });
  final int start, end;
  final ParsedMedicineDate date;

  /// True when a separator-less token is still role-unsafe without a date
  /// label. Unambiguous 8-digit full dates are deliberately false: downstream
  /// chronology may use a coherent pair, while a singleton remains only a
  /// sub-threshold hint and non-date labels still veto the value.
  final bool compact;
}

/// Call with compact forms enabled only in a date-valued context. India-facing
/// printed dates use day/month/year; GS1 YYMMDD is decoded separately from its AI.
/// Ambiguous six-digit day/month/two-digit-year numbers are never guessed here.
ParsedMedicineDate? parseMedicineDateText(
  String raw, {
  bool allowCompact = true,
}) {
  final matches = extractMedicineDateMatches(raw, allowCompact: allowCompact);
  return matches.isEmpty ? null : matches.first.date;
}

List<MedicineDateMatch> extractMedicineDateMatches(
  String raw, {
  bool allowCompact = false,
}) {
  final text = _repairNumericOcr(raw);
  final result = <MedicineDateMatch>[];
  final occupied = <(int, int)>[];

  void add(
    RegExp pattern,
    ParsedMedicineDate? Function(RegExpMatch) parse, {
    bool compact = false,
  }) {
    for (final match in pattern.allMatches(text)) {
      if (occupied.any(
        (span) => match.start < span.$2 && match.end > span.$1,
      )) {
        continue;
      }
      // Reserve the complete syntactic surface before semantic/boundary
      // rejection. This prevents an embedded or invalid full date such as
      // A32/02/2027 from degrading into the plausible-looking 02/2027 tail.
      occupied.add((match.start, match.end));
      final before = text.substring(0, match.start);
      final after = text.substring(match.end);
      if (RegExp(r'[A-Za-z0-9]$').hasMatch(before) &&
          !_medicineCompactDatePrefix.hasMatch(before)) {
        continue;
      }
      if (RegExp(r'^[A-Za-z0-9]').hasMatch(after)) continue;
      final date = parse(match);
      if (date != null) {
        result.add(
          MedicineDateMatch(match.start, match.end, date, compact: compact),
        );
      }
    }
  }

  // A whitespace-only separator is deliberately bounded. OCR/layout mergers
  // often render two printed columns as "04/2026       04/2028"; unlimited
  // whitespace previously allowed the tail of the first value and head of the
  // second to be parsed as a synthetic cross-column date. Punctuation may
  // still have arbitrary surrounding whitespace because it is an explicit
  // separator on the package.
  const sep = r'(?:\s{1,3}|\s*[,./-]\s*)';
  add(
    RegExp('(?<!\\d)(20\\d{2})$sep(\\d{1,2})$sep(\\d{1,2})(?!\\d)'),
    (m) => _date(int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!)),
  );
  add(
    RegExp('(?<!\\d)(\\d{1,2})$sep(\\d{1,2})$sep(20\\d{2}|\\d{2})(?!\\d)'),
    (m) => _date(_year(m[3]!), int.parse(m[2]!), int.parse(m[1]!)),
  );

  // English and Hindi named months share one calendar grammar. Script digits
  // are normalized before parsing, so a pack such as "अप्रैल २०२८" reaches the
  // same chronology engine as "APR 2028" instead of falling through merely
  // because the already-recognized Hindi MFG/EXP role used a Hindi month word.
  const monthNames =
      r'JAN(?:UARY)?|FEB(?:RUARY)?|MAR(?:CH)?|APR(?:IL)?|MAY|JUN(?:E)?|JUL(?:Y)?|AUG(?:UST)?|SEP(?:T(?:EMBER)?)?|OCT(?:OBER)?|NOV(?:EMBER)?|DEC(?:EMBER)?|'
      r'जनवरी|फरवरी|फ़रवरी|फ़रवरी|मार्च|अप्रैल|मई|जून|जुलाई|अगस्त|सितंबर|सितम्बर|अक्टूबर|नवंबर|नवम्बर|दिसंबर|दिसम्बर';
  const namedMonthBoundary = r'A-Za-z0-9\u0900-\u097F';

  add(
    RegExp(
      '(?<![$namedMonthBoundary])(\\d{1,2})$sep($monthNames)$sep(20\\d{2}|\\d{2})(?![$namedMonthBoundary])',
      caseSensitive: false,
    ),
    (m) => _date(_year(m[3]!), _month(m[2]!), int.parse(m[1]!)),
  );
  // A named month also makes MONTH DAY YEAR unambiguous when the final
  // year has four digits. Reserve the whole surface before validating it:
  // "APR 31, 2028" must not degrade into the month-only date "APR 31".
  add(
    RegExp(
      '(?<![$namedMonthBoundary])($monthNames)$sep(\\d{1,2})$sep(20\\d{2})(?![$namedMonthBoundary])',
      caseSensitive: false,
    ),
    (m) => _date(int.parse(m[3]!), _month(m[1]!), int.parse(m[2]!)),
  );
  // Year-first named dates are unambiguous when a four-digit year and literal
  // month word are both present. Supporting this common import/OCR order costs
  // no fuzzy guessing and remains inside the same calendar validator.
  add(
    RegExp(
      '(?<![$namedMonthBoundary])(20\\d{2})$sep($monthNames)$sep(\\d{1,2})(?![$namedMonthBoundary])',
      caseSensitive: false,
    ),
    (m) => _date(int.parse(m[1]!), _month(m[2]!), int.parse(m[3]!)),
  );
  add(
    RegExp(
      '(?<![$namedMonthBoundary])($monthNames)$sep(20\\d{2}|\\d{2})(?![$namedMonthBoundary])',
      caseSensitive: false,
    ),
    (m) => _date(_year(m[2]!), _month(m[1]!), null),
  );
  add(
    RegExp(
      '(?<![$namedMonthBoundary])(20\\d{2})$sep($monthNames)(?![$namedMonthBoundary])',
      caseSensitive: false,
    ),
    (m) => _date(int.parse(m[1]!), _month(m[2]!), null),
  );
  add(
    RegExp('(?<!\\d)(20\\d{2})$sep(\\d{1,2})(?!\\d)'),
    (m) => _date(int.parse(m[1]!), int.parse(m[2]!), null),
  );
  add(
    RegExp('(?<!\\d)(\\d{1,2})$sep(20\\d{2}|\\d{2})(?!\\d)'),
    (m) => _date(_year(m[2]!), int.parse(m[1]!), null),
  );

  if (allowCompact) {
    // OCR frequently drops punctuation around alphabetic month names. Month
    // letters are strong date syntax, but a glued token is still marked compact
    // so an unlabeled singleton cannot become an authoritative EXP/MFG fact.
    add(
      RegExp(
        '(?<![$namedMonthBoundary])(\\d{1,2})($monthNames)(20\\d{2}|\\d{2})(?![$namedMonthBoundary])',
        caseSensitive: false,
      ),
      (m) => _date(_year(m[3]!), _month(m[2]!), int.parse(m[1]!)),
      compact: true,
    );
    add(
      RegExp(
        '(?<![$namedMonthBoundary])($monthNames)(20\\d{2}|\\d{2})(?![$namedMonthBoundary])',
        caseSensitive: false,
      ),
      (m) => _date(_year(m[2]!), _month(m[1]!), null),
      compact: true,
    );

    // Four-digit years make an 8-digit full date self-validating enough for the
    // downstream chronology engine: try both DDMMYYYY and YYYYMMDD and accept
    // only one unique valid calendar interpretation. It is not marked role-
    // unsafe compact, so two separator-less dates can form an MFG/EXP pair even
    // when OCR dropped every label. A lone value still cannot auto-fill because
    // date intelligence keeps an unlabeled singleton below its apply threshold.
    add(RegExp(r'(?<!\d)(\d{8})(?!\d)'), (m) {
      final digits = m[1]!;
      final candidates = <ParsedMedicineDate>[];
      void keep(int year, int month, int? day) {
        final date = _date(year, month, day);
        if (date != null &&
            !candidates.any((other) => other.value == date.value)) {
          candidates.add(date);
        }
      }

      keep(
        int.parse(digits.substring(4)),
        int.parse(digits.substring(2, 4)),
        int.parse(digits.substring(0, 2)),
      );
      keep(
        int.parse(digits.substring(0, 4)),
        int.parse(digits.substring(4, 6)),
        int.parse(digits.substring(6)),
      );
      return candidates.length == 1 ? candidates.single : null;
    });

    // Six digits can only be MMYYYY/YYYYMM here. They are much easier to
    // confuse with a lot/serial code, so preserve the compact marker and let
    // date intelligence require an explicit/adjacent date label or an isolated
    // coherent two-date chronology.
    add(RegExp(r'(?<!\d)(\d{6})(?!\d)'), (m) {
      final digits = m[1]!;
      final candidates = <ParsedMedicineDate>[];
      void keep(int year, int month) {
        final date = _date(year, month, null);
        if (date != null &&
            !candidates.any((other) => other.value == date.value)) {
          candidates.add(date);
        }
      }

      keep(int.parse(digits.substring(2)), int.parse(digits.substring(0, 2)));
      keep(int.parse(digits.substring(0, 4)), int.parse(digits.substring(4)));
      return candidates.length == 1 ? candidates.single : null;
    }, compact: true);

    // Many Indian packs print month/year as MM/YY and OCR may drop the slash,
    // yielding four digits such as 0428. Treat this only as compact date syntax:
    // semantic date intelligence still requires an owning date label or exactly
    // two isolated values forming a plausible MFG→EXP shelf-life chronology.
    // A singleton "0428" therefore never becomes an authoritative date by itself.
    add(
      RegExp(r'(?<!\d)(\d{4})(?!\d)'),
      (m) {
        final digits = m[1]!;
        return _date(
          _year(digits.substring(2)),
          int.parse(digits.substring(0, 2)),
          null,
        );
      },
      compact: true,
    );
  }
  result.sort((a, b) => a.start.compareTo(b.start));
  return result;
}

ParsedMedicineDate? _date(int year, int month, int? day) {
  if (year < 2000 || year > 2099 || month < 1 || month > 12) return null;
  final prefix =
      '${year.toString().padLeft(4, '0')}-${month.toString().padLeft(2, '0')}';
  if (day == null) return ParsedMedicineDate(value: prefix, monthOnly: true);
  if (day < 1 || day > 31) return null;
  final date = DateTime.utc(year, month, day);
  if (date.year != year || date.month != month || date.day != day) return null;
  return ParsedMedicineDate(
    value: '$prefix-${day.toString().padLeft(2, '0')}',
    monthOnly: false,
  );
}

int _year(String value) =>
    value.length == 2 ? 2000 + int.parse(value) : int.parse(value);

int _month(String value) {
  final key = value.trim().toLowerCase();
  final hindi = const <String, int>{
    'जनवरी': 1,
    'फरवरी': 2,
    'फ़रवरी': 2,
    'फ़रवरी': 2,
    'मार्च': 3,
    'अप्रैल': 4,
    'मई': 5,
    'जून': 6,
    'जुलाई': 7,
    'अगस्त': 8,
    'सितंबर': 9,
    'सितम्बर': 9,
    'अक्टूबर': 10,
    'नवंबर': 11,
    'नवम्बर': 11,
    'दिसंबर': 12,
    'दिसम्बर': 12,
  }[key];
  if (hindi != null) return hindi;
  if (key.length < 3) return 0;
  return const {
        'jan': 1,
        'feb': 2,
        'mar': 3,
        'apr': 4,
        'may': 5,
        'jun': 6,
        'jul': 7,
        'aug': 8,
        'sep': 9,
        'oct': 10,
        'nov': 11,
        'dec': 12,
      }[key.substring(0, 3)] ??
      0;
}

String _repairNumericOcr(String raw) {
  // Replace directional/invisible OCR artifacts one-for-one so date offsets
  // stay aligned with the original line used by spatial/role reasoning.
  var text = raw
      .replaceAll(
        RegExp(r'[\u200B-\u200F\u202A-\u202E\u2060\u2066-\u2069\uFEFF]'),
        ' ',
      )
      .replaceAll(RegExp(r'[\u00A0\u2007\u202F\u3000]'), ' ')
      .replaceAll(RegExp(r'[／⁄∕]'), '/')
      .replaceAll(RegExp(r'[‐‑‒–—−]'), '-')
      .replaceAll(RegExp(r'[٫．]'), '.');

  // Geometry-aware date evidence can reach this parser before the general OCR
  // canonicalizer. Normalize the full-width ASCII block one code point to one
  // code point so labels (ＭＦＧ/ＥＸＰ), digits and punctuation are readable
  // without changing spatial character offsets.
  text = text.replaceAllMapped(RegExp(r'[\uFF01-\uFF5E]'), (m) {
    return String.fromCharCode(m[0]!.codeUnitAt(0) - 0xFEE0);
  });

  // One-to-one digit replacements also keep detector character offsets intact.
  text = text.replaceAllMapped(RegExp(r'[०-९٠-٩۰-۹０-９]'), (m) {
    final code = m[0]!.codeUnitAt(0);
    final zero = code >= 0xFF10
        ? 0xFF10
        : code >= 0x0966
        ? 0x0966
        : code >= 0x06F0
        ? 0x06F0
        : 0x0660;
    return (code - zero).toString();
  });

  // OCR frequently glues a date directly to its field label and reads 0/1 as
  // O/I/l/L. Repair only this tightly bounded label-adjacent token first;
  // global letter-to-digit replacement would corrupt medicine names/batch IDs.
  text = text.replaceAllMapped(
    RegExp(
      r'((?:m[.\s]*f[.\s]*[gd]\.?|e[.\s]*x[.\s]*p\.?(?:iry|ires|iration)?|d[.\s]*o[.\s]*[me]\.?|b[.\s]*b[.\s]*e\.?|e[.\s]*[./-][.\s]*d\.?|xpry|expn\.?|prod(?:uction)?\.?\s*(?:date|dt)|date\s+of\s+m[.\s]*f[.\s]*[gd]\.?|mfr\.?\s*(?:date|dt)|use\s*(?:before|by|till|until|up\s*to|upto)|best\s*before(?:\s*end)?|valid\s*(?:till|until|upto|up\s*to))'
      r'(?:[\s.:_-]*(?:date|dt|on))?[\s.:_-]*)([0-9OoIlL]{4,8})(?![A-Za-z0-9])',
      caseSensitive: false,
    ),
    (m) => '${m[1]!}${_repairOcrDigitToken(m[2]!)}',
  );

  return text.replaceAllMapped(
    RegExp(r'(?<![A-Za-z0-9])([0-9OoIlL]{1,8})(?![A-Za-z0-9])'),
    (m) {
      final token = m[1]!;
      // Require at least one real digit before interpreting O/I/l/L as numeric
      // OCR confusions. Pure words such as OIL or LOLL must never be converted
      // into identifier-like 0/1 strings that can masquerade as compact dates.
      if (!RegExp(r'\d').hasMatch(token)) return token;
      return _repairOcrDigitToken(token);
    },
  );
}

String _repairOcrDigitToken(String value) => value
    .replaceAll(RegExp('[Oo]'), '0')
    .replaceAll(RegExp('[IlL]'), '1');
