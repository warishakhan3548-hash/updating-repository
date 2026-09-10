enum RemovalReasonHint { expired, damaged, returned, correction, soldOut }

extension RemovalReasonHintDetails on RemovalReasonHint {
  String? get archiveReason => switch (this) {
    RemovalReasonHint.expired => 'Expired',
    RemovalReasonHint.damaged => 'Damaged',
    RemovalReasonHint.returned => 'Returned',
    RemovalReasonHint.correction => 'Correction',
    RemovalReasonHint.soldOut => null,
  };

  List<String> get commandTerms => switch (this) {
    RemovalReasonHint.expired => const [
      'expired',
      'expire ho gayi',
      'expiry ho gayi',
      'एक्सपायर्ड',
      'एक्सपायर',
    ],
    RemovalReasonHint.damaged => const [
      'damaged',
      'damage',
      'broken',
      'kharab',
      'खराब',
      'डैमेज',
    ],
    RemovalReasonHint.returned => const [
      'returned',
      'return',
      'supplier return',
      'wapas',
      'वापस',
      'रिटर्न',
    ],
    RemovalReasonHint.correction => const [
      'correction',
      'wrong entry',
      'galat entry',
      'mistake',
      'गलत एंट्री',
      'करेक्शन',
    ],
    RemovalReasonHint.soldOut => const [
      'sold',
      'sold out',
      'stock finished',
      'stock khatam',
      'bik gaya',
      'बिक गया',
      'स्टॉक खत्म',
    ],
  };
}

RemovalReasonHint? detectRemovalReason(String raw) {
  final text = _normalized(raw);
  for (final reason in const [
    RemovalReasonHint.soldOut,
    RemovalReasonHint.expired,
    RemovalReasonHint.damaged,
    RemovalReasonHint.returned,
    RemovalReasonHint.correction,
  ]) {
    if (reason.commandTerms.any((term) => _containsPhrase(text, term))) {
      return reason;
    }
  }
  return null;
}

class StockLocationPatch {
  const StockLocationPatch({
    this.block,
    this.row,
    this.vertical,
    this.location,
  });

  const StockLocationPatch.clear()
    : block = '',
      row = '',
      vertical = '',
      location = '';

  final String? block;
  final String? row;
  final String? vertical;
  final String? location;

  bool get isEmpty =>
      block == null && row == null && vertical == null && location == null;

  bool get clearsEverything =>
      block == '' && row == '' && vertical == '' && location == '';
}

class ParsedStockLocationCommand {
  const ParsedStockLocationCommand({required this.query, required this.patch});

  final String query;
  final StockLocationPatch patch;
}

ParsedStockLocationCommand? parseStockLocationCommand(String raw) {
  if (raw.trim().isEmpty || raw.length > 500) return null;
  final normalized = _normalized(raw);
  if (!_containsAny(normalized, _locationMutationVerbs)) return null;

  final clearMatch = RegExp(
    r'(?:location|shelf|rack|लोकेशन|शेल्फ|रैक|जगह)\s*(?:clear|empty|remove|hatao|hata do|खाली|हटाओ|हटा दो)(?:\s*(?:karo|kar do|करो|कर दो))?',
    caseSensitive: false,
    unicode: true,
  ).firstMatch(raw);
  if (clearMatch != null) {
    final target = _targetAfterRemoving(raw, [
      _TextSpan(clearMatch.start, clearMatch.end),
    ]);
    return ParsedStockLocationCommand(
      query: target,
      patch: const StockLocationPatch.clear(),
    );
  }

  final spans = <_TextSpan>[];
  String? block;
  String? row;
  String? vertical;

  String? tagged(RegExp expression, String label) {
    final matches = expression.allMatches(raw).toList(growable: false);
    if (matches.length > 1) {
      throw FormatException('Use only one $label value in a location command.');
    }
    if (matches.isEmpty) return null;
    final match = matches.single;
    final value = _boundedLocationValue(match.group(1) ?? '', label, 40);
    if (_reservedLocationValue(value)) {
      throw FormatException('A $label value is missing or ambiguous.');
    }
    spans.add(_TextSpan(match.start, match.end));
    return value;
  }

  block = tagged(
    RegExp(
      r'(?:block|ब्लॉक)\s*[:#=-]?\s*([A-Za-z0-9\u0900-\u097f._/-]{1,40})',
      caseSensitive: false,
      unicode: true,
    ),
    'block',
  );
  row = tagged(
    RegExp(
      r'(?:row|रो|पंक्ति)\s*[:#=-]?\s*([A-Za-z0-9\u0900-\u097f._/-]{1,40})',
      caseSensitive: false,
      unicode: true,
    ),
    'row',
  );
  vertical = tagged(
    RegExp(
      r'(?:vertical|vert|वर्टिकल)\s*[:#=-]?\s*([A-Za-z0-9\u0900-\u097f._/-]{1,40})',
      caseSensitive: false,
      unicode: true,
    ),
    'vertical',
  );

  String? location;
  if (block == null && row == null && vertical == null) {
    final free = RegExp(
      r'(?:location|shelf|rack|लोकेशन|शेल्फ|रैक|जगह)\s*[:#=-]?\s*(.{1,180}?)\s*(?:set(?:\s+(?:karo|kar do))?|move(?:\s+(?:karo|kar do))?|shift(?:\s+(?:karo|kar do))?|rakh(?:\s+do)?|rakho|सेट(?:\s+(?:करो|कर दो))?|मूव(?:\s+(?:करो|कर दो))?|शिफ्ट(?:\s+(?:करो|कर दो))?|रख(?:\s+दो)?|रखो)\s*$',
      caseSensitive: false,
      unicode: true,
    ).firstMatch(raw);
    if (free == null) return null;
    location = _boundedLocationValue(free.group(1) ?? '', 'location', 160);
    spans.add(_TextSpan(free.start, free.end));
  }

  final patch = sanitizeStockLocationPatch(
    StockLocationPatch(
      block: block,
      row: row,
      vertical: vertical,
      location: location,
    ),
  );
  if (patch.isEmpty) return null;
  final target = _targetAfterRemoving(raw, spans);
  return ParsedStockLocationCommand(query: target, patch: patch);
}

StockLocationPatch sanitizeStockLocationPatch(StockLocationPatch patch) {
  if (patch.isEmpty) {
    throw const FormatException('A stock location update is empty.');
  }
  String? clean(String? value, String label, int max) {
    if (value == null) return null;
    if (value.isEmpty) return '';
    return _boundedLocationValue(value, label, max);
  }

  return StockLocationPatch(
    block: clean(patch.block, 'block', 40),
    row: clean(patch.row, 'row', 40),
    vertical: clean(patch.vertical, 'vertical', 40),
    location: clean(patch.location, 'location', 160),
  );
}

String describeStockLocationPatch(StockLocationPatch patch) {
  if (patch.clearsEverything) return 'clear the saved stock location';
  final parts = <String>[
    if (patch.block != null) _locationPart('Block', patch.block!),
    if (patch.row != null) _locationPart('Row', patch.row!),
    if (patch.vertical != null) _locationPart('Vertical', patch.vertical!),
    if (patch.location != null) _locationPart('Location', patch.location!),
  ];
  return parts.join(' · ');
}

String _locationPart(String label, String value) =>
    value.isEmpty ? '$label: clear' : '$label: $value';

String _boundedLocationValue(String raw, String label, int max) {
  if (RegExp(r'[\u0000-\u001f\u007f]').hasMatch(raw)) {
    throw FormatException('Invalid control character in $label.');
  }
  final value = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (value.isEmpty || value.length > max) {
    throw FormatException('$label must be between 1 and $max characters.');
  }
  return value;
}

bool _reservedLocationValue(String value) => const {
  'block',
  'row',
  'vertical',
  'vert',
  'location',
  'shelf',
  'rack',
  'set',
  'move',
  'shift',
  'karo',
  'kar',
  'करो',
  'सेट',
  'मूव',
}.contains(_normalized(value));

class _TextSpan {
  const _TextSpan(this.start, this.end);
  final int start;
  final int end;
}

String _targetAfterRemoving(String raw, List<_TextSpan> spans) {
  var value = raw;
  final ordered = [...spans]..sort((a, b) => b.start.compareTo(a.start));
  for (final span in ordered) {
    value = value.replaceRange(span.start, span.end, ' ');
  }
  for (final phrase in _locationCommandTerms) {
    value = _stripWholePhrase(value, phrase);
  }
  return value
      .replaceAll(RegExp(r'[^A-Za-z0-9\u0900-\u097f+./-]+', unicode: true), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}

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

String _normalized(String value) => value
    .toLowerCase()
    .replaceAll(RegExp(r'[^a-z0-9\u0900-\u097f]+', unicode: true), ' ')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

bool _containsPhrase(String normalizedText, String phrase) {
  final needle = _normalized(phrase);
  return normalizedText == needle ||
      normalizedText.startsWith('$needle ') ||
      normalizedText.endsWith(' $needle') ||
      normalizedText.contains(' $needle ');
}

bool _containsAny(String text, List<String> phrases) =>
    phrases.any((phrase) => _containsPhrase(text, phrase));

const _locationMutationVerbs = <String>[
  'set',
  'set karo',
  'set kar do',
  'move',
  'move karo',
  'move kar do',
  'shift',
  'shift karo',
  'shift kar do',
  'rakh do',
  'rakho',
  'clear',
  'hatao',
  'hata do',
  'सेट',
  'सेट करो',
  'सेट कर दो',
  'मूव',
  'मूव करो',
  'शिफ्ट',
  'रख दो',
  'रखो',
  'हटाओ',
  'हटा दो',
];

const _locationCommandTerms = <String>[
  'set location',
  'location set',
  'move location',
  'location move',
  'shift location',
  'location shift',
  'set karo',
  'set kar do',
  'move karo',
  'move kar do',
  'shift karo',
  'shift kar do',
  'rakh do',
  'rakho',
  'location',
  'shelf',
  'rack',
  'jagah',
  'to',
  'pe',
  'par',
  'mein',
  'me',
  'karo',
  'kar do',
  'लोकेशन',
  'शेल्फ',
  'रैक',
  'जगह',
  'सेट करो',
  'सेट कर दो',
  'मूव करो',
  'शिफ्ट करो',
  'रख दो',
  'रखो',
  'करो',
  'कर दो',
];
