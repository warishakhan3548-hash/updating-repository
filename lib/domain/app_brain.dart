import 'inventory.dart';

enum AppSection { home, stock, ai, calculator, profile }

enum AppBrainAction {
  unknown,
  navigate,
  search,
  addMedicine,
  editMedicine,
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
    this.confidence = 0,
  });

  final AppBrainAction action;
  final AppSection? section;
  final SearchScope scope;
  final String query;
  final double confidence;

  bool get needsMedicineTarget => switch (action) {
    AppBrainAction.editMedicine ||
    AppBrainAction.removeMedicine ||
    AppBrainAction.markSold ||
    AppBrainAction.recordSale => true,
    _ => false,
  };

  bool get destructive => switch (action) {
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
    return AppBrainIntent(
      action: AppBrainAction.recordSale,
      query: _extractMedicineQuery(raw, _saleTerms),
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

  if (_containsAny(text, const [
    'what needs attention',
    'needs attention',
    'attention brief',
    'attention summary',
    'risk summary',
    'problem stock',
    'aaj kya dekhna hai',
    'aaj kya karna hai',
    'kya dikkat hai',
    'क्या देखना है',
    'आज क्या करना है',
    'क्या दिक्कत है',
  ])) {
    return const AppBrainIntent(
      action: AppBrainAction.attentionBrief,
      confidence: .98,
    );
  }

  if (_containsAny(text, _scanTerms)) {
    // Scanner lives inside the authoritative Medicine Database flow. Opening
    // Stock is safer than inventing a second scan/mutation path in the Brain.
    return const AppBrainIntent(
      action: AppBrainAction.navigate,
      section: AppSection.stock,
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

AppBrainIntent? _operationalReadIntent(String raw, String text) {
  // These are intentionally read-only routings. The Brain resolves the phrase
  // into the existing fuzzy Medicine Database rather than calculating or
  // mutating hidden state itself.
  if (_containsAny(text, _locationTerms)) {
    final query = _extractMedicineQuery(raw, _locationTerms);
    return AppBrainIntent(
      action: AppBrainAction.search,
      query: query,
      confidence: query.isEmpty ? .76 : .98,
    );
  }

  if (_containsAny(text, _stockLookupTerms)) {
    final query = _extractMedicineQuery(raw, _stockLookupTerms);
    if (query.isNotEmpty) {
      return AppBrainIntent(
        action: AppBrainAction.search,
        query: query,
        confidence: .98,
      );
    }
    return const AppBrainIntent(
      action: AppBrainAction.inventorySummary,
      confidence: .98,
    );
  }

  if (_containsAny(text, _expiryLookupTerms)) {
    final query = _extractMedicineQuery(raw, _expiryLookupTerms);
    return AppBrainIntent(
      action: AppBrainAction.search,
      query: query,
      confidence: query.isEmpty ? .76 : .98,
    );
  }

  if (_containsAny(text, _fefoTerms)) {
    final query = _extractMedicineQuery(raw, _fefoTerms);
    return AppBrainIntent(
      action: AppBrainAction.search,
      query: query,
      confidence: query.isEmpty ? .76 : .99,
    );
  }

  return null;
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

bool _containsAny(String text, List<String> phrases) =>
    phrases.any((phrase) => text.contains(_normalized(phrase)));

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
  'this',
  'that',
  'hai',
  'hain',
  'stock',
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
