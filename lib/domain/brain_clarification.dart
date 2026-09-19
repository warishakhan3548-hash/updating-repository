import 'app_brain.dart';
import 'medicine.dart';

enum BrainChoiceResolutionKind {
  noMatch,
  ambiguous,
  cancelled,
  stale,
  resolved,
}

class BrainChoiceResolution {
  const BrainChoiceResolution(this.kind, {this.stockId});

  final BrainChoiceResolutionKind kind;
  final String? stockId;
}

class BrainChoiceCandidate {
  const BrainChoiceCandidate._({
    required this.id,
    required this.revision,
    required this.title,
    required this.batchNumber,
    required this.barcode,
    required this.block,
    required this.row,
    required this.vertical,
    required this.location,
    required this.address,
  });

  factory BrainChoiceCandidate.fromMedicine(Medicine medicine) =>
      BrainChoiceCandidate._(
        id: medicine.id,
        revision: medicine.revision,
        title: medicine.title,
        batchNumber: medicine.batchNumber,
        barcode: medicine.barcode,
        block: medicine.block,
        row: medicine.row,
        vertical: medicine.vertical,
        location: medicine.location,
        address: medicine.address,
      );

  final String id;
  final int revision;
  final String title;
  final String batchNumber;
  final String barcode;
  final String block;
  final String row;
  final String vertical;
  final String location;
  final String address;

  String get displayCue {
    final facts = <String>[
      title,
      if (batchNumber.trim().isNotEmpty) 'Batch ${batchNumber.trim()}',
      if (barcode.trim().isNotEmpty) 'Barcode ${barcode.trim()}',
      if (address.trim().isNotEmpty) address.trim(),
    ];
    return facts.join(' · ');
  }
}

/// Ephemeral clarification state for rows already displayed to the pharmacist.
/// It has no mutation authority. Every ordinal is revision-bound and the whole
/// mapping fails closed if any displayed row changes before the follow-up.
class PendingBrainChoice {
  PendingBrainChoice({
    required this.intent,
    required Iterable<Medicine> candidates,
    required this.createdAt,
    this.ttl = const Duration(minutes: 5),
  }) : candidates = List<BrainChoiceCandidate>.unmodifiable(
         candidates.map(BrainChoiceCandidate.fromMedicine),
       ) {
    if (this.candidates.length < 2 || this.candidates.length > 12) {
      throw const FormatException(
        'Aaris clarification requires 2 to 12 displayed stock rows.',
      );
    }
    if (ttl.inMilliseconds <= 0 ||
        ttl.inMilliseconds > const Duration(minutes: 15).inMilliseconds) {
      throw const FormatException('Invalid Aaris clarification lifetime.');
    }
    final ids = this.candidates.map((candidate) => candidate.id).toSet();
    if (ids.length != this.candidates.length) {
      throw const FormatException(
        'Aaris clarification cannot contain duplicate stock IDs.',
      );
    }
    if (this.candidates.any((candidate) => candidate.revision < 1)) {
      throw const FormatException(
        'Aaris clarification requires revisioned stock rows.',
      );
    }
    if (intent.action != AppBrainAction.search && !intent.needsMedicineTarget) {
      throw const FormatException(
        'This Aaris action cannot be resumed from a medicine choice.',
      );
    }
  }

  final AppBrainIntent intent;
  final List<BrainChoiceCandidate> candidates;
  final DateTime createdAt;
  final Duration ttl;

  BrainChoiceResolution resolve(
    String raw, {
    required Map<String, Medicine> records,
    required DateTime now,
  }) {
    final text = _choiceText(raw);
    if (text.isEmpty || raw.length > 240) {
      return const BrainChoiceResolution(BrainChoiceResolutionKind.noMatch);
    }
    if (_cancelChoices.contains(text)) {
      return const BrainChoiceResolution(BrainChoiceResolutionKind.cancelled);
    }

    final age = now.difference(createdAt);
    if (age.isNegative || age > ttl || !_isCurrent(records)) {
      return const BrainChoiceResolution(BrainChoiceResolutionKind.stale);
    }

    final ordinal = _choiceOrdinal(text);
    if (ordinal != null) {
      if (ordinal < 1 || ordinal > candidates.length) {
        return const BrainChoiceResolution(BrainChoiceResolutionKind.noMatch);
      }
      return BrainChoiceResolution(
        BrainChoiceResolutionKind.resolved,
        stockId: candidates[ordinal - 1].id,
      );
    }

    final labelled = _labelledMatches(text);
    if (labelled != null) return _resultFor(labelled);

    // Never convert a loose/fuzzy medicine phrase into a destructive target.
    return const BrainChoiceResolution(BrainChoiceResolutionKind.noMatch);
  }

  bool _isCurrent(Map<String, Medicine> records) {
    for (final candidate in candidates) {
      final live = records[candidate.id];
      if (live == null ||
          live.archived ||
          live.revision != candidate.revision) {
        return false;
      }
    }
    return true;
  }

  List<BrainChoiceCandidate>? _labelledMatches(String text) {
    final constraints = <String, String>{};
    var repeatedLabel = false;

    void capture(String key, RegExp expression) {
      final matches = expression.allMatches(text).toList(growable: false);
      if (matches.length > 1) {
        repeatedLabel = true;
        return;
      }
      if (matches.isEmpty) return;
      final value = _trimChoiceGlue(matches.single.group(1) ?? '');
      if (value.isNotEmpty) constraints[key] = value;
    }

    capture(
      'batch',
      RegExp(
        r'(?:^| )(?:batch|बैच)(?: (?:no|number|नंबर))?[:# -]*([a-z0-9ऀ-ॿ._/-]{1,60})',
        caseSensitive: false,
        unicode: true,
      ),
    );
    capture(
      'barcode',
      RegExp(
        r'(?:^| )(?:barcode|bar code|बारकोड)[:# -]*([a-z0-9._/-]{1,80})',
        caseSensitive: false,
        unicode: true,
      ),
    );
    capture(
      'block',
      RegExp(
        r'(?:^| )(?:block|ब्लॉक)[:# -]*([a-z0-9ऀ-ॿ._/-]{1,40})',
        caseSensitive: false,
        unicode: true,
      ),
    );
    capture(
      'row',
      RegExp(
        r'(?:^| )(?:row|रो|पंक्ति)[:# -]*([a-z0-9ऀ-ॿ._/-]{1,40})',
        caseSensitive: false,
        unicode: true,
      ),
    );
    capture(
      'vertical',
      RegExp(
        r'(?:^| )(?:vertical|vert|वर्टिकल)[:# -]*([a-z0-9ऀ-ॿ._/-]{1,40})',
        caseSensitive: false,
        unicode: true,
      ),
    );
    capture(
      'location',
      RegExp(
        r'(?:^| )(?:location|rack|shelf|लोकेशन|रैक|शेल्फ|जगह)[:# -]*([a-z0-9ऀ-ॿ._/-][a-z0-9ऀ-ॿ._/ -]{0,79})$',
        caseSensitive: false,
        unicode: true,
      ),
    );

    if (repeatedLabel) {
      return List<BrainChoiceCandidate>.of(candidates, growable: false);
    }
    if (constraints.isEmpty) return null;

    bool exact(String left, String right) =>
        _choiceText(left) == _choiceText(right);
    bool exactLocation(BrainChoiceCandidate candidate, String cue) =>
        exact(candidate.location, cue) || exact(candidate.address, cue);

    return candidates
        .where((candidate) {
          final batch = constraints['batch'];
          if (batch != null && !exact(candidate.batchNumber, batch))
            return false;
          final barcode = constraints['barcode'];
          if (barcode != null && !exact(candidate.barcode, barcode))
            return false;
          final block = constraints['block'];
          if (block != null && !exact(candidate.block, block)) return false;
          final row = constraints['row'];
          if (row != null && !exact(candidate.row, row)) return false;
          final vertical = constraints['vertical'];
          if (vertical != null && !exact(candidate.vertical, vertical))
            return false;
          final location = constraints['location'];
          if (location != null && !exactLocation(candidate, location))
            return false;
          return true;
        })
        .toList(growable: false);
  }

  BrainChoiceResolution _resultFor(List<BrainChoiceCandidate> matches) {
    if (matches.length == 1) {
      return BrainChoiceResolution(
        BrainChoiceResolutionKind.resolved,
        stockId: matches.single.id,
      );
    }
    if (matches.length > 1) {
      return const BrainChoiceResolution(BrainChoiceResolutionKind.ambiguous);
    }
    return const BrainChoiceResolution(BrainChoiceResolutionKind.noMatch);
  }
}

String _choiceText(String raw) =>
    _asciiDigits(raw.toLowerCase())
        .replaceAll(RegExp(r'[^a-z0-9ऀ-ॿ._/-]+', unicode: true), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();

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

int? _choiceOrdinal(String text) {
  final direct = _ordinals[text];
  if (direct != null) return direct;
  final reduced = text
      .split(' ')
      .where((token) => !_ordinalGlue.contains(token))
      .join(' ');
  final reducedDirect = _ordinals[reduced];
  if (reducedDirect != null) return reducedDirect;
  if (reduced.endsWith(' one')) {
    return _ordinals[reduced.substring(0, reduced.length - 4).trim()];
  }
  return null;
}

String _trimChoiceGlue(String value) {
  final tokens = _choiceText(value).split(' ').toList();
  while (tokens.isNotEmpty && _trailingChoiceGlue.contains(tokens.last)) {
    tokens.removeLast();
  }
  return tokens.join(' ');
}

const _cancelChoices = <String>{
  'cancel',
  'cancel it',
  'never mind',
  'nevermind',
  'leave it',
  'rehne do',
  'rehne dena',
  'chhodo',
  'chhod do',
  'रहने दो',
  'छोड़ो',
  'छोड़ दो',
  'कैंसल',
};

const _ordinals = <String, int>{
  '1': 1,
  '1st': 1,
  'first': 1,
  'one': 1,
  'pehla': 1,
  'pehli': 1,
  'पहला': 1,
  'पहली': 1,
  '2': 2,
  '2nd': 2,
  'second': 2,
  'two': 2,
  'dusra': 2,
  'dusri': 2,
  'doosra': 2,
  'doosri': 2,
  'दूसरा': 2,
  'दूसरी': 2,
  '3': 3,
  '3rd': 3,
  'third': 3,
  'three': 3,
  'teesra': 3,
  'teesri': 3,
  'तीसरा': 3,
  'तीसरी': 3,
  '4': 4,
  '4th': 4,
  'fourth': 4,
  'four': 4,
  'chautha': 4,
  'चौथा': 4,
  '5': 5,
  '5th': 5,
  'fifth': 5,
  'five': 5,
  'paanchva': 5,
  'पांचवां': 5,
  '6': 6,
  '6th': 6,
  'sixth': 6,
  'six': 6,
  'chhatha': 6,
  'छठा': 6,
  '7': 7,
  '7th': 7,
  'seventh': 7,
  'seven': 7,
  'saatva': 7,
  'सातवां': 7,
  '8': 8,
  '8th': 8,
  'eighth': 8,
  'eight': 8,
  'aathva': 8,
  'आठवां': 8,
  '9': 9,
  '9th': 9,
  'ninth': 9,
  'nine': 9,
  'nauva': 9,
  'नौवां': 9,
  '10': 10,
  '10th': 10,
  'tenth': 10,
  'ten': 10,
  '11': 11,
  '11th': 11,
  'eleventh': 11,
  '12': 12,
  '12th': 12,
  'twelfth': 12,
};

const _ordinalGlue = <String>{
  'option',
  'number',
  'no',
  'the',
  'choose',
  'select',
  'pick',
  'medicine',
  'stock',
  'entry',
  'wali',
  'waali',
  'wala',
  'waala',
  'ko',
  'please',
  'karo',
  'kar',
  'do',
  'ऑप्शन',
  'नंबर',
  'वाली',
  'वाला',
  'मेडिसिन',
  'स्टॉक',
  'एंट्री',
  'को',
  'चुनो',
  'सेलेक्ट',
  'सिलेक्ट',
  'करो',
  'कर',
  'दो',
};

const _trailingChoiceGlue = <String>{
  'wali',
  'waali',
  'wala',
  'waala',
  'medicine',
  'stock',
  'entry',
  'choose',
  'select',
  'karo',
  'kar',
  'do',
  'वाली',
  'वाला',
  'मेडिसिन',
  'स्टॉक',
  'एंट्री',
  'चुनो',
  'सेलेक्ट',
  'सिलेक्ट',
  'करो',
  'कर',
  'दो',
};
