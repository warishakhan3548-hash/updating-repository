import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../domain/medicine.dart';
import '../domain/supplier_return.dart';

class SupplierReturnService {
  static const _channel = MethodChannel('com.aaris.pharmacy/documents');

  @visibleForTesting
  static bool shouldOfferHandoverConfirmation(ShareResultStatus status) =>
      status != ShareResultStatus.dismissed;

  Future<bool> share(ReviewedSupplierReturn review) async {
    if (review.lines.isEmpty || review.lines.length > 500) {
      throw const FormatException(
        'Choose between 1 and 500 reviewed stock entries.',
      );
    }
    final payload = <String, dynamic>{
      'title': 'Aaris Pharmacy Supplier Return List',
      'date': dateText(review.reviewedAt),
      'supplier': review.supplier.toJson(),
      'lines': review.lines.map((line) => line.toJson()).toList(growable: false),
    };

    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      final path = await _channel.invokeMethod<String>(
        'createSupplierReturnPdf',
        payload,
      );
      if (path == null || path.isEmpty) {
        throw StateError('The supplier return PDF could not be created.');
      }
      final result = await SharePlus.instance.share(
        ShareParams(
          title: 'Aaris Pharmacy supplier return',
          text:
              '${review.supplier.name} · ${review.lines.length} stock entries · ${dateText(review.reviewedAt)}',
          files: <XFile>[XFile(path, mimeType: 'application/pdf')],
        ),
      );
      return shouldOfferHandoverConfirmation(result.status);
    }

    final result = await SharePlus.instance.share(
      ShareParams(
        title: 'Aaris Pharmacy supplier return',
        text: const JsonEncoder.withIndent('  ').convert(payload),
      ),
    );
    return shouldOfferHandoverConfirmation(result.status);
  }
}
