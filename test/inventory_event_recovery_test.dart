import 'dart:convert';

import 'package:aaris_pharmacy/data/inventory_database.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, Object?> _row({
  String detail = '',
  String id = 'event-1',
  int revision = 7,
  int soldValue = 0,
  int unknownSold = 0,
  int undone = 0,
}) => <String, Object?>{
  'id': id,
  'revision': revision,
  'detail': detail,
  'sold_value': soldValue,
  'unknown_sold': unknownSold,
  'undone': undone,
};

Map<String, dynamic> _detail({
  String id = 'event-1',
  int revision = 7,
  bool undoable = true,
  Object? before = const <String, dynamic>{},
  Object? supplierBefore = const <String, dynamic>{},
  Object? settingsBefore = const <String, dynamic>{
    'shortDays': 5,
    'months': 2,
  },
  Object? salesBefore = const <String, dynamic>{},
}) => <String, dynamic>{
  'id': id,
  'revision': revision,
  'label': 'Edited Dolo',
  'time': '2026-09-12T12:00:00.000Z',
  'undoable': undoable,
  'undone': false,
  'before': before,
  'supplierBefore': supplierBefore,
  'salesBefore': salesBefore,
  'settingsBefore': settingsBefore,
  // Deliberately different from SQL columns: the read boundary must trust the
  // normalized table columns for aggregate/undo state, not duplicated JSON.
  'soldValue': 999,
  'unknownSold': 9,
};

void main() {
  test('valid audit row is normalized from SQL witnesses', () {
    final event = decodeStoredInventoryEvent(
      _row(
        detail: jsonEncode(_detail()),
        soldValue: 2500,
        unknownSold: 1,
        undone: 1,
      ),
    );

    expect(event, isNotNull);
    expect(event!['revision'], 7);
    expect(event['soldValue'], 2500);
    expect(event['unknownSold'], 1);
    expect(event['undone'], isTrue);
    expect(event['undoable'], isTrue);
  });

  test('missing supplier before-image disables Undo without dropping history', () {
    final detail = _detail()..remove('supplierBefore');
    final event = decodeStoredInventoryEvent(
      _row(detail: jsonEncode(detail)),
    );

    expect(event, isNotNull);
    expect(event!['undoable'], isFalse);
    expect(event['supplierBefore'], isA<Map<String, dynamic>>());
    expect((event['supplierBefore'] as Map), isEmpty);
  });

  test('malformed sales before-image disables Undo without dropping history', () {
    final event = decodeStoredInventoryEvent(
      _row(detail: jsonEncode(_detail(salesBefore: 'corrupt'))),
    );

    expect(event, isNotNull);
    expect(event!['undoable'], isFalse);
    expect(event['salesBefore'], isA<Map<String, dynamic>>());
    expect((event['salesBefore'] as Map), isEmpty);
  });

  test('malformed non-authoritative event JSON is skipped', () {
    expect(
      decodeStoredInventoryEvent(_row(detail: '{not-json')),
      isNull,
    );
  });

  test('detail cannot impersonate a different SQL event revision', () {
    expect(
      decodeStoredInventoryEvent(
        _row(detail: jsonEncode(_detail(revision: 8))),
      ),
      isNull,
    );
  });

  test('broken undo payload stays visible but loses Undo authority', () {
    final event = decodeStoredInventoryEvent(
      _row(
        detail: jsonEncode(
          _detail(before: 'corrupt', settingsBefore: null, salesBefore: 'bad'),
        ),
      ),
    );

    expect(event, isNotNull);
    expect(event!['undoable'], isFalse);
    expect(event['before'], isA<Map<String, dynamic>>());
    expect((event['before'] as Map), isEmpty);
    expect(event['salesBefore'], isA<Map<String, dynamic>>());
    expect((event['salesBefore'] as Map), isEmpty);
  });
}
