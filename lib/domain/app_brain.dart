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
  undoLast,
  inventorySummary,
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

  // Explicit write intent always wins over category words such as "expired".
  // Example: "expired Dolo delete karo" must prepare removal of Dolo rather
  // than merely opening the expired list.
  if (_containsAny(text, const [
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
  ])) {
    return AppBrainIntent(
      action: AppBrainAction.removeMedicine,
      query: _extractMedicineQuery(raw, _removeTerms),
      confidence: .98,
    );
  }

  if (_containsAny(text, const [
    'mark sold',
    'sold mark',
    'stock finished',
    'stock khatam',
    'poora stock bik gaya',
    'pura stock bik gaya',
    'पूरा स्टॉक बिक गया',
    'स्टॉक खत्म',
  ])) {
    return AppBrainIntent(
      action: AppBrainAction.markSold,
      query: _extractMedicineQuery(raw, _soldTerms),
      confidence: .98,
    );
  }

  if (_containsAny(text, const [
    'record sale',
    'sale record',
    'sale add',
    'becha',
    'bikri',
    'बिक्री',
    'सेल रिकॉर्ड',
  ])) {
    return AppBrainIntent(
      action: AppBrainAction.recordSale,
      query: _extractMedicineQuery(raw, _saleTerms),
      confidence: .96,
    );
  }

  if (_containsAny(text, const [
    'edit',
    'update medicine',
    'medicine update',
    'badlo',
    'change medicine',
    'एडिट',
    'अपडेट',
    'बदलो',
  ])) {
    return AppBrainIntent(
      action: AppBrainAction.editMedicine,
      query: _extractMedicineQuery(raw, _editTerms),
      confidence: .95,
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

  final listIntent = _listIntent(text);
  if (listIntent != null) return listIntent;

  final section = _sectionIntent(text);
  if (section != null) {
    return AppBrainIntent(
      action: AppBrainAction.navigate,
      section: section,
      confidence: .97,
    );
  }

  if (_containsAny(text, const [
    'search',
    'find',
    'dhoondo',
    'dhundo',
    'dikhao',
    'show medicine',
    'खोजो',
    'ढूंढो',
    'दिखाओ',
  ])) {
    return AppBrainIntent(
      action: AppBrainAction.search,
      query: _extractMedicineQuery(raw, _searchTerms),
      confidence: .94,
    );
  }

  return const AppBrainIntent(action: AppBrainAction.unknown);
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
  if (_containsAny(text, const ['go home', 'open home', 'home kholo', 'होम खोलो'])) {
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
  if (_containsAny(text, const ['open ai', 'ai kholo', 'एआई खोलो'])) {
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

String _normalized(String value) => value
    .toLowerCase()
    .replaceAll(RegExp(r'[^a-z0-9\u0900-\u097f]+', unicode: true), ' ')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

bool _containsAny(String text, List<String> phrases) =>
    phrases.any((phrase) => text.contains(_normalized(phrase)));

String _extractMedicineQuery(String raw, List<String> terms) {
  var value = raw;
  final ordered = [...terms]..sort((a, b) => b.length.compareTo(a.length));
  for (final term in ordered) {
    value = value.replaceAll(RegExp(RegExp.escape(term), caseSensitive: false), ' ');
  }
  for (final filler in const [
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
    'मेडिसिन',
    'दवा',
    'को',
    'करो',
    'कर दो',
    'मुझे',
    'मेरी',
  ]) {
    value = value.replaceAll(RegExp(RegExp.escape(filler), caseSensitive: false), ' ');
  }
  return value
      .replaceAll(RegExp(r'[^A-Za-z0-9\u0900-\u097f+./-]+', unicode: true), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}

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
