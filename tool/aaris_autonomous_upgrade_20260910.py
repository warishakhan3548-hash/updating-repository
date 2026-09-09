#!/usr/bin/env python3
from __future__ import annotations

import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE_BRANCH = "upgrade/aaris-brain-quick-intake-20260910"


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


def write(path: str, text: str) -> None:
    target = ROOT / path
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(text, encoding="utf-8")


def replace_once(path: str, old: str, new: str) -> None:
    text = read(path)
    count = text.count(old)
    if count != 1:
        raise RuntimeError(f"{path}: expected exactly one surgical target, found {count}")
    write(path, text.replace(old, new, 1))


def copy_from_source(path: str) -> None:
    data = subprocess.check_output(
        ["git", "show", f"origin/{SOURCE_BRANCH}:{path}"], cwd=ROOT
    ).decode("utf-8")
    write(path, data)


# ---------------------------------------------------------------------------
# 1. Reviewed pharmacist quick intake
# ---------------------------------------------------------------------------
# Reuse the already-reviewed parser/test assets from the stale feature branch,
# but transplant only their narrow feature onto current main. Never overwrite
# current main's newer Brain/scanner/recovery work with old whole-file blobs.
for source_path in (
    "lib/domain/medicine_entry_prefill.dart",
    "test/medicine_entry_prefill_test.dart",
    "test/medicine_entry_prefill_prefix_guard_test.dart",
    "docs/AARIS_BRAIN_REVIEWED_QUICK_INTAKE_2026_09_10.md",
):
    copy_from_source(source_path)

replace_once(
    "lib/domain/app_brain.dart",
    "import 'medicine_brief.dart';\n",
    "import 'medicine_brief.dart';\nimport 'medicine_entry_prefill.dart';\n",
)
replace_once(
    "lib/domain/app_brain.dart",
    """    this.locationPatch,\n    this.removalReason,\n    this.confidence = 0,\n""",
    """    this.locationPatch,\n    this.removalReason,\n    this.addPrefill,\n    this.confidence = 0,\n""",
)
replace_once(
    "lib/domain/app_brain.dart",
    """  final StockLocationPatch? locationPatch;\n  final RemovalReasonHint? removalReason;\n  final double confidence;\n""",
    """  final StockLocationPatch? locationPatch;\n  final RemovalReasonHint? removalReason;\n  final MedicineEntryPrefill? addPrefill;\n  final double confidence;\n""",
)
replace_once(
    "lib/domain/app_brain.dart",
    """  if (_containsAny(text, const [\n    'add medicine',\n    'new medicine',\n    'medicine add',\n    'add stock',\n    'nayi medicine',\n    'nayi dawai',\n    'नई मेडिसिन',\n    'नई दवा',\n    'मेडिसिन जोड़',\n  ])) {\n    return const AppBrainIntent(\n      action: AppBrainAction.addMedicine,\n      confidence: .98,\n    );\n  }\n""",
    """  final addPrefill = parseMedicineAddPrefill(raw);\n  if (addPrefill != null) {\n    return AppBrainIntent(\n      action: AppBrainAction.addMedicine,\n      addPrefill: addPrefill,\n      confidence: .99,\n    );\n  }\n""",
)

replace_once(
    "lib/ui/brain_screen.dart",
    """    final intent = parseAppBrainIntent(raw);\n    setState(() {\n      _busy = true;\n      _reply = 'Understanding command…';\n      if (supplied != null) _command.text = supplied;\n    });\n    try {\n      await _execute(intent, raw);\n""",
    """    setState(() {\n      _busy = true;\n      _reply = 'Understanding command…';\n      if (supplied != null) _command.text = supplied;\n    });\n    try {\n      final intent = parseAppBrainIntent(raw);\n      await _execute(intent, raw);\n""",
)
replace_once(
    "lib/ui/brain_screen.dart",
    """      case AppBrainAction.addMedicine:\n        if (mounted) {\n          widget.onOpenSection(AppSection.stock);\n          setState(() => _reply = 'Opening a fresh medicine entry.');\n          await Future<void>.delayed(Duration.zero);\n          if (mounted) await openEditor(context, widget.controller);\n        }\n        return;\n""",
    """      case AppBrainAction.addMedicine:\n        if (mounted) {\n          final prefill = intent.addPrefill;\n          widget.onOpenSection(AppSection.stock);\n          setState(\n            () => _reply = prefill == null || prefill.isEmpty\n                ? 'Opening a fresh medicine entry.'\n                : 'Prepared a review-only medicine draft from your explicit command facts: ${prefill.reviewSummary}. Nothing is saved until you review and press Save.',\n          );\n          await Future<void>.delayed(Duration.zero);\n          if (mounted) {\n            await openEditor(context, widget.controller, prefill: prefill);\n          }\n        }\n        return;\n""",
)

replace_once(
    "lib/ui/editor_screen.dart",
    "import '../domain/medicine_discovery.dart';\n",
    "import '../domain/medicine_discovery.dart';\nimport '../domain/medicine_entry_prefill.dart';\n",
)
replace_once(
    "lib/ui/editor_screen.dart",
    """  MedicineDraftSeed? seed,\n  MedicineScanDraft? scanDraft,\n  String barcode = '',\n""",
    """  MedicineDraftSeed? seed,\n  MedicineScanDraft? scanDraft,\n  MedicineEntryPrefill? prefill,\n  String barcode = '',\n""",
)
replace_once(
    "lib/ui/editor_screen.dart",
    """        seed: seed,\n        scanDraft: scanDraft,\n        barcode: barcode,\n""",
    """        seed: seed,\n        scanDraft: scanDraft,\n        prefill: prefill,\n        barcode: barcode,\n""",
)
replace_once(
    "lib/ui/editor_screen.dart",
    """    this.seed,\n    this.scanDraft,\n    this.barcode = '',\n""",
    """    this.seed,\n    this.scanDraft,\n    this.prefill,\n    this.barcode = '',\n""",
)
replace_once(
    "lib/ui/editor_screen.dart",
    """  final MedicineDraftSeed? seed;\n  final MedicineScanDraft? scanDraft;\n  final String barcode, ocrText;\n""",
    """  final MedicineDraftSeed? seed;\n  final MedicineScanDraft? scanDraft;\n  final MedicineEntryPrefill? prefill;\n  final String barcode, ocrText;\n""",
)
replace_once(
    "lib/ui/editor_screen.dart",
    """    final seed = widget.seed;\n    final scan = widget.scanDraft;\n    String identityValue(String? catalog, String scanned) =>\n""",
    """    final seed = widget.seed;\n    final scan = widget.scanDraft;\n    final prefill = widget.prefill;\n    String identityValue(String? catalog, String scanned) =>\n""",
)
replace_once(
    "lib/ui/editor_screen.dart",
    """          'ocrText': widget.ocrText.trim().isNotEmpty\n              ? widget.ocrText\n              : scan?.searchableOcrText ?? '',\n        };\n""",
    """          'ocrText': widget.ocrText.trim().isNotEmpty\n              ? widget.ocrText\n              : scan?.searchableOcrText ?? '',\n          ...?prefill?.editorValues,\n        };\n""",
)
replace_once(
    "lib/ui/editor_screen.dart",
    """    fields['price'] = TextEditingController(\n      text: widget.record?.unitPricePaise == null\n          ? ''\n          : (widget.record!.unitPricePaise! / 100).toStringAsFixed(2),\n    );\n""",
    """    fields['price'] = TextEditingController(\n      text: widget.record?.unitPricePaise == null\n          ? prefill?.priceText ?? ''\n          : (widget.record!.unitPricePaise! / 100).toStringAsFixed(2),\n    );\n""",
)
replace_once(
    "lib/ui/editor_screen.dart",
    """    final record = widget.record;\n    _form = record?.form ?? identityValue(seed?.form, scan?.form ?? '');\n    _mfgMonthOnly = record?.mfg == null\n        ? scan?.mfgMonthOnly ?? false\n        : record!.mfgMonthOnly;\n    _expiryMonthOnly = record?.expiry == null || record!.expiryMonthOnly;\n    if (record?.expiry == null && scan?.expiry.isNotEmpty == true) {\n      _expiryMonthOnly = scan!.expiryMonthOnly;\n      final value = parseDate(scan.expiry, monthEnd: _expiryMonthOnly);\n      if (value != null) {\n        fields['expiry']!.text = inputDateText(\n          value,\n          monthOnly: _expiryMonthOnly,\n        );\n      }\n    }\n    if (record?.expiry != null) {\n      fields['expiry']!.text = inputDateText(\n        record!.expiry!,\n        monthOnly: _expiryMonthOnly,\n      );\n    }\n    if (record?.mfg != null) {\n      fields['mfg']!.text = inputDateText(\n        record!.mfg!,\n        monthOnly: record.mfgMonthOnly,\n      );\n    } else if (scan?.mfg.isNotEmpty == true) {\n      final value = parseDate(scan!.mfg, monthStart: _mfgMonthOnly);\n      if (value != null) {\n        fields['mfg']!.text = inputDateText(value, monthOnly: _mfgMonthOnly);\n      }\n    }\n""",
    """    final record = widget.record;\n    _form =\n        record?.form ??\n        (prefill?.form.isNotEmpty == true\n            ? prefill!.form\n            : identityValue(seed?.form, scan?.form ?? ''));\n    _mfgMonthOnly = record?.mfg != null\n        ? record!.mfgMonthOnly\n        : prefill?.mfg.isNotEmpty == true\n        ? prefill!.mfgMonthOnly\n        : scan?.mfgMonthOnly ?? false;\n    _expiryMonthOnly = record?.expiry != null\n        ? record!.expiryMonthOnly\n        : prefill?.expiry.isNotEmpty == true\n        ? prefill!.expiryMonthOnly\n        : scan?.expiry.isNotEmpty == true\n        ? scan!.expiryMonthOnly\n        : true;\n    if (record?.expiry == null && prefill?.expiry.isNotEmpty == true) {\n      final value = parseDate(\n        prefill!.expiry,\n        monthEnd: prefill.expiryMonthOnly,\n      );\n      if (value != null) {\n        fields['expiry']!.text = inputDateText(\n          value,\n          monthOnly: prefill.expiryMonthOnly,\n        );\n      }\n    } else if (record?.expiry == null && scan?.expiry.isNotEmpty == true) {\n      _expiryMonthOnly = scan!.expiryMonthOnly;\n      final value = parseDate(scan.expiry, monthEnd: _expiryMonthOnly);\n      if (value != null) {\n        fields['expiry']!.text = inputDateText(\n          value,\n          monthOnly: _expiryMonthOnly,\n        );\n      }\n    }\n    if (record?.expiry != null) {\n      fields['expiry']!.text = inputDateText(\n        record!.expiry!,\n        monthOnly: _expiryMonthOnly,\n      );\n    }\n    if (record?.mfg != null) {\n      fields['mfg']!.text = inputDateText(\n        record!.mfg!,\n        monthOnly: record.mfgMonthOnly,\n      );\n    } else if (prefill?.mfg.isNotEmpty == true) {\n      final value = parseDate(prefill!.mfg, monthStart: prefill.mfgMonthOnly);\n      if (value != null) {\n        fields['mfg']!.text = inputDateText(\n          value,\n          monthOnly: prefill.mfgMonthOnly,\n        );\n      }\n    } else if (scan?.mfg.isNotEmpty == true) {\n      final value = parseDate(scan!.mfg, monthStart: _mfgMonthOnly);\n      if (value != null) {\n        fields['mfg']!.text = inputDateText(value, monthOnly: _mfgMonthOnly);\n      }\n    }\n""",
)

# ---------------------------------------------------------------------------
# 2. Exactly-once reviewed operation receipts
# ---------------------------------------------------------------------------
# A double callback, rapid double-tap or lifecycle retry must not create a
# second physical stock movement or sale. A secure request ID is minted at the
# review boundary and persisted atomically with the mutation. Replaying the same
# reviewed operation is a no-op; creating a fresh review mints a fresh intent.

replace_once(
    "lib/domain/dispensing_plan.dart",
    """  const ReviewedFefoSale({\n    required this.baseRevision,\n    required this.occurredAt,\n    required this.plan,\n  });\n\n  final int baseRevision;\n  final DateTime occurredAt;\n  final FefoDispensingPlan plan;\n""",
    """  const ReviewedFefoSale({\n    required this.requestId,\n    required this.baseRevision,\n    required this.occurredAt,\n    required this.plan,\n  });\n\n  /// Stable exactly-once token for this pharmacist-reviewed sale intent.\n  final String requestId;\n  final int baseRevision;\n  final DateTime occurredAt;\n  final FefoDispensingPlan plan;\n""",
)

replace_once(
    "lib/state/pharmacy_controller.dart",
    """class ReviewedStockAdjustment {\n  const ReviewedStockAdjustment({\n    required this.baseRevision,\n""",
    """class ReviewedStockAdjustment {\n  const ReviewedStockAdjustment({\n    required this.requestId,\n    required this.baseRevision,\n""",
)
replace_once(
    "lib/state/pharmacy_controller.dart",
    """  final int baseRevision;\n  final String stockId;\n  final int recordRevision;\n  final StockAdjustmentKind kind;\n""",
    """  final String requestId;\n  final int baseRevision;\n  final String stockId;\n  final int recordRevision;\n  final StockAdjustmentKind kind;\n""",
)
replace_once(
    "lib/state/pharmacy_controller.dart",
    """class BulkArchiveReview {\n  BulkArchiveReview({\n    required this.baseRevision,\n    required Iterable<String> activeIds,\n  }) : activeIds = Set.unmodifiable(activeIds);\n\n  final int baseRevision;\n""",
    """class BulkArchiveReview {\n  BulkArchiveReview({\n    required this.requestId,\n    required this.baseRevision,\n    required Iterable<String> activeIds,\n  }) : activeIds = Set.unmodifiable(activeIds);\n\n  final String requestId;\n  final int baseRevision;\n""",
)
replace_once(
    "lib/state/pharmacy_controller.dart",
    """class ReviewedArchivedRestore {\n  const ReviewedArchivedRestore({\n    required this.baseRevision,\n""",
    """class ReviewedArchivedRestore {\n  const ReviewedArchivedRestore({\n    required this.requestId,\n    required this.baseRevision,\n""",
)
# This occurrence is now the archived-restore fields; target the unique sequence.
replace_once(
    "lib/state/pharmacy_controller.dart",
    """  final int baseRevision;\n  final String stockId;\n  final int recordRevision;\n  final String archiveReason;\n  final DateTime? archivedAt;\n""",
    """  final String requestId;\n  final int baseRevision;\n  final String stockId;\n  final int recordRevision;\n  final String archiveReason;\n  final DateTime? archivedAt;\n""",
)

replace_once(
    "lib/state/pharmacy_controller.dart",
    """    return ReviewedFefoSale(\n      baseRevision: snapshot.revision,\n""",
    """    return ReviewedFefoSale(\n      requestId: newId(),\n      baseRevision: snapshot.revision,\n""",
)
replace_once(
    "lib/state/pharmacy_controller.dart",
    """  Future<void> applyFefoSale(ReviewedFefoSale review) async {\n    if (review.baseRevision != snapshot.revision) {\n""",
    """  Future<void> applyFefoSale(ReviewedFefoSale review) async {\n    if (snapshot.receipts.contains(review.requestId)) return;\n    if (review.baseRevision != snapshot.revision) {\n""",
)
replace_once(
    "lib/state/pharmacy_controller.dart",
    """        upserts: updates,\n        upsertSales: saleEvents,\n      ),\n""",
    """        upserts: updates,\n        upsertSales: saleEvents,\n        requestId: review.requestId,\n      ),\n""",
)

replace_once(
    "lib/state/pharmacy_controller.dart",
    """  Future<void> save(Medicine record, {required int expectedRevision}) async {\n""",
    """  Future<void> save(\n    Medicine record, {\n    required int expectedRevision,\n    String? requestId,\n  }) async {\n""",
)
replace_once(
    "lib/state/pharmacy_controller.dart",
    """        upserts: [record],\n      ),\n    );\n  }\n\n  Future<void> setWarnings""",
    """        upserts: [record],\n        requestId: requestId,\n      ),\n    );\n  }\n\n  Future<void> setWarnings""",
)

replace_once(
    "lib/state/pharmacy_controller.dart",
    """    return ReviewedStockAdjustment(\n      baseRevision: snapshot.revision,\n""",
    """    return ReviewedStockAdjustment(\n      requestId: newId(),\n      baseRevision: snapshot.revision,\n""",
)
replace_once(
    "lib/state/pharmacy_controller.dart",
    """  Future<void> applyStockAdjustment(ReviewedStockAdjustment review) async {\n    if (review.baseRevision != snapshot.revision) {\n""",
    """  Future<void> applyStockAdjustment(ReviewedStockAdjustment review) async {\n    if (snapshot.receipts.contains(review.requestId)) return;\n    if (review.baseRevision != snapshot.revision) {\n""",
)
replace_once(
    "lib/state/pharmacy_controller.dart",
    """        label: label,\n        upserts: [live.patch(changes)],\n      ),\n""",
    """        label: label,\n        upserts: [live.patch(changes)],\n        requestId: review.requestId,\n      ),\n""",
)

replace_once(
    "lib/state/pharmacy_controller.dart",
    """  BulkArchiveReview reviewArchiveAll() => BulkArchiveReview(\n    baseRevision: snapshot.revision,\n""",
    """  BulkArchiveReview reviewArchiveAll() => BulkArchiveReview(\n    requestId: newId(),\n    baseRevision: snapshot.revision,\n""",
)
replace_once(
    "lib/state/pharmacy_controller.dart",
    """  Future<void> applyArchiveAll(BulkArchiveReview review) async {\n    if (review.baseRevision != snapshot.revision) {\n""",
    """  Future<void> applyArchiveAll(BulkArchiveReview review) async {\n    if (snapshot.receipts.contains(review.requestId)) return;\n    if (review.baseRevision != snapshot.revision) {\n""",
)
replace_once(
    "lib/state/pharmacy_controller.dart",
    """        upserts: [\n          for (final id in orderedIds)\n            archiveMedicine(\n              snapshot.records[id]!,\n              reason: 'Protected bulk removal',\n              at: removedAt,\n            ),\n        ],\n      ),\n""",
    """        upserts: [\n          for (final id in orderedIds)\n            archiveMedicine(\n              snapshot.records[id]!,\n              reason: 'Protected bulk removal',\n              at: removedAt,\n            ),\n        ],\n        requestId: review.requestId,\n      ),\n""",
)

replace_once(
    "lib/state/pharmacy_controller.dart",
    """    return ReviewedArchivedRestore(\n      baseRevision: snapshot.revision,\n""",
    """    return ReviewedArchivedRestore(\n      requestId: newId(),\n      baseRevision: snapshot.revision,\n""",
)
replace_once(
    "lib/state/pharmacy_controller.dart",
    """  Future<void> applyArchivedRestore(ReviewedArchivedRestore review) async {\n    if (review.baseRevision != snapshot.revision) {\n""",
    """  Future<void> applyArchivedRestore(ReviewedArchivedRestore review) async {\n    if (snapshot.receipts.contains(review.requestId)) return;\n    if (review.baseRevision != snapshot.revision) {\n""",
)
replace_once(
    "lib/state/pharmacy_controller.dart",
    """        label: 'Restored ${live.name}',\n        upserts: [restoreArchivedMedicine(live)],\n      ),\n""",
    """        label: 'Restored ${live.name}',\n        upserts: [restoreArchivedMedicine(live)],\n        requestId: review.requestId,\n      ),\n""",
)

# Location changes use the same controller save boundary, now with an optional
# reviewed request token, so no parallel write authority is introduced.
replace_once(
    "lib/state/stock_location_operations.dart",
    "import '../domain/brain_operations.dart';\n",
    "import '../domain/brain_operations.dart';\nimport '../domain/medicine.dart';\n",
)
replace_once(
    "lib/state/stock_location_operations.dart",
    """  const ReviewedStockLocationUpdate({\n    required this.baseRevision,\n""",
    """  const ReviewedStockLocationUpdate({\n    required this.requestId,\n    required this.baseRevision,\n""",
)
replace_once(
    "lib/state/stock_location_operations.dart",
    """  final int baseRevision;\n  final String stockId;\n""",
    """  final String requestId;\n  final int baseRevision;\n  final String stockId;\n""",
)
replace_once(
    "lib/state/stock_location_operations.dart",
    """    return ReviewedStockLocationUpdate(\n      baseRevision: snapshot.revision,\n""",
    """    return ReviewedStockLocationUpdate(\n      requestId: newId(),\n      baseRevision: snapshot.revision,\n""",
)
replace_once(
    "lib/state/stock_location_operations.dart",
    """  Future<void> applyStockLocationUpdate(\n    ReviewedStockLocationUpdate review,\n  ) async {\n    if (review.baseRevision != snapshot.revision) {\n""",
    """  Future<void> applyStockLocationUpdate(\n    ReviewedStockLocationUpdate review,\n  ) async {\n    if (snapshot.receipts.contains(review.requestId)) return;\n    if (review.baseRevision != snapshot.revision) {\n""",
)
replace_once(
    "lib/state/stock_location_operations.dart",
    """      }),\n      expectedRevision: review.baseRevision,\n    );\n""",
    """      }),\n      expectedRevision: review.baseRevision,\n      requestId: review.requestId,\n    );\n""",
)

# Persistence is the final exactly-once firewall. Validate the request shape
# first, then acknowledge an already-committed request before testing the old
# revision. This makes a genuine retry a successful no-op while malformed input
# still fails closed. A fresh request ID still has to pass the revision gate.
replace_once(
    "lib/data/inventory_database.dart",
    """    'AI request': mutation.requestId,\n""",
    """    'reviewed request': mutation.requestId,\n""",
)
replace_once(
    "lib/data/inventory_database.dart",
    """      if (before.revision != mutation.expectedRevision)\n        throw StateError(\n          'Inventory changed. Reopen this review before saving.',\n        );\n      _validateMutationShape(mutation);\n      if (mutation.requestId != null &&\n          before.receipts.contains(mutation.requestId))\n        throw StateError('This AI request has already been applied.');\n""",
    """      _validateMutationShape(mutation);\n      if (mutation.requestId != null &&\n          before.receipts.contains(mutation.requestId)) {\n        return before;\n      }\n      if (before.revision != mutation.expectedRevision) {\n        throw StateError(\n          'Inventory changed. Reopen this review before saving.',\n        );\n      }\n""",
)
replace_once(
    "lib/data/inventory_database.dart",
    """  Future<InventorySnapshot> commit(InventoryMutation mutation) async {\n    if (_state.revision != mutation.expectedRevision)\n      throw StateError('Inventory changed. Reopen this review.');\n    _validateMutationShape(mutation);\n    if (mutation.requestId != null &&\n        _state.receipts.contains(mutation.requestId))\n      throw StateError('Request already applied.');\n    final event = makeEvent(_state, mutation);\n""",
    """  Future<InventorySnapshot> commit(InventoryMutation mutation) async {\n    _validateMutationShape(mutation);\n    if (mutation.requestId != null &&\n        _state.receipts.contains(mutation.requestId)) {\n      return _state;\n    }\n    if (_state.revision != mutation.expectedRevision) {\n      throw StateError('Inventory changed. Reopen this review.');\n    }\n    final event = makeEvent(_state, mutation);\n""",
)

# ---------------------------------------------------------------------------
# 3. Adversarial regression coverage for exactly-once stock and sale effects
# ---------------------------------------------------------------------------
write(
    "test/reviewed_operation_idempotency_test.dart",
    r"""import 'package:flutter_test/flutter_test.dart';

import '../lib/data/inventory_database.dart';
import '../lib/domain/medicine.dart';
import '../lib/state/pharmacy_controller.dart';
import 'domain_contract.dart';

void main() {
  late PharmacyController controller;

  setUp(() async {
    controller = PharmacyController(
      MemoryInventoryStorage(),
      clock: () => contractToday,
      backgroundSearch: false,
    );
    await controller.initialize();
  });

  tearDown(() {
    controller.dispose();
  });

  test('concurrent replay of one reviewed receipt increments stock once', () async {
    await controller.save(stock('a', quantity: 10), expectedRevision: 0);
    final review = controller.reviewStockAdjustment(
      'a',
      kind: StockAdjustmentKind.receive,
      quantity: 5,
    );

    await Future.wait([
      controller.applyStockAdjustment(review),
      controller.applyStockAdjustment(review),
    ]);

    expect(controller.snapshot.records['a']!.quantity, 15);
    expect(controller.snapshot.revision, 2);
    expect(controller.snapshot.receipts, contains(review.requestId));
    expect(
      controller.snapshot.events.where(
        (event) => (event['label'] as String).startsWith('Received stock'),
      ),
      hasLength(1),
    );
  });

  test('a committed review remains exactly once after unrelated later writes', () async {
    await controller.save(stock('a', quantity: 10), expectedRevision: 0);
    final first = controller.reviewStockAdjustment(
      'a',
      kind: StockAdjustmentKind.receive,
      quantity: 5,
    );
    await controller.applyStockAdjustment(first);
    await controller.save(stock('b', quantity: 4), expectedRevision: 2);
    final revisionBeforeReplay = controller.snapshot.revision;

    await controller.applyStockAdjustment(first);

    expect(controller.snapshot.revision, revisionBeforeReplay);
    expect(controller.snapshot.records['a']!.quantity, 15);

    final distinct = controller.reviewStockAdjustment(
      'a',
      kind: StockAdjustmentKind.receive,
      quantity: 2,
    );
    expect(distinct.requestId, isNot(first.requestId));
    await controller.applyStockAdjustment(distinct);
    expect(controller.snapshot.records['a']!.quantity, 17);
    expect(controller.snapshot.revision, revisionBeforeReplay + 1);
  });

  test('concurrent replay of one reviewed FEFO sale creates one sale ledger effect', () async {
    await controller.save(
      stock('a', quantity: 10, expiry: '2026-10-01'),
      expectedRevision: 0,
    );
    final review = controller.reviewFefoSale('a', quantity: 3);

    await Future.wait([
      controller.applyFefoSale(review),
      controller.applyFefoSale(review),
    ]);

    expect(controller.snapshot.records['a']!.quantity, 7);
    expect(controller.sales, hasLength(1));
    expect(controller.sales.single.quantity, 3);
    expect(controller.snapshot.revision, 2);
    expect(controller.snapshot.receipts, contains(review.requestId));
  });

  test('receipt replay stays blocked after Undo while a fresh review remains possible', () async {
    await controller.save(stock('a', quantity: 10), expectedRevision: 0);
    final review = controller.reviewStockAdjustment(
      'a',
      kind: StockAdjustmentKind.receive,
      quantity: 5,
    );
    await controller.applyStockAdjustment(review);
    await controller.undo();
    expect(controller.snapshot.records['a']!.quantity, 10);
    final afterUndoRevision = controller.snapshot.revision;

    await controller.applyStockAdjustment(review);

    expect(controller.snapshot.records['a']!.quantity, 10);
    expect(controller.snapshot.revision, afterUndoRevision);
    expect(controller.snapshot.receipts, contains(review.requestId));

    final fresh = controller.reviewStockAdjustment(
      'a',
      kind: StockAdjustmentKind.receive,
      quantity: 5,
    );
    await controller.applyStockAdjustment(fresh);
    expect(controller.snapshot.records['a']!.quantity, 15);
  });
}
""",
)

# Update the living implementation record without rewriting historical docs.
progress = read("docs/PROGRESS.md")
marker = "## Completed in source\n"
addition = """## Autonomous safety and quick-intake upgrade — 2026-09-10\n\n- Aaris Brain can convert explicit add-medicine commands into a review-only editor draft containing only pharmacist-typed facts (quantity, dates, batch/barcode, price and location included). Ambiguous numbers remain text evidence rather than guessed stock or dosage facts.\n- Pharmacist-reviewed FEFO sales, stock corrections/receipts, stock relocation, protected bulk removal and removed-stock restore now carry durable exactly-once request receipts. Duplicate callbacks/retries cannot repeat the physical stock or sale effect; a fresh review intentionally mints a fresh request.\n- Exactly-once receipts are enforced again at the authoritative persistence boundary while malformed requests and genuinely stale new requests still fail closed. Undo reverses the stock effect without resurrecting the old request token.\n- The single SQLite medicine database, explicit confirmations, audit/Undo, sale-ledger firewall, integrity firewall and local-first AI/OCR review boundaries remain authoritative.\n\n"""
if addition not in progress:
    if marker not in progress:
        raise RuntimeError("docs/PROGRESS.md: completion marker missing")
    progress = progress.replace(marker, addition + marker, 1)
    write("docs/PROGRESS.md", progress)

print("Aaris autonomous upgrade patch applied successfully")
