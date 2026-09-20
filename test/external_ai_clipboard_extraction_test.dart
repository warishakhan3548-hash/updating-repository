import 'dart:convert';

import 'package:aaris_pharmacy/domain/ai_protocol.dart';
import 'package:aaris_pharmacy/domain/medicine.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final now = DateTime(2026, 9, 20, 16, 50);

  String envelope({
    String requestId = 'request_12345',
    String changeId = 'change_12345',
    String name = 'Cefixime',
    String reply = 'Prepared for review',
  }) => jsonEncode(<String, dynamic>{
    'schema': pharmacySchema,
    'requestId': requestId,
    'changeId': changeId,
    'baseRevision': 1,
    'reply': reply,
    'actions': <Map<String, dynamic>>[
      <String, dynamic>{
        'op': 'add',
        'id': 'ai_${requestId}_medicine',
        'fields': <String, dynamic>{'name': name, 'strength': '200 mg'},
      },
    ],
  });

  test('extracts one Aaris envelope from unrelated clipboard prose', () {
    final raw = '''
Worked for 43s

Random copied UI text that is not part of the command.
${envelope()}

Share · Copy · some unrelated footer text
''';

    final plan = parseAiPlan(
      raw,
      const <String, Medicine>{},
      1,
      const <String>{},
      now,
    );

    expect(plan.changes, hasLength(1));
    expect(plan.changes.single.after.name, 'Cefixime');
    expect(plan.changes.single.after.strength, '200 mg');
  });

  test('ignores unrelated JSON and braces around the Aaris envelope', () {
    final raw =
        'prefix {"telemetry":{"ok":true}} text {broken junk\n'
        '${envelope(name: 'Azithromycin')}\n'
        'suffix {"screen":"chat","count":2}';

    final plan = parseAiPlan(
      raw,
      const <String, Medicine>{},
      1,
      const <String>{},
      now,
    );

    expect(plan.changes.single.after.name, 'Azithromycin');
  });

  test('balanced extraction survives braces and escaped quotes in reply', () {
    final raw = [
      'Copied answer:',
      envelope(
        name: 'Cetirizine',
        reply: 'Prepared {safely}; owner said "add it".',
      ),
      'End of copied answer.',
    ].join('\n');

    final plan = parseAiPlan(
      raw,
      const <String, Medicine>{},
      1,
      const <String>{},
      now,
    );

    expect(plan.reply, 'Prepared {safely}; owner said "add it".');
    expect(plan.changes.single.after.name, 'Cetirizine');
  });

  test('accepts a fenced JSON envelope even with prose outside the fence', () {
    final raw = '''
Some copied heading
```json
${envelope(name: 'Pantoprazole')}
```
Some copied footer
''';

    final plan = parseAiPlan(
      raw,
      const <String, Medicine>{},
      1,
      const <String>{},
      now,
    );

    expect(plan.changes.single.after.name, 'Pantoprazole');
  });

  test('extracts Aaris envelope even when schema is not the first key', () {
    final reordered = jsonEncode(<String, dynamic>{
      'requestId': 'request_33333',
      'reply': 'Prepared for review',
      'actions': <Map<String, dynamic>>[
        <String, dynamic>{
          'op': 'add',
          'id': 'ai_request_33333_medicine',
          'fields': <String, dynamic>{'name': 'Losartan'},
        },
      ],
      'baseRevision': 1,
      'schema': pharmacySchema,
      'changeId': 'change_33333',
    });

    final plan = parseAiPlan(
      'Copied heading\n$reordered\nCopied footer',
      const <String, Medicine>{},
      1,
      const <String>{},
      now,
    );

    expect(plan.changes.single.after.name, 'Losartan');
  });

  test('rejects ambiguous clipboard text containing two Aaris envelopes', () {
    final raw = '''
${envelope(requestId: 'request_11111', changeId: 'change_11111')}
unrelated separator
${envelope(requestId: 'request_22222', changeId: 'change_22222')}
''';

    expect(
      () => parseAiPlan(
        raw,
        const <String, Medicine>{},
        1,
        const <String>{},
        now,
      ),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('More than one Aaris Pharmacy change'),
        ),
      ),
    );
  });

  test('never treats ordinary clipboard text as an inventory command', () {
    expect(
      () => parseAiPlan(
        'Worked for 43s. Hello world. {"foo":"bar"}',
        const <String, Medicine>{},
        1,
        const <String>{},
        now,
      ),
      throwsFormatException,
    );
  });
}
