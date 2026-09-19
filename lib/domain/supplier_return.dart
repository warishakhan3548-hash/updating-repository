import 'medicine.dart';
import 'supplier.dart';

class SupplierReturnLine {
  const SupplierReturnLine({
    required this.record,
    required this.quantity,
    required this.daysLeft,
  });

  final Medicine record;
  final int quantity;
  final int daysLeft;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'stockId': record.id,
    'name': record.name,
    'strength': record.strength,
    'form': record.form,
    'manufacturer': record.manufacturer,
    'batchNumber': record.batchNumber,
    'expiry': record.expiry == null ? null : dateText(record.expiry!),
    'quantity': quantity,
    'location': record.address,
    'unitPricePaise': record.unitPricePaise,
    'daysLeft': daysLeft,
  };
}

class ReviewedSupplierReturn {
  const ReviewedSupplierReturn({
    required this.baseRevision,
    required this.supplier,
    required this.lines,
    required this.reviewedAt,
  });

  final int baseRevision;
  final Supplier supplier;
  final List<SupplierReturnLine> lines;
  final DateTime reviewedAt;

  int get totalUnits =>
      lines.fold<int>(0, (total, line) => total + line.quantity);
}
