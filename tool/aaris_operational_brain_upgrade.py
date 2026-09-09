from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def replace_once(path: str, old: str, new: str) -> None:
    target = ROOT / path
    text = target.read_text(encoding="utf-8")
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{path}: expected one match, found {count}: {old[:120]!r}")
    target.write_text(text.replace(old, new, 1), encoding="utf-8")


def write(path: str, content: str) -> None:
    target = ROOT / path
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(content, encoding="utf-8")


brain_operations = r'''enum RemovalReasonHint { expired, damaged, returned, correction, soldOut }

extension RemovalReasonHintDetails on RemovalReasonHint {
  String? get archiveReason => switch (this) {
    RemovalReasonHint.expired => 'Expired',
    RemovalReasonHint.damaged => 'Damaged',
    RemovalReasonHint.returned => 'Returned',
    RemovalReasonHint.correction => 'Correction',
    RemovalReasonHint.soldOut => null,
  };

  List<String> get commandTerms => switch (this) {
    RemovalReasonHint.expired => const [
      'expired',
      'expire ho gayi',
      'expiry ho gayi',
      'एक्सपायर्ड',
      'एक्सपायर',
    ],
    RemovalReasonHint.damaged => const [
      'damaged',
      'damage',
      'broken',
      'kharab',
      'खराब',
      'डैमेज',
    ],
    RemovalReasonHint.returned => const [
      'returned',
      'return',
      'supplier return',
      'wapas',
      'वापस',
      'रिटर्न',
    ],
    RemovalReasonHint.correction => const [
      'correction',
      'wrong entry',
      'galat entry',
      'mistake',
      'गलत एंट्री',
      'करेक्शन',
    ],
    RemovalReasonHint.soldOut => const [
      'sold',
      'sold out',
      'stock finished',
      'stock khatam',
      'bik gaya',
      'बिक गया',
      'स्टॉक खत्म',
    ],
  };
}

RemovalReasonHint? detectRemovalReason(String raw) {
  final text = _normalized(raw);
  for (final reason in const [
    RemovalReasonHint.soldOut,
    RemovalReasonHint.expired,
    RemovalReasonHint.damaged,
    RemovalReasonHint.returned,
    RemovalReasonHint.correction,
  ]) {
    if (reason.commandTerms.any((term) => _containsPhrase(text, term))) {
      return reason;
    }
  }
  return null;
}

class StockLocationPatch {
  const StockLocationPatch({
    this.block,
    this.row,
    this.vertical,
    this.location,
  });

  const StockLocationPatch.clear()
    : block = '',
      row = '',
      vertical = '',
      location = '';

  final String? block;
  final String? row;
  final String? vertical;
  final String? location;

  bool get isEmpty =>
      block == null && row == null && vertical == null && location == null;

  bool get clearsEverything =>
      block == '' && row == '' && vertical == '' && location == '';
}

class ParsedStockLocationCommand {
  const ParsedStockLocationCommand({
    required this.query,
    required this.patch,
  });

  final String query;
  final StockLocationPatch patch;
}

ParsedStockLocationCommand? parseStockLocationCommand(String raw) {
  if (raw.trim().isEmpty || raw.length > 500) return null;
  final normalized = _normalized(raw);
  if (!_containsAny(normalized, _locationMutationVerbs)) return null;

  final clearMatch = RegExp(
    r'(?:location|shelf|rack|लोकेशन|शेल्फ|रैक|जगह)\s*(?:clear|empty|remove|hatao|hata do|खाली|हटाओ|हटा दो)(?:\s*(?:karo|kar do|करो|कर दो))?',
    caseSensitive: false,
    unicode: true,
  ).firstMatch(raw);
  if (clearMatch != null) {
    final target = _targetAfterRemoving(raw, [
      _TextSpan(clearMatch.start, clearMatch.end),
    ]);
    if (target.isEmpty) return null;
    return ParsedStockLocationCommand(
      query: target,
      patch: const StockLocationPatch.clear(),
    );
  }

  final spans = <_TextSpan>[];
  String? block;
  String? row;
  String? vertical;

  String? tagged(RegExp expression, String label) {
    final matches = expression.allMatches(raw).toList(growable: false);
    if (matches.length > 1) {
      throw FormatException('Use only one $label value in a location command.');
    }
    if (matches.isEmpty) return null;
    final match = matches.single;
    final value = _boundedLocationValue(match.group(1) ?? '', label, 40);
    if (_reservedLocationValue(value)) {
      throw FormatException('A $label value is missing or ambiguous.');
    }
    spans.add(_TextSpan(match.start, match.end));
    return value;
  }

  block = tagged(
    RegExp(
      r'(?:block|ब्लॉक)\s*[:#=-]?\s*([A-Za-z0-9\u0900-\u097f._/-]{1,40})',
      caseSensitive: false,
      unicode: true,
    ),
    'block',
  );
  row = tagged(
    RegExp(
      r'(?:row|रो|पंक्ति)\s*[:#=-]?\s*([A-Za-z0-9\u0900-\u097f._/-]{1,40})',
      caseSensitive: false,
      unicode: true,
    ),
    'row',
  );
  vertical = tagged(
    RegExp(
      r'(?:vertical|vert|वर्टिकल)\s*[:#=-]?\s*([A-Za-z0-9\u0900-\u097f._/-]{1,40})',
      caseSensitive: false,
      unicode: true,
    ),
    'vertical',
  );

  String? location;
  if (block == null && row == null && vertical == null) {
    final free = RegExp(
      r'(?:location|shelf|rack|लोकेशन|शेल्फ|रैक|जगह)\s*[:#=-]?\s*(.{1,180}?)\s*(?:set(?:\s+(?:karo|kar do))?|move(?:\s+(?:karo|kar do))?|shift(?:\s+(?:karo|kar do))?|rakh(?:\s+do)?|rakho|सेट(?:\s+(?:करो|कर दो))?|मूव(?:\s+(?:करो|कर दो))?|शिफ्ट(?:\s+(?:करो|कर दो))?|रख(?:\s+दो)?|रखो)\s*$',
      caseSensitive: false,
      unicode: true,
    ).firstMatch(raw);
    if (free == null) return null;
    location = _boundedLocationValue(free.group(1) ?? '', 'location', 160);
    spans.add(_TextSpan(free.start, free.end));
  }

  final patch = sanitizeStockLocationPatch(
    StockLocationPatch(
      block: block,
      row: row,
      vertical: vertical,
      location: location,
    ),
  );
  if (patch.isEmpty) return null;
  final target = _targetAfterRemoving(raw, spans);
  if (target.isEmpty) return null;
  return ParsedStockLocationCommand(query: target, patch: patch);
}

StockLocationPatch sanitizeStockLocationPatch(StockLocationPatch patch) {
  if (patch.isEmpty) {
    throw const FormatException('A stock location update is empty.');
  }
  String? clean(String? value, String label, int max) {
    if (value == null) return null;
    if (value.isEmpty) return '';
    return _boundedLocationValue(value, label, max);
  }

  return StockLocationPatch(
    block: clean(patch.block, 'block', 40),
    row: clean(patch.row, 'row', 40),
    vertical: clean(patch.vertical, 'vertical', 40),
    location: clean(patch.location, 'location', 160),
  );
}

String describeStockLocationPatch(StockLocationPatch patch) {
  if (patch.clearsEverything) return 'clear the saved stock location';
  final parts = <String>[
    if (patch.block != null) _locationPart('Block', patch.block!),
    if (patch.row != null) _locationPart('Row', patch.row!),
    if (patch.vertical != null) _locationPart('Vertical', patch.vertical!),
    if (patch.location != null) _locationPart('Location', patch.location!),
  ];
  return parts.join(' · ');
}

String _locationPart(String label, String value) =>
    value.isEmpty ? '$label: clear' : '$label: $value';

String _boundedLocationValue(String raw, String label, int max) {
  if (RegExp(r'[\u0000-\u001f\u007f]').hasMatch(raw)) {
    throw FormatException('Invalid control character in $label.');
  }
  final value = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (value.isEmpty || value.length > max) {
    throw FormatException('$label must be between 1 and $max characters.');
  }
  return value;
}

bool _reservedLocationValue(String value) => const {
  'block',
  'row',
  'vertical',
  'vert',
  'location',
  'shelf',
  'rack',
  'set',
  'move',
  'shift',
  'karo',
  'kar',
  'करो',
  'सेट',
  'मूव',
}.contains(_normalized(value));

class _TextSpan {
  const _TextSpan(this.start, this.end);
  final int start;
  final int end;
}

String _targetAfterRemoving(String raw, List<_TextSpan> spans) {
  var value = raw;
  final ordered = [...spans]..sort((a, b) => b.start.compareTo(a.start));
  for (final span in ordered) {
    value = value.replaceRange(span.start, span.end, ' ');
  }
  for (final phrase in _locationCommandTerms) {
    value = _stripWholePhrase(value, phrase);
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

String _normalized(String value) => value
    .toLowerCase()
    .replaceAll(RegExp(r'[^a-z0-9\u0900-\u097f]+', unicode: true), ' ')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

bool _containsPhrase(String normalizedText, String phrase) {
  final needle = _normalized(phrase);
  return normalizedText == needle ||
      normalizedText.startsWith('$needle ') ||
      normalizedText.endsWith(' $needle') ||
      normalizedText.contains(' $needle ');
}

bool _containsAny(String text, List<String> phrases) =>
    phrases.any((phrase) => _containsPhrase(text, phrase));

const _locationMutationVerbs = <String>[
  'set', 'set karo', 'set kar do', 'move', 'move karo', 'move kar do',
  'shift', 'shift karo', 'shift kar do', 'rakh do', 'rakho', 'clear',
  'hatao', 'hata do', 'सेट', 'सेट करो', 'सेट कर दो', 'मूव', 'मूव करो',
  'शिफ्ट', 'रख दो', 'रखो', 'हटाओ', 'हटा दो',
];

const _locationCommandTerms = <String>[
  'set location', 'location set', 'move location', 'location move',
  'shift location', 'location shift', 'set karo', 'set kar do',
  'move karo', 'move kar do', 'shift karo', 'shift kar do', 'rakh do',
  'rakho', 'location', 'shelf', 'rack', 'jagah', 'to', 'pe', 'par',
  'mein', 'me', 'karo', 'kar do', 'लोकेशन', 'शेल्फ', 'रैक', 'जगह',
  'सेट करो', 'सेट कर दो', 'मूव करो', 'शिफ्ट करो', 'रख दो', 'रखो',
  'करो', 'कर दो',
];
'''

location_ops = r'''import '../domain/brain_operations.dart';
import 'pharmacy_controller.dart';

class ReviewedStockLocationUpdate {
  const ReviewedStockLocationUpdate({
    required this.baseRevision,
    required this.stockId,
    required this.recordRevision,
    required this.patch,
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
  final StockLocationPatch patch;
  final String beforeBlock;
  final String beforeRow;
  final String beforeVertical;
  final String beforeLocation;
  final String afterBlock;
  final String afterRow;
  final String afterVertical;
  final String afterLocation;

  bool get changesLocation =>
      beforeBlock != afterBlock || beforeRow != afterRow ||
      beforeVertical != afterVertical || beforeLocation != afterLocation;

  String get beforeDisplay => _displayLocation(
    beforeBlock, beforeRow, beforeVertical, beforeLocation,
  );
  String get afterDisplay => _displayLocation(
    afterBlock, afterRow, afterVertical, afterLocation,
  );
}

extension PharmacyStockLocationOperations on PharmacyController {
  ReviewedStockLocationUpdate reviewStockLocationUpdate(
    String id,
    StockLocationPatch requested,
  ) {
    final medicine = snapshot.records[id];
    if (medicine == null || medicine.archived) {
      throw StateError('Choose an active stock entry before changing location.');
    }
    if (medicine.sold) {
      throw StateError(
        'This entry is SOLD and has no active physical stock to relocate. Receive stock or choose an active batch instead.',
      );
    }
    final patch = sanitizeStockLocationPatch(requested);
    return ReviewedStockLocationUpdate(
      baseRevision: snapshot.revision,
      stockId: medicine.id,
      recordRevision: medicine.revision,
      patch: patch,
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

  Future<void> applyStockLocationUpdate(ReviewedStockLocationUpdate review) async {
    if (review.baseRevision != snapshot.revision) {
      throw StateError(
        'Inventory changed after the location review. Review this move again before saving.',
      );
    }
    final live = snapshot.records[review.stockId];
    if (live == null || live.archived || live.sold || live.revision != review.recordRevision) {
      throw StateError(
        'The reviewed stock entry changed or is no longer active. Review the location again.',
      );
    }
    final fresh = reviewStockLocationUpdate(live.id, review.patch);
    if (fresh.beforeBlock != review.beforeBlock ||
        fresh.beforeRow != review.beforeRow ||
        fresh.beforeVertical != review.beforeVertical ||
        fresh.beforeLocation != review.beforeLocation ||
        fresh.afterBlock != review.afterBlock ||
        fresh.afterRow != review.afterRow ||
        fresh.afterVertical != review.afterVertical ||
        fresh.afterLocation != review.afterLocation) {
      throw StateError(
        'Stock location facts changed after review. Nothing was saved; review the move again.',
      );
    }
    if (!fresh.changesLocation) return;

    await save(
      live.patch({
        'block': fresh.afterBlock,
        'row': fresh.afterRow,
        'vertical': fresh.afterVertical,
        'location': fresh.afterLocation,
      }),
      expectedRevision: review.baseRevision,
    );
  }
}

String _displayLocation(String block, String row, String vertical, String location) {
  final parts = <String>[
    if (block.isNotEmpty) 'Block $block',
    if (row.isNotEmpty) 'Row $row',
    if (vertical.isNotEmpty) 'Vertical $vertical',
    if (location.isNotEmpty) location,
  ];
  return parts.isEmpty ? 'No location recorded' : parts.join(' · ');
}
'''

location_tests = r'''import 'package:aaris_pharmacy/data/inventory_database.dart';
import 'package:aaris_pharmacy/domain/app_brain.dart';
import 'package:aaris_pharmacy/domain/brain_operations.dart';
import 'package:aaris_pharmacy/domain/medicine.dart';
import 'package:aaris_pharmacy/state/pharmacy_controller.dart';
import 'package:aaris_pharmacy/state/stock_location_operations.dart';
import 'package:flutter_test/flutter_test.dart';

Medicine stock(String id, {bool sold = false}) => Medicine.fromJson({
  'id': id,
  'name': 'Dolo',
  'strength': '650 mg',
  'form': 'Tablet',
  'quantity': sold ? 0 : 10,
  'expiry': '2027-12',
  'block': 'A1',
  'row': 'R1',
  'vertical': 'V1',
  'location': 'Front shelf',
  'sold': sold,
  'soldAt': sold ? '2026-09-09T10:00:00.000' : null,
  'soldQuantity': sold ? 10 : null,
  'revision': 1,
});

Future<PharmacyController> controllerWithClock() async {
  final controller = PharmacyController(
    MemoryInventoryStorage(),
    clock: () => DateTime(2026, 9, 10, 12),
    backgroundSearch: false,
  );
  await controller.initialize();
  return controller;
}

void main() {
  group('Aaris Brain location command parsing', () {
    test('parses structured partial relocation without touching medicine strength', () {
      final intent = parseAppBrainIntent(
        'Dolo 650 location Block B2 Row R4 Vertical V3 set karo',
      );
      expect(intent.action, AppBrainAction.relocateMedicine);
      expect(intent.query, 'Dolo 650');
      expect(intent.locationPatch?.block, 'B2');
      expect(intent.locationPatch?.row, 'R4');
      expect(intent.locationPatch?.vertical, 'V3');
      expect(intent.locationPatch?.location, isNull);
      expect(intent.destructive, isFalse);
      expect(intent.mutatesInventory, isTrue);
    });

    test('supports exact context and free-form shelf destinations', () {
      final intent = parseAppBrainIntent('isko shelf Cold Cabinet 2 set karo');
      expect(intent.action, AppBrainAction.relocateMedicine);
      expect(intent.query, 'isko');
      expect(isAppBrainContextReference(intent.query), isTrue);
      expect(intent.locationPatch?.location, 'Cold Cabinet 2');
    });

    test('location clear is relocation, never a medicine delete command', () {
      final intent = parseAppBrainIntent('Dolo 650 location hata do');
      expect(intent.action, AppBrainAction.relocateMedicine);
      expect(intent.query, 'Dolo 650');
      expect(intent.locationPatch?.clearsEverything, isTrue);
    });

    test('plain location question remains a read-only operational brief', () {
      final intent = parseAppBrainIntent('Dolo 650 kahan hai');
      expect(intent.action, AppBrainAction.search);
      expect(intent.locationPatch, isNull);
    });
  });

  group('reviewed stock relocation', () {
    test('relocation is revision-bound, partial, atomic and undoable', () async {
      final controller = await controllerWithClock();
      addTearDown(controller.dispose);
      await controller.save(stock('a'), expectedRevision: 0);

      final review = controller.reviewStockLocationUpdate(
        'a',
        const StockLocationPatch(block: 'B8', row: 'R2'),
      );
      expect(review.beforeDisplay, contains('Block A1'));
      expect(review.afterDisplay, contains('Block B8'));
      expect(review.afterVertical, 'V1');
      expect(review.afterLocation, 'Front shelf');

      await controller.applyStockLocationUpdate(review);
      final moved = controller.snapshot.records['a']!;
      expect(moved.block, 'B8');
      expect(moved.row, 'R2');
      expect(moved.vertical, 'V1');
      expect(moved.location, 'Front shelf');
      expect(controller.sales, isEmpty);

      await controller.undo();
      expect(controller.snapshot.records['a']!.block, 'A1');
      expect(controller.snapshot.records['a']!.row, 'R1');
    });

    test('stale review cannot overwrite a concurrent inventory change', () async {
      final controller = await controllerWithClock();
      addTearDown(controller.dispose);
      await controller.save(stock('a'), expectedRevision: 0);
      final review = controller.reviewStockLocationUpdate(
        'a',
        const StockLocationPatch(location: 'Back shelf'),
      );
      await controller.save(stock('b'), expectedRevision: 1);

      await expectLater(controller.applyStockLocationUpdate(review), throwsStateError);
      expect(controller.snapshot.records['a']!.location, 'Front shelf');
    });

    test('SOLD entries cannot be relocated as if physical stock exists', () async {
      final controller = await controllerWithClock();
      addTearDown(controller.dispose);
      await controller.save(stock('sold', sold: true), expectedRevision: 0);

      expect(
        () => controller.reviewStockLocationUpdate(
          'sold',
          const StockLocationPatch(block: 'B2'),
        ),
        throwsStateError,
      );
    });
  });

  group('explicit removal reason extraction', () {
    test('reason is bounded and stripped from medicine target', () {
      final damaged = parseAppBrainIntent('Dolo 650 damaged remove karo');
      expect(damaged.action, AppBrainAction.removeMedicine);
      expect(damaged.query, 'Dolo 650');
      expect(damaged.removalReason, RemovalReasonHint.damaged);

      final expired = parseAppBrainIntent('expired Dolo 650 delete karo');
      expect(expired.query, 'Dolo 650');
      expect(expired.removalReason, RemovalReasonHint.expired);
    });

    test('sold removal hint stays an explicit SOLD workflow hint', () {
      final intent = parseAppBrainIntent('Dolo 650 sold remove karo');
      expect(intent.action, AppBrainAction.removeMedicine);
      expect(intent.query, 'Dolo 650');
      expect(intent.removalReason, RemovalReasonHint.soldOut);
    });
  });
}
'''

upgrade_doc = r'''# Aaris Reviewed Operational Orchestration — 2026-09-10

This pass extends the existing Aaris Brain rather than adding another inventory or mutation engine.

## Reviewed stock relocation

Aaris Brain can understand explicit stock-location commands such as `Dolo 650 location Block B2 Row R4 Vertical V3 set karo` and `isko shelf Cold Cabinet 2 set karo` after an exact stock row is already in context.

The command parser only accepts explicit location vocabulary plus a mutation verb. Medicine strength numbers are not location fields. Structured Block / Row / Vertical values and bounded free-form shelf/rack locations are extracted deterministically; ambiguous or malformed location commands do not become writes.

A relocation produces a revision-bound review token containing the exact stock ID, record revision, inventory revision and before/after physical location. The pharmacist sees the before/after location and must confirm. The controller then re-reads live inventory and fails closed if any relevant fact changed. The final write goes through the existing authoritative controller/database integrity and Undo path. SOLD rows cannot be relocated as if physical stock still exists.

## Intent-aware removal reasons

Explicit reasons such as Expired, Damaged, Returned and Correction are captured as bounded deterministic intent slots. The reason text is removed from fuzzy medicine targeting, improving exact-match quality. A supplied reason skips only the redundant reason picker; the final destructive confirmation is still mandatory. A `sold` / `stock finished` hint routes to the existing SOLD confirmation instead of archiving a sale as a generic removal.

## Preserved invariants

- SQLite remains the only authoritative medicine database.
- No location command can edit clinical identity, expiry, quantity, sales or price.
- Uncertain medicine resolution still requires exact pharmacist selection.
- Every actual location write is reviewed, revision checked, atomic and undoable.
- Natural-language bulk deletion remains blocked.
- OCR/AI confidence never bypasses deterministic validation.
- No patient/customer identity or cloud persistence is introduced.
'''

write('lib/domain/brain_operations.dart', brain_operations)
write('lib/state/stock_location_operations.dart', location_ops)
write('test/stock_location_operations_test.dart', location_tests)
write('docs/AARIS_REVIEWED_OPERATIONAL_ORCHESTRATION_2026_09_10.md', upgrade_doc)

replace_once('lib/domain/app_brain.dart', "import 'inventory.dart';\nimport 'medicine_brief.dart';", "import 'brain_operations.dart';\nimport 'inventory.dart';\nimport 'medicine_brief.dart';")
replace_once('lib/domain/app_brain.dart', "  setQuantity,\n  receiveStock,\n  removeMedicine,", "  setQuantity,\n  receiveStock,\n  relocateMedicine,\n  removeMedicine,")
replace_once('lib/domain/app_brain.dart', "    this.quantity,\n    this.briefFocus,\n    this.confidence = 0,", "    this.quantity,\n    this.briefFocus,\n    this.locationPatch,\n    this.removalReason,\n    this.confidence = 0,")
replace_once('lib/domain/app_brain.dart', "  final int? quantity;\n  final MedicineBriefFocus? briefFocus;\n  final double confidence;", "  final int? quantity;\n  final MedicineBriefFocus? briefFocus;\n  final StockLocationPatch? locationPatch;\n  final RemovalReasonHint? removalReason;\n  final double confidence;")
replace_once('lib/domain/app_brain.dart', "        AppBrainAction.setQuantity ||\n        AppBrainAction.receiveStock ||\n        AppBrainAction.removeMedicine ||", "        AppBrainAction.setQuantity ||\n        AppBrainAction.receiveStock ||\n        AppBrainAction.relocateMedicine ||\n        AppBrainAction.removeMedicine ||")
replace_once('lib/domain/app_brain.dart', "  bool get destructive => switch (action) {\n    AppBrainAction.setQuantity ||\n    AppBrainAction.removeMedicine ||\n    AppBrainAction.markSold ||\n    AppBrainAction.recordSale ||\n    AppBrainAction.bulkRemoveBlocked => true,\n    _ => false,\n  };", "  bool get destructive => switch (action) {\n    AppBrainAction.setQuantity ||\n    AppBrainAction.removeMedicine ||\n    AppBrainAction.markSold ||\n    AppBrainAction.recordSale ||\n    AppBrainAction.bulkRemoveBlocked => true,\n    _ => false,\n  };\n\n  bool get mutatesInventory => switch (action) {\n    AppBrainAction.setQuantity ||\n    AppBrainAction.receiveStock ||\n    AppBrainAction.relocateMedicine ||\n    AppBrainAction.removeMedicine ||\n    AppBrainAction.markSold ||\n    AppBrainAction.recordSale ||\n    AppBrainAction.undoLast => true,\n    _ => false,\n  };")
replace_once('lib/domain/app_brain.dart', "  final stockAdjustment = _stockAdjustmentIntent(raw);\n  if (stockAdjustment != null) return stockAdjustment;\n\n  // Explicit write intent wins over category words such as \"expired\".\n  if (_containsAny(text, _removeTerms)) {\n    return AppBrainIntent(\n      action: AppBrainAction.removeMedicine,\n      query: _extractMedicineQuery(raw, _removeTerms),\n      confidence: .98,\n    );\n  }", "  final stockAdjustment = _stockAdjustmentIntent(raw);\n  if (stockAdjustment != null) return stockAdjustment;\n\n  // Physical stock relocation is a narrow deterministic write command. It is\n  // recognized before generic remove/edit language so \"location hata do\"\n  // clears only location facts and can never become a medicine deletion.\n  final locationUpdate = parseStockLocationCommand(raw);\n  if (locationUpdate != null) {\n    return AppBrainIntent(\n      action: AppBrainAction.relocateMedicine,\n      query: locationUpdate.query,\n      locationPatch: locationUpdate.patch,\n      confidence: .99,\n    );\n  }\n\n  // Explicit write intent wins over category words such as \"expired\". A\n  // bounded reason hint improves target resolution but never skips the final\n  // destructive confirmation in the UI.\n  if (_containsAny(text, _removeTerms)) {\n    final reason = detectRemovalReason(raw);\n    return AppBrainIntent(\n      action: AppBrainAction.removeMedicine,\n      query: _extractMedicineQuery(raw, [\n        ..._removeTerms,\n        if (reason != null) ...reason.commandTerms,\n      ]),\n      removalReason: reason,\n      confidence: .98,\n    );\n  }")

replace_once('lib/ui/brain_screen.dart', "import '../domain/app_brain.dart';\nimport '../domain/attention.dart';", "import '../domain/app_brain.dart';\nimport '../domain/attention.dart';\nimport '../domain/brain_operations.dart';")
replace_once('lib/ui/brain_screen.dart', "import '../state/pharmacy_controller.dart';\nimport 'ai_screen.dart';", "import '../state/pharmacy_controller.dart';\nimport '../state/stock_location_operations.dart';\nimport 'ai_screen.dart';")
replace_once('lib/ui/brain_screen.dart', "      case AppBrainAction.setQuantity:\n      case AppBrainAction.receiveStock:\n      case AppBrainAction.removeMedicine:", "      case AppBrainAction.setQuantity:\n      case AppBrainAction.receiveStock:\n      case AppBrainAction.relocateMedicine:\n      case AppBrainAction.removeMedicine:")
replace_once('lib/ui/brain_screen.dart', "        fromContext: true,\n        requestedQuantity: intent.quantity,\n      );", "        fromContext: true,\n        requestedQuantity: intent.quantity,\n        locationPatch: intent.locationPatch,\n        removalReason: intent.removalReason,\n      );")
replace_once('lib/ui/brain_screen.dart', "          intent.action,\n          productTarget,\n          requestedQuantity: intent.quantity,\n        );", "          intent.action,\n          productTarget,\n          requestedQuantity: intent.quantity,\n          locationPatch: intent.locationPatch,\n          removalReason: intent.removalReason,\n        );")
replace_once('lib/ui/brain_screen.dart', "          intent.action,\n          record,\n          requestedQuantity: intent.quantity,\n        );", "          intent.action,\n          record,\n          requestedQuantity: intent.quantity,\n          locationPatch: intent.locationPatch,\n          removalReason: intent.removalReason,\n        );")
replace_once('lib/ui/brain_screen.dart', "      action: intent.action,\n      requestedQuantity: intent.quantity,\n    );", "      action: intent.action,\n      requestedQuantity: intent.quantity,\n      locationPatch: intent.locationPatch,\n      removalReason: intent.removalReason,\n    );")
replace_once('lib/ui/brain_screen.dart', "    bool fromContext = false,\n    int? requestedQuantity,\n  }) async {", "    bool fromContext = false,\n    int? requestedQuantity,\n    StockLocationPatch? locationPatch,\n    RemovalReasonHint? removalReason,\n  }) async {")
replace_once('lib/ui/brain_screen.dart', "      AppBrainAction.receiveStock when requestedQuantity != null =>\n        '${record.title} matched. Preparing a reviewed +$requestedQuantity-unit stock receipt.',\n      _ => _editorInstruction(action, record),", "      AppBrainAction.receiveStock when requestedQuantity != null =>\n        '${record.title} matched. Preparing a reviewed +$requestedQuantity-unit stock receipt.',\n      AppBrainAction.relocateMedicine when locationPatch != null =>\n        '${record.title} matched. Preparing a reviewed location change: ${describeStockLocationPatch(locationPatch)}.',\n      _ => _editorInstruction(action, record),")
replace_once('lib/ui/brain_screen.dart', "    if (action == AppBrainAction.removeMedicine) {\n      await _removeTarget(record);\n      return;\n    }", "    if (action == AppBrainAction.removeMedicine) {\n      if (removalReason == RemovalReasonHint.soldOut) {\n        await _markSoldTarget(record);\n      } else {\n        await _removeTarget(record, reasonHint: removalReason);\n      }\n      return;\n    }\n    if (action == AppBrainAction.relocateMedicine) {\n      if (locationPatch == null) {\n        throw StateError('The reviewed location command is incomplete. Nothing changed.');\n      }\n      await _reviewLocationUpdate(record, locationPatch);\n      return;\n    }")

insert_location_method = r'''  Future<void> _reviewLocationUpdate(
    Medicine original,
    StockLocationPatch patch,
  ) async {
    if (!mounted) return;
    final review = widget.controller.reviewStockLocationUpdate(original.id, patch);
    final live = widget.controller.snapshot.records[review.stockId];
    if (live == null || live.archived) {
      throw StateError('That stock entry is no longer active. Nothing changed.');
    }
    if (!review.changesLocation) {
      setState(
        () => _reply =
            '${live.title} already has that stock location. No inventory change was needed.',
      );
      return;
    }

    final confirmed =
        await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (ctx) => AlertDialog(
            title: Text('Update ${live.name} location?'),
            content: Text(
              '${_stockIdentityCue(live)}\n\nBefore: ${review.beforeDisplay}\nAfter: ${review.afterDisplay}\n\nOnly physical storage-location fields will change. Medicine identity, expiry, quantity, price and sales are untouched. The write is revision-checked and Undo remains available.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Update location'),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed || !mounted) {
      setState(() => _reply = 'Location update cancelled. Nothing changed.');
      return;
    }

    await widget.controller.applyStockLocationUpdate(review);
    if (!mounted) return;
    final updated = widget.controller.snapshot.records[live.id];
    if (updated != null && !updated.archived) _remember(updated);
    setState(
      () => _reply =
          '${live.title} moved to ${review.afterDisplay}. The reviewed location change is audited and Undo is available.',
    );
  }

'''
replace_once('lib/ui/brain_screen.dart', "  Future<void> _removeTarget(Medicine original) async {", insert_location_method + "  Future<void> _removeTarget(\n    Medicine original, {\n    RemovalReasonHint? reasonHint,\n  }) async {")
replace_once('lib/ui/brain_screen.dart', "    final reason = await showDialog<String>(\n      context: context,", "    final reason = reasonHint?.archiveReason ??\n        await showDialog<String>(\n      context: context,")
replace_once('lib/ui/brain_screen.dart', "    int? requestedQuantity,\n    MedicineBriefFocus? briefFocus,\n  }) async {", "    int? requestedQuantity,\n    MedicineBriefFocus? briefFocus,\n    StockLocationPatch? locationPatch,\n    RemovalReasonHint? removalReason,\n  }) async {")
replace_once('lib/ui/brain_screen.dart', "                          requestedQuantity: requestedQuantity,\n                        );", "                          requestedQuantity: requestedQuantity,\n                          locationPatch: locationPatch,\n                          removalReason: removalReason,\n                        );")
replace_once('lib/ui/brain_screen.dart', "    AppBrainAction.receiveStock =>\n      '${record.title} opened for a received-stock review.',\n    AppBrainAction.editMedicine =>", "    AppBrainAction.receiveStock =>\n      '${record.title} opened for a received-stock review.',\n    AppBrainAction.relocateMedicine =>\n      '${record.title} opened for a reviewed stock-location change.',\n    AppBrainAction.editMedicine =>")
replace_once('lib/ui/brain_screen.dart', "    AppBrainAction.receiveStock => 'Choose stock to receive · $query',\n    AppBrainAction.editMedicine =>", "    AppBrainAction.receiveStock => 'Choose stock to receive · $query',\n    AppBrainAction.relocateMedicine => 'Choose stock to relocate · $query',\n    AppBrainAction.editMedicine =>")

replace_once('docs/ARCHITECTURE.md', "| `state/pharmacy_controller.dart` | Reactive state, midnight rollover, commands and isolate search orchestration |", "| `state/pharmacy_controller.dart` | Reactive state, midnight rollover, commands and isolate search orchestration |\n| `state/stock_location_operations.dart` | Revision-bound reviewed physical-stock relocation; no clinical or sales write authority |")

print('Aaris operational Brain source upgrade applied successfully.')
