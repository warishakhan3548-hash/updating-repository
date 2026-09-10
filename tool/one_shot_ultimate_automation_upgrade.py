from pathlib import Path
from textwrap import dedent


def _with_indent(block: str, width: int) -> str:
    prefix = ' ' * width
    return ''.join(prefix + line if line.strip() else line for line in block.splitlines(True))


def replace_once(path: str, old: str, new: str) -> None:
    file = Path(path)
    text = file.read_text()
    old = dedent(old)
    new = dedent(new)
    matches = []
    for width in range(0, 21):
        candidate = _with_indent(old, width)
        positions = []
        cursor = 0
        while True:
            index = text.find(candidate, cursor)
            if index < 0:
                break
            if candidate.startswith('\n') or index == 0 or text[index - 1] == '\n':
                positions.append(index)
            cursor = index + 1
        if len(positions) == 1:
            matches.append((width, candidate))
        elif len(positions) > 1:
            raise SystemExit(
                f'{path}: patch anchor is ambiguous at indent {width}: {len(positions)} matches'
            )
    if len(matches) != 1:
        raise SystemExit(f'{path}: expected one patch anchor, found {len(matches)}')
    width, candidate = matches[0]
    replacement = _with_indent(new, width)
    file.write_text(text.replace(candidate, replacement, 1))


def write_new(path: str, content: str) -> None:
    file = Path(path)
    if file.exists():
        raise SystemExit(f'{path}: refusing to overwrite an existing file')
    file.write_text(dedent(content).lstrip())


# ---------------------------------------------------------------------------
# 1) Make ordinary single-row sales use the same dependency-scoped review
#    semantics as FEFO, SOLD, removal, restore, stock correction and relocation.
# ---------------------------------------------------------------------------
replace_once(
    'lib/state/pharmacy_controller.dart',
    '''
class ReviewedMarkSold {
  const ReviewedMarkSold({required this.baseRevision, required this.record});

  final int baseRevision;
  final Medicine record;
  String get stockId => record.id;
}
''',
    '''
class ReviewedMarkSold {
  const ReviewedMarkSold({required this.baseRevision, required this.record});

  final int baseRevision;
  final Medicine record;
  String get stockId => record.id;
}

/// Immutable single-stock sale review.
///
/// The token binds the pharmacist's confirmation to the exact physical stock
/// row and exact sale facts they reviewed. Unrelated database traffic may advance
/// the global inventory revision, but any change to this row fails closed.
class ReviewedSale {
  const ReviewedSale({
    required this.baseRevision,
    required this.record,
    required this.quantity,
    required this.totalAmountPaise,
    required this.occurredAt,
    required this.markSoldOut,
  });

  final int baseRevision;
  final Medicine record;
  final int quantity;
  final int? totalAmountPaise;
  final DateTime occurredAt;
  final bool markSoldOut;

  String get stockId => record.id;
}
''',
)

replace_once(
    'lib/state/pharmacy_controller.dart',
    '''
Future<void> recordSale(
  String id, {
  required int quantity,
  int? totalAmountPaise,
  DateTime? occurredAt,
  bool markSoldOut = false,
  int? expectedRevision,
}) async {
  if (expectedRevision != null && expectedRevision != snapshot.revision) {
    throw StateError(
      'Inventory changed. Reopen this entry before recording a sale.',
    );
  }
  final medicine = snapshot.records[id];
  if (medicine == null || medicine.archived) {
    throw StateError('This stock entry is unavailable.');
  }
  if (medicine.sold) {
    throw StateError('Restock this medicine before recording another sale.');
  }
  if (quantity < 1 || quantity > _maxStockQuantity) {
    throw const FormatException(
      'Sale quantity must be a positive whole number.',
    );
  }
  if (totalAmountPaise != null &&
      (totalAmountPaise < 0 || totalAmountPaise > maxExactPaise)) {
    throw const FormatException(
      'Sale amount is outside the supported range.',
    );
  }
  final time = occurredAt ?? clock();
  if (civilDay(time).isAfter(today)) {
    throw const FormatException('A sale cannot be recorded in the future.');
  }
  validateDispensingDate(medicine, time);
  final current = medicine.quantity;
  if (current != null && quantity > current) {
    throw FormatException(
      'Only $current units are recorded in stock. Correct the stock first or enter a smaller sale.',
    );
  }
  if (markSoldOut && current == null) {
    throw const FormatException(
      'Stock quantity is unknown, so this sale cannot safely mark the entry completely finished. Verify the physical quantity first or use the explicit whole-stock SOLD action.',
    );
  }
  if (markSoldOut && current != null && quantity != current) {
    throw const FormatException(
      'To mark this entry out of stock, the sale quantity must equal all remaining units.',
    );
  }
  final remaining = current == null ? null : current - quantity;
  final sale = SaleEvent(
    id: newId(),
    stockId: medicine.id,
    medicineName: medicine.name,
    strength: medicine.strength,
    form: medicine.form,
    salt: medicine.salt,
    quantity: quantity,
    occurredAt: time,
    totalAmountPaise: totalAmountPaise,
    savedUnitPricePaise: medicine.unitPricePaise,
  );
  final updated = medicine.patch({
    'quantity': markSoldOut ? 0 : remaining,
    if (markSoldOut) ...{
      'sold': true,
      'soldAt': time.toIso8601String(),
      'soldQuantity': current,
      'soldUnitPricePaise': medicine.unitPricePaise,
    },
  });
  await _commit(
    InventoryMutation(
      expectedRevision: snapshot.revision,
      label:
          'Recorded sale · ${medicine.name} · $quantity ${quantity == 1 ? 'unit' : 'units'}${markSoldOut ? ' · marked sold' : ''}',
      upserts: [updated],
      upsertSales: [sale],
    ),
  );
}
''',
    '''
ReviewedSale reviewSale(
  String id, {
  required int quantity,
  int? totalAmountPaise,
  DateTime? occurredAt,
  bool markSoldOut = false,
  Medicine? reviewedRecord,
}) {
  final medicine = snapshot.records[id];
  if (medicine == null || medicine.archived) {
    throw StateError('This stock entry is unavailable.');
  }
  if (reviewedRecord != null && !_sameReviewedMedicine(medicine, reviewedRecord)) {
    throw StateError(
      'This stock entry changed while the sale dialog was open. Review the live medicine again before recording the sale.',
    );
  }
  if (medicine.sold) {
    throw StateError('Restock this medicine before recording another sale.');
  }
  if (quantity < 1 || quantity > _maxStockQuantity) {
    throw const FormatException(
      'Sale quantity must be a positive whole number.',
    );
  }
  if (totalAmountPaise != null &&
      (totalAmountPaise < 0 || totalAmountPaise > maxExactPaise)) {
    throw const FormatException(
      'Sale amount is outside the supported range.',
    );
  }
  final time = occurredAt ?? clock();
  if (civilDay(time).isAfter(today)) {
    throw const FormatException('A sale cannot be recorded in the future.');
  }
  validateDispensingDate(medicine, time);
  final current = medicine.quantity;
  if (current != null && quantity > current) {
    throw FormatException(
      'Only $current units are recorded in stock. Correct the stock first or enter a smaller sale.',
    );
  }
  if (markSoldOut && current == null) {
    throw const FormatException(
      'Stock quantity is unknown, so this sale cannot safely mark the entry completely finished. Verify the physical quantity first or use the explicit whole-stock SOLD action.',
    );
  }
  if (markSoldOut && current != null && quantity != current) {
    throw const FormatException(
      'To mark this entry out of stock, the sale quantity must equal all remaining units.',
    );
  }

  return ReviewedSale(
    baseRevision: snapshot.revision,
    record: Medicine.fromJson(medicine.toJson()),
    quantity: quantity,
    totalAmountPaise: totalAmountPaise,
    occurredAt: time,
    markSoldOut: markSoldOut,
  );
}

Future<void> applySale(ReviewedSale review) async {
  final live = snapshot.records[review.stockId];
  if (live == null ||
      live.archived ||
      live.sold ||
      !_sameReviewedMedicine(live, review.record)) {
    throw StateError(
      'The reviewed stock entry changed or is no longer active. Review the sale again; nothing was saved.',
    );
  }

  // Re-run every deterministic sale invariant against the live database. This
  // deliberately rebases over unrelated global writes while keeping the exact
  // reviewed stock row immutable. The final persistence CAS still rejects a
  // later race between this synchronous revalidation and the queued commit.
  final fresh = reviewSale(
    live.id,
    quantity: review.quantity,
    totalAmountPaise: review.totalAmountPaise,
    occurredAt: review.occurredAt,
    markSoldOut: review.markSoldOut,
    reviewedRecord: review.record,
  );
  final medicine = fresh.record;
  final current = medicine.quantity;
  final remaining = current == null ? null : current - fresh.quantity;
  final sale = SaleEvent(
    id: newId(),
    stockId: medicine.id,
    medicineName: medicine.name,
    strength: medicine.strength,
    form: medicine.form,
    salt: medicine.salt,
    quantity: fresh.quantity,
    occurredAt: fresh.occurredAt,
    totalAmountPaise: fresh.totalAmountPaise,
    savedUnitPricePaise: medicine.unitPricePaise,
  );
  final updated = medicine.patch({
    'quantity': fresh.markSoldOut ? 0 : remaining,
    if (fresh.markSoldOut) ...{
      'sold': true,
      'soldAt': fresh.occurredAt.toIso8601String(),
      'soldQuantity': current,
      'soldUnitPricePaise': medicine.unitPricePaise,
    },
  });
  await _commit(
    InventoryMutation(
      expectedRevision: fresh.baseRevision,
      label:
          'Recorded sale · ${medicine.name} · ${fresh.quantity} ${fresh.quantity == 1 ? 'unit' : 'units'}${fresh.markSoldOut ? ' · marked sold' : ''}',
      upserts: [updated],
      upsertSales: [sale],
    ),
  );
}

/// Immediate compatibility gateway. New user-facing confirmation flows should
/// use reviewSale/applySale so harmless unrelated inventory traffic does not
/// invalidate an otherwise exact pharmacist review.
Future<void> recordSale(
  String id, {
  required int quantity,
  int? totalAmountPaise,
  DateTime? occurredAt,
  bool markSoldOut = false,
  int? expectedRevision,
}) async {
  if (expectedRevision != null && expectedRevision != snapshot.revision) {
    throw StateError(
      'Inventory changed. Reopen this entry before recording a sale.',
    );
  }
  await applySale(
    reviewSale(
      id,
      quantity: quantity,
      totalAmountPaise: totalAmountPaise,
      occurredAt: occurredAt,
      markSoldOut: markSoldOut,
    ),
  );
}
''',
)

replace_once(
    'lib/ui/editor_screen.dart',
    '''
await widget.controller.recordSale(
  record.id,
  quantity: result.quantity,
  totalAmountPaise: result.amountPaise,
  markSoldOut: result.markSoldOut,
  occurredAt: result.occurredAt,
  expectedRevision: _baseRevision,
);
''',
    '''
final review = widget.controller.reviewSale(
  record.id,
  quantity: result.quantity,
  totalAmountPaise: result.amountPaise,
  markSoldOut: result.markSoldOut,
  occurredAt: result.occurredAt,
  reviewedRecord: record,
);
await widget.controller.applySale(review);
''',
)


# ---------------------------------------------------------------------------
# 2) Human-like deterministic Aaris Brain field-edit routing.
#    This expands understanding without letting AI invent field values.
# ---------------------------------------------------------------------------
replace_once(
    'lib/domain/app_brain.dart',
    "if (_containsAny(text, _editTerms)) families.add('edit');",
    "if (_containsAny(text, _editTerms) || _looksLikeFieldEdit(text)) {\n  families.add('edit');\n}",
)

replace_once(
    'lib/domain/app_brain.dart',
    '''
if (_containsAny(text, _editTerms)) {
  return AppBrainIntent(
    action: AppBrainAction.editMedicine,
    query: _extractMedicineQuery(raw, _editTerms),
    confidence: .95,
  );
}
''',
    '''
final fieldEdit = _fieldEditIntent(raw, text);
if (fieldEdit != null) return fieldEdit;

if (_containsAny(text, _editTerms)) {
  return AppBrainIntent(
    action: AppBrainAction.editMedicine,
    query: _extractMedicineQuery(raw, _editTerms),
    confidence: .95,
  );
}
''',
)

replace_once(
    'lib/domain/app_brain.dart',
    '''
AppBrainIntent? _operationalReadIntent(String raw, String text) {
''',
    '''
AppBrainIntent? _fieldEditIntent(String raw, String text) {
  if (!_looksLikeFieldEdit(text)) return null;
  final query = _extractMedicineQuery(raw, [
    ..._editorFieldEditVerbs,
    ..._editorFieldTerms,
  ]);
  return AppBrainIntent(
    action: AppBrainAction.editMedicine,
    query: query,
    confidence: query.isEmpty ? .90 : .99,
  );
}

bool _looksLikeFieldEdit(String text) =>
    _containsAny(text, _editorFieldEditVerbs) &&
    _containsAny(text, _editorFieldTerms);

AppBrainIntent? _operationalReadIntent(String raw, String text) {
''',
)

replace_once(
    'lib/domain/app_brain.dart',
    '''
const _editTerms = <String>[
''',
    '''
const _editorFieldEditVerbs = <String>[
  'change',
  'update',
  'edit',
  'correct',
  'fix',
  'set',
  'badlo',
  'badal do',
  'sahi karo',
  'theek karo',
  'बदलो',
  'बदल दो',
  'अपडेट',
  'एडिट',
  'सही करो',
  'ठीक करो',
  'सेट',
];

const _editorFieldTerms = <String>[
  'expiry date',
  'expiry',
  'exp date',
  'mfg date',
  'manufacturing date',
  'manufacturing',
  'mfg',
  'batch number',
  'batch no',
  'batch',
  'barcode',
  'bar code',
  'unit price',
  'price',
  'amount',
  'salt',
  'strength',
  'brand',
  'manufacturer',
  'medicine name',
  'name',
  'form',
  'notes',
  'note',
  'एक्सपायरी डेट',
  'एक्सपायरी',
  'एमएफजी डेट',
  'मैन्युफैक्चरिंग डेट',
  'बैच नंबर',
  'बैच',
  'बारकोड',
  'कीमत',
  'अमाउंट',
  'सॉल्ट',
  'स्ट्रेंथ',
  'ब्रांड',
  'मैन्युफैक्चरर',
  'मेडिसिन नाम',
  'नाम',
  'फॉर्म',
  'नोट्स',
  'नोट',
];

const _editTerms = <String>[
''',
)


# ---------------------------------------------------------------------------
# 3) Regression tests for the new concurrency boundary and Brain grammar.
# ---------------------------------------------------------------------------
write_new(
    'test/reviewed_sale_concurrency_test.dart',
    '''
import 'package:aaris_pharmacy/data/inventory_database.dart';
import 'package:aaris_pharmacy/domain/medicine.dart';
import 'package:aaris_pharmacy/state/pharmacy_controller.dart';
import 'package:flutter_test/flutter_test.dart';

Medicine stock(String id, {String name = 'Dolo', int? quantity = 10}) =>
    Medicine.fromJson({
      'id': id,
      'name': name,
      'strength': '650 mg',
      'form': 'Tablet',
      'quantity': quantity,
      'expiry': '2027-12',
      'revision': 1,
    });

Future<PharmacyController> controller() async {
  final value = PharmacyController(
    MemoryInventoryStorage(),
    clock: () => DateTime(2026, 9, 10, 12),
    backgroundSearch: false,
  );
  await value.initialize();
  return value;
}

void main() {
  group('dependency-scoped reviewed single-stock sale', () {
    test('survives unrelated inventory writes', () async {
      final value = await controller();
      addTearDown(value.dispose);
      await value.save(stock('a'), expectedRevision: 0);
      final displayed = value.snapshot.records['a']!;
      final review = value.reviewSale(
        'a',
        quantity: 2,
        totalAmountPaise: 4200,
        reviewedRecord: displayed,
      );

      await value.save(
        stock('b', name: 'Crocin'),
        expectedRevision: value.snapshot.revision,
      );
      await value.applySale(review);

      expect(value.snapshot.records['a']!.quantity, 8);
      expect(value.snapshot.records['b']!.quantity, 10);
      expect(value.sales, hasLength(1));
      expect(value.sales.single.quantity, 2);
      expect(value.sales.single.totalAmountPaise, 4200);
    });

    test('rejects a target row changed after review', () async {
      final value = await controller();
      addTearDown(value.dispose);
      await value.save(stock('a'), expectedRevision: 0);
      final review = value.reviewSale('a', quantity: 2);
      final live = value.snapshot.records['a']!;
      await value.save(
        live.patch({'notes': 'physical pack rechecked'}),
        expectedRevision: value.snapshot.revision,
      );

      await expectLater(value.applySale(review), throwsStateError);
      expect(value.snapshot.records['a']!.quantity, 10);
      expect(value.sales, isEmpty);
    });

    test('rejects a stale editor snapshot before preparing the sale', () async {
      final value = await controller();
      addTearDown(value.dispose);
      await value.save(stock('a'), expectedRevision: 0);
      final displayed = value.snapshot.records['a']!;
      await value.save(
        displayed.patch({'notes': 'changed elsewhere'}),
        expectedRevision: value.snapshot.revision,
      );

      expect(
        () => value.reviewSale(
          'a',
          quantity: 1,
          reviewedRecord: displayed,
        ),
        throwsStateError,
      );
      expect(value.sales, isEmpty);
    });

    test('unknown stock cannot be silently marked sold out', () async {
      final value = await controller();
      addTearDown(value.dispose);
      await value.save(stock('a', quantity: null), expectedRevision: 0);

      expect(
        () => value.reviewSale('a', quantity: 1, markSoldOut: true),
        throwsFormatException,
      );
      expect(value.snapshot.records['a']!.sold, isFalse);
      expect(value.sales, isEmpty);
    });

    test('reviewed sold-out sale remains atomic and undoable', () async {
      final value = await controller();
      addTearDown(value.dispose);
      await value.save(stock('a', quantity: 3), expectedRevision: 0);
      final review = value.reviewSale(
        'a',
        quantity: 3,
        totalAmountPaise: 9000,
        markSoldOut: true,
      );
      await value.applySale(review);

      expect(value.snapshot.records['a']!.quantity, 0);
      expect(value.snapshot.records['a']!.sold, isTrue);
      expect(value.sales, hasLength(1));
      await value.undo();
      expect(value.snapshot.records['a']!.quantity, 3);
      expect(value.snapshot.records['a']!.sold, isFalse);
      expect(value.sales, isEmpty);
    });
  });
}
''',
)

write_new(
    'test/brain_field_edit_intent_test.dart',
    '''
import 'package:aaris_pharmacy/domain/app_brain.dart';
import 'package:aaris_pharmacy/domain/medicine_brief.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Aaris Brain human field-edit routing', () {
    test('routes natural field corrections into exact medicine editing', () {
      final expiry = parseAppBrainIntent('Dolo 650 expiry change karo');
      expect(expiry.action, AppBrainAction.editMedicine);
      expect(expiry.query, 'Dolo 650');

      final batch = parseAppBrainIntent('Dolo 650 batch number update karo');
      expect(batch.action, AppBrainAction.editMedicine);
      expect(batch.query, 'Dolo 650');

      final price = parseAppBrainIntent('Dolo 650 price correct karo');
      expect(price.action, AppBrainAction.editMedicine);
      expect(price.query, 'Dolo 650');

      final hindi = parseAppBrainIntent('Dolo 650 एक्सपायरी बदल दो');
      expect(hindi.action, AppBrainAction.editMedicine);
      expect(hindi.query, 'Dolo 650');
    });

    test('contextual field edit can reuse only the exact remembered target', () {
      final intent = parseAppBrainIntent('isko expiry update karo');
      expect(intent.action, AppBrainAction.editMedicine);
      expect(intent.query, 'isko');
      expect(isAppBrainContextReference(intent.query), isTrue);
      expect(intent.canUseImplicitExactContext, isTrue);
    });

    test('read-only expiry question stays read-only', () {
      final intent = parseAppBrainIntent('Dolo 650 expiry kab hai');
      expect(intent.action, AppBrainAction.search);
      expect(intent.briefFocus, MedicineBriefFocus.expiry);
      expect(intent.query, 'Dolo 650');
    });

    test('stock quantity and location retain their specialized operations', () {
      final quantity = parseAppBrainIntent('Dolo 650 quantity 20 set karo');
      expect(quantity.action, AppBrainAction.setQuantity);
      expect(quantity.quantity, 20);

      final location = parseAppBrainIntent('Dolo 650 location Rack C set karo');
      expect(location.action, AppBrainAction.relocateMedicine);
      expect(location.locationPatch?.location, 'Rack C');
    });

    test('negative deferred and compound field edits fail closed', () {
      final negative = parseAppBrainIntent("don't change Dolo 650 expiry");
      expect(negative.action, AppBrainAction.safetyBlocked);
      expect(negative.safetyReason, AppBrainSafetyReason.negatedMutation);

      final deferred = parseAppBrainIntent('kal Dolo 650 expiry update karo');
      expect(deferred.action, AppBrainAction.safetyBlocked);
      expect(deferred.safetyReason, AppBrainSafetyReason.deferredMutation);

      final compound = parseAppBrainIntent(
        'Dolo 650 expiry change karo then remove Dolo 650',
      );
      expect(compound.action, AppBrainAction.safetyBlocked);
      expect(compound.safetyReason, AppBrainSafetyReason.compoundMutation);
    });
  });
}
''',
)

write_new(
    'docs/ULTIMATE_AUTOMATION_UPGRADE_2026_09_10.md',
    '''
# Aaris Pharmacy — automation safety upgrade (2026-09-10)

This upgrade deepens the existing architecture instead of replacing it.

## Reviewed single-stock sales

Ordinary editor sales now use the same review/apply pattern already used by FEFO,
SOLD, removal, restore, stock adjustments and location changes. A review is bound
to the exact physical Medicine row shown to the pharmacist. Unrelated inventory
traffic can advance the global database revision without forcing a harmless retry,
but any edit to the reviewed row invalidates the operation. The persistence CAS
and sale-ledger firewall remain authoritative at commit time.

The editor additionally binds its sale review to the exact Medicine snapshot that
was visible while the dialog was open. A background or competing edit to that row
therefore cannot be silently accepted after confirmation.

## Human field-edit commands

Aaris Brain now understands natural commands such as `Dolo expiry change karo`,
`batch number update`, `price correct`, and equivalent Hindi phrases. These commands
only resolve the exact local stock target and open the existing reviewed editor;
they never invent a new expiry, price, salt, batch, barcode, strength or other
medicine fact.

The same deterministic mutation firewall handles field edits. Negated, deferred
or compound instructions fail closed before target search, while read-only expiry
questions, stock quantity commands and physical-location commands retain their
specialized deterministic routes.

## Invariants preserved

- One authoritative Medicine Database.
- No silent destructive mutation.
- No AI/OCR output can bypass pharmacist review.
- No invented clinical or medicine facts.
- Sale audit remains append-only outside audited Undo/backup recovery.
- FEFO and expiry validation remain deterministic.
- All mutation commits remain revision-checked, atomic and undoable.
- The design remains local-first and stores no customer/patient identity.
''',
)

print('Aaris ultimate automation patch prepared successfully')
