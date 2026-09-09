import 'dart:convert';
import 'dart:io';

import '../lib/domain/ai_protocol.dart';
import '../lib/domain/local_ai_protocol.dart';
import '../lib/domain/medicine.dart';
import '../lib/domain/medicine_understanding.dart';

void main() {
  var passed = 0;
  void check(bool value, String label) {
    if (!value) throw StateError(label);
    passed++;
  }

  void rejects(void Function() run, String label) {
    try {
      run();
    } on FormatException {
      passed++;
      return;
    }
    throw StateError('Accepted: $label');
  }

  final today = DateTime.utc(2026, 9, 9);
  final records = [
    for (var i = 0; i < 20; i++)
      Medicine(
        id: 'stock_$i',
        name: 'Dolo',
        salt: 'Paracetamol',
        strength: '650 mg',
        expiry: i == 0 ? DateTime.utc(2026, 9, 8) : null,
        quantity: i == 0 ? 0 : null,
      ),
  ];
  final ctx = LocalInventoryContext(
    records: records,
    sales: [],
    revision: 7,
    today: today,
  );
  check(ctx.summary['zeroQuantityEntries'] == 1, 'Unknown is not zero');
  check(ctx.summary['expiredEntries'] == 1, 'Civil expiry');
  check(ctx.summary['unknownExpiryEntries'] == 19, 'Unknown expiry');
  rejects(
    () => ctx.finish({
      'reply': 'ok',
      'actions': [
        {'op': 'remove', 'id': 'stock_0'},
      ],
    }),
    'unretrieved ID',
  );
  final page = ctx.read({'tool': 'search', 'query': 'paracetamol'});
  check((page['rows'] as List).length == 8, 'Bounded page');
  check(
    page['totalMatches'] == 20 && page['nextOffset'] == 8,
    'No silent truncation',
  );
  final id = ((page['rows'] as List).first as Map)['id'];
  final response = ctx.finish({
    'reply': 'Review stock update',
    'actions': [
      {
        'op': 'update',
        'id': id,
        'fields': {'quantity': 25},
      },
    ],
  });
  final plan = parseAiPlan(
    response,
    {for (final m in records) m.id: m},
    7,
    {},
    today,
  );
  check(
    plan.changes.single.after.quantity == 25,
    'Existing validator integration',
  );
  check(jsonDecode(response)['baseRevision'] == 7, 'App owns revision');
  rejects(
    () => ctx.read({'tool': 'sql', 'query': 'DELETE FROM medicines'}),
    'SQL',
  );
  rejects(
    () => ctx.read({'tool': 'get', 'id': id, 'path': '/private'}),
    'Unknown argument',
  );
  rejects(() => ctx.read({'tool': 'search', 'offset': -1}), 'Negative offset');
  rejects(
    () => ctx.finish({'reply': 'ok', 'actions': [], 'baseRevision': 8}),
    'Model revision',
  );
  rejects(
    () => localJsonObject('Here is JSON: {"reply":"hi"}'),
    'Prose extraction',
  );
  check(
    localJsonObject('```json\n{"reply":"नमस्ते"}\n```')['reply'] == 'नमस्ते',
    'Hindi JSON',
  );
  final draft = MedicineScanDraft(
    fields: {
      'expiry': const ExtractedMedicineField(value: '2028-07', confidence: .9),
    },
    rawText: 'Paracetamol 650 mg MFG 08/2026 EXP 07/2028',
    searchKeywords: '',
    frameSequences: [1],
  );
  final corrected = validateLocalScan(draft, {
    'fields': {
      'salt': {'value': 'Paracetamol', 'quote': 'Paracetamol 650 mg'},
      'expiry': {'value': '2026-08', 'quote': 'MFG 08/2026'},
    },
  });
  check(corrected.salt == 'Paracetamol', 'Evidence-bound semantic label');
  check(
    corrected.field('salt').conflicted && corrected.needsReview,
    'New labels need review',
  );
  check(corrected.expiry == '2028-07', 'AI cannot swap MFG and EXP');
  rejects(
    () => validateLocalScan(draft, {
      'fields': {
        'salt': {'value': 'Pantoprazole', 'quote': 'Paracetamol 650 mg'},
      },
    }),
    'Unsupported medicine',
  );
  rejects(
    () => validateLocalScan(draft, {
      'fields': {
        'salt': {'value': 'Cefixime', 'quote': 'Cefixime 200 mg'},
      },
    }),
    'Evidence from another video object',
  );
  rejects(
    () => validateLocalScan(draft, {
      'fields': {
        'quantity': {'value': '650', 'quote': '650 mg'},
      },
    }),
    'Strength becomes quantity',
  );
  stdout.writeln('Local AI contract: $passed passed.');
}
