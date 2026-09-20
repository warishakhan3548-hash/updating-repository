import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import '../lib/domain/ai_conversation.dart';
import '../lib/domain/ai_protocol.dart';

String _planJson({String changeId = 'change_random10_20260920_a1'}) =>
    jsonEncode(<String, dynamic>{
      'schema': pharmacySchema,
      'requestId': '9c4f34e3bde6088ea398d959e793913f',
      'changeId': changeId,
      'baseRevision': 1,
      'reply': 'Prepared for review.',
      'actions': <Map<String, dynamic>>[
        <String, dynamic>{
          'op': 'add',
          'id': 'ai_9c4f34e3bde6088ea398d959e793913f_amoxicillin',
          'fields': <String, dynamic>{
            'name': 'Amoxicillin',
            'salt': 'Amoxicillin trihydrate',
          },
        },
      ],
    });

void main() {
  test('copied timing text before pharmacy JSON is safely extracted', () {
    final json = _planJson();
    final response = AiConversationResponse.parse('Worked for 43s\n\n$json');

    expect(response.planJson, json);
    expect(response.reply, isEmpty);
  });

  test('plain prose around one pharmacy JSON still routes to review', () {
    final json = _planJson();
    final response = AiConversationResponse.parse(
      'Here is the requested change:\n$json\nCopy this into Aaris.',
    );

    expect(response.planJson, json);
  });

  test('two pharmacy objects in one paste fail closed as ambiguous', () {
    final first = _planJson(changeId: 'change_random10_20260920_a1');
    final second = _planJson(changeId: 'change_random10_20260920_a2');

    expect(
      () => AiConversationResponse.parse('$first\n$second'),
      throwsFormatException,
    );
  });

  test('incomplete pharmacy marker never becomes normal chat', () {
    const raw =
        'Worked for 43s\n{"schema":"aaris.pharmacy.v1","actions":[';

    expect(() => AiConversationResponse.parse(raw), throwsFormatException);
  });
}
