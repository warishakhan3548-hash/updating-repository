from pathlib import Path


def replace_once(path: str, old: str, new: str) -> None:
    target = Path(path)
    text = target.read_text()
    count = text.count(old)
    if count != 1:
        raise SystemExit(f'{path}: expected exactly one guarded match, found {count}')
    target.write_text(text.replace(old, new, 1))


replace_once(
    'lib/domain/local_ai_protocol.dart',
    '''Allowed proposals: {"op":"add","fields":{"name":"..."}}, {"op":"update","id":"retrieved ID","fields":{"quantity":25}}, {"op":"remove","id":"retrieved ID"}, {"op":"mark_sold","id":"retrieved ID"}, {"op":"restock","id":"retrieved ID","fields":{"quantity":25}}, {"op":"restore","id":"retrieved archived ID"}.\nEditable fields: name, brand, salt, strength, form, manufacturer, mfg, expiry, batchNumber, barcode, quantity, unitPricePaise, location, notes. Dates YYYY-MM-DD or printed month YYYY-MM. Expiry month includes its last day. Do not invent dates, quantities or costs. Printed MRP is NOT inventory cost; pack size is NOT stock quantity. Never equate unknown quantity with zero. Never combine stock quantities of different strengths/forms or stock units.\n''',
    '''Allowed proposals: {"op":"add","fields":{"name":"..."}}, {"op":"update","id":"retrieved ID","fields":{"expiry":"2028-07"}}, {"op":"set_quantity","id":"retrieved ID","fields":{"quantity":25}}, {"op":"receive_stock","id":"retrieved ID","fields":{"quantity":12}}, {"op":"remove","id":"retrieved ID"}, {"op":"mark_sold","id":"retrieved ID"}, {"op":"restock","id":"retrieved ID","fields":{"quantity":25}}, {"op":"restore","id":"retrieved archived ID"}.\nEditable fact fields: name, brand, salt, strength, form, manufacturer, mfg, expiry, batchNumber, barcode, unitPricePaise, location, notes. Generic update MUST NOT change quantity. set_quantity means the exact counted quantity after a physical count. receive_stock means a positive number of newly received units to add to a known current quantity. If the current quantity is unknown, ask for a physical count and use set_quantity. Do not receive into expired stock; a SOLD row must be reopened with restock. Dates YYYY-MM-DD or printed month YYYY-MM. Expiry month includes its last day. Do not invent dates, quantities or costs. Printed MRP is NOT inventory cost; pack size is NOT stock quantity. Never equate unknown quantity with zero. Never combine stock quantities of different strengths/forms or stock units.\n''',
)

replace_once(
    'tool/check_local_ai.dart',
    '''        'op': 'update',\n        'id': id,\n        'fields': {'quantity': 25},\n''',
    '''        'op': 'set_quantity',\n        'id': id,\n        'fields': {'quantity': 25},\n''',
)

replace_once(
    'test/ai_stock_intent_firewall_test.dart',
    """import 'package:aaris_pharmacy/domain/ai_protocol.dart';\n""",
    """import 'package:aaris_pharmacy/domain/ai_protocol.dart';\nimport 'package:aaris_pharmacy/domain/local_ai_protocol.dart';\n""",
)

replace_once(
    'test/ai_stock_intent_firewall_test.dart',
    """    test('AI export teaches explicit quantity semantics without inference', () {\n""",
    """    test('offline AI uses the same explicit reviewed stock language', () {\n      final record = stock('stock-1');\n      final context = LocalInventoryContext(\n        records: [record],\n        sales: const [],\n        revision: 7,\n        today: DateTime(2026, 9, 10),\n      );\n\n      expect(context.instructions, contains('\\\"op\\\":\\\"set_quantity\\\"'));\n      expect(context.instructions, contains('\\\"op\\\":\\\"receive_stock\\\"'));\n      expect(\n        context.instructions,\n        contains('Generic update MUST NOT change quantity'),\n      );\n\n      final row = context.read({'tool': 'search', 'query': 'Dolo'});\n      final id = ((row['rows'] as List).single as Map)['id'];\n      final response = context.finish({\n        'reply': 'Review counted stock',\n        'actions': [\n          {\n            'op': 'set_quantity',\n            'id': id,\n            'fields': {'quantity': 7},\n          },\n        ],\n      });\n      final plan = parseAiPlan(\n        response,\n        {record.id: record},\n        7,\n        const {},\n        DateTime(2026, 9, 10),\n      );\n      expect(plan.changes.single.operation, 'set_quantity');\n      expect(plan.changes.single.after.quantity, 7);\n    });\n\n    test('AI export teaches explicit quantity semantics without inference', () {\n""",
)
