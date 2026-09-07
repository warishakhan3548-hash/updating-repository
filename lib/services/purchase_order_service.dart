import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../domain/medicine.dart';

class PurchaseOrderLine {
  const PurchaseOrderLine({
    required this.name,
    required this.salt,
    required this.strength,
    required this.reason,
    required this.quantity,
    this.currentQuantity,
    this.unitCostPaise,
  });

  final String name;
  final String salt;
  final String strength;
  final String reason;
  final int quantity;
  final int? currentQuantity;
  final int? unitCostPaise;

  int? get estimatedAmountPaise =>
      unitCostPaise == null ? null : stockValue(quantity, unitCostPaise!);

  Map<String, dynamic> toJson() => {
    'name': name,
    'salt': salt,
    'strength': strength,
    'reason': reason,
    'quantity': quantity,
    'currentQuantity': currentQuantity,
    'unitCostPaise': unitCostPaise,
    'estimatedAmountPaise': estimatedAmountPaise,
  };
}

class PurchaseOrderService {
  static const _channel = MethodChannel('com.aaris.pharmacy/documents');

  Future<void> share({
    required List<PurchaseOrderLine> lines,
    required DateTime date,
  }) async {
    if (lines.isEmpty) {
      throw const FormatException('Select at least one medicine to order.');
    }
    final payload = {
      'title': 'Aaris Pharmacy Purchase Order',
      'date': dateText(date),
      'lines': lines.map((line) => line.toJson()).toList(),
    };
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      final path = await _channel.invokeMethod<String>(
        'createPurchaseOrderPdf',
        payload,
      );
      if (path == null || path.isEmpty) {
        throw StateError('The purchase-order PDF could not be created.');
      }
      await SharePlus.instance.share(
        ShareParams(
          title: 'Aaris Pharmacy purchase order',
          text: 'Purchase order dated ${dateText(date)}',
          files: [XFile(path, mimeType: 'application/pdf')],
        ),
      );
      return;
    }

    // A readable fallback keeps web/desktop usable without claiming a PDF.
    final text = const JsonEncoder.withIndent('  ').convert(payload);
    await SharePlus.instance.share(
      ShareParams(title: 'Aaris Pharmacy purchase order', text: text),
    );
  }
}
