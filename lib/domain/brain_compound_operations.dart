import 'app_brain.dart';
import 'brain_operations.dart';

/// A deliberately narrow two-clause work command that can be reviewed and
/// committed as one transaction. It is not a general workflow language.
class BrainStockAdjustmentAndLocationCommand {
  const BrainStockAdjustmentAndLocationCommand({
    required this.action,
    required this.query,
    required this.quantity,
    required this.locationPatch,
  });

  final AppBrainAction action;
  final String query;
  final int quantity;
  final StockLocationPatch locationPatch;

  AppBrainIntent toIntent() => AppBrainIntent(
    action: action,
    query: query,
    quantity: quantity,
    locationPatch: locationPatch,
    confidence: 1,
  );
}

/// Recognizes only: one exact stock adjustment + one physical-location update.
///
/// Both clauses are independently parsed through the existing Aaris Brain
/// firewall. Alternatives, more than two clauses, mismatched medicine targets,
/// incomplete quantities, destructive lifecycle actions and deferred/negated
/// instructions are rejected. Returning null gives the ordinary parser full
/// control, which means unsafe compound commands continue to fail closed.
BrainStockAdjustmentAndLocationCommand?
parseBrainStockAdjustmentAndLocationCommand(String raw) {
  final value = raw.trim();
  if (value.isEmpty || value.length > 900 || _containsChoiceConnector(value)) {
    return null;
  }

  final clauses = value
      .split(_sequenceConnector)
      .map((part) => part.trim())
      .where((part) => part.isNotEmpty)
      .toList(growable: false);
  if (clauses.length != 2) return null;

  late final AppBrainIntent first;
  late final AppBrainIntent second;
  try {
    first = parseAppBrainIntent(clauses[0]);
    second = parseAppBrainIntent(clauses[1]);
  } on FormatException {
    return null;
  }

  AppBrainIntent? adjustment;
  AppBrainIntent? location;
  for (final intent in <AppBrainIntent>[first, second]) {
    switch (intent.action) {
      case AppBrainAction.setQuantity:
      case AppBrainAction.receiveStock:
        if (adjustment != null || intent.quantity == null) return null;
        adjustment = intent;
      case AppBrainAction.relocateMedicine:
        if (location != null || intent.locationPatch == null) return null;
        location = intent;
      default:
        return null;
    }
  }

  final stockIntent = adjustment;
  final locationIntent = location;
  if (stockIntent == null || locationIntent == null) return null;

  final query = _mergeTargets(stockIntent.query, locationIntent.query);
  if (query == null) return null;
  return BrainStockAdjustmentAndLocationCommand(
    action: stockIntent.action,
    query: query,
    quantity: stockIntent.quantity!,
    locationPatch: locationIntent.locationPatch!,
  );
}

String? _mergeTargets(String first, String second) {
  final a = first.trim();
  final b = second.trim();
  final aImplicit = a.isEmpty || isAppBrainContextReference(a);
  final bImplicit = b.isEmpty || isAppBrainContextReference(b);

  if (!aImplicit && !bImplicit) {
    return _targetKey(a) == _targetKey(b) ? a : null;
  }
  if (!aImplicit) return a;
  if (!bImplicit) return b;
  if (a.isNotEmpty) return a;
  return b;
}

String _targetKey(String value) => value
    .toLowerCase()
    .replaceAll(RegExp(r'[^a-z0-9\u0900-\u097f]+', unicode: true), ' ')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

bool _containsChoiceConnector(String raw) {
  final text = _targetKey(raw);
  return RegExp(
    r'(^|\s)(?:or|either|versus|vs|ya|या)(?=\s|$)',
    caseSensitive: false,
    unicode: true,
  ).hasMatch(text);
}

final _sequenceConnector = RegExp(
  r'(?:\s*[,;]\s*|\s+)(?:and\s+then|then|aur\s+phir|aur\s+fir|phir|fir|uske\s+baad|और\s+फिर|फिर|उसके\s+बाद)(?=\s|[,;]|$)\s*[,;]?\s*',
  caseSensitive: false,
  unicode: true,
);
