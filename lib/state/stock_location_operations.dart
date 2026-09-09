import '../domain/brain_operations.dart';
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
      beforeBlock != afterBlock ||
      beforeRow != afterRow ||
      beforeVertical != afterVertical ||
      beforeLocation != afterLocation;

  String get beforeDisplay =>
      _displayLocation(beforeBlock, beforeRow, beforeVertical, beforeLocation);
  String get afterDisplay =>
      _displayLocation(afterBlock, afterRow, afterVertical, afterLocation);
}

extension PharmacyStockLocationOperations on PharmacyController {
  ReviewedStockLocationUpdate reviewStockLocationUpdate(
    String id,
    StockLocationPatch requested,
  ) {
    final medicine = snapshot.records[id];
    if (medicine == null || medicine.archived) {
      throw StateError(
        'Choose an active stock entry before changing location.',
      );
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

  Future<void> applyStockLocationUpdate(
    ReviewedStockLocationUpdate review,
  ) async {
    if (review.baseRevision != snapshot.revision) {
      throw StateError(
        'Inventory changed after the location review. Review this move again before saving.',
      );
    }
    final live = snapshot.records[review.stockId];
    if (live == null ||
        live.archived ||
        live.sold ||
        live.revision != review.recordRevision) {
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

String _displayLocation(
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
