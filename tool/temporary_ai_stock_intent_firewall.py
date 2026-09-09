from pathlib import Path


def replace_once(path: str, old: str, new: str) -> None:
    target = Path(path)
    text = target.read_text()
    count = text.count(old)
    if count != 1:
        raise SystemExit(f'{path}: expected exactly one guarded match, found {count}')
    target.write_text(text.replace(old, new, 1))


replace_once(
    'lib/domain/ai_protocol.dart',
    '''{"op":"update","id":"EXACT_EXISTING_ID","fields":{"expiry":"2027-02-28"}}\n{"op":"mark_sold","id":"EXACT_EXISTING_ID"}\n{"op":"restock","id":"EXACT_EXISTING_ID","fields":{"quantity":20,"expiry":"2028-01"}}\n{"op":"remove","id":"EXACT_EXISTING_ID"}\nAll editable fields: name, brand, manufacturer, salt, strength, form, mfg, expiry, quantity, unitPricePaise, barcode, batchNumber, block, row, vertical, location, notes, ocrText.\n''',
    '''{"op":"update","id":"EXACT_EXISTING_ID","fields":{"expiry":"2027-02-28"}}\n{"op":"set_quantity","id":"EXACT_EXISTING_ID","fields":{"quantity":18}}\n{"op":"receive_stock","id":"EXACT_EXISTING_ID","fields":{"quantity":12}}\n{"op":"mark_sold","id":"EXACT_EXISTING_ID"}\n{"op":"restock","id":"EXACT_EXISTING_ID","fields":{"quantity":20,"expiry":"2028-01"}}\n{"op":"remove","id":"EXACT_EXISTING_ID"}\nEditable fact fields: name, brand, manufacturer, salt, strength, form, mfg, expiry, unitPricePaise, barcode, batchNumber, block, row, vertical, location, notes, ocrText. Generic update MUST NOT change quantity. Use set_quantity for an exact physical-count correction and receive_stock for a positive newly-received quantity delta. Quantity remains allowed when adding new stock or restocking a SOLD entry.\n''',
)

replace_once(
    'lib/domain/ai_protocol.dart',
    '''Never infer quantities or costs.\nAggregate sales contain medicine movement only''',
    '''Never infer quantities or costs. For receive_stock, fields.quantity is the positive number of units newly received and is added to the known current quantity. For set_quantity, fields.quantity is the exact counted quantity after correction and may be zero without implying SOLD. If current quantity is unknown, do not use receive_stock; request a physical count and use set_quantity. Do not receive into expired stock.\nAggregate sales contain medicine movement only''',
)

replace_once(
    'lib/domain/ai_protocol.dart',
    '''        'mark_sold',\n        'restock',\n        'restore',\n''',
    '''        'mark_sold',\n        'set_quantity',\n        'receive_stock',\n        'restock',\n        'restore',\n''',
)

replace_once(
    'lib/domain/ai_protocol.dart',
    '''        if ((op == 'remove' || op == 'mark_sold' || op == 'restore') &&\n            fields.isNotEmpty) {\n''',
    '''        if ((op == 'remove' || op == 'mark_sold' || op == 'restore') &&\n            fields.isNotEmpty) {\n''',
)

replace_once(
    'lib/domain/ai_protocol.dart',
    '''        if (op == 'mark_sold') {\n          if (before.sold)\n            throw const FormatException('This entry is already sold.');\n          if (isExpiredOn(before, now))\n            throw const FormatException(\n              'Expired stock cannot be marked sold. Remove it as expired instead.',\n            );\n          after = before.patch({\n            'sold': true,\n            'quantity': 0,\n            'soldAt': now.toIso8601String(),\n            'soldQuantity': before.quantity,\n            'soldUnitPricePaise': before.unitPricePaise,\n          });\n        } else if (op == 'remove') {\n''',
    '''        if (op == 'mark_sold') {\n          if (before.sold)\n            throw const FormatException('This entry is already sold.');\n          if (isExpiredOn(before, now))\n            throw const FormatException(\n              'Expired stock cannot be marked sold. Remove it as expired instead.',\n            );\n          after = before.patch({\n            'sold': true,\n            'quantity': 0,\n            'soldAt': now.toIso8601String(),\n            'soldQuantity': before.quantity,\n            'soldUnitPricePaise': before.unitPricePaise,\n          });\n        } else if (op == 'set_quantity') {\n          if (fields.length != 1 || !fields.containsKey('quantity')) {\n            throw const FormatException(\n              'set_quantity accepts only the exact counted quantity.',\n            );\n          }\n          final quantity = fields['quantity'];\n          if (quantity is! int || quantity < 0 || quantity > 100000000) {\n            throw const FormatException(\n              'set_quantity needs an exact stock count from 0 to 100000000.',\n            );\n          }\n          if (before.sold) {\n            throw const FormatException(\n              'A SOLD entry must be reopened with restock, not set_quantity.',\n            );\n          }\n          if (before.quantity == quantity) {\n            throw const FormatException(\n              'set_quantity must change the current counted quantity.',\n            );\n          }\n          after = before.patch({'quantity': quantity});\n        } else if (op == 'receive_stock') {\n          if (fields.length != 1 || !fields.containsKey('quantity')) {\n            throw const FormatException(\n              'receive_stock accepts only the positive received quantity delta.',\n            );\n          }\n          final received = fields['quantity'];\n          if (received is! int || received <= 0 || received > 100000000) {\n            throw const FormatException(\n              'receive_stock needs a positive received quantity.',\n            );\n          }\n          if (before.sold) {\n            throw const FormatException(\n              'A SOLD entry must be reopened with restock, including a reviewed expiry.',\n            );\n          }\n          if (isExpiredOn(before, now)) {\n            throw const FormatException(\n              'Do not receive new units into an expired stock entry. Add or select the correct active batch.',\n            );\n          }\n          final current = before.quantity;\n          if (current == null) {\n            throw const FormatException(\n              'Current quantity is unknown. Count the stock and use set_quantity first.',\n            );\n          }\n          final target = current + received;\n          if (target > 100000000) {\n            throw const FormatException(\n              'Received quantity exceeds the supported stock limit. Check the stock unit.',\n            );\n          }\n          after = before.patch({'quantity': target});\n        } else if (op == 'remove') {\n''',
)

replace_once(
    'lib/domain/ai_protocol.dart',
    '''        } else {\n          if (fields.isEmpty)\n            throw const FormatException('Update has no changes.');\n          after = before.patch(fields);\n        }\n''',
    '''        } else {\n          if (fields.isEmpty)\n            throw const FormatException('Update has no changes.');\n          if (fields.containsKey('quantity')) {\n            throw const FormatException(\n              'Generic update cannot change stock quantity. Use set_quantity or receive_stock.',\n            );\n          }\n          after = before.patch(fields);\n        }\n''',
)

replace_once(
    'lib/ui/ai_screen.dart',
    '''                !_requiresExplicitLifecycleSelection(plan.changes[i].operation))\n''',
    '''                !_requiresExplicitMutationSelection(plan.changes[i].operation))\n''',
)

replace_once(
    'lib/ui/ai_screen.dart',
    '''    'restock' => _aiPurple,\n    'restore' => green,\n''',
    '''    'set_quantity' => amber,\n    'receive_stock' => green,\n    'restock' => _aiPurple,\n    'restore' => green,\n''',
)

replace_once(
    'lib/ui/ai_screen.dart',
    '''              'Unselected changes stay untouched. Remove, SOLD and Restore actions are never pre-selected.',\n''',
    '''              'Unselected changes stay untouched. Removal, SOLD, restore and stock-quantity operations are never pre-selected.',\n''',
)

replace_once(
    'lib/ui/ai_screen.dart',
    '''bool _requiresExplicitLifecycleSelection(String operation) =>\n    const {'remove', 'mark_sold', 'restore'}.contains(operation);\n''',
    '''bool _requiresExplicitMutationSelection(String operation) => const {\n  'remove',\n  'mark_sold',\n  'restore',\n  'set_quantity',\n  'receive_stock',\n}.contains(operation);\n''',
)

replace_once(
    'lib/ui/ai_screen.dart',
    '''      'mark_sold': 'Mark out of stock · reorder',\n      'restock': 'Restock medicine',\n      'restore': 'Restore removed stock',\n''',
    '''      'mark_sold': 'Mark out of stock · reorder',\n      'set_quantity': 'Set exact counted quantity · review required',\n      'receive_stock': 'Receive stock quantity · review required',\n      'restock': 'Restock medicine',\n      'restore': 'Restore removed stock',\n''',
)

Path('test/ai_stock_intent_firewall_test.dart').write_text(r'''import 'dart:convert';

import 'package:aaris_pharmacy/domain/ai_protocol.dart';
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

AiPlan parse(
  Map<String, dynamic> action, {
  Medicine? record,
  DateTime? now,
}) => parseAiPlan(
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

    test('receive_stock fails closed for unknown, expired and SOLD baselines', () {
      for (final record in [
        stock('stock-1', quantity: null),
        stock('stock-1', expiry: '2026-09-09'),
        stock('stock-1', sold: true),
      ]) {
        expect(
          () => parse(
            {
              'op': 'receive_stock',
              'id': 'stock-1',
              'fields': {'quantity': 3},
            },
            record: record,
          ),
          throwsFormatException,
        );
      }
    });

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
        () => parse(
          {
            'op': 'receive_stock',
            'id': 'stock-1',
            'fields': {'quantity': 1},
          },
          record: stock('stock-1', quantity: 100000000),
        ),
        throwsFormatException,
      );
    });

    test('AI export teaches explicit quantity semantics without inference', () {
      final export = PharmacyExport(
        revision: 7,
        records: [stock('stock-1')],
        today: DateTime(2026, 9, 10),
      );

      expect(export.prompt, contains('"op":"set_quantity"'));
      expect(export.prompt, contains('"op":"receive_stock"'));
      expect(export.prompt, contains('Generic update MUST NOT change quantity'));
      expect(export.prompt, contains('Never infer quantities or costs'));
    });
  });
}
''')
