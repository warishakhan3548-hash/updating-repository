import 'dart:convert';

import 'package:aaris_pharmacy/domain/ai_protocol.dart';
import 'package:aaris_pharmacy/domain/local_ai_protocol.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final today = DateTime(2026, 9, 20, 12);

  test('owner can explicitly accept a minimal add after declining optional facts', () {
    expect(
      ownerAcceptsMinimalAdd(
        instruction: 'Cefixime 200mg add kar do',
      ),
      isFalse,
      reason: 'A normal first add request may still ask one useful optional question.',
    );

    expect(
      ownerAcceptsMinimalAdd(
        instruction: 'Arey jodo aur mujhey kuchh nahi pata',
        conversation:
            'Owner: Cefixime 200mg add kar do\n'
            'Assistant: Quantity aur form bata do.',
      ),
      isTrue,
    );

    expect(
      ownerAcceptsMinimalAdd(
        instruction: 'मुझे नहीं पता भाई, बस ऐड कर दो',
        conversation: 'Owner: Cefixime 200mg जोड़ दो',
      ),
      isTrue,
    );

    expect(
      ownerAcceptsMinimalAdd(
        instruction: 'mujhe nahi pata',
        conversation: 'Assistant: You could add a medicine later.',
      ),
      isFalse,
      reason: 'Assistant wording alone must never grant mutation permission.',
    );
  });

  test('cloud and local prompts make optional add facts explicitly non-blocking', () {
    final export = PharmacyExport(
      revision: 4,
      records: const [],
      today: today,
    );
    expect(export.prompt, contains('the medicine name is the only required medicine fact'));
    expect(export.prompt, contains('STOP ASKING'));
    expect(export.prompt, contains('Never require quantity, form, expiry, price, batch or supplier for a new add'));
    expect(export.prompt, contains('Omitted quantity means unknown, not zero'));

    final local = LocalInventoryContext(
      records: const [],
      sales: const [],
      revision: 4,
      today: today,
    );
    expect(local.instructions, contains('For a NEW add, only name is required'));
    expect(local.instructions, contains('immediately propose the add with only known facts'));
    expect(local.instructions, contains('Omitted quantity means unknown, not zero'));
  });

  test('review accepts Cefixime add with known facts only', () {
    const requestId = 'session_minimal_add';
    final raw = jsonEncode({
      'schema': pharmacySchema,
      'requestId': requestId,
      'changeId': 'change_minimal_001',
      'baseRevision': 3,
      'reply': 'Known facts prepared for review',
      'actions': [
        {
          'op': 'add',
          'id': 'ai_${requestId}_cefixime200',
          'fields': {
            'name': 'Cefixime',
            'strength': '200mg',
            'expiry': '2026-09-22',
          },
        },
      ],
    });

    final plan = parseAiPlan(
      raw,
      const {},
      3,
      const {},
      today,
    );
    final medicine = plan.changes.single.after;
    expect(medicine.name, 'Cefixime');
    expect(medicine.strength, '200mg');
    expect(dateText(medicine.expiry!), '2026-09-22');
    expect(medicine.quantity, isNull);
    expect(medicine.form, isEmpty);
    expect(medicine.unitPricePaise, isNull);
    expect(medicine.batchNumber, isEmpty);
    expect(medicine.supplierId, isEmpty);
  });
}
