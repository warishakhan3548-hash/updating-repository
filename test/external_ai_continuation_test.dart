import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import '../lib/domain/ai_protocol.dart';
import '../lib/domain/medicine.dart';

void main() {
  final now = DateTime(2026, 9, 17, 12, 0);

  Medicine stock({
    required String id,
    String name = 'Paracetamol',
    String strength = '500mg',
    String location = 'Rack A',
    int revision = 1,
  }) => Medicine.fromJson({
    'id': id,
    'name': name,
    'strength': strength,
    'form': 'Tablet',
    'location': location,
    'quantity': 10,
    'revision': revision,
  });

  String envelope({
    required String requestId,
    String? changeId,
    required int baseRevision,
    required List<Map<String, dynamic>> actions,
  }) => jsonEncode({
    'schema': pharmacySchema,
    'requestId': requestId,
    if (changeId != null) 'changeId': changeId,
    'baseRevision': baseRevision,
    'reply': 'Prepared for review',
    'actions': actions,
  });

  test('same external session can rebase many distinct changes onto live stock', () {
    const session = 'session_12345';
    final live = stock(id: 'existing', revision: 4);
    final first = parseAiPlan(
      envelope(
        requestId: session,
        changeId: 'change_0001',
        baseRevision: 2,
        actions: [
          {
            'op': 'update',
            'id': 'existing',
            'fields': {'location': 'Rack B'},
          },
        ],
      ),
      {'existing': live},
      7,
      const {},
      now,
    );

    expect(first.baseRevision, 7);
    expect(first.requestId, '$session:change_0001');
    expect(first.changes.single.before!.location, 'Rack A');
    expect(first.changes.single.after.location, 'Rack B');

    final afterFirst = first.changes.single.after;
    final second = parseAiPlan(
      envelope(
        requestId: session,
        changeId: 'change_0002',
        baseRevision: 2,
        actions: [
          {
            'op': 'update',
            'id': 'existing',
            'fields': {'expiry': '2028-03'},
          },
        ],
      ),
      {'existing': afterFirst},
      8,
      {first.requestId},
      now,
    );

    expect(second.baseRevision, 8);
    expect(second.requestId, '$session:change_0002');
    expect(second.changes.single.before!.location, 'Rack B');
    expect(dateText(second.changes.single.after.expiry!), '2028-03-31');
  });

  test('reusing the same changeId is blocked as an exact replay', () {
    const session = 'session_12345';
    final live = stock(id: 'existing');
    final raw = envelope(
      requestId: session,
      changeId: 'change_0001',
      baseRevision: 1,
      actions: [
        {
          'op': 'update',
          'id': 'existing',
          'fields': {'location': 'Rack B'},
        },
      ],
    );
    final reviewed = parseAiPlan(raw, {'existing': live}, 1, const {}, now);

    expect(
      () => parseAiPlan(raw, {'existing': live}, 2, {reviewed.requestId}, now),
      throwsFormatException,
    );
  });

  test('session add ID can be reused for later update and removal', () {
    const session = 'session_12345';
    const addedId = 'ai_session_12345_cefixime200';
    final add = parseAiPlan(
      envelope(
        requestId: session,
        changeId: 'change_add1',
        baseRevision: 5,
        actions: [
          {
            'op': 'add',
            'id': addedId,
            'fields': {
              'name': 'Cefixime',
              'strength': '200mg',
              'form': 'Tablet',
              'quantity': 10,
            },
          },
        ],
      ),
      const {},
      5,
      const {},
      now,
    );

    expect(add.changes.single.after.id, addedId);
    final added = add.changes.single.after;

    final update = parseAiPlan(
      envelope(
        requestId: session,
        changeId: 'change_exp1',
        baseRevision: 5,
        actions: [
          {
            'op': 'update',
            'id': addedId,
            'fields': {'expiry': '2028-06'},
          },
        ],
      ),
      {addedId: added},
      6,
      {add.requestId},
      now,
    );

    expect(update.changes.single.before!.id, addedId);
    expect(dateText(update.changes.single.after.expiry!), '2028-06-30');

    final updated = update.changes.single.after;
    final remove = parseAiPlan(
      envelope(
        requestId: session,
        changeId: 'change_del1',
        baseRevision: 5,
        actions: [
          {'op': 'remove', 'id': addedId},
        ],
      ),
      {addedId: updated},
      7,
      {add.requestId, update.requestId},
      now,
    );

    expect(remove.changes.single.after.archived, isTrue);
  });

  test('legacy JSON without changeId still allows distinct turns but blocks replay', () {
    const session = 'session_legacy1';
    final live = stock(id: 'existing');
    final firstRaw = envelope(
      requestId: session,
      baseRevision: 3,
      actions: [
        {
          'op': 'update',
          'id': 'existing',
          'fields': {'location': 'Rack B'},
        },
      ],
    );
    final first = parseAiPlan(firstRaw, {'existing': live}, 3, const {}, now);
    final afterFirst = first.changes.single.after;

    final secondRaw = envelope(
      requestId: session,
      baseRevision: 3,
      actions: [
        {
          'op': 'update',
          'id': 'existing',
          'fields': {'notes': 'Owner verified'},
        },
      ],
    );
    final second = parseAiPlan(
      secondRaw,
      {'existing': afterFirst},
      4,
      {first.requestId},
      now,
    );

    expect(second.requestId, isNot(first.requestId));
    expect(second.changes.single.after.notes, 'Owner verified');
    expect(
      () => parseAiPlan(
        firstRaw,
        {'existing': afterFirst},
        4,
        {first.requestId},
        now,
      ),
      throwsFormatException,
    );
  });
}
