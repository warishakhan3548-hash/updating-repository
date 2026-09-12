final medicineManufacturingLabel = RegExp(
  r'(?<![A-Za-z])(?:m[.\s]*f[.\s]*[gd]\.?(?:\s*date)?|(?:date\s*of\s*)?manufactur(?:e|ed|ing)(?![A-Za-z]|\s+by)(?:\s*(?:date|on))?|production\s*date|निर्माण\s*(?:तिथि|दिनांक)?)(?![A-Za-z])',
  caseSensitive: false,
);
final medicineExpiryLabel = RegExp(
  r'(?<![A-Za-z])(?:e[.\s]*x[.\s]*p\.?(?:iry|ires|iration)?(?:\s*date)?|use\s*(?:before|by)|best\s*before|समाप्ति\s*(?:तिथि|दिनांक)?)(?![A-Za-z])',
  caseSensitive: false,
);
final medicineNonDateLabel = RegExp(
  r'\b(?:batch(?:\s*(?:no|number))?|lot(?:\s*no)?|b\s*no|serial|barcode|gtin|mrp|price|licen[cs]e|pack\s*size)\b',
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
      // Reserve invalid full dates too: 32/02/2027 must not become 02/2027.
      occupied.add((match.start, match.end));
      final before = text.substring(0, match.start);
      final after = text.substring(match.end);
      if (RegExp(r'[A-Za-z0-9]$').hasMatch(before) &&
          !RegExp(
            r'(?<![A-Za-z])(?:mfg|mfd|exp)(?:date)?$',
            caseSensitive: false,
          ).hasMatch(before)) {
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

  const sep = r'[\s,./-]+';
  add(
    RegExp('(?<!\\d)(20\\d{2})$sep(\\d{1,2})$sep(\\d{1,2})(?!\\d)'),
    (m) => _date(int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!)),
  );
  add(
    RegExp('(?<!\\d)(\\d{1,2})$sep(\\d{1,2})$sep(20\\d{2}|\\d{2})(?!\\d)'),
    (m) => _date(_year(m[3]!), int.parse(m[2]!), int.parse(m[1]!)),
  );
  const monthNames =
      r'JAN(?:UARY)?|FEB(?:RUARY)?|MAR(?:CH)?|APR(?:IL)?|MAY|JUN(?:E)?|JUL(?:Y)?|AUG(?:UST)?|SEP(?:T(?:EMBER)?)?|OCT(?:OBER)?|NOV(?:EMBER)?|DEC(?:EMBER)?';
  add(
    RegExp(
      '(?<![A-Za-z0-9])(\\d{1,2})$sep($monthNames)[\\s,./-]+(20\\d{2}|\\d{2})(?!\\d)',
      caseSensitive: false,
    ),
    (m) => _date(_year(m[3]!), _month(m[2]!), int.parse(m[1]!)),
  );
  add(
    RegExp(
      '(?<![A-Za-z0-9])($monthNames)[\\s,./-]+(20\\d{2}|\\d{2})(?!\\d)',
      caseSensitive: false,
    ),
    (m) => _date(_year(m[2]!), _month(m[1]!), null),
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
    // Four-digit years disambiguate DDMMYYYY / YYYYMMDD and MMYYYY / YYYYMM.
    // Evaluate the complete token; never extract a date from inside a GTIN.
    add(RegExp(r'(?<!\d)(\d{8}|\d{6})(?!\d)'), (m) {
      final digits = m[1]!;
      final candidates = <ParsedMedicineDate>[];
      void keep(int year, int month, int? day) {
        final date = _date(year, month, day);
        if (date != null &&
            !candidates.any((other) => other.value == date.value)) {
          candidates.add(date);
        }
      }

      if (digits.length == 8) {
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
      } else {
        keep(
          int.parse(digits.substring(2)),
          int.parse(digits.substring(0, 2)),
          null,
        );
        keep(
          int.parse(digits.substring(0, 4)),
          int.parse(digits.substring(4)),
          null,
        );
      }
      return candidates.length == 1 ? candidates.single : null;
    }, compact: true);
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

int _month(String value) =>
    const {
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
    }[value.substring(0, 3).toLowerCase()] ??
    0;

String _repairNumericOcr(String raw) {
  // One-to-one replacements keep detector character offsets intact.
  final digits = raw.replaceAllMapped(RegExp(r'[०-९٠-٩۰-۹]'), (m) {
    final code = m[0]!.codeUnitAt(0);
    final zero = code >= 0x966
        ? 0x966
        : code >= 0x6f0
        ? 0x6f0
        : 0x660;
    return (code - zero).toString();
  });
  return digits.replaceAllMapped(
    RegExp(r'(?<![A-Za-z0-9])([0-9OoIl]{1,8})(?![A-Za-z0-9])'),
    (m) {
      final token = m[1]!;
      if (!RegExp(r'\d').hasMatch(token) && token.length == 1) return token;
      return token
          .replaceAll(RegExp('[Oo]'), '0')
          .replaceAll(RegExp('[Il]'), '1');
    },
  );
}
