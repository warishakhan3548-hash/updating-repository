import 'package:aaris_pharmacy/domain/local_context_budget.dart';
import 'package:aaris_pharmacy/domain/medicine_understanding.dart';
import 'package:aaris_pharmacy/services/local_scan_turn.dart';
import 'package:flutter_test/flutter_test.dart';

const _draft = MedicineScanDraft(
  fields: <String, ExtractedMedicineField>{
    'name': ExtractedMedicineField(
      value: 'MOXIYES-D',
      confidence: .91,
      support: 1,
    ),
    'brand': ExtractedMedicineField(
      value: 'MOXIYES-D',
      confidence: .91,
      support: 1,
    ),
    'form': ExtractedMedicineField(
      value: 'Drops',
      confidence: .84,
      support: 1,
    ),
    'expiry': ExtractedMedicineField(
      value: '2027-04',
      confidence: .88,
      support: 1,
    ),
  },
  rawText: 'MOXIYES-D\n10 ml\nMFG 05/2026\nEXP 04/2027\nEye Drops',
  searchKeywords: 'moxiyes d eye drops',
  frameSequences: <int>[0],
  expiryMonthOnly: true,
  mfgMonthOnly: true,
  overallConfidence: .86,
);

const _machineReadyDraft = MedicineScanDraft(
  fields: <String, ExtractedMedicineField>{
    'name': ExtractedMedicineField(
      value: 'DOLO 650',
      confidence: .95,
      support: 2,
    ),
    'brand': ExtractedMedicineField(
      value: 'DOLO 650',
      confidence: .95,
      support: 2,
    ),
    'salt': ExtractedMedicineField(
      value: 'Paracetamol',
      confidence: .95,
      support: 2,
    ),
    'strength': ExtractedMedicineField(
      value: '650 mg',
      confidence: .95,
      support: 2,
    ),
    'form': ExtractedMedicineField(
      value: 'Tablets',
      confidence: .95,
      support: 2,
    ),
  },
  rawText: 'DOLO 650 TABLETS\nParacetamol IP 650 mg\nMFG 01/2026 EXP 12/2027',
  searchKeywords: 'dolo 650 paracetamol tablets',
  frameSequences: <int>[0],
  overallConfidence: .95,
);

void main() {
  test('empty local-model output never reaches JSON decode or breaks preview', () async {
    var calls = 0;

    final result = await runLocalScanTurn(
      draft: _draft,
      sourceLimit: 5000,
      outputTokens: 512,
      checkCurrent: () {},
      generate: (handoff, outputTokens) async {
        calls++;
        return '';
      },
    );

    expect(identical(result, _draft), isTrue);
    expect(calls, greaterThanOrEqualTo(1));
    expect(calls, lessThanOrEqualTo(2));
  });

  test('truncated JSON fails closed to deterministic scan evidence', () async {
    var calls = 0;

    final result = await runLocalScanTurn(
      draft: _draft,
      sourceLimit: 5000,
      outputTokens: 512,
      checkCurrent: () {},
      generate: (handoff, outputTokens) async {
        calls++;
        return '{"fields":{"brand":';
      },
    );

    expect(identical(result, _draft), isTrue);
    expect(calls, greaterThanOrEqualTo(1));
    expect(calls, lessThanOrEqualTo(2));
  });

  test('native context exhaustion preserves the offline draft', () async {
    final result = await runLocalScanTurn(
      draft: _draft,
      sourceLimit: 5000,
      outputTokens: 512,
      checkCurrent: () {},
      generate: (handoff, outputTokens) async {
        throw const LocalContextBudgetFailure(
          inputTokens: 2000,
          outputTokens: 512,
          contextTokens: 2048,
        );
      },
    );

    expect(identical(result, _draft), isTrue);
  });

  test('failed Local AI turn cannot authorize a high-confidence machine save', () async {
    final result = await runLocalScanTurn(
      draft: _machineReadyDraft,
      sourceLimit: 5000,
      outputTokens: 512,
      checkCurrent: () {},
      generate: (handoff, outputTokens) async => '',
    );

    expect(result.overallConfidence, lessThan(.88));
    expect(result.brand, _machineReadyDraft.brand);
    expect(result.salt, _machineReadyDraft.salt);
    expect(result.strength, _machineReadyDraft.strength);
    expect(result.form, _machineReadyDraft.form);
  });

  test('partial valid AI evidence remains review-only', () async {
    final result = await runLocalScanTurn(
      draft: _machineReadyDraft,
      sourceLimit: 5000,
      outputTokens: 512,
      checkCurrent: () {},
      generate: (handoff, outputTokens) async => '''
{"fields":{"brand":{"value":"DOLO 650","quote":"DOLO 650"},"form":{"value":"Tablets","quote":"TABLETS"}}}
''',
    );

    expect(result.overallConfidence, lessThan(.88));
  });

  test('complete source-grounded identity witness preserves machine-save confidence', () async {
    final result = await runLocalScanTurn(
      draft: _machineReadyDraft,
      sourceLimit: 5000,
      outputTokens: 512,
      checkCurrent: () {},
      generate: (handoff, outputTokens) async => '''
{"fields":{"brand":{"value":"DOLO 650","quote":"DOLO 650"},"salt":{"value":"Paracetamol","quote":"Paracetamol IP 650 mg"},"strength":{"value":"650 mg","quote":"Paracetamol IP 650 mg"},"form":{"value":"Tablets","quote":"TABLETS"}},"ingredients":[{"salt":"Paracetamol","strength":"650 mg","quote":"Paracetamol IP 650 mg"}]}
''',
    );

    expect(result.overallConfidence, greaterThanOrEqualTo(.88));
    expect(result.brand, 'DOLO 650');
    expect(result.salt, 'Paracetamol');
    expect(result.strength, '650 mg');
    expect(result.form, 'Tablets');
  });
}
