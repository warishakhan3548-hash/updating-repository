import 'inventory.dart';
import 'medicine_brief.dart';

enum AppSection { home, stock, ai, calculator, profile }

enum AppBrainAction {
  unknown,
  navigate,
  search,
  addMedicine,
  scanMedicine,
  editMedicine,
  setQuantity,
  receiveStock,
  removeMedicine,
  markSold,
  recordSale,
  reorderReview,
  undoLast,
  inventorySummary,
  attentionBrief,
  bulkRemoveBlocked,
}

class AppBrainIntent {
  const AppBrainIntent({
    required this.action,
    this.section,
    this.scope = SearchScope.all,
    this.query = '',
    this.quantity,
    this.briefFocus,
    this.confidence = 0,
  });

  final AppBrainAction action;
  final AppSection? section;
  final SearchScope scope;
  final String query;
  final int? quantity;
  final MedicineBriefFocus? briefFocus;
  final double confidence;

  bool get needsMedicineTarget =>
      briefFocus != null ||
      switch (action) {
        AppBrainAction.editMedicine ||
        AppBrainAction.setQuantity ||
        AppBrainAction.receiveStock ||
        AppBrainAction.removeMedicine ||
        AppBrainAction.markSold ||
        AppBrainAction.recordSale => true,
        _ => false,
      };

  bool get destructive => switch (action) {
    AppBrainAction.setQuantity ||
    AppBrainAction.removeMedicine ||
    AppBrainAction.markSold ||
    AppBrainAction.recordSale ||
    AppBrainAction.bulkRemoveBlocked => true,
    _ => false,
  };
}

AppBrainIntent parseAppBrainIntent(String raw) {
  final text = _normalized(raw);
  if (text.isEmpty) {
    return const AppBrainIntent(action: AppBrainAction.unknown);
  }

  if (_containsAny(text, const [
    'undo',
    'undo last',
    'last change undo',
    'wapas karo',
    'wapas kar do',
    'pichla change wapas',
    'पिछला बदलाव वापस',
    'वापस करो',
  ])) {
    return const AppBrainIntent(
      action: AppBrainAction.undoLast,
      confidence: .99,
    );
  }

  // Natural-language control must never become an unreviewed bulk destructive
  // path. Single-stock removal is supported; Delete All remains behind the
  // dedicated protected owner flow.
  if (_isBulkRemoval(text)) {
    return const AppBrainIntent(
      action: AppBrainAction.bulkRemoveBlocked,
      confidence: 1,
    );
  }

  // Read-only analytics questions are recognized before the write-side sale
  // vocabulary. This prevents phrases such as "aaj ki bikri kitni" from ever
  // being interpreted as a stock mutation. The Calculator/Tracking surface is
  // the existing deterministic source of truth for these metrics.
  if (_containsAny(text, _analyticsReadTerms)) {
    return const AppBrainIntent(
      action: AppBrainAction.navigate,
      section: AppSection.calculator,
      confidence: .98,
    );
  }

  // Explicit stock correction / receiving commands are parsed before generic
  // "add stock" and "edit" vocabulary. The parser accepts an exact quantity
  // only when one command-shaped quantity can be isolated; medicine strengths
  // therefore remain search evidence instead of becoming stock counts.
  final stockAdjustment = _stockAdjustmentIntent(raw);
  if (stockAdjustment != null) return stockAdjustment;

  // Explicit write intent wins over category words such as "expired".
  if (_containsAny(text, _removeTerms)) {
    return AppBrainIntent(
      action: AppBrainAction.removeMedicine,
      query: _extractMedicineQuery(raw, _removeTerms),
      confidence: .98,
    );
  }

  if (_containsAny(text, _soldTerms)) {
    final query = _extractMedicineQuery(raw, _soldTerms);
    // "stock khatam" without a target is informational, never an implicit
    // mutation. It opens the SOLD/reorder projection instead.
    if (query.isEmpty) {
      return const AppBrainIntent(
        action: AppBrainAction.search,
        scope: SearchScope.sold,
        confidence: .94,
      );
    }
    return AppBrainIntent(
      action: AppBrainAction.markSold,
      query: query,
      confidence: .98,
    );
  }

  if (_containsAny(text, _saleTerms)) {
    final saleInput = _extractExplicitSaleQuantity(raw);
    return AppBrainIntent(
      action: AppBrainAction.recordSale,
      query: _extractMedicineQuery(saleInput.remainingText, _saleTerms),
      quantity: saleInput.quantity,
      confidence: .96,
    );
  }

  if (_containsAny(text, _editTerms)) {
    return AppBrainIntent(
      action: AppBrainAction.editMedicine,
      query: _extractMedicineQuery(raw, _editTerms),
      confidence: .95,
    );
  }

  if (_containsAny(text, _attentionTerms)) {
    return const AppBrainIntent(
      action: AppBrainAction.attentionBrief,
      confidence: .98,
    );
  }

  if (_containsAny(text, _scanTerms)) {
    // The Brain launches the existing scanner/import review path. This action
    // only navigates into that authoritative flow; it never writes inventory.
    return const AppBrainIntent(
      action: AppBrainAction.scanMedicine,
      confidence: .97,
    );
  }

  // Category lists (short-expiry / month-expiry / expired / sold) win before
  // targeted read questions so "short expiry" never becomes a medicine named
  // "short". This preserves the dashboard projections as authoritative filters.
  final listIntent = _listIntent(text);
  if (listIntent != null) return listIntent;

  final operational = _operationalReadIntent(raw, text);
  if (operational != null) return operational;

  if (_containsAny(text, const [
    'stock summary',
    'inventory summary',
    'stock kitna',
    'kitna stock',
    'total medicines',
    'total medicine',
    'inventory batao',
    'stock batao',
    'कितना स्टॉक',
    'कुल मेडिसिन',
    'स्टॉक बताओ',
  ])) {
    return const AppBrainIntent(
      action: AppBrainAction.inventorySummary,
      confidence: .98,
    );
  }

  if (_containsAny(text, const [
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

  if (_containsAny(text, const [
    'order now',
    'reorder list',
    'reorder review',
    'what to order',
    'what should i order',
    'low stock review',
    'low stock order',
    'purchase order',
    'kya order karna hai',
    'order kya karna hai',
    'reorder dikhao',
    'ऑर्डर क्या करना है',
    'रीऑर्डर',
    'परचेज ऑर्डर',
  ])) {
    return const AppBrainIntent(
      action: AppBrainAction.reorderReview,
      confidence: .98,
    );
  }

  final section = _sectionIntent(text);
  if (section != null) {
    return AppBrainIntent(
      action: AppBrainAction.navigate,
      section: section,
      confidence: .97,
    );
  }

  if (_containsAny(text, _searchTerms)) {
    return AppBrainIntent(
      action: AppBrainAction.search,
      query: _extractMedicineQuery(raw, _searchTerms),
      confidence: .94,
    );
  }

  // Batch/barcode/location identifiers are common enough that a pharmacist
  // should not need to say the word "search" first. Location questions were
  // already consumed by the operational intent above.
  if (_containsAny(text, _identifierTerms)) {
    final query = _extractMedicineQuery(raw, _identifierTerms);
    return AppBrainIntent(
      action: AppBrainAction.search,
      query: query,
      confidence: query.isEmpty ? .74 : .96,
    );
  }

  // A short non-question such as "Dolo 650" is treated as an intentional stock
  // lookup. Questions/advice/reasoning remain routed to the reviewed AI layer.
  if (_looksLikeDirectLookup(raw, text)) {
    return AppBrainIntent(
      action: AppBrainAction.search,
      query: raw.trim(),
      confidence: .78,
    );
  }

  return const AppBrainIntent(action: AppBrainAction.unknown);
}

AppBrainIntent? _stockAdjustmentIntent(String raw) {
  final exact = _extractStockAdjustment(
    raw,
    _setQuantityPatterns,
    allowZero: true,
  );
  if (exact != null) {
    return AppBrainIntent(
      action: AppBrainAction.setQuantity,
      query: _extractMedicineQuery(exact.remainingText, const <String>[]),
      quantity: exact.quantity,
      confidence: .99,
    );
  }

  final received = _extractStockAdjustment(
    raw,
    _receiveStockPatterns,
    allowZero: false,
  );
  if (received != null) {
    return AppBrainIntent(
      action: AppBrainAction.receiveStock,
      query: _extractMedicineQuery(received.remainingText, const <String>[]),
      quantity: received.quantity,
      confidence: .99,
    );
  }
  return null;
}

AppBrainIntent? _operationalReadIntent(String raw, String text) {
  final matches = <MedicineBriefFocus, List<String>>{
    if (_containsAny(text, _stockLookupTerms))
      MedicineBriefFocus.stock: _stockLookupTerms,
    if (_containsAny(text, _expiryLookupTerms))
      MedicineBriefFocus.expiry: _expiryLookupTerms,
    if (_containsAny(text, _locationTerms))
      MedicineBriefFocus.location: _locationTerms,
    if (_containsAny(text, _fefoTerms)) MedicineBriefFocus.fefo: _fefoTerms,
  };
  if (matches.isEmpty) return null;

  // Multiple operational questions about the same medicine are answered from
  // one coherent read-only snapshot instead of independently parsing each
  // clause. All matched vocabulary is stripped before fuzzy target resolution.
  final terms = <String>[
    for (final values in matches.values) ...values,
  ];
  final query = _extractMedicineQuery(raw, terms);
  if (matches.length == 1 &&
      matches.containsKey(MedicineBriefFocus.stock) &&
      query.isEmpty) {
    return const AppBrainIntent(
      action: AppBrainAction.inventorySummary,
      confidence: .98,
    );
  }

  return AppBrainIntent(
    action: AppBrainAction.search,
    query: query,
    briefFocus: matches.length == 1
        ? matches.keys.single
        : MedicineBriefFocus.summary,
    confidence: query.isEmpty ? .76 : .99,
  );
}

AppBrainIntent? _listIntent(String text) {
  final wantsList = _containsAny(text, const [
    'show',
    'list',
    'open',
    'dikhao',
    'dikhana',
    'batao',
    'दिखाओ',
    'लिस्ट',
    'खोलो',
  ]);

  if (_containsAny(text, const [
    'expired',
    'expiry ho gayi',
    'expire ho gayi',
    'एक्सपायर्ड',
  ])) {
    return AppBrainIntent(
      action: AppBrainAction.search,
      scope: SearchScope.expired,
      confidence: wantsList ? .99 : .96,
    );
  }
  if (_containsAny(text, const [
    'sold medicines',
    'sold medicine',
    'sold list',
    'biki medicine',
    'बिकी मेडिसिन',
  ])) {
    return const AppBrainIntent(
      action: AppBrainAction.search,
      scope: SearchScope.sold,
      confidence: .99,
    );
  }
  if (_containsAny(text, const [
    'short expiry',
    'short-expiry',
    'days left',
    'jaldi expire',
    'जल्दी एक्सपायर',
  ])) {
    return const AppBrainIntent(
      action: AppBrainAction.search,
      scope: SearchScope.shortExpiry,
      confidence: .96,
    );
  }
  if (_containsAny(text, const [
    'month expiry',
    'months left',
    'month left',
    'महीने में एक्सपायर',
  ])) {
    return const AppBrainIntent(
      action: AppBrainAction.search,
      scope: SearchScope.monthExpiry,
      confidence: .96,
    );
  }
  return null;
}

AppSection? _sectionIntent(String text) {
  if (_containsAny(text, const [
    'go home',
    'open home',
    'home kholo',
    'home chalo',
    'होम खोलो',
  ])) {
    return AppSection.home;
  }
  if (_containsAny(text, const [
    'open stock',
    'medicine database',
    'open database',
    'stock kholo',
    'database kholo',
    'मेडिसिन डेटाबेस',
    'स्टॉक खोलो',
  ])) {
    return AppSection.stock;
  }
  if (_containsAny(text, const [
    'open ai',
    'ai kholo',
    'brain kholo',
    'aaris brain',
    'एआई खोलो',
  ])) {
    return AppSection.ai;
  }
  if (_containsAny(text, const [
    'open calculator',
    'calculator kholo',
    'stats kholo',
    'statistics',
    'कैलकुलेटर खोलो',
  ])) {
    return AppSection.calculator;
  }
  if (_containsAny(text, const [
    'open profile',
    'profile kholo',
    'settings kholo',
    'प्रोफाइल खोलो',
  ])) {
    return AppSection.profile;
  }
  return null;
}

bool isAppBrainContextReference(String raw) {
  final text = _normalized(raw);
  return const {
    'this',
    'it',
    'this one',
    'this medicine',
    'same',
    'same one',
    'same medicine',
    'selected one',
    'selected medicine',
    'last one',
    'last medicine',
    'isko',
    'ise',
    'iska',
    'iski',
    'usko',
    'usse',
    'uska',
    'uski',
    'ye',
    'yeh',
    'wahi',
    'jo select kiya',
    'इसको',
    'इसे',
    'इसका',
    'इसकी',
    'उसको',
    'उसका',
    'उसकी',
    'यही',
    'वही',
  }.contains(text);
}

String _normalized(String value) => value
    .toLowerCase()
    .replaceAll(RegExp(r'[^a-z0-9\u0900-\u097f]+', unicode: true), ' ')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

bool _containsAny(String text, List<String> phrases) => phrases.any((phrase) {
  final needle = _normalized(phrase);
  if (needle.isEmpty) return false;
  return text == needle ||
      text.startsWith('$needle ') ||
      text.endsWith(' $needle') ||
      text.contains(' $needle ');
});

bool _isBulkRemoval(String text) {
  if (!_containsAny(text, _removeTerms)) return false;
  return _containsAny(text, const [
    'delete all',
    'remove all',
    'all medicine',
    'all medicines',
    'all stock',
    'whole inventory',
    'entire inventory',
    'sab medicine',
    'sab medicines',
    'saari medicine',
    'sari medicine',
    'sara stock',
    'poora stock delete',
    'pura stock delete',
    'सब मेडिसिन',
    'सारी मेडिसिन',
    'पूरा स्टॉक',
    'सारा स्टॉक',
    'सब डिलीट',
  ]);
}

bool _looksLikeDirectLookup(String raw, String text) {
  if (raw.contains('?') || text.isEmpty || raw.trim().length > 80) return false;
  final tokens = text.split(' ');
  if (tokens.length > 7) return false;
  if (_containsAny(text, const [
    'what',
    'which',
    'why',
    'how',
    'should',
    'can i',
    'recommend',
    'compare',
    'explain',
    'analyse',
    'analyze',
    'advice',
    'plan',
    'pattern',
    'before food',
    'after food',
    'dose',
    'dosage',
    'use for',
    'kya',
    'kyun',
    'kaise',
    'batao kya',
    'क्या',
    'क्यों',
    'कैसे',
    'खुराक',
  ])) {
    return false;
  }
  if (const {
    'medicine',
    'medicines',
    'stock',
    'database',
    'dawai',
    'दवा',
    'मेडिसिन',
  }.contains(text)) {
    return false;
  }
  return RegExp(r'[a-z0-9\u0900-\u097f]', unicode: true).hasMatch(text);
}

class _ExplicitSaleQuantity {
  const _ExplicitSaleQuantity(this.remainingText, this.quantity);

  final String remainingText;
  final int? quantity;
}

class _ExplicitStockAdjustment {
  const _ExplicitStockAdjustment(this.remainingText, this.quantity);

  final String remainingText;
  final int quantity;
}

class _StockAdjustmentMatch {
  const _StockAdjustmentMatch(this.start, this.end, this.quantityText);

  final int start, end;
  final String quantityText;
}

_ExplicitSaleQuantity _extractExplicitSaleQuantity(String raw) {
  final expression = RegExp(
    r'(?:(?:qty|quantity)\s*[:=]?\s*([0-9०-९]{1,9})|([0-9०-९]{1,9})\s*(?:units?|pcs?|pieces?|यूनिट(?:्स)?))',
    caseSensitive: false,
    unicode: true,
  );
  final matches = expression.allMatches(raw).toList();
  // Multiple quantity statements are ambiguous. Preserve the original command
  // and fall back to the reviewed editor instead of guessing which number wins.
  if (matches.length != 1) return _ExplicitSaleQuantity(raw, null);
  final match = matches.single;
  final digits = _asciiDigits(match.group(1) ?? match.group(2) ?? '');
  final quantity = int.tryParse(digits);
  if (quantity == null || quantity < 1 || quantity > _maxCommandQuantity) {
    return _ExplicitSaleQuantity(raw, null);
  }
  final remaining = raw.replaceRange(match.start, match.end, ' ');
  return _ExplicitSaleQuantity(remaining, quantity);
}

_ExplicitStockAdjustment? _extractStockAdjustment(
  String raw,
  List<RegExp> patterns, {
  required bool allowZero,
}) {
  final found = <_StockAdjustmentMatch>[];
  final seen = <String>{};
  for (final pattern in patterns) {
    for (final match in pattern.allMatches(raw)) {
      final quantityText = match.group(1) ?? '';
      final key = '${match.start}:${match.end}:$quantityText';
      if (seen.add(key)) {
        found.add(
          _StockAdjustmentMatch(match.start, match.end, quantityText),
        );
      }
    }
  }
  if (found.length != 1) return null;
  final match = found.single;
  final quantity = int.tryParse(_asciiDigits(match.quantityText));
  final minimum = allowZero ? 0 : 1;
  if (quantity == null ||
      quantity < minimum ||
      quantity > _maxCommandQuantity) {
    return null;
  }
  final remaining = raw.replaceRange(match.start, match.end, ' ');
  return _ExplicitStockAdjustment(remaining, quantity);
}

String _asciiDigits(String value) {
  const devanagari = '०१२३४५६७८९';
  final output = StringBuffer();
  for (final rune in value.runes) {
    final char = String.fromCharCode(rune);
    final index = devanagari.indexOf(char);
    output.write(index < 0 ? char : index.toString());
  }
  return output.toString();
}

String _extractMedicineQuery(String raw, List<String> terms) {
  var value = raw;
  final ordered = [...terms]..sort((a, b) => b.length.compareTo(a.length));
  for (final term in ordered) {
    value = _stripWholePhrase(value, term);
  }
  for (final filler in _fillers) {
    value = _stripWholePhrase(value, filler);
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

const _maxCommandQuantity = 100000000;

final _setQuantityPatterns = <RegExp>[
  RegExp(
    r'(?:set|correct)\s+(?:stock\s+)?(?:qty|quantity)\s*(?:to\s*)?[:=]?\s*([0-9०-९]{1,9})(?:\s*units?)?',
    caseSensitive: false,
    unicode: true,
  ),
  RegExp(
    r'(?:stock\s+)?(?:qty|quantity)\s*(?:to\s*)?[:=]?\s*([0-9०-९]{1,9})\s*(?:set|correct|karo|kar do)',
    caseSensitive: false,
    unicode: true,
  ),
  RegExp(
    r'stock\s+(?:set|correct)\s*(?:to\s*)?[:=]?\s*([0-9०-९]{1,9})(?:\s*units?)?',
    caseSensitive: false,
    unicode: true,
  ),
  RegExp(
    r'(?:स्टॉक\s+)?(?:क्वांटिटी|मात्रा)\s*([0-9०-९]{1,9})\s*(?:सेट|करो|कर दो)',
    caseSensitive: false,
    unicode: true,
  ),
];

final _receiveStockPatterns = <RegExp>[
  RegExp(
    r'(?:restock|stock\s+add|add\s+stock|receive\s+stock|stock\s+receive)\s*(?:by\s*)?[:=]?\s*([0-9०-९]{1,9})(?:\s*(?:units?|pcs?|pieces?))?',
    caseSensitive: false,
    unicode: true,
  ),
  RegExp(
    r'([0-9०-९]{1,9})\s*(?:units?|pcs?|pieces?)\s*(?:restock|stock\s+add|add\s+stock|receive\s+stock)',
    caseSensitive: false,
    unicode: true,
  ),
  RegExp(
    r'(?:stock\s+badhao|stock\s+badha do|stock\s+badhado)\s*([0-9०-९]{1,9})(?:\s*units?)?',
    caseSensitive: false,
    unicode: true,
  ),
  RegExp(
    r'(?:स्टॉक\s+जोड़ो|स्टॉक\s+बढ़ाओ|स्टॉक\s+बढ़ा दो)\s*([0-9०-९]{1,9})(?:\s*(?:यूनिट|यूनिट्स))?',
    caseSensitive: false,
    unicode: true,
  ),
];

const _fillers = <String>[
  'please',
  'plz',
  'medicine',
  'medicines',
  'dawai',
  'dawa',
  'stock entry',
  'entry',
  'ko',
  'karo',
  'kar do',
  'karna',
  'mujhe',
  'mera',
  'meri',
  'the',
  'hai',
  'hain',
  'stock',
  'and',
  'aur',
  'और',
  'मेडिसिन',
  'दवा',
  'को',
  'करो',
  'कर दो',
  'मुझे',
  'मेरी',
  'है',
  'हैं',
];

const _removeTerms = <String>[
  'delete',
  'remove',
  'archive',
  'hatao',
  'hata do',
  'hata dena',
  'हटाओ',
  'हटा दो',
  'डिलीट',
  'रिमूव',
];

const _soldTerms = <String>[
  'mark sold',
  'sold mark',
  'stock finished',
  'stock khatam',
  'poora stock bik gaya',
  'pura stock bik gaya',
  'पूरा स्टॉक बिक गया',
  'स्टॉक खत्म',
];

const _saleTerms = <String>[
  'record sale',
  'sale record',
  'sale add',
  'becha',
  'bikri',
  'बिक्री',
  'सेल रिकॉर्ड',
];

const _editTerms = <String>[
  'edit',
  'update medicine',
  'medicine update',
  'badlo',
  'change medicine',
  'एडिट',
  'अपडेट',
  'बदलो',
];

const _analyticsReadTerms = <String>[
  'sales summary',
  'sale summary',
  'sales today',
  'today sales',
  'today sale',
  'aaj ki bikri',
  'aaj bikri',
  'bikri batao',
  'aaj ki sale',
  'bikri kitni',
  'sale kitni',
  'sales report',
  'sale report',
  'fast moving',
  'fastest moving',
  'top selling',
  'best selling',
  'slow moving',
  'slowest moving',
  'कम बिक',
  'तेज बिक',
  'आज की बिक्री',
  'बिक्री रिपोर्ट',
];

const _attentionTerms = <String>[
  'what needs attention',
  'needs attention',
  'attention brief',
  'attention summary',
  'risk summary',
  'problem stock',
  'data quality',
  'data quality check',
  'inventory problems',
  'stock problems',
  'duplicate stock',
  'duplicate entries',
  'barcode conflict',
  'scan conflict',
  'missing expiry',
  'missing quantity',
  'future mfg',
  'future manufacturing date',
  'aaj kya dekhna hai',
  'aaj kya karna hai',
  'kya dikkat hai',
  'क्या देखना है',
  'आज क्या करना है',
  'क्या दिक्कत है',
  'डाटा क्वालिटी',
];

const _scanTerms = <String>[
  'scan medicine',
  'scan pack',
  'start scan',
  'open scanner',
  'scanner kholo',
  'scan karo',
  'barcode scan',
  'स्कैन करो',
  'स्कैनर खोलो',
  'मेडिसिन स्कैन',
];

const _locationTerms = <String>[
  'where is',
  'where are',
  'location of',
  'location batao',
  'location dikhao',
  'kahan hai',
  'kidhar hai',
  'rack kaha',
  'rack kahan',
  'shelf kaha',
  'shelf kahan',
  'कहाँ है',
  'किधर है',
  'लोकेशन बताओ',
  'रैक कहाँ',
  'शेल्फ कहाँ',
];

const _stockLookupTerms = <String>[
  'how much stock',
  'stock of',
  'stock kitna hai',
  'stock kitna',
  'kitna stock hai',
  'kitna stock',
  'quantity of',
  'quantity kitni hai',
  'quantity kitni',
  'kitni quantity hai',
  'kitni quantity',
  'units left',
  'kitne bache',
  'kitni bachi',
  'कितना स्टॉक है',
  'कितना स्टॉक',
  'कितनी क्वांटिटी',
  'कितने बचे',
];

const _expiryLookupTerms = <String>[
  'expiry date of',
  'expiry of',
  'expiry kab hai',
  'expiry kab',
  'expiry batao',
  'exp date',
  'exp kab',
  'kab expire hogi',
  'kab expire hoga',
  'kab expire',
  'एक्सपायरी कब है',
  'एक्सपायरी कब',
  'एक्सपायरी बताओ',
  'कब एक्सपायर',
];

const _fefoTerms = <String>[
  'which batch first',
  'which stock first',
  'sell which batch first',
  'dispense which batch first',
  'first expiry first out',
  'fefo',
  'pehle kaunsi batch',
  'pehle konsi batch',
  'pehle konsa batch',
  'kaunsi batch pehle',
  'konsi batch pehle',
  'pehle kya nikalu',
  'पहले कौनसी बैच',
  'कौनसी बैच पहले',
  'पहले क्या निकालूं',
];

const _searchTerms = <String>[
  'search',
  'find',
  'dhoondo',
  'dhundo',
  'dikhao',
  'show medicine',
  'खोजो',
  'ढूंढो',
  'दिखाओ',
];

const _identifierTerms = <String>[
  'batch number',
  'batch no',
  'batch',
  'barcode',
  'bar code',
  'location',
  'rack',
  'shelf',
  'block',
  'row',
  'बैच नंबर',
  'बैच',
  'बारकोड',
  'लोकेशन',
  'रैक',
];
