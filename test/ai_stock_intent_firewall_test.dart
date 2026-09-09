import 'dart:convert';

import 'package:aaris_pharmacy/domain/ai_protocol.dart';
import 'package:aaris_pharmacy/domain/local_ai_protocol.dart';
import 'package:aaris_pharmacy/domain/medicine.dart';
import 'package:flutter_test/flutter_test.dart';

Medicine stock(
  String id, {
  int? quantity = 10,
  bool sold = false,
  String expiry = '2027-12',
}) => Medicine.fromJson({
  'id': id,
  'name': 'Dolo',
  'strength': '650mg',
  'form': 'Tablet',
  'quantity': sold ? 0 : quantity,
  'expiry': expiry,
  'sold': sold,
  'soldAt': sold ? '2026-09-09T10:00:00.000Z' : null,
  'soldQuantity': sold ? 10 : null,
});

String envelope(Map<String, dynamic> action) => jsonEncode({
  'schema': pharmacySchema,
  'requestId': 'request_stock_firewall',
  'baseRevision': 7,
  'actions': [action],
});

AiPlan parse(Map<String, dynamic> action, {Medicine? record, DateTime? now}) =>
    parseAiPlan(
      envelope(action),
      {'stock-1': record ?? stock('stock-1')},
      7,
      const {},
      now ?? DateTime(2026, 9, 10, 12),
    );

void main() {
  group('AI stock-intent firewall', () {
    test('generic update cannot silently change stock quantity', () {
      expect(
        () => parse({
          'op': 'update',
          'id': 'stock-1',
          'fields': {'quantity': 20},
        }),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('Generic update cannot change stock quantity'),
          ),
        ),
      );
    });

    test('receive_stock is an explicit positive delta over known stock', () {
      final change = parse({
        'op': 'receive_stock',
        'id': 'stock-1',
        'fields': {'quantity': 12},
      }).changes.single;

      expect(change.operation, 'receive_stock');
      expect(change.before!.quantity, 10);
      expect(change.after.quantity, 22);
      expect(change.after.sold, isFalse);
      expect(change.after.id, 'stock-1');
    });

    test('set_quantity is an exact physical-count correction, not SOLD', () {
      final change = parse({
        'op': 'set_quantity',
        'id': 'stock-1',
        'fields': {'quantity': 0},
      }).changes.single;

      expect(change.operation, 'set_quantity');
      expect(change.after.quantity, 0);
      expect(change.after.sold, isFalse);
      expect(change.after.soldAt, isNull);
    });

    test(
      'receive_stock fails closed for unknown, expired and SOLD baselines',
      () {
        for (final record in [
          stock('stock-1', quantity: null),
          stock('stock-1', expiry: '2026-09-09'),
          stock('stock-1', sold: true),
        ]) {
          expect(
            () => parse({
              'op': 'receive_stock',
              'id': 'stock-1',
              'fields': {'quantity': 3},
            }, record: record),
            throwsFormatException,
          );
        }
      },
    );

    test('stock operations reject mixed fields and impossible totals', () {
      expect(
        () => parse({
          'op': 'set_quantity',
          'id': 'stock-1',
          'fields': {'quantity': 5, 'expiry': '2028-01'},
        }),
        throwsFormatException,
      );
      expect(
        () => parse({
          'op': 'receive_stock',
          'id': 'stock-1',
          'fields': {'quantity': 1},
        }, record: stock('stock-1', quantity: 100000000)),
        throwsFormatException,
      );
    });

    test('offline AI uses the same explicit reviewed stock language', () {
      final record = stock('stock-1');
      final context = LocalInventoryContext(
        records: [record],
        sales: const [],
        revision: 7,
        today: DateTime(2026, 9, 10),
      );

      expect(context.instructions, contains('\"op\":\"set_quantity\"'));
      expect(context.instructions, contains('\"op\":\"receive_stock\"'));
      expect(
        context.instructions,
        contains('Generic update MUST NOT change quantity'),
      );

      final row = context.read({'tool': 'search', 'query': 'Dolo'});
      final id = ((row['rows'] as List).single as Map)['id'];
      final response = context.finish({
        'reply': 'Review counted stock',
        'actions': [
          {
            'op': 'set_quantity',
            'id': id,
            'fields': {'quantity': 7},
          },
        ],
      });
      final plan = parseAiPlan(
        response,
        {record.id: record},
        7,
        const {},
        DateTime(2026, 9, 10),
      );
      expect(plan.changes.single.operation, 'set_quantity');
      expect(plan.changes.single.after.quantity, 7);
    });

    test('AI export teaches explicit quantity semantics without inference', () {
      final export = PharmacyExport(
        revision: 7,
        records: [stock('stock-1')],
        today: DateTime(2026, 9, 10),
      );

      expect(export.prompt, contains('"op":"set_quantity"'));
      expect(export.prompt, contains('"op":"receive_stock"'));
      expect(
        export.prompt,
        contains('Generic update MUST NOT change quantity'),
      );
      expect(export.prompt, contains('Never infer quantities or costs'));
    });
  });
}
