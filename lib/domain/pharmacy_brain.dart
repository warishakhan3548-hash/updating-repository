import 'search.dart';

enum PharmacyBrainIntent {
  none,
  findMedicine,
  editMedicine,
  removeMedicine,
  sellMedicine,
  addMedicine,
  scanMedicine,
  showExpired,
  showShortExpiry,
  showMonthExpiry,
  showSold,
  openBackup,
  openOrders,
}

enum PharmacyBrainRisk { readOnly, reviewRequired, destructive }

class PharmacyBrainPlan {
  const PharmacyBrainPlan({
    required this.intent,
    required this.query,
    required this.confidence,
    required this.risk,
    required this.message,
  });

  final PharmacyBrainIntent intent;
  final String query;
  final double confidence;
  final PharmacyBrainRisk risk;
  final String message;

  bool get handled => intent != PharmacyBrainIntent.none;
  bool get needsMedicine => switch (intent) {
    PharmacyBrainIntent.findMedicine ||
    PharmacyBrainIntent.editMedicine ||
    PharmacyBrainIntent.removeMedicine ||
    PharmacyBrainIntent.sellMedicine => true,
    _ => false,
  };
}

/// Fast, offline-first intent router for common pharmacist commands.
///
/// This layer deliberately handles only deterministic app navigation and stock
/// workflows. Complex inventory edits continue to use the reviewed AI protocol.
/// Destructive commands never mutate data here; they only produce a typed plan
/// that the UI must resolve to an exact stock entry and confirm with the owner.
class PharmacyBrain {
  const PharmacyBrain._();

  static PharmacyBrainPlan understand(String raw) {
    final original = raw.trim();
    if (original.isEmpty) return _none;

    final command = _commandText(original);
    final words = command.split(' ').where((word) => word.isNotEmpty).toSet();

    final remove = words.contains('remove');
    final sell = words.contains('sell') ||
        RegExp(r'\b(?:mark\s+sold|sold\s+(?:kar|karo|kardo|krdo|mark))\b')
            .hasMatch(command);
    final edit = words.contains('edit');
    final add = words.contains('add');
    final scan = words.contains('scan');
    final backup = words.contains('backup');
    final reorder = words.contains('reorder') ||
        RegExp(r'\border\s+(?:list|screen|page)\b').hasMatch(command);

    if (remove) {
      return PharmacyBrainPlan(
        intent: PharmacyBrainIntent.removeMedicine,
        query: _extractQuery(command, PharmacyBrainIntent.removeMedicine),
        confidence: .99,
        risk: PharmacyBrainRisk.destructive,
        message:
            'I’ll find the exact stock entry first. Nothing will be removed until you choose the reason and confirm it.',
      );
    }
    if (sell) {
      return PharmacyBrainPlan(
        intent: PharmacyBrainIntent.sellMedicine,
        query: _extractQuery(command, PharmacyBrainIntent.sellMedicine),
        confidence: .98,
        risk: PharmacyBrainRisk.reviewRequired,
        message:
            'I’ll open the exact medicine stock so you can record the sale or mark the whole entry sold.',
      );
    }
    if (edit) {
      return PharmacyBrainPlan(
        intent: PharmacyBrainIntent.editMedicine,
        query: _extractQuery(command, PharmacyBrainIntent.editMedicine),
        confidence: .98,
        risk: PharmacyBrainRisk.reviewRequired,
        message:
            'I’ll find the exact medicine entry and open its saved details for editing.',
      );
    }
    if (_mentionsShortExpiry(command)) {
      return const PharmacyBrainPlan(
        intent: PharmacyBrainIntent.showShortExpiry,
        query: '',
        confidence: .98,
        risk: PharmacyBrainRisk.readOnly,
        message: 'Opening medicines inside your short-expiry window.',
      );
    }
    if (_mentionsMonthExpiry(command)) {
      return const PharmacyBrainPlan(
        intent: PharmacyBrainIntent.showMonthExpiry,
        query: '',
        confidence: .96,
        risk: PharmacyBrainRisk.readOnly,
        message: 'Opening medicines inside your month-expiry window.',
      );
    }
    if (_mentionsExpired(command)) {
      return const PharmacyBrainPlan(
        intent: PharmacyBrainIntent.showExpired,
        query: '',
        confidence: .98,
        risk: PharmacyBrainRisk.readOnly,
        message: 'Opening expired medicines, newest expiries first.',
      );
    }
    if (_mentionsSoldList(command)) {
      return const PharmacyBrainPlan(
        intent: PharmacyBrainIntent.showSold,
        query: '',
        confidence: .97,
        risk: PharmacyBrainRisk.readOnly,
        message: 'Opening sold medicines and reorder-needed stock.',
      );
    }
    if (backup) {
      return const PharmacyBrainPlan(
        intent: PharmacyBrainIntent.openBackup,
        query: '',
        confidence: .99,
        risk: PharmacyBrainRisk.readOnly,
        message: 'Opening backup and restore tools.',
      );
    }
    if (reorder) {
      return const PharmacyBrainPlan(
        intent: PharmacyBrainIntent.openOrders,
        query: '',
        confidence: .96,
        risk: PharmacyBrainRisk.readOnly,
        message: 'Opening your reorder and purchase-order workflow.',
      );
    }
    if (scan) {
      return const PharmacyBrainPlan(
        intent: PharmacyBrainIntent.scanMedicine,
        query: '',
        confidence: .99,
        risk: PharmacyBrainRisk.readOnly,
        message: 'Opening the medicine scanner.',
      );
    }
    if (add) {
      return const PharmacyBrainPlan(
        intent: PharmacyBrainIntent.addMedicine,
        query: '',
        confidence: .98,
        risk: PharmacyBrainRisk.reviewRequired,
        message: 'Opening a new medicine entry.',
      );
    }

    final find = words.contains('find');
    if (find) {
      final query = _extractQuery(command, PharmacyBrainIntent.findMedicine);
      return PharmacyBrainPlan(
        intent: PharmacyBrainIntent.findMedicine,
        query: query,
        confidence: query.isEmpty ? .70 : .96,
        risk: PharmacyBrainRisk.readOnly,
        message: query.isEmpty
            ? 'Tell me the medicine name, salt, barcode, batch or location to search.'
            : 'Searching your medicine database.',
      );
    }

    // In the dedicated command box, a compact non-question phrase is most
    // likely a medicine lookup. Questions remain for the full AI chat.
    if (!_looksLikeQuestion(command)) {
      final compact = _extractQuery(command, PharmacyBrainIntent.findMedicine);
      final count = compact.split(' ').where((part) => part.isNotEmpty).length;
      if (compact.isNotEmpty && count <= 8) {
        return PharmacyBrainPlan(
          intent: PharmacyBrainIntent.findMedicine,
          query: compact,
          confidence: .82,
          risk: PharmacyBrainRisk.readOnly,
          message: 'Searching your medicine database.',
        );
      }
    }

    return _none;
  }

  static const _none = PharmacyBrainPlan(
    intent: PharmacyBrainIntent.none,
    query: '',
    confidence: 0,
    risk: PharmacyBrainRisk.readOnly,
    message:
        'This needs the full AI assistant. I did not run any stock action automatically.',
  );

  static String _commandText(String raw) {
    var text = raw.toLowerCase();
    const replacements = <String, String>{
      'हटा दो': ' remove ',
      'हटा देना': ' remove ',
      'हटाना है': ' remove ',
      'हटाओ': ' remove ',
      'डिलीट': ' remove ',
      'delete': ' remove ',
      'remove': ' remove ',
      'archive': ' remove ',
      'बेच दो': ' sell ',
      'बेचना है': ' sell ',
      'बिक गया': ' sell ',
      'sell': ' sell ',
      'एडिट': ' edit ',
      'बदल दो': ' edit ',
      'बदलना है': ' edit ',
      'edit': ' edit ',
      'update details': ' edit ',
      'खोजो': ' find ',
      'ढूंढो': ' find ',
      'ढूँढो': ' find ',
      'दिखाओ': ' find ',
      'search': ' find ',
      'find': ' find ',
      'जोड़ो': ' add ',
      'ऐड': ' add ',
      'add': ' add ',
      'स्कैन': ' scan ',
      'scan': ' scan ',
      'एक्सपायर्ड': ' expired ',
      'एक्सपायर': ' expired ',
      'expired': ' expired ',
      'शॉर्ट एक्सपायरी': ' short expiry ',
      'short expiry': ' short expiry ',
      'मंथ एक्सपायरी': ' month expiry ',
      'month expiry': ' month expiry ',
      'सोल्ड': ' sold ',
      'बैकअप': ' backup ',
      'backup': ' backup ',
      'रीऑर्डर': ' reorder ',
      're-order': ' reorder ',
      'reorder': ' reorder ',
    };
    for (final entry in replacements.entries) {
      text = text.replaceAll(entry.key, entry.value);
    }
    return searchText(text).replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  static String _extractQuery(String command, PharmacyBrainIntent intent) {
    const filler = <String>{
      'remove',
      'sell',
      'sold',
      'edit',
      'find',
      'add',
      'scan',
      'medicine',
      'medicines',
      'dawa',
      'dawai',
      'drug',
      'stock',
      'entry',
      'database',
      'please',
      'pls',
      'open',
      'show',
      'me',
      'my',
      'the',
      'this',
      'that',
      'ko',
      'ka',
      'ki',
      'ke',
      'se',
      'mein',
      'mujhe',
      'mera',
      'meri',
      'kar',
      'karo',
      'kardo',
      'krdo',
      'karna',
      'hai',
      'do',
      'wala',
      'wali',
      'वाली',
      'वाला',
      'मुझे',
      'मेरी',
      'मेरा',
      'को',
      'का',
      'की',
      'के',
      'से',
      'में',
      'यह',
      'ये',
      'इस',
      'उस',
      'दवा',
      'दवाई',
      'करो',
      'करना',
      'है',
      'दो',
    };
    final extra = switch (intent) {
      PharmacyBrainIntent.removeMedicine => const {'archive'},
      PharmacyBrainIntent.sellMedicine => const {'mark', 'out', 'finished'},
      PharmacyBrainIntent.editMedicine => const {'change', 'details', 'update'},
      _ => const <String>{},
    };
    final filtered = command
        .split(' ')
        .where(
          (word) =>
              word.isNotEmpty && !filler.contains(word) && !extra.contains(word),
        )
        .join(' ');
    return searchText(filtered);
  }

  static bool _mentionsExpired(String command) =>
      RegExp(r'\bexpired\b').hasMatch(command) &&
      !RegExp(r'\bremove\b').hasMatch(command);

  static bool _mentionsShortExpiry(String command) =>
      command.contains('short expiry') ||
      command.contains('few days expiry') ||
      command.contains('days left');

  static bool _mentionsMonthExpiry(String command) =>
      command.contains('month expiry') || command.contains('months left');

  static bool _mentionsSoldList(String command) {
    if (!RegExp(r'\bsold\b').hasMatch(command)) return false;
    if (RegExp(r'\bsold\s+(?:kar|karo|kardo|krdo|mark)\b').hasMatch(command)) {
      return false;
    }
    return true;
  }

  static bool _looksLikeQuestion(String command) =>
      RegExp(
        r'\b(?:what|why|how|when|where|which|who|can|should|could|is|are|kya|kyu|kyun|kaise|kab|kahan|क्या|क्यों|कैसे|कब|कहाँ)\b',
      ).hasMatch(command) ||
      command.contains('?');
}
