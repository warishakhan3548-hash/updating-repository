enum PharmacyBrainIntent {
  searchMedicine,
  editMedicine,
  removeMedicine,
  addMedicine,
  scanMedicine,
  openDatabase,
  openExpired,
  openShortExpiry,
  openMonthExpiry,
  openSold,
  openActivity,
  openProfile,
  openHome,
  openAi,
  inventoryHealth,
  blockedBulkRemove,
  unknown,
}

class PharmacyBrainCommand {
  const PharmacyBrainCommand({
    required this.intent,
    required this.original,
    this.target = '',
  });

  final PharmacyBrainIntent intent;
  final String original;
  final String target;

  bool get needsMedicine => switch (intent) {
    PharmacyBrainIntent.searchMedicine ||
    PharmacyBrainIntent.editMedicine ||
    PharmacyBrainIntent.removeMedicine => true,
    _ => false,
  };

  bool get destructive =>
      intent == PharmacyBrainIntent.removeMedicine ||
      intent == PharmacyBrainIntent.blockedBulkRemove;
}

/// Deterministic app-command language for common pharmacist actions.
///
/// This parser never invents a database ID and never writes inventory. It only
/// classifies a bounded Hindi/Hinglish/English command. Medicine identity is
/// resolved later against the authoritative local search index.
class PharmacyBrainParser {
  const PharmacyBrainParser._();

  static const _remove = <String>[
    'delete',
    'remove',
    'archive',
    'erase',
    'hatao',
    'hata do',
    'hata',
    'nikalo',
    'nikal do',
    'डिलीट',
    'रिमूव',
    'हटाओ',
    'हटा दो',
    'हटा',
    'निकालो',
    'निकाल दो',
  ];
  static const _edit = <String>[
    'edit',
    'update',
    'change',
    'modify',
    'badlo',
    'badal do',
    'एडिट',
    'अपडेट',
    'बदलो',
    'बदल दो',
  ];
  static const _search = <String>[
    'search',
    'find',
    'show',
    'open',
    'look for',
    'dikhao',
    'dhoondo',
    'dhundo',
    'khojo',
    'सर्च',
    'ढूंढो',
    'ढूँढो',
    'खोजो',
    'दिखाओ',
    'खोलो',
  ];
  static const _add = <String>[
    'add medicine',
    'add stock',
    'new medicine',
    'new stock',
    'medicine add',
    'add',
    'jodo',
    'jod do',
    'ऐड मेडिसिन',
    'ऐड',
    'नई दवा',
    'नयी दवा',
    'दवा जोड़ो',
    'जोड़ो',
    'जोड़ दो',
  ];
  static const _scan = <String>[
    'scan',
    'scanner',
    'barcode',
    'camera',
    'photo scan',
    'स्कैन',
    'स्कैनर',
    'बारकोड',
    'कैमरा',
  ];

  static PharmacyBrainCommand parse(String raw) {
    final original = raw.trim();
    if (original.isEmpty) {
      return const PharmacyBrainCommand(
        intent: PharmacyBrainIntent.unknown,
        original: '',
      );
    }
    final text = _normalize(original);

    // Destructive language wins over every other interpretation. Broad/bulk
    // deletion is blocked instead of being converted into many stock writes.
    if (_containsAny(text, _remove)) {
      final target = _extractTarget(text, _remove);
      return PharmacyBrainCommand(
        intent: _looksBulkRemoval(text, target)
            ? PharmacyBrainIntent.blockedBulkRemove
            : PharmacyBrainIntent.removeMedicine,
        original: original,
        target: target,
      );
    }
    if (_containsAny(text, _scan)) {
      return PharmacyBrainCommand(
        intent: PharmacyBrainIntent.scanMedicine,
        original: original,
      );
    }
    if (_containsAny(text, _add)) {
      return PharmacyBrainCommand(
        intent: PharmacyBrainIntent.addMedicine,
        original: original,
        target: _extractTarget(text, _add),
      );
    }

    final navigation = _navigationIntent(text);
    if (navigation != null) {
      return PharmacyBrainCommand(intent: navigation, original: original);
    }

    if (_containsAny(text, _edit)) {
      return PharmacyBrainCommand(
        intent: PharmacyBrainIntent.editMedicine,
        original: original,
        target: _extractTarget(text, _edit),
      );
    }
    if (_containsAny(text, _search)) {
      return PharmacyBrainCommand(
        intent: PharmacyBrainIntent.searchMedicine,
        original: original,
        target: _extractTarget(text, _search),
      );
    }

    // A bare medicine/brand/barcode phrase should feel instantaneous. Longer
    // prose is not guessed here and is delegated to the reviewed full AI.
    final words = text.split(' ').where((word) => word.isNotEmpty).length;
    if (words <= 6) {
      return PharmacyBrainCommand(
        intent: PharmacyBrainIntent.searchMedicine,
        original: original,
        target: text,
      );
    }
    return PharmacyBrainCommand(
      intent: PharmacyBrainIntent.unknown,
      original: original,
    );
  }

  static PharmacyBrainIntent? _navigationIntent(String text) {
    if (_containsAny(text, const [
      'inventory health',
      'stock health',
      'what needs attention',
      'what is urgent',
      'today priority',
      'aaj kya zaroori',
      'aaj kya jaroori',
      'आज क्या जरूरी',
      'आज क्या ज़रूरी',
      'क्या जरूरी है',
      'स्टॉक हेल्थ',
    ])) {
      return PharmacyBrainIntent.inventoryHealth;
    }
    if (_containsAny(text, const [
          'expired medicine',
          'expired medicines',
          'expired stock',
          'show expired',
          'expired dikhao',
          'expired wali dikhao',
          'expiry ho chuki',
          'एक्सपायर्ड मेडिसिन',
          'एक्सपायर्ड दवा',
          'एक्सपायर हो चुकी',
        ]) ||
        text == 'expired') {
      return PharmacyBrainIntent.openExpired;
    }
    if (_containsAny(text, const [
      'short expiry',
      'short expiry dikhao',
      'expiring soon',
      'days left medicine',
      'days left medicines',
      'days left dikhao',
      'jaldi expire wali',
      'जल्दी एक्सपायर',
      'शॉर्ट एक्सपायरी',
    ])) {
      return PharmacyBrainIntent.openShortExpiry;
    }
    if (_containsAny(text, const [
      'month expiry',
      'month expiry dikhao',
      'months left medicine',
      'months left medicines',
      'months left dikhao',
      'मंथ एक्सपायरी',
      'महीने में एक्सपायर',
    ])) {
      return PharmacyBrainIntent.openMonthExpiry;
    }
    if (_containsAny(text, const [
          'sold medicines',
          'sold medicine',
          'sold stock',
          'sold dikhao',
          'sold wali dikhao',
          'reorder list',
          'biki hui dikhao',
          'बिकी दवा',
          'बिकी हुई दवा',
          'सोल्ड मेडिसिन',
          'रीऑर्डर',
        ]) ||
        text == 'sold') {
      return PharmacyBrainIntent.openSold;
    }
    if (_containsAny(text, const [
      'open database',
      'database kholo',
      'medicine database',
      'medicine database kholo',
      'open stock',
      'stock database',
      'stock kholo',
      'inventory kholo',
      'add remove kholo',
      'डेटाबेस खोलो',
      'मेडिसिन डेटाबेस',
      'स्टॉक खोलो',
    ])) {
      return PharmacyBrainIntent.openDatabase;
    }
    if (_containsAny(text, const [
      'open activity',
      'activity',
      'activity kholo',
      'stats',
      'stats kholo',
      'statistics',
      'sales activity',
      'hisaab dikhao',
      'एक्टिविटी',
      'स्टैट्स',
      'हिसाब',
    ])) {
      return PharmacyBrainIntent.openActivity;
    }
    if (_containsAny(text, const [
      'open profile',
      'profile',
      'profile kholo',
      'प्रोफाइल',
      'प्रोफाइल खोलो',
    ])) {
      return PharmacyBrainIntent.openProfile;
    }
    if (_containsAny(text, const [
      'go home',
      'home',
      'home jao',
      'home kholo',
      'होम',
      'होम जाओ',
    ])) {
      return PharmacyBrainIntent.openHome;
    }
    if (_containsAny(text, const [
      'open ai',
      'ai kholo',
      'ai open karo',
      'full ai',
      'ai assistant',
      'model hub',
      'model hub kholo',
      'local ai kholo',
      'लोकल ai',
      'एआई',
      'एआई खोलो',
      'मॉडल हब',
    ])) {
      return PharmacyBrainIntent.openAi;
    }
    return null;
  }

  static String _normalize(String value) => value
      .toLowerCase()
      .replaceAll(RegExp(r'[\n\r\t,;:!?।]+'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  static bool _containsAny(String text, Iterable<String> phrases) =>
      phrases.any((phrase) => _containsPhrase(text, phrase));

  static bool _containsPhrase(String text, String phrase) =>
      text == phrase ||
      text.startsWith('$phrase ') ||
      text.endsWith(' $phrase') ||
      text.contains(' $phrase ');

  static bool _hasAnyToken(String text, Iterable<String> tokens) {
    final padded = ' $text ';
    return tokens.any((token) => padded.contains(' $token '));
  }

  static String _extractTarget(String text, Iterable<String> actions) {
    var target = ' $text ';
    final phrases = actions.toList()..sort((a, b) => b.length.compareTo(a.length));
    for (final phrase in phrases) {
      target = target.replaceAll(' $phrase ', ' ');
    }
    const filler = <String>{
      'please',
      'plz',
      'the',
      'this',
      'that',
      'my',
      'mere',
      'meri',
      'mujhe',
      'medicine',
      'medicines',
      'med',
      'stock',
      'entry',
      'database',
      'inventory',
      'from',
      'in',
      'ko',
      'ki',
      'ka',
      'ke',
      'kar',
      'karo',
      'do',
      'wala',
      'wali',
      'वो',
      'यह',
      'ये',
      'इस',
      'उस',
      'मेरी',
      'मेरे',
      'मुझे',
      'दवा',
      'मेडिसिन',
      'स्टॉक',
      'एंट्री',
      'डेटाबेस',
      'इन्वेंटरी',
      'को',
      'की',
      'का',
      'के',
      'से',
      'में',
      'कर',
      'करो',
      'दो',
      'वाली',
      'वाला',
    };
    return target
        .trim()
        .split(' ')
        .where((word) => word.isNotEmpty && !filler.contains(word))
        .join(' ')
        .trim();
  }

  static bool _looksBulkRemoval(String text, String target) {
    if (_hasAnyToken(text, const [
      'all',
      'every',
      'entire',
      'sab',
      'saare',
      'sare',
      'sari',
      'सभी',
      'सब',
      'सारे',
      'सारी',
      'पूरा',
      'पूरी',
    ])) {
      return true;
    }
    final words = target.split(' ').where((word) => word.isNotEmpty).length;
    if (words > 3) return false;
    return target.isEmpty ||
        _hasAnyToken(target, const [
          'expired',
          'expiry',
          'sold',
          'removed',
          'stock',
          'inventory',
          'medicines',
          'एक्सपायर्ड',
          'बिकी',
          'बिका',
          'स्टॉक',
          'दवाएं',
          'दवाइयां',
        ]);
  }
}
