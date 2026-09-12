import 'medicine.dart';
import 'tracking.dart';

enum BrainAnalyticsFocus { salesSummary, fastMoving, slowMoving }

enum BrainAnalyticsRangeKind { today, lastDays, weekToDate, monthToDate }

/// A read-only local analytics request understood by Aaris Brain.
///
/// This object never carries a medicine mutation. It only selects a deterministic
/// TrackingStats projection over already-recorded sale/inventory facts.
class BrainAnalyticsRequest {
  const BrainAnalyticsRequest({
    required this.focus,
    required this.rangeKind,
    this.days = 30,
  });

  final BrainAnalyticsFocus focus;
  final BrainAnalyticsRangeKind rangeKind;
  final int days;

  TrackingRange resolveRange(DateTime today) {
    final day = civilDay(today);
    return switch (rangeKind) {
      BrainAnalyticsRangeKind.today => TrackingRange(start: day, end: day),
      BrainAnalyticsRangeKind.lastDays => TrackingRange.lastDays(day, days),
      BrainAnalyticsRangeKind.weekToDate => TrackingRange(
        start: day.subtract(Duration(days: day.weekday - DateTime.monday)),
        end: day,
      ),
      BrainAnalyticsRangeKind.monthToDate => TrackingRange(
        start: DateTime.utc(day.year, day.month, 1),
        end: day,
      ),
    };
  }

  String rangeLabel(DateTime today) {
    final range = resolveRange(today);
    return switch (rangeKind) {
      BrainAnalyticsRangeKind.today => 'today',
      BrainAnalyticsRangeKind.weekToDate =>
        'this week (${dateText(range.start)} to ${dateText(range.end)})',
      BrainAnalyticsRangeKind.monthToDate =>
        'this month (${dateText(range.start)} to ${dateText(range.end)})',
      BrainAnalyticsRangeKind.lastDays =>
        '${range.days} day${range.days == 1 ? '' : 's'} (${dateText(range.start)} to ${dateText(range.end)})',
    };
  }
}

/// Parses only explicitly read-only sales/movement language.
///
/// Write verbs such as `sell`, `record sale`, quantity mutations and medical
/// questions are intentionally outside this grammar. That keeps the app's
/// existing mutation firewall authoritative and prevents an analytics phrase
/// from becoming a stock-changing command.
BrainAnalyticsRequest? parseBrainAnalyticsRequest(String raw) {
  if (raw.trim().isEmpty || raw.length > 500) return null;
  final text = _normalized(raw);
  final focus = _analyticsFocus(text);
  if (focus == null) return null;

  final explicitDays = _explicitDayWindow(raw);
  if (explicitDays != null) {
    if (explicitDays < 1 || explicitDays > 3660) return null;
    return BrainAnalyticsRequest(
      focus: focus,
      rangeKind: explicitDays == 1
          ? BrainAnalyticsRangeKind.today
          : BrainAnalyticsRangeKind.lastDays,
      days: explicitDays,
    );
  }

  if (_containsAny(text, _todayTerms)) {
    return BrainAnalyticsRequest(
      focus: focus,
      rangeKind: BrainAnalyticsRangeKind.today,
      days: 1,
    );
  }
  if (_containsAny(text, _weekTerms)) {
    return BrainAnalyticsRequest(
      focus: focus,
      rangeKind: BrainAnalyticsRangeKind.weekToDate,
    );
  }
  if (_containsAny(text, _monthTerms)) {
    return BrainAnalyticsRequest(
      focus: focus,
      rangeKind: BrainAnalyticsRangeKind.monthToDate,
    );
  }

  return BrainAnalyticsRequest(
    focus: focus,
    rangeKind: BrainAnalyticsRangeKind.lastDays,
  );
}

String buildBrainAnalyticsBrief({
  required BrainAnalyticsRequest request,
  required TrackingStats stats,
  required DateTime today,
}) {
  final period = request.rangeLabel(today);
  return switch (request.focus) {
    BrainAnalyticsFocus.salesSummary => _salesSummary(stats, period),
    BrainAnalyticsFocus.fastMoving => _fastMoving(stats, period),
    BrainAnalyticsFocus.slowMoving => _slowMoving(stats, period),
  };
}

String _salesSummary(TrackingStats stats, String period) {
  if (stats.recordedSales == 0) {
    return 'Sales brief · $period: no recorded sale events. Aaris is reading only the local sale ledger; it will not infer missing sales.';
  }

  final knownAmountEvents = stats.recordedSales - stats.unknownRevenueSales;
  final amount = knownAmountEvents == 0
      ? 'sale amount not recorded for these events'
      : 'known sale amount ${money(stats.revenuePaise)}${stats.unknownRevenueSales == 0 ? '' : ' · ${stats.unknownRevenueSales} event${stats.unknownRevenueSales == 1 ? '' : 's'} missing sale amount'}';
  final fastest = stats.fastestMoving.take(3).toList(growable: false);
  final movers = fastest.isEmpty
      ? ''
      : ' · Top movement: ${fastest.map(_movementCue).join(' · ')}';
  return 'Sales brief · $period: ${stats.recordedSales} recorded sale event${stats.recordedSales == 1 ? '' : 's'} · ${stats.unitsSold} unit${stats.unitsSold == 1 ? '' : 's'} sold · $amount$movers.';
}

String _fastMoving(TrackingStats stats, String period) {
  final rows = stats.fastestMoving.take(5).toList(growable: false);
  if (rows.isEmpty) {
    return 'Fast-moving brief · $period: no recorded movement is available. Aaris will not manufacture a demand ranking from missing sales.';
  }
  return 'Fast-moving brief · $period: ${rows.map(_movementCue).join(' · ')}. Ranking uses recorded sale units only.';
}

String _slowMoving(TrackingStats stats, String period) {
  final rows = stats.slowMoving.take(5).toList(growable: false);
  if (rows.isEmpty) {
    return 'Slow-moving brief · $period: no currently stocked product falls below the deterministic movement threshold from recorded sales.';
  }
  return 'Slow-moving brief · $period: ${rows.map(_movementCue).join(' · ')}. This is an operational stock signal, not medical advice.';
}

String _movementCue(ProductMovement movement) =>
    '${movement.title}: ${movement.unitsSold} unit${movement.unitsSold == 1 ? '' : 's'} · ${movement.unitsPerDay.toStringAsFixed(2)}/day';

BrainAnalyticsFocus? _analyticsFocus(String text) {
  if (_containsAny(text, _fastTerms)) return BrainAnalyticsFocus.fastMoving;
  if (_containsAny(text, _slowTerms)) return BrainAnalyticsFocus.slowMoving;
  if (_containsAny(text, _summaryTerms))
    return BrainAnalyticsFocus.salesSummary;
  return null;
}

int? _explicitDayWindow(String raw) {
  final patterns = <RegExp>[
    RegExp(
      r'(?:last|past|previous|pichle|pichhle|pichli|पिछले|पिछली)\s*([0-9०-९]{1,4})\s*(?:days?|din|दिन)',
      caseSensitive: false,
      unicode: true,
    ),
    RegExp(
      r'([0-9०-९]{1,4})\s*(?:days?|din|दिन)\s*(?:sales?|sale|bikri|बिक्री|movement|moving)',
      caseSensitive: false,
      unicode: true,
    ),
  ];
  final found = <String>[];
  for (final pattern in patterns) {
    for (final match in pattern.allMatches(raw)) {
      final value = match.group(1);
      if (value != null) found.add(value);
    }
  }
  if (found.isEmpty) return null;
  final distinct = found.map(_asciiDigits).toSet();
  if (distinct.length != 1) return -1;
  return int.tryParse(distinct.single);
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

const _summaryTerms = <String>[
  'sales summary',
  'sale summary',
  'sales today',
  'today sales',
  'today sale',
  'sales report',
  'sale report',
  'sales kitni',
  'sale kitni',
  'bikri kitni',
  'bikri batao',
  'aaj ki bikri',
  'aaj bikri',
  'aaj ki sale',
  'आज की बिक्री',
  'बिक्री रिपोर्ट',
  'बिक्री कितनी',
];

const _fastTerms = <String>[
  'fast moving',
  'fastest moving',
  'top selling',
  'best selling',
  'fast mover',
  'tez bik',
  'तेज बिक',
  'सबसे ज्यादा बिक',
  'सबसे ज़्यादा बिक',
];

const _slowTerms = <String>[
  'slow moving',
  'slowest moving',
  'slow mover',
  'kam bik',
  'कम बिक',
  'कम बिकने',
];

const _todayTerms = <String>['today', 'aaj', 'आज'];

const _weekTerms = <String>[
  'this week',
  'week to date',
  'is hafte',
  'iss hafte',
  'इस हफ्ते',
  'इस सप्ताह',
];

const _monthTerms = <String>[
  'this month',
  'month to date',
  'is mahine',
  'iss mahine',
  'इस महीने',
];
