#!/usr/bin/env python3
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def base_file(path: str) -> str:
    return subprocess.check_output(
        ["git", "show", f"origin/main:{path}"], cwd=ROOT, text=True
    )


def write(path: str, content: str) -> None:
    target = ROOT / path
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(content, encoding="utf-8")


def reset_to_main(path: str) -> None:
    write(path, base_file(path))


def replace_once(path: str, old: str, new: str) -> None:
    target = ROOT / path
    text = target.read_text(encoding="utf-8")
    count = text.count(old)
    if count != 1:
        raise RuntimeError(f"{path}: expected one replacement anchor, found {count}")
    target.write_text(text.replace(old, new, 1), encoding="utf-8")


def insert_before_once(path: str, anchor: str, addition: str) -> None:
    target = ROOT / path
    text = target.read_text(encoding="utf-8")
    count = text.count(anchor)
    if count != 1:
        raise RuntimeError(f"{path}: expected one insertion anchor, found {count}")
    target.write_text(text.replace(anchor, addition + anchor, 1), encoding="utf-8")


# Undo formatter-only churn, then reapply just the intended production changes.
for file_name in (
    "lib/state/pharmacy_controller.dart",
    "lib/ui/brain_screen.dart",
):
    reset_to_main(file_name)

replace_once(
    "lib/ui/brain_screen.dart",
    "import '../domain/brain_clarification.dart';\n",
    "import '../domain/brain_clarification.dart';\nimport '../domain/brain_compound_operations.dart';\n",
)

replace_once(
    "lib/ui/brain_screen.dart",
    """      if (await _continuePendingChoice(raw)) return;\n      final intent = parseAppBrainIntent(raw);\n      await _execute(intent, raw);\n""",
    """      if (await _continuePendingChoice(raw)) return;\n      final compound = parseBrainStockAdjustmentAndLocationCommand(raw);\n      if (compound != null) {\n        await _medicineAction(compound.toIntent());\n        return;\n      }\n      final intent = parseAppBrainIntent(raw);\n      await _execute(intent, raw);\n""",
)

replace_once(
    "lib/ui/brain_screen.dart",
    """    final instruction = switch (action) {\n      AppBrainAction.recordSale when requestedQuantity != null =>\n        '${record.title} matched. Preparing a deterministic $requestedQuantity-unit FEFO allocation across active batches.',\n      AppBrainAction.setQuantity when requestedQuantity != null =>\n        '${record.title} matched. Preparing an exact stock correction to $requestedQuantity units.',\n      AppBrainAction.receiveStock when requestedQuantity != null =>\n        '${record.title} matched. Preparing a reviewed +$requestedQuantity-unit stock receipt.',\n      AppBrainAction.relocateMedicine when locationPatch != null =>\n        '${record.title} matched. Preparing a reviewed location change: ${describeStockLocationPatch(locationPatch)}.',\n      _ => _editorInstruction(action, record),\n    };\n""",
    """    final instruction = switch (action) {\n      AppBrainAction.recordSale when requestedQuantity != null =>\n        '${record.title} matched. Preparing a deterministic $requestedQuantity-unit FEFO allocation across active batches.',\n      AppBrainAction.setQuantity\n          when requestedQuantity != null && locationPatch != null =>\n        '${record.title} matched. Preparing one atomic stock correction to $requestedQuantity units plus ${describeStockLocationPatch(locationPatch)}.',\n      AppBrainAction.receiveStock\n          when requestedQuantity != null && locationPatch != null =>\n        '${record.title} matched. Preparing one atomic +$requestedQuantity-unit receipt plus ${describeStockLocationPatch(locationPatch)}.',\n      AppBrainAction.setQuantity when requestedQuantity != null =>\n        '${record.title} matched. Preparing an exact stock correction to $requestedQuantity units.',\n      AppBrainAction.receiveStock when requestedQuantity != null =>\n        '${record.title} matched. Preparing a reviewed +$requestedQuantity-unit stock receipt.',\n      AppBrainAction.relocateMedicine when locationPatch != null =>\n        '${record.title} matched. Preparing a reviewed location change: ${describeStockLocationPatch(locationPatch)}.',\n      _ => _editorInstruction(action, record),\n    };\n""",
)

replace_once(
    "lib/ui/brain_screen.dart",
    """    // Short deterministic mutations always resolve an exact stock row first,\n    // prepare a review tied to the current inventory revision, and still require\n    // a pharmacist confirmation before the controller can commit anything.\n    if (action == AppBrainAction.removeMedicine) {\n""",
    """    // A safe two-clause stock+location command becomes one reviewed\n    // transaction. The combined path prevents a partial quantity-only or\n    // location-only write if the second half becomes stale or invalid.\n    if ((action == AppBrainAction.setQuantity ||\n            action == AppBrainAction.receiveStock) &&\n        requestedQuantity != null &&\n        locationPatch != null) {\n      await _reviewStockAdjustmentAndLocation(\n        record,\n        action,\n        requestedQuantity,\n        locationPatch,\n      );\n      return;\n    }\n\n    // Short deterministic mutations always resolve an exact stock row first,\n    // prepare a review tied to the current inventory revision, and still require\n    // a pharmacist confirmation before the controller can commit anything.\n    if (action == AppBrainAction.removeMedicine) {\n""",
)

insert_before_once(
    "lib/ui/brain_screen.dart",
    "  Future<void> _reviewStockAdjustment(\n",
    """  Future<void> _reviewStockAdjustmentAndLocation(\n    Medicine original,\n    AppBrainAction action,\n    int quantity,\n    StockLocationPatch patch,\n  ) async {\n    if (!mounted) return;\n    final kind = action == AppBrainAction.receiveStock\n        ? StockAdjustmentKind.receive\n        : StockAdjustmentKind.setExact;\n    final review = widget.controller.reviewStockAdjustmentAndLocation(\n      original.id,\n      kind: kind,\n      quantity: quantity,\n      locationPatch: patch,\n    );\n    final live = widget.controller.snapshot.records[review.stockId];\n    if (live == null || live.archived) {\n      throw StateError(\n        'That stock entry is no longer active. Nothing changed.',\n      );\n    }\n    if (!review.changesQuantity && !review.changesLocation) {\n      setState(\n        () => _reply =\n            '${live.title} already has the requested stock count and location. No inventory change was needed.',\n      );\n      return;\n    }\n\n    final beforeQuantity = review.beforeQuantity == null\n        ? 'unknown'\n        : '${review.beforeQuantity} units';\n    final receive = kind == StockAdjustmentKind.receive;\n    final confirmed =\n        await showDialog<bool>(\n          context: context,\n          barrierDismissible: false,\n          builder: (ctx) => AlertDialog(\n            title: Text(\n              receive\n                  ? 'Receive $quantity units + update location?'\n                  : 'Correct stock + update location?',\n            ),\n            content: SingleChildScrollView(\n              child: Text(\n                '${_stockIdentityCue(live)}\\n\\nQuantity\\nBefore: $beforeQuantity\\nAfter: ${review.afterQuantity} units\\n\\nLocation\\nBefore: ${review.beforeLocationDisplay}\\nAfter: ${review.afterLocationDisplay}\\n\\n${review.wasSold ? 'This entry is currently SOLD. Receiving stock will explicitly reopen it while preserving historical sale events.\\n\\n' : ''}Both changes will save together as ONE revision-checked, audited and undoable inventory transaction. If this exact stock row changes before commit, neither half is saved.',\n              ),\n            ),\n            actions: [\n              TextButton(\n                onPressed: () => Navigator.pop(ctx, false),\n                child: const Text('Cancel'),\n              ),\n              FilledButton(\n                onPressed: () => Navigator.pop(ctx, true),\n                child: Text(receive ? 'Receive + move' : 'Correct + move'),\n              ),\n            ],\n          ),\n        ) ??\n        false;\n    if (!confirmed || !mounted) {\n      setState(() => _reply = 'Combined stock action cancelled. Nothing changed.');\n      return;\n    }\n\n    await widget.controller.applyStockAdjustmentAndLocation(review);\n    if (!mounted) return;\n    final updated = widget.controller.snapshot.records[live.id];\n    if (updated != null && !updated.archived) _remember(updated);\n    setState(\n      () => _reply = receive\n          ? '${live.title}: +$quantity units received and location updated to ${review.afterLocationDisplay} in one atomic transaction. Undo is available.'\n          : '${live.title}: stock corrected to ${review.afterQuantity} units and location updated to ${review.afterLocationDisplay} in one atomic transaction. Sales history was not changed; Undo is available.',\n    );\n  }\n\n""",
)

replace_once(
    "lib/state/pharmacy_controller.dart",
    "import '../domain/backup.dart';\n",
    "import '../domain/backup.dart';\nimport '../domain/brain_operations.dart';\n",
)

insert_before_once(
    "lib/state/pharmacy_controller.dart",
    "class BulkArchiveReview {\n",
    """class ReviewedStockAdjustmentAndLocation {\n  const ReviewedStockAdjustmentAndLocation({\n    required this.baseRevision,\n    required this.stockId,\n    required this.recordRevision,\n    required this.kind,\n    required this.requestedQuantity,\n    required this.beforeQuantity,\n    required this.afterQuantity,\n    required this.wasSold,\n    required this.locationPatch,\n    required this.beforeBlock,\n    required this.beforeRow,\n    required this.beforeVertical,\n    required this.beforeLocation,\n    required this.afterBlock,\n    required this.afterRow,\n    required this.afterVertical,\n    required this.afterLocation,\n  });\n\n  final int baseRevision;\n  final String stockId;\n  final int recordRevision;\n  final StockAdjustmentKind kind;\n  final int requestedQuantity;\n  final int? beforeQuantity;\n  final int afterQuantity;\n  final bool wasSold;\n  final StockLocationPatch locationPatch;\n  final String beforeBlock;\n  final String beforeRow;\n  final String beforeVertical;\n  final String beforeLocation;\n  final String afterBlock;\n  final String afterRow;\n  final String afterVertical;\n  final String afterLocation;\n\n  bool get changesQuantity => beforeQuantity != afterQuantity;\n  bool get changesLocation =>\n      beforeBlock != afterBlock ||\n      beforeRow != afterRow ||\n      beforeVertical != afterVertical ||\n      beforeLocation != afterLocation;\n\n  String get beforeLocationDisplay => _stockLocationDisplay(\n    beforeBlock,\n    beforeRow,\n    beforeVertical,\n    beforeLocation,\n  );\n  String get afterLocationDisplay => _stockLocationDisplay(\n    afterBlock,\n    afterRow,\n    afterVertical,\n    afterLocation,\n  );\n}\n\nString _stockLocationDisplay(\n  String block,\n  String row,\n  String vertical,\n  String location,\n) {\n  final parts = <String>[\n    if (block.isNotEmpty) 'Block $block',\n    if (row.isNotEmpty) 'Row $row',\n    if (vertical.isNotEmpty) 'Vertical $vertical',\n    if (location.isNotEmpty) location,\n  ];\n  return parts.isEmpty ? 'No location recorded' : parts.join(' · ');\n}\n\n""",
)

insert_before_once(
    "lib/state/pharmacy_controller.dart",
    "  Future<void> recordSale(\n",
    """  ReviewedStockAdjustmentAndLocation reviewStockAdjustmentAndLocation(\n    String id, {\n    required StockAdjustmentKind kind,\n    required int quantity,\n    required StockLocationPatch locationPatch,\n  }) {\n    final medicine = snapshot.records[id];\n    if (medicine == null || medicine.archived) {\n      throw StateError(\n        'Choose an active stock entry before changing stock and location.',\n      );\n    }\n    if (medicine.sold && kind != StockAdjustmentKind.receive) {\n      throw StateError(\n        'This entry is SOLD. Receive stock before assigning an active physical-stock location.',\n      );\n    }\n\n    final adjustment = reviewStockAdjustment(\n      id,\n      kind: kind,\n      quantity: quantity,\n    );\n    final patch = sanitizeStockLocationPatch(locationPatch);\n    return ReviewedStockAdjustmentAndLocation(\n      baseRevision: snapshot.revision,\n      stockId: medicine.id,\n      recordRevision: medicine.revision,\n      kind: adjustment.kind,\n      requestedQuantity: adjustment.requestedQuantity,\n      beforeQuantity: adjustment.beforeQuantity,\n      afterQuantity: adjustment.afterQuantity,\n      wasSold: adjustment.wasSold,\n      locationPatch: patch,\n      beforeBlock: medicine.block,\n      beforeRow: medicine.row,\n      beforeVertical: medicine.vertical,\n      beforeLocation: medicine.location,\n      afterBlock: patch.block ?? medicine.block,\n      afterRow: patch.row ?? medicine.row,\n      afterVertical: patch.vertical ?? medicine.vertical,\n      afterLocation: patch.location ?? medicine.location,\n    );\n  }\n\n  Future<void> applyStockAdjustmentAndLocation(\n    ReviewedStockAdjustmentAndLocation review,\n  ) async {\n    final live = snapshot.records[review.stockId];\n    if (live == null ||\n        live.archived ||\n        live.revision != review.recordRevision) {\n      throw StateError(\n        'The reviewed stock entry changed or is no longer active. Review the combined action again.',\n      );\n    }\n\n    final fresh = reviewStockAdjustmentAndLocation(\n      live.id,\n      kind: review.kind,\n      quantity: review.requestedQuantity,\n      locationPatch: review.locationPatch,\n    );\n    if (fresh.beforeQuantity != review.beforeQuantity ||\n        fresh.afterQuantity != review.afterQuantity ||\n        fresh.wasSold != review.wasSold ||\n        fresh.beforeBlock != review.beforeBlock ||\n        fresh.beforeRow != review.beforeRow ||\n        fresh.beforeVertical != review.beforeVertical ||\n        fresh.beforeLocation != review.beforeLocation ||\n        fresh.afterBlock != review.afterBlock ||\n        fresh.afterRow != review.afterRow ||\n        fresh.afterVertical != review.afterVertical ||\n        fresh.afterLocation != review.afterLocation) {\n      throw StateError(\n        'Stock or location facts changed after review. Nothing was saved; review both changes again.',\n      );\n    }\n    if (!fresh.changesQuantity && !fresh.changesLocation) return;\n\n    final changes = <String, dynamic>{\n      'quantity': fresh.afterQuantity,\n      'block': fresh.afterBlock,\n      'row': fresh.afterRow,\n      'vertical': fresh.afterVertical,\n      'location': fresh.afterLocation,\n    };\n    if (fresh.kind == StockAdjustmentKind.receive && live.sold) {\n      changes.addAll({\n        'sold': false,\n        'soldAt': null,\n        'soldQuantity': null,\n        'soldUnitPricePaise': null,\n      });\n    }\n    final quantityLabel = fresh.kind == StockAdjustmentKind.receive\n        ? '+${fresh.requestedQuantity} units (${fresh.beforeQuantity}→${fresh.afterQuantity})'\n        : '${fresh.beforeQuantity == null ? 'unknown' : fresh.beforeQuantity}→${fresh.afterQuantity} units';\n    await _commit(\n      InventoryMutation(\n        expectedRevision: fresh.baseRevision,\n        label:\n            'Stock + location · ${live.name} · $quantityLabel · ${fresh.afterLocationDisplay}',\n        upserts: [live.patch(changes)],\n      ),\n    );\n  }\n\n""",
)

# Resolve all analyzer-reported BuildContext lifetime warnings in scanner intake.
for old, new in (
    ("if (units == null || !mounted) return;", "if (units == null || !context.mounted) return;"),
    ("if (confirmed != true || !mounted) return;", "if (confirmed != true || !context.mounted) return;"),
    ("      if (!mounted) return;\n      ScaffoldMessenger.of(context).showSnackBar(", "      if (!context.mounted) return;\n      ScaffoldMessenger.of(context).showSnackBar("),
    ("      if (mounted) showError(context, error);", "      if (context.mounted) showError(context, error);"),
):
    replace_once("lib/ui/import_screen.dart", old, new)

# Modernize persistent CI to the runner-supported Node 24 action generation and
# make analyzer information diagnostics fail the build instead of accumulating.
for workflow in (
    ".github/workflows/flutter.yml",
    ".github/workflows/release-apk.yml",
):
    replace_once(workflow, "uses: actions/checkout@v4", "uses: actions/checkout@v5")
    replace_once(workflow, "uses: actions/setup-java@v4", "uses: actions/setup-java@v5")
    replace_once(
        workflow,
        "run: dart analyze lib test tool third_party/lib_llama_cpp/lib",
        "run: dart analyze --fatal-infos lib test tool third_party/lib_llama_cpp/lib",
    )

print("Surgical diff cleanup, lifecycle hardening and CI gate upgrade applied.")
