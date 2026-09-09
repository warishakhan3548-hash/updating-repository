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

/// Fast, deterministic command language for app navigation and stock targeting.
///
/// This parser deliberately does not mutate inventory and does not rely on an
/// LLM. It turns common Hindi/Hinglish/English owner commands into a bounded
/// intent. Medicine identity is resolved separately against the authoritative
/// inventory search index, so language understanding can never invent an ID.
class PharmacyBrainParser {
  const PharmacyBrainParser._();

  static const _removePhrases = <String>[
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
  static const _editPhrases = <String>[
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
  static const _searchPhrases = <String>[
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
  static const _addPhrases = <String>[
    'add medicine',
    'add stock',
    'new medicine',
    'new stock',
    'medicine add',
    'jodo',
    'jod do',
    'ऐड मेडिसिन',
    'नई दवा',
    'नयी दवा',
    'दवा जोड़ो',
    'जोड़ दो',
  ];
  static const _scanPhrases = <String>[
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
    final text = _normalized(original);

    // Destructive language is evaluated first. A broad destructive request is
    // never silently converted into many medicine mutations.
    if (_containsAny(text, _removePhrases)) {
      final target = _extractTarget(text, _removePhrases);
      if (_looksBulkRemoval(text, target)) {
        return PharmacyBrainCommand(
          intent: PharmacyBrainIntent.blockedBulkRemove,
          original: original,
          target: target,
        );
      }
      return PharmacyBrainCommand(
        intent: PharmacyBrainIntent.removeMedicine,
        original: original,
        target: target,
      );
    }

    if (_containsAny(text, _scanPhrases)) {
      return PharmacyBrainCommand(
        intent: PharmacyBrainIntent.scanMedicine,
        original: original,
      );
    }
    if (_containsAny(text, _addPhrases)) {
      return PharmacyBrainCommand(
        intent: PharmacyBrainIntent.addMedicine,
        original: original,
      );
    }

    if (_isHealthRequest(text)) {
      return PharmacyBrainCommand(
        intent: PharmacyBrainIntent.inventoryHealth,
        original: original,
      );
    }
    if (_isExpiredRequest(text)) {
      return PharmacyBrainCommand(
        intent: PharmacyBrainIntent.openExpired,
        original: original,
      );
    }
    if (_isShortExpiryRequest(text)) {
      return PharmacyBrainCommand(
        intent: PharmacyBrainIntent.openShortExpiry,
        original: original,
      );
    }
    if (_isMonthExpiryRequest(text)) {
      return PharmacyBrainCommand(
        intent: PharmacyBrainIntent.openMonthExpiry,
        original: original,
      );
    }
    if (_isSoldRequest(text)) {
      return PharmacyBrainCommand(
        intent: PharmacyBrainIntent.openSold,
        original: original,
      );
    }
    if (_isDatabaseRequest(text)) {
      return PharmacyBrainCommand(
        intent: PharmacyBrainIntent.openDatabase,
        original: original,
      );
    }
    if (_isActivityRequest(text)) {
      return PharmacyBrainCommand(
        intent: PharmacyBrainIntent.openActivity,
        original: original,
      );
    }
    if (_isProfileRequest(text)) {
      return PharmacyBrainCommand(
        intent: PharmacyBrainIntent.openProfile,
        original: original,
      );
    }
    if (_isHomeRequest(text)) {
      return PharmacyBrainCommand(
        intent: PharmacyBrainIntent.openHome,
        original: original,
      );
    }
    if (_isAiRequest(text)) {
      return PharmacyBrainCommand(
        intent: PharmacyBrainIntent.openAi,
        original: original,
      );
    }

    if (_containsAny(text, _editPhrases)) {
      return PharmacyBrainCommand(
        intent: PharmacyBrainIntent.editMedicine,
        original: original,
        target: _extractTarget(text, _editPhrases),
      );
    }
    if (_containsAny(text, _searchPhrases)) {
      return PharmacyBrainCommand(
        intent: PharmacyBrainIntent.searchMedicine,
        original: original,
        target: _extractTarget(text, _searchPhrases),
      );
    }

    // A short bare phrase is extremely useful in a pharmacy: saying just a
    // medicine name should behave like search. Longer free-form requests are
    // handed to the full reviewed AI rather than guessed here.
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

  static String _normalized(String value) => value
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

  static String _extractTarget(String text, Iterable<String> actionPhrases) {
    var target = ' $text ';
    final phrases = actionPhrases.toList()
      ..sort((a, b) => b.length.compareTo(a.length));
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
    final words = target
        .trim()
        .split(' ')
        .where((word) => word.isNotEmpty && !filler.contains(word))
        .toList();
    return words.join(' ').trim();
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
    final broad = target.trim();
    return broad.isEmpty ||
        const {
          'expired',
          'expiry',
          'sold',
          'removed',
          'short expiry',
          'month expiry',
          'एक्सपायर्ड',
          'बिकी',
          'बिका',
        }.contains(broad);
  }

  static bool _isHealthRequest(String text) =>
      _containsAny(text, const [
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
      ]);

  static bool _isExpiredRequest(String text) =>
      _containsAny(text, const [
        'expired medicine',
        'expired medicines',
        'expired stock',
        'show expired',
        'एक्सपायर्ड मेडिसिन',
        'एक्सपायर्ड दवा',
        'एक्सपायर हो चुकी',
      ]) ||
      text == 'expired';

  static bool _isShortExpiryRequest(String text) =>
      _containsAny(text, const [
        'short expiry',
        'expiring soon',
        'days left medicine',
        'days left medicines',
        'जल्दी एक्सपायर',
        'शॉर्ट एक्सपायरी',
      ]);

  static bool _isMonthExpiryRequest(String text) =>
      _containsAny(text, const [
        'month expiry',
        'months left medicine',
        'months left medicines',
        'मंथ एक्सपायरी',
        'महीने में एक्सपायर',
      ]);

  static bool _isSoldRequest(String text) =>
      _containsAny(text, const [
        'sold medicines',
        'sold medicine',
        'sold stock',
        'reorder list',
        'बिकी दवा',
        'बिकी हुई दवा',
        'सोल्ड मेडिसिन',
        'रीऑर्डर',
      ]) ||
      text == 'sold';

  static bool _isDatabaseRequest(String text) =>
      _containsAny(text, const [
        'open database',
        'medicine database',
        'open stock',
        'stock database',
        'डेटाबेस खोलो',
        'मेडिसिन डेटाबेस',
        'स्टॉक खोलो',
      ]);

  static bool _isActivityRequest(String text) =>
      _containsAny(text, const [
        'open activity',
        'activity',
        'stats',
        'statistics',
        'sales activity',
        'एक्टिविटी',
        'स्टैट्स',
        'हिसाब',
      ]);

  static bool _isProfileRequest(String text) =>
      _containsAny(text, const ['open profile', 'profile', 'प्रोफाइल']);

  static bool _isHomeRequest(String text) =>
      _containsAny(text, const ['go home', 'open home', 'home', 'होम']);

  static bool _isAiRequest(String text) =>
      _containsAny(text, const [
        'open ai',
        'full ai',
        'ai assistant',
        'model hub',
        'लोकल ai',
        'एआई',
        'मॉडल हब',
      ]);
}
