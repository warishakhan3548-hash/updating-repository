#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


def write(path: str, content: str) -> None:
    target = ROOT / path
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(content, encoding="utf-8")


def replace_once(path: str, old: str, new: str) -> None:
    text = read(path)
    if new in text:
        return
    count = text.count(old)
    if count != 1:
        raise RuntimeError(f"{path}: expected one replacement anchor, found {count}")
    write(path, text.replace(old, new, 1))


def insert_before_once(path: str, anchor: str, addition: str) -> None:
    text = read(path)
    if addition in text:
        return
    count = text.count(anchor)
    if count != 1:
        raise RuntimeError(f"{path}: expected one insertion anchor, found {count}")
    write(path, text.replace(anchor, addition + anchor, 1))


def create_exact(path: str, content: str) -> None:
    target = ROOT / path
    if target.exists():
        existing = target.read_text(encoding="utf-8")
        if existing != content:
            raise RuntimeError(f"{path}: file already exists with different content")
        return
    write(path, content)


create_exact(
    "lib/domain/brain_compound_operations.dart",
    r'''import 'app_brain.dart';
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
''',
)

replace_once(
    "lib/domain/app_brain.dart",
    r'''bool _looksLikeScheduledMutation(String raw) =>
    RegExp(
      r'\b(?:at\s+)?(?:[01]?\d|2[0-3]):[0-5]\d(?:\s*(?:a\.?m\.?|p\.?m\.?)\b)?',
      caseSensitive: false,
    ).hasMatch(raw) ||
    RegExp(
      r'\b(?:[1-9]|1[0-2])\s*(?:a\.?m\.?|p\.?m\.?)\b',
      caseSensitive: false,
    ).hasMatch(raw) ||
    RegExp(
      r'\b(?:on\s+)?(?:\d{1,2}[/-]\d{1,2}(?:[/-]\d{2,4})?|\d{4}-\d{2}-\d{2})\b',
      caseSensitive: false,
    ).hasMatch(raw) ||
    RegExp(
      r'\b(?:in\s+)?\d+\s*(?:minutes?|hours?|days?|weeks?|months?)\b',
      caseSensitive: false,
    ).hasMatch(raw) ||
    RegExp(
      r'(?:[0-9०-९]+\s*बजे|[0-9०-९]+\s*(?:ghante|din|hafte|mahine)\s*baad)',
      caseSensitive: false,
      unicode: true,
    ).hasMatch(raw);
''',
    r'''bool _looksLikeScheduledMutation(String raw) {
  if (RegExp(
        r'\b(?:at\s+)?(?:[01]?\d|2[0-3]):[0-5]\d(?:\s*(?:a\.?m\.?|p\.?m\.?)\b)?',
        caseSensitive: false,
      ).hasMatch(raw) ||
      RegExp(
        r'\b(?:[1-9]|1[0-2])\s*(?:a\.?m\.?|p\.?m\.?)\b',
        caseSensitive: false,
      ).hasMatch(raw) ||
      RegExp(
        r'\b(?:in\s+)?\d+\s*(?:minutes?|hours?|days?|weeks?|months?)\b',
        caseSensitive: false,
      ).hasMatch(raw) ||
      RegExp(
        r'(?:[0-9०-९]+\s*बजे|[0-9०-९]+\s*(?:ghante|din|hafte|mahine)\s*baad)',
        caseSensitive: false,
        unicode: true,
      ).hasMatch(raw)) {
    return true;
  }

  // Calendar-looking values are common stock identifiers when immediately
  // labelled EXP/expiry/MFG/MFD. Treat only that narrow evidence shape as an
  // inventory fact. Unlabelled dates and schedule-shaped prefixes remain
  // deferred instructions and therefore fail closed.
  final calendar = RegExp(
    r'\b(?:\d{1,2}[/-]\d{1,2}(?:[/-]\d{2,4})?|\d{4}-\d{2}-\d{2}|\d{1,2}\s+(?:jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|jun(?:e)?|jul(?:y)?|aug(?:ust)?|sep(?:t(?:ember)?)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?)\s+\d{2,4}|(?:jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|jun(?:e)?|jul(?:y)?|aug(?:ust)?|sep(?:t(?:ember)?)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?)\s+\d{1,2}(?:,\s*)?\d{4})\b',
    caseSensitive: false,
  );
  for (final match in calendar.allMatches(raw)) {
    if (!_isLabelledInventoryDate(raw, match.start)) return true;
  }
  return false;
}

bool _isLabelledInventoryDate(String raw, int dateStart) {
  final start = dateStart > 96 ? dateStart - 96 : 0;
  final prefix = raw.substring(start, dateStart);
  final label = RegExp(
    r'(?:exp\.?|expiry(?:\s+date)?|mfg\.?|mfd\.?|manufactur(?:e|ed|ing)(?:\s+date)?|एक्सपायरी|एक्सपाइरी|एमएफजी|एमएफडी)\s*[:#=-]?\s*$',
    caseSensitive: false,
    unicode: true,
  ).firstMatch(prefix);
  if (label == null) return false;

  final beforeLabel = _normalized(prefix.substring(0, label.start));
  if (beforeLabel.isEmpty) return true;
  final previous = beforeLabel.split(' ').last;
  return !_dateSchedulingPrefixes.contains(previous);
}

const _dateSchedulingPrefixes = <String>{
  'on',
  'at',
  'after',
  'before',
  'by',
  'until',
  'till',
  'when',
  'jab',
  'baad',
  'pehle',
  'par',
  'ko',
  'जब',
  'बाद',
  'पहले',
  'पर',
  'को',
};
''',
)

replace_once(
    "lib/ui/brain_screen.dart",
    "import '../domain/brain_clarification.dart';\n",
    "import '../domain/brain_clarification.dart';\nimport '../domain/brain_compound_operations.dart';\n",
)

replace_once(
    "lib/ui/brain_screen.dart",
    r'''      if (await _continuePendingChoice(raw)) return;
      final intent = parseAppBrainIntent(raw);
      await _execute(intent, raw);
''',
    r'''      if (await _continuePendingChoice(raw)) return;
      final compound = parseBrainStockAdjustmentAndLocationCommand(raw);
      if (compound != null) {
        await _medicineAction(compound.toIntent());
        return;
      }
      final intent = parseAppBrainIntent(raw);
      await _execute(intent, raw);
''',
)

replace_once(
    "lib/ui/brain_screen.dart",
    r'''    final instruction = switch (action) {
      AppBrainAction.recordSale when requestedQuantity != null =>
        '${record.title} matched. Preparing a deterministic $requestedQuantity-unit FEFO allocation across active batches.',
      AppBrainAction.setQuantity when requestedQuantity != null =>
        '${record.title} matched. Preparing an exact stock correction to $requestedQuantity units.',
      AppBrainAction.receiveStock when requestedQuantity != null =>
        '${record.title} matched. Preparing a reviewed +$requestedQuantity-unit stock receipt.',
      AppBrainAction.relocateMedicine when locationPatch != null =>
        '${record.title} matched. Preparing a reviewed location change: ${describeStockLocationPatch(locationPatch)}.',
      _ => _editorInstruction(action, record),
    };
''',
    r'''    final instruction = switch (action) {
      AppBrainAction.recordSale when requestedQuantity != null =>
        '${record.title} matched. Preparing a deterministic $requestedQuantity-unit FEFO allocation across active batches.',
      AppBrainAction.setQuantity
          when requestedQuantity != null && locationPatch != null =>
        '${record.title} matched. Preparing one atomic stock correction to $requestedQuantity units plus ${describeStockLocationPatch(locationPatch)}.',
      AppBrainAction.receiveStock
          when requestedQuantity != null && locationPatch != null =>
        '${record.title} matched. Preparing one atomic +$requestedQuantity-unit receipt plus ${describeStockLocationPatch(locationPatch)}.',
      AppBrainAction.setQuantity when requestedQuantity != null =>
        '${record.title} matched. Preparing an exact stock correction to $requestedQuantity units.',
      AppBrainAction.receiveStock when requestedQuantity != null =>
        '${record.title} matched. Preparing a reviewed +$requestedQuantity-unit stock receipt.',
      AppBrainAction.relocateMedicine when locationPatch != null =>
        '${record.title} matched. Preparing a reviewed location change: ${describeStockLocationPatch(locationPatch)}.',
      _ => _editorInstruction(action, record),
    };
''',
)

replace_once(
    "lib/ui/brain_screen.dart",
    r'''    // Short deterministic mutations always resolve an exact stock row first,
    // prepare a review tied to the current inventory revision, and still require
    // a pharmacist confirmation before the controller can commit anything.
    if (action == AppBrainAction.removeMedicine) {
''',
    r'''    // A safe two-clause stock+location command becomes one reviewed
    // transaction. The combined path prevents a partial quantity-only or
    // location-only write if the second half becomes stale or invalid.
    if ((action == AppBrainAction.setQuantity ||
            action == AppBrainAction.receiveStock) &&
        requestedQuantity != null &&
        locationPatch != null) {
      await _reviewStockAdjustmentAndLocation(
        record,
        action,
        requestedQuantity,
        locationPatch,
      );
      return;
    }

    // Short deterministic mutations always resolve an exact stock row first,
    // prepare a review tied to the current inventory revision, and still require
    // a pharmacist confirmation before the controller can commit anything.
    if (action == AppBrainAction.removeMedicine) {
''',
)

insert_before_once(
    "lib/ui/brain_screen.dart",
    r'''  Future<void> _reviewStockAdjustment(
''',
    r'''  Future<void> _reviewStockAdjustmentAndLocation(
    Medicine original,
    AppBrainAction action,
    int quantity,
    StockLocationPatch patch,
  ) async {
    if (!mounted) return;
    final kind = action == AppBrainAction.receiveStock
        ? StockAdjustmentKind.receive
        : StockAdjustmentKind.setExact;
    final review = widget.controller.reviewStockAdjustmentAndLocation(
      original.id,
      kind: kind,
      quantity: quantity,
      locationPatch: patch,
    );
    final live = widget.controller.snapshot.records[review.stockId];
    if (live == null || live.archived) {
      throw StateError(
        'That stock entry is no longer active. Nothing changed.',
      );
    }
    if (!review.changesQuantity && !review.changesLocation) {
      setState(
        () => _reply =
            '${live.title} already has the requested stock count and location. No inventory change was needed.',
      );
      return;
    }

    final beforeQuantity = review.beforeQuantity == null
        ? 'unknown'
        : '${review.beforeQuantity} units';
    final receive = kind == StockAdjustmentKind.receive;
    final confirmed =
        await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (ctx) => AlertDialog(
            title: Text(
              receive
                  ? 'Receive $quantity units + update location?'
                  : 'Correct stock + update location?',
            ),
            content: SingleChildScrollView(
              child: Text(
                '${_stockIdentityCue(live)}\n\nQuantity\nBefore: $beforeQuantity\nAfter: ${review.afterQuantity} units\n\nLocation\nBefore: ${review.beforeLocationDisplay}\nAfter: ${review.afterLocationDisplay}\n\n${review.wasSold ? 'This entry is currently SOLD. Receiving stock will explicitly reopen it while preserving historical sale events.\n\n' : ''}Both changes will save together as ONE revision-checked, audited and undoable inventory transaction. If this exact stock row changes before commit, neither half is saved.',
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: Text(receive ? 'Receive + move' : 'Correct + move'),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed || !mounted) {
      setState(() => _reply = 'Combined stock action cancelled. Nothing changed.');
      return;
    }

    await widget.controller.applyStockAdjustmentAndLocation(review);
    if (!mounted) return;
    final updated = widget.controller.snapshot.records[live.id];
    if (updated != null && !updated.archived) _remember(updated);
    setState(
      () => _reply = receive
          ? '${live.title}: +$quantity units received and location updated to ${review.afterLocationDisplay} in one atomic transaction. Undo is available.'
          : '${live.title}: stock corrected to ${review.afterQuantity} units and location updated to ${review.afterLocationDisplay} in one atomic transaction. Sales history was not changed; Undo is available.',
    );
  }

''',
)

replace_once(
    "lib/state/pharmacy_controller.dart",
    "import '../domain/backup.dart';\n",
    "import '../domain/backup.dart';\nimport '../domain/brain_operations.dart';\n",
)

insert_before_once(
    "lib/state/pharmacy_controller.dart",
    r'''class BulkArchiveReview {
''',
    r'''class ReviewedStockAdjustmentAndLocation {
  const ReviewedStockAdjustmentAndLocation({
    required this.baseRevision,
    required this.stockId,
    required this.recordRevision,
    required this.kind,
    required this.requestedQuantity,
    required this.beforeQuantity,
    required this.afterQuantity,
    required this.wasSold,
    required this.locationPatch,
    required this.beforeBlock,
    required this.beforeRow,
    required this.beforeVertical,
    required this.beforeLocation,
    required this.afterBlock,
    required this.afterRow,
    required this.afterVertical,
    required this.afterLocation,
  });

  final int baseRevision;
  final String stockId;
  final int recordRevision;
  final StockAdjustmentKind kind;
  final int requestedQuantity;
  final int? beforeQuantity;
  final int afterQuantity;
  final bool wasSold;
  final StockLocationPatch locationPatch;
  final String beforeBlock;
  final String beforeRow;
  final String beforeVertical;
  final String beforeLocation;
  final String afterBlock;
  final String afterRow;
  final String afterVertical;
  final String afterLocation;

  bool get changesQuantity => beforeQuantity != afterQuantity;
  bool get changesLocation =>
      beforeBlock != afterBlock ||
      beforeRow != afterRow ||
      beforeVertical != afterVertical ||
      beforeLocation != afterLocation;

  String get beforeLocationDisplay => _stockLocationDisplay(
    beforeBlock,
    beforeRow,
    beforeVertical,
    beforeLocation,
  );
  String get afterLocationDisplay => _stockLocationDisplay(
    afterBlock,
    afterRow,
    afterVertical,
    afterLocation,
  );
}

String _stockLocationDisplay(
  String block,
  String row,
  String vertical,
  String location,
) {
  final parts = <String>[
    if (block.isNotEmpty) 'Block $block',
    if (row.isNotEmpty) 'Row $row',
    if (vertical.isNotEmpty) 'Vertical $vertical',
    if (location.isNotEmpty) location,
  ];
  return parts.isEmpty ? 'No location recorded' : parts.join(' · ');
}

''',
)

insert_before_once(
    "lib/state/pharmacy_controller.dart",
    r'''  Future<void> recordSale(
''',
    r'''  ReviewedStockAdjustmentAndLocation reviewStockAdjustmentAndLocation(
    String id, {
    required StockAdjustmentKind kind,
    required int quantity,
    required StockLocationPatch locationPatch,
  }) {
    final medicine = snapshot.records[id];
    if (medicine == null || medicine.archived) {
      throw StateError(
        'Choose an active stock entry before changing stock and location.',
      );
    }
    if (medicine.sold && kind != StockAdjustmentKind.receive) {
      throw StateError(
        'This entry is SOLD. Receive stock before assigning an active physical-stock location.',
      );
    }

    final adjustment = reviewStockAdjustment(
      id,
      kind: kind,
      quantity: quantity,
    );
    final patch = sanitizeStockLocationPatch(locationPatch);
    return ReviewedStockAdjustmentAndLocation(
      baseRevision: snapshot.revision,
      stockId: medicine.id,
      recordRevision: medicine.revision,
      kind: adjustment.kind,
      requestedQuantity: adjustment.requestedQuantity,
      beforeQuantity: adjustment.beforeQuantity,
      afterQuantity: adjustment.afterQuantity,
      wasSold: adjustment.wasSold,
      locationPatch: patch,
      beforeBlock: medicine.block,
      beforeRow: medicine.row,
      beforeVertical: medicine.vertical,
      beforeLocation: medicine.location,
      afterBlock: patch.block ?? medicine.block,
      afterRow: patch.row ?? medicine.row,
      afterVertical: patch.vertical ?? medicine.vertical,
      afterLocation: patch.location ?? medicine.location,
    );
  }

  Future<void> applyStockAdjustmentAndLocation(
    ReviewedStockAdjustmentAndLocation review,
  ) async {
    final live = snapshot.records[review.stockId];
    if (live == null ||
        live.archived ||
        live.revision != review.recordRevision) {
      throw StateError(
        'The reviewed stock entry changed or is no longer active. Review the combined action again.',
      );
    }

    final fresh = reviewStockAdjustmentAndLocation(
      live.id,
      kind: review.kind,
      quantity: review.requestedQuantity,
      locationPatch: review.locationPatch,
    );
    if (fresh.beforeQuantity != review.beforeQuantity ||
        fresh.afterQuantity != review.afterQuantity ||
        fresh.wasSold != review.wasSold ||
        fresh.beforeBlock != review.beforeBlock ||
        fresh.beforeRow != review.beforeRow ||
        fresh.beforeVertical != review.beforeVertical ||
        fresh.beforeLocation != review.beforeLocation ||
        fresh.afterBlock != review.afterBlock ||
        fresh.afterRow != review.afterRow ||
        fresh.afterVertical != review.afterVertical ||
        fresh.afterLocation != review.afterLocation) {
      throw StateError(
        'Stock or location facts changed after review. Nothing was saved; review both changes again.',
      );
    }
    if (!fresh.changesQuantity && !fresh.changesLocation) return;

    final changes = <String, dynamic>{
      'quantity': fresh.afterQuantity,
      'block': fresh.afterBlock,
      'row': fresh.afterRow,
      'vertical': fresh.afterVertical,
      'location': fresh.afterLocation,
    };
    if (fresh.kind == StockAdjustmentKind.receive && live.sold) {
      changes.addAll({
        'sold': false,
        'soldAt': null,
        'soldQuantity': null,
        'soldUnitPricePaise': null,
      });
    }
    final quantityLabel = fresh.kind == StockAdjustmentKind.receive
        ? '+${fresh.requestedQuantity} units (${fresh.beforeQuantity}→${fresh.afterQuantity})'
        : '${fresh.beforeQuantity == null ? 'unknown' : fresh.beforeQuantity}→${fresh.afterQuantity} units';
    await _commit(
      InventoryMutation(
        expectedRevision: fresh.baseRevision,
        label:
            'Stock + location · ${live.name} · $quantityLabel · ${fresh.afterLocationDisplay}',
        upserts: [live.patch(changes)],
      ),
    );
  }

''',
)

create_exact(
    "test/brain_compound_stock_operation_test.dart",
    r'''import 'package:aaris_pharmacy/data/inventory_database.dart';
import 'package:aaris_pharmacy/domain/app_brain.dart';
import 'package:aaris_pharmacy/domain/brain_compound_operations.dart';
import 'package:aaris_pharmacy/domain/brain_operations.dart';
import 'package:aaris_pharmacy/domain/medicine.dart';
import 'package:aaris_pharmacy/state/pharmacy_controller.dart';
import 'package:flutter_test/flutter_test.dart';

Medicine _stock(
  String id, {
  int quantity = 10,
  bool sold = false,
  String location = 'Rack A',
}) => Medicine.fromJson({
  'id': id,
  'name': 'Dolo',
  'strength': '650 mg',
  'form': 'Tablet',
  'quantity': sold ? 0 : quantity,
  'expiry': '2027-12',
  'location': location,
  'sold': sold,
  'soldAt': sold ? '2026-09-09T10:00:00.000' : null,
  'soldQuantity': sold ? quantity : null,
  'revision': 1,
});

Future<PharmacyController> _controller() async {
  final controller = PharmacyController(
    MemoryInventoryStorage(),
    clock: () => DateTime(2026, 9, 10, 12),
    backgroundSearch: false,
  );
  await controller.initialize();
  return controller;
}

void main() {
  group('Aaris Brain atomic stock work command parser', () {
    test('accepts only stock adjustment plus location as two safe clauses', () {
      final command = parseBrainStockAdjustmentAndLocationCommand(
        'Dolo 650 stock add 5 units then location Rack C set karo',
      );
      expect(command, isNotNull);
      expect(command!.action, AppBrainAction.receiveStock);
      expect(command.query, 'Dolo 650');
      expect(command.quantity, 5);
      expect(command.locationPatch.location, 'Rack C');

      final reverse = parseBrainStockAdjustmentAndLocationCommand(
        'isko location Rack B set karo phir stock add ३ units',
      );
      expect(reverse, isNotNull);
      expect(reverse!.action, AppBrainAction.receiveStock);
      expect(reverse.quantity, 3);
      expect(isAppBrainContextReference(reverse.query), isTrue);
    });

    test('different targets, choices and destructive compounds never stage', () {
      expect(
        parseBrainStockAdjustmentAndLocationCommand(
          'Dolo stock add 5 units then Crocin location Rack B set karo',
        ),
        isNull,
      );
      expect(
        parseBrainStockAdjustmentAndLocationCommand(
          'Dolo stock add 5 units or location Rack B set karo',
        ),
        isNull,
      );
      expect(
        parseBrainStockAdjustmentAndLocationCommand(
          'Dolo stock add 5 units then delete Dolo',
        ),
        isNull,
      );
      expect(
        parseAppBrainIntent(
          'Dolo stock add 5 units then delete Dolo',
        ).action,
        AppBrainAction.safetyBlocked,
      );
    });

    test('future or negated clause cannot be upgraded into an atomic command', () {
      expect(
        parseBrainStockAdjustmentAndLocationCommand(
          'Dolo stock add 5 units tomorrow then location Rack B set karo',
        ),
        isNull,
      );
      expect(
        parseBrainStockAdjustmentAndLocationCommand(
          'Dolo quantity 20 set mat karo then location Rack B set karo',
        ),
        isNull,
      );
    });
  });

  group('atomic stock and location transaction', () {
    test('updates both facts in one audited undoable commit', () async {
      final controller = await _controller();
      addTearDown(controller.dispose);
      await controller.save(_stock('a'), expectedRevision: 0);

      final review = controller.reviewStockAdjustmentAndLocation(
        'a',
        kind: StockAdjustmentKind.receive,
        quantity: 5,
        locationPatch: const StockLocationPatch(location: 'Rack C'),
      );
      expect(review.beforeQuantity, 10);
      expect(review.afterQuantity, 15);
      expect(review.beforeLocationDisplay, 'Rack A');
      expect(review.afterLocationDisplay, 'Rack C');

      await controller.applyStockAdjustmentAndLocation(review);
      final changed = controller.snapshot.records['a']!;
      expect(changed.quantity, 15);
      expect(changed.location, 'Rack C');
      expect(controller.sales, isEmpty);
      expect(controller.snapshot.events.first['label'], contains('Stock + location'));

      await controller.undo();
      final restored = controller.snapshot.records['a']!;
      expect(restored.quantity, 10);
      expect(restored.location, 'Rack A');
    });

    test('unrelated writes survive but exact target edits invalidate review', () async {
      final controller = await _controller();
      addTearDown(controller.dispose);
      await controller.save(_stock('a'), expectedRevision: 0);
      final review = controller.reviewStockAdjustmentAndLocation(
        'a',
        kind: StockAdjustmentKind.receive,
        quantity: 2,
        locationPatch: const StockLocationPatch(location: 'Rack B'),
      );
      await controller.save(_stock('b'), expectedRevision: 1);

      await controller.applyStockAdjustmentAndLocation(review);
      expect(controller.snapshot.records['a']!.quantity, 12);
      expect(controller.snapshot.records['a']!.location, 'Rack B');

      final stale = controller.reviewStockAdjustmentAndLocation(
        'a',
        kind: StockAdjustmentKind.setExact,
        quantity: 20,
        locationPatch: const StockLocationPatch(location: 'Rack C'),
      );
      final live = controller.snapshot.records['a']!;
      await controller.save(
        live.patch({'notes': 'physical count changed after review'}),
        expectedRevision: controller.snapshot.revision,
      );
      await expectLater(
        controller.applyStockAdjustmentAndLocation(stale),
        throwsStateError,
      );
      expect(controller.snapshot.records['a']!.quantity, 12);
      expect(controller.snapshot.records['a']!.location, 'Rack B');
    });

    test('receiving SOLD stock reopens it without deleting sales history', () async {
      final controller = await _controller();
      addTearDown(controller.dispose);
      await controller.save(_stock('a', quantity: 6), expectedRevision: 0);
      await controller.recordSale(
        'a',
        quantity: 6,
        markSoldOut: true,
        totalAmountPaise: 6000,
      );
      expect(controller.sales, hasLength(1));

      final review = controller.reviewStockAdjustmentAndLocation(
        'a',
        kind: StockAdjustmentKind.receive,
        quantity: 8,
        locationPatch: const StockLocationPatch(location: 'Rack D'),
      );
      await controller.applyStockAdjustmentAndLocation(review);
      final reopened = controller.snapshot.records['a']!;
      expect(reopened.sold, isFalse);
      expect(reopened.quantity, 8);
      expect(reopened.location, 'Rack D');
      expect(controller.sales, hasLength(1));
    });

    test('exact correction plus location never invents SOLD or a sale', () async {
      final controller = await _controller();
      addTearDown(controller.dispose);
      await controller.save(_stock('a'), expectedRevision: 0);
      final review = controller.reviewStockAdjustmentAndLocation(
        'a',
        kind: StockAdjustmentKind.setExact,
        quantity: 0,
        locationPatch: const StockLocationPatch(location: 'Count Desk'),
      );
      await controller.applyStockAdjustmentAndLocation(review);
      final changed = controller.snapshot.records['a']!;
      expect(changed.quantity, 0);
      expect(changed.sold, isFalse);
      expect(changed.location, 'Count Desk');
      expect(controller.sales, isEmpty);
    });
  });
}
''',
)

create_exact(
    "test/brain_temporal_target_test.dart",
    r'''import 'package:aaris_pharmacy/domain/app_brain.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Aaris Brain inventory-date versus schedule firewall', () {
    test('labelled EXP/MFG dates may identify a stock row', () {
      for (final command in [
        'remove Dolo 650 EXP 12/09/2026',
        'Dolo 650 expiry 2026-09-12 remove',
        'Dolo 650 MFG 01/09/2026 delete',
        'remove Dolo 650 MFD 12 Sep 2026',
      ]) {
        final intent = parseAppBrainIntent(command);
        expect(intent.action, AppBrainAction.removeMedicine, reason: command);
        expect(intent.safetyReason, isNull, reason: command);
      }
    });

    test('unlabelled and schedule-shaped dates still fail closed', () {
      for (final command in [
        'remove Dolo on 12/09/2026',
        'remove Dolo 12/09/2026',
        'remove Dolo on expiry 12/09/2026',
        'Dolo delete Sep 12, 2026',
        'Dolo delete on 12 Sep 2026',
      ]) {
        final intent = parseAppBrainIntent(command);
        expect(intent.action, AppBrainAction.safetyBlocked, reason: command);
        expect(
          intent.safetyReason,
          AppBrainSafetyReason.deferredMutation,
          reason: command,
        );
      }
    });

    test('clock and relative-time guards remain unchanged', () {
      for (final command in [
        'remove Dolo at 17:30',
        'remove Dolo at 5 pm',
        'Dolo 2 hours baad remove',
        'Dolo २ घंटे बाद remove',
      ]) {
        final intent = parseAppBrainIntent(command);
        expect(intent.action, AppBrainAction.safetyBlocked, reason: command);
        expect(
          intent.safetyReason,
          AppBrainSafetyReason.deferredMutation,
          reason: command,
        );
      }
    });
  });
}
''',
)

insert_before_once(
    "docs/ARCHITECTURE.md",
    "## Deterministic operational autopilot\n",
    """### Atomic pharmacist work commands\n\nAaris Brain may combine exactly one reviewed quantity adjustment (receive or exact\ncount correction) with exactly one physical-location update when the pharmacist\nuses an explicit sequential command. This is not a general workflow interpreter.\nEach clause must independently pass the deterministic intent firewall, both clauses\nmust resolve to the same exact stock row, and alternatives/destructive/future or\nnegated clauses fail closed. The controller presents one before/after review and\ncommits both facts in one revision-checked SQLite mutation, so a race can never\nleave a quantity-only or location-only half-update. Undo restores both together.\n\nThe temporal firewall also distinguishes a narrowly labelled stock fact such as\n`EXP 12/09/2026`, `MFG 01/09/2026` or `MFD 12 Sep 2026` from an instruction\nscheduled for that date. Unlabelled dates and schedule-shaped prefixes such as\n`on 12/09/2026` or `on expiry 12/09/2026` remain blocked before target lookup.\n\n""",
)

insert_before_once(
    "docs/PROGRESS.md",
    "- Existing GitHub workflows run source checks and produce an Android release APK.\n",
    """- Aaris Brain now recognizes one narrow safe two-step work command: receive/correct\n  stock plus physical-location update for the same exact row. Both facts receive\n  one review and one atomic/undoable commit; mismatched targets, destructive\n  compounds, alternatives, uncertainty and deferred/negated clauses still fail\n  closed. Labelled EXP/MFG/MFD dates can identify a batch without being mistaken\n  for a future schedule, while unlabelled/scheduled dates remain blocked.\n""",
)

create_exact(
    "docs/AARIS_ATOMIC_WORK_COMMANDS_2026_09_10.md",
    """# Aaris Brain atomic pharmacist work commands — 10 September 2026\n\nThis upgrade removes a real workflow tax without weakening the pharmacy safety\nboundary. A pharmacist can now express one tightly-scoped sequential job such as\n`Dolo 650 stock add 5 units then location Rack C set karo`. Aaris does not run\ntwo independent writes. It resolves one exact physical row, computes the before\nand after stock/location facts, shows one explicit review, then commits both in\none serialized SQLite mutation. Undo restores the pair together.\n\n## Safety envelope\n\n- Supported composition is deliberately limited to exactly one receive/exact-count\n  adjustment plus exactly one physical-location update. It is not a general macro\n  or autonomous scripting language.\n- Each clause goes through the existing deterministic intent parser. Negation,\n  conditional/future language, incomplete quantities and unsafe intents cannot be\n  promoted into the atomic path.\n- `or/either/ya`, destructive lifecycle actions and more than two clauses are not\n  eligible. The ordinary compound-command firewall remains authoritative.\n- If both clauses name a medicine, their normalized exact target wording must\n  agree. Otherwise the composite route is rejected. One clause may use the exact\n  session context only under the existing fingerprint rules.\n- Fuzzy search never gains mutation authority. Ambiguous rows still enter the\n  revision-bound candidate chooser, and the final action uses the selected exact\n  stock ID.\n- The reviewed token is bound to the row revision and all quantity/location facts.\n  Unrelated inventory activity may continue, but any target-row change forces a\n  fresh review. The persistence compare-and-swap remains the final authority.\n- Receiving a previously SOLD row explicitly reopens current stock while retaining\n  historical sale events. Exact correction to zero still does not invent a SOLD\n  lifecycle or a sale event.\n\n## Temporal intent hardening\n\nA previous conservative date detector treated every calendar-looking token inside\na write command as a future schedule. That safely blocked bad automation but also\nblocked legitimate exact stock targeting by printed dates. The detector now grants\none narrow exception only when a date is immediately labelled as EXP/expiry,\nMFG/MFD or manufacturing date. Scheduling prefixes invalidate the exception.\nTherefore `remove Dolo EXP 12/09/2026` can proceed to exact-row review, while\n`remove Dolo on 12/09/2026`, `remove Dolo 12/09/2026` and\n`remove Dolo on expiry 12/09/2026` still fail closed. Clock-time and relative-time\nguards are unchanged.\n\n## Verification contract\n\nDedicated tests cover parser admission/rejection, target mismatch, alternatives,\nfuture/negative clauses, atomic commit + Undo, unrelated-write rebasing, stale-row\nrejection, SOLD recovery with preserved sales, no silent SOLD/sale creation, and\ncalendar-date firewall boundaries. The upgrade workflow also runs full static\nanalysis, the complete Flutter regression suite and a debug Android compile before\nthe temporary upgrade machinery removes itself.\n""",
)

print("Aaris atomic work-command source patch applied.")
