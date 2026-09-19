import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import '../lib/domain/ai_protocol.dart';
import '../lib/domain/medicine.dart';

void main() {
  final now = DateTime(2026, 9, 17, 14, 0);

  String envelope({
    required String requestId,
    required int baseRevision,
    String? changeId,
    required List<Map<String, dynamic>> actions,
  }) => jsonEncode({
    'schema': pharmacySchema,
    'requestId': requestId,
    if (changeId != null) 'changeId': changeId,
    'baseRevision': baseRevision,
    'reply': 'Prepared for review',
    'actions': actions,
  });

  Medicine stock(
    String id, {
    String name = 'Paracetamol',
    String strength = '500mg',
    String form = 'Tablet',
    String location = '',
  }) => Medicine.fromJson({
    'id': id,
    'name': name,
    'strength': strength,
    'form': form,
    'location': location,
    'quantity': 10,
  });

  test('legacy AI re-add becomes update for the unique item added in this session', () {
    const session = 'session_followup1';
    final first = parseAiPlan(
      envelope(
        requestId: session,
        baseRevision: 3,
        actions: [
          {
            'op': 'add',
            'fields': {'name': 'Paracetamol', 'strength': '500mg'},
          },
        ],
      ),
      const {},
      3,
      const {},
      now,
    );
    final added = first.changes.single.after;
    expect(added.id, startsWith('ai_${session}_'));

    final followUp = parseAiPlan(
      envelope(
        requestId: session,
        baseRevision: 3,
        actions: [
          {
            // A forgetful external model incorrectly says add again. Aaris
            // recovers this as an edit because exactly one same-session item
            // matches the medicine identity.
            'op': 'add',
            'fields': {
              'name': 'Paracetamol',
              'strength': '500mg',
              'expiry': '2026-10-05',
            },
          },
        ],
      ),
      {added.id: added},
      4,
      {first.requestId},
      now,
    );

    expect(followUp.changes.single.operation, 'update');
    expect(followUp.changes.single.before!.id, added.id);
    expect(followUp.changes.single.after.id, added.id);
    expect(dateText(followUp.changes.single.after.expiry!), '2026-10-05');
  });

  test('repeated stable session add ID is recovered as an update', () {
    const session = 'session_followup2';
    const id = 'ai_session_followup2_cefixime200';
    final current = stock(id, name: 'Cefixime', strength: '200mg');
    final plan = parseAiPlan(
      envelope(
        requestId: session,
        changeId: 'change_expiry_02',
        baseRevision: 1,
        actions: [
          {
            'op': 'add',
            'id': id,
            'fields': {
              'name': 'Cefixime',
              'strength': '200mg',
              'expiry': '2028-04',
            },
          },
        ],
      ),
      {id: current},
      7,
      const {},
      now,
    );

    expect(plan.changes.single.operation, 'update');
    expect(plan.changes.single.after.id, id);
    expect(dateText(plan.changes.single.after.expiry!), '2028-04-30');
  });

  test('match fallback can update and remove a uniquely identified live item', () {
    const session = 'session_followup3';
    const id = 'ai_session_followup3_para500';
    final current = stock(id, location: 'Rack A');

    final update = parseAiPlan(
      envelope(
        requestId: session,
        changeId: 'change_location3',
        baseRevision: 1,
        actions: [
          {
            'op': 'update',
            'match': {'name': 'Paracetamol', 'strength': '500mg'},
            'fields': {'location': 'Rack B'},
          },
        ],
      ),
      {id: current},
      2,
      const {},
      now,
    );
    expect(update.changes.single.after.id, id);
    expect(update.changes.single.after.location, 'Rack B');

    final afterUpdate = update.changes.single.after;
    final remove = parseAiPlan(
      envelope(
        requestId: session,
        changeId: 'change_remove3',
        baseRevision: 1,
        actions: [
          {
            'op': 'remove',
            'match': {'name': 'Paracetamol', 'strength': '500mg'},
          },
        ],
      ),
      {id: afterUpdate},
      3,
      {update.requestId},
      now,
    );
    expect(remove.changes.single.after.id, id);
    expect(remove.changes.single.after.archived, isTrue);
  });

  test('ambiguous match fails closed instead of editing the wrong batch', () {
    const session = 'session_followup4';
    final a = stock('batch_a', location: 'Rack A');
    final b = stock('batch_b', location: 'Rack B');

    expect(
      () => parseAiPlan(
        envelope(
          requestId: session,
          changeId: 'change_ambiguous4',
          baseRevision: 1,
          actions: [
            {
              'op': 'update',
              'match': {'name': 'Paracetamol', 'strength': '500mg'},
              'fields': {'expiry': '2027-01'},
            },
          ],
        ),
        {'batch_a': a, 'batch_b': b},
        1,
        const {},
        now,
      ),
      throwsFormatException,
    );
  });

  test('match remains ambiguous when one candidate belongs to this AI session', () {
    const session = 'session_followup5';
    const sessionId = 'ai_session_followup5_para500';
    final sessionAdded = stock(sessionId, location: 'Rack A');
    final existing = stock('existing_para500', location: 'Rack B');

    expect(
      () => parseAiPlan(
        envelope(
          requestId: session,
          changeId: 'change_ambiguous5',
          baseRevision: 1,
          actions: [
            {
              'op': 'update',
              'match': {'name': 'Paracetamol', 'strength': '500mg'},
              'fields': {'expiry': '2027-02'},
            },
          ],
        ),
        {sessionId: sessionAdded, existing.id: existing},
        2,
        const {},
        now,
      ),
      throwsFormatException,
    );
  });

  test('non-string action id fails closed as a format error', () {
    const session = 'session_followup6';
    final current = stock('existing');

    expect(
      () => parseAiPlan(
        envelope(
          requestId: session,
          changeId: 'change_bad_id6',
          baseRevision: 1,
          actions: [
            {
              'op': 'update',
              'id': 42,
              'fields': {'location': 'Rack Z'},
            },
          ],
        ),
        {current.id: current},
        1,
        const {},
        now,
      ),
      throwsFormatException,
    );
  });

  test('add with match fails closed instead of creating duplicate stock', () {
    const session = 'session_addmatch7';
    final current = stock('existing_para500');

    expect(
      () => parseAiPlan(
        envelope(
          requestId: session,
          changeId: 'change_addmatch7',
          baseRevision: 1,
          actions: [
            {
              'op': 'add',
              'match': {'name': 'Paracetamol', 'strength': '500mg'},
              'fields': {
                'name': 'Paracetamol',
                'strength': '500mg',
                'expiry': '2027-04',
              },
            },
          ],
        ),
        {current.id: current},
        1,
        const {},
        now,
      ),
      throwsFormatException,
    );
  });

}
