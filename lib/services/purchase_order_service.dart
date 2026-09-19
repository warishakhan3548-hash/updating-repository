import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../domain/medicine.dart';
import '../domain/purchase_order.dart';

export '../domain/purchase_order.dart' show PurchaseOrderLine;

class PurchaseOrderService {
  static const _channel = MethodChannel('com.aaris.pharmacy/documents');

  Future<void> share({
    required List<PurchaseOrderLine> lines,
    required DateTime date,
  }) async {
    if (date.year < 2000 || date.year > 2200) {
      throw const FormatException('Purchase-order date is outside the safe range.');
    }

    // Validate at the service boundary as well as in the UI. This keeps native
    // PDF/share integration from receiving duplicate, malformed or overflowing
    // order facts if a future caller bypasses the current Order Review screen.
    final reviewed = validatePurchaseOrderDraft(lines);
    final payload = {
      'title': 'Aaris Pharmacy Purchase Order',
      'date': dateText(date),
      'lines': reviewed.map((line) => line.toJson()).toList(growable: false),
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
