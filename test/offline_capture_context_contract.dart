import 'dart:async';
import 'dart:convert';

import '../lib/domain/local_ai_protocol.dart';
import '../lib/domain/local_context_budget.dart';
import '../lib/domain/medicine.dart';
import '../lib/domain/medicine_date_intelligence.dart';
import '../lib/domain/medicine_resolution_v2.dart';
import '../lib/domain/medicine_understanding.dart';
import '../lib/domain/spatial_traceability.dart';
import '../lib/services/local_chat_turn.dart';

void _check(bool value, String reason) {
  if (!value) throw StateError(reason);
}

MedicineDateResolution _dates(String text) => inferMedicineDateIntelligence(
  frames: [MedicineFrameEvidence(text: text)],
  referenceDate: DateTime.utc(2026, 9, 12),
);

Map<String, FutureOr<void> Function()> offlineCaptureContextContract() => {
  'calendar matrix validates every month boundary and both compact orders': () {
    for (final year in [2000, 2024, 2025, 2026, 2027, 2028, 2099]) {
      for (var month = 1; month <= 12; month++) {
        final mm = month.toString().padLeft(2, '0');
        for (var day = 0; day <= 32; day++) {
          final dd = day.toString().padLeft(2, '0');
          final valid = day > 0 && day <= DateTime.utc(year, month + 1, 0).day;
          for (final raw in ['$dd$mm$year', '$year$mm$dd']) {
            _check(
              parseMedicineDateText(raw)?.value ==
                  (valid ? '$year-$mm-$dd' : null),
              'Calendar boundary failed: $raw',
            );
          }
        }
      }
    }
  },
  'an unseen brand cannot invent a salt without printed composition': () {
    final payload = understandMedicineEvidenceV2Message({
      'referenceDate': '2026-09-12',
      'knowledge': <Object?>[],
      'catalog': <Object?>[],
      'evidence': [
        const MedicineFrameEvidence(
          text: 'ZORBEXA 650\nTABLETS\nMFG 05042025\nEXP 06042028',
        ).toMessage(),
      ],
    });
    final drafts = MedicineUnderstandingResult.fromMessage(payload).drafts;
    _check(
      drafts.length == 1,
      'Brand-only pack was not kept as one review draft',
    );
    for (final draft in drafts) {
      _check(
        draft.salt.isEmpty,
        'A brand-only pack invented composition: ${draft.salt}',
      );
    }
  },
  for (final raw in [
    '05042027',
    '05 04 2027',
    '05/04/2027',
    '05,04,2027',
    '20270405',
    '2027-04-05',
    '०५०४२०२७',
    '05O42O27',
  ])
    'calendar parses $raw': () {
      final date = parseMedicineDateText(raw);
      _check(
        date?.value == '2027-04-05' && !date!.monthOnly,
        '$raw did not preserve day precision: ${date?.value}',
      );
    },
  for (final raw in ['042027', '202704', '04/2027', '2027-04', 'APR 2027'])
    'month precision $raw': () {
      final date = parseMedicineDateText(raw);
      _check(
        date?.value == '2027-04' && date!.monthOnly,
        'Month precision lost',
      );
    },
  for (final raw in [
    '31022027',
    '00042027',
    '20270229',
    '20271305',
    '32/02/2027',
    '31 02 2027',
    '050427',
    '8900504202701',
    'LOT05042027',
    '05042027AB',
  ])
    'reject malformed date or identifier $raw': () {
      _check(
        parseMedicineDateText(raw) == null,
        'Invalid/embedded date accepted: $raw',
      );
    },
  'leap-year validation': () {
    _check(
      parseMedicineDateText('29022028')?.value == '2028-02-29',
      'Valid leap day rejected',
    );
    _check(
      parseMedicineDateText('29022027') == null,
      'Invalid leap day accepted',
    );
  },
  for (final label in [
    'MFG',
    'M.F.G.',
    'MFD',
    'Manufacturing Date',
    'Date of Manufacture',
    'निर्माण तिथि',
  ])
    'manufacturing label $label': () {
      final result = _dates('$label 05042025');
      _check(
        result.manufacturing?.date.value == '2025-04-05',
        'MFG not associated',
      );
      _check(result.expiry == null, 'MFG was invented as EXP');
    },
  'fused manufacturing and expiry labels': () {
    final result = _dates('MFG05042025 EXP06042028');
    _check(
      result.manufacturing?.date.value == '2025-04-05',
      'Glued MFG missed',
    );
    _check(result.expiry?.date.value == '2028-04-06', 'Glued EXP missed');
    _check(!result.conflicted, 'Valid ordered labels conflict');
  },
  'adjacent OCR line belongs to manufacturing label': () {
    final result = _dates('MFG DATE\n05042025\nEXPIRY\n06042028');
    _check(result.manufacturing?.date.value == '2025-04-05', 'Split MFG lost');
    _check(result.expiry?.date.value == '2028-04-06', 'Split EXP lost');
  },
  'batch and MRP must not masquerade as dates': () {
    for (final raw in [
      'Batch 05042027',
      'MRP 05042027',
      'GTIN 05042027',
      'MFG Batch 05042027',
      'MFG\nBatch 05042027',
    ]) {
      _check(_dates(raw).isEmpty, 'Non-date numeric field accepted: $raw');
    }
    _check(
      _dates('05042027').isEmpty,
      'Bare compact number assigned a date role',
    );
  },
  'future MFG keeps its role and requires review': () {
    final result = _dates('MFG 05042027');
    _check(
      result.manufacturing?.date.value == '2027-04-05',
      'Reported compact MFG still missing',
    );
    _check(
      result.expiry == null && result.conflicted,
      'Future MFG silently relabelled/trusted',
    );
  },
  'conflicting printed MFG values fail closed': () {
    _check(
      _dates('MFG 05042025\nMFG 06042025\nEXP 06042028').conflicted,
      'Competing labels were silently resolved',
    );
  },
  'reversed chronology fails closed': () {
    _check(
      _dates('MFG 05042026\nEXP 05042025').conflicted,
      'MFG after EXP accepted',
    );
  },
  'future singleton is below auto-fill confidence': () {
    final result = _dates('05 04 2027');
    _check(
      (result.expiry?.confidence ?? 0) < .78,
      'Calendar alone asserted EXP',
    );
  },
  'OCR geometry binds compact MFG and EXP values separately': () {
    final result = inferSpatialTraceability(const [
      MedicineFrameEvidence(
        text: 'M.F.G.\n05042025\nEXP\n06042028',
        layoutLines: [
          MedicineTextLineEvidence(
            text: 'M.F.G.',
            left: 0,
            top: 0,
            width: 40,
            height: 14,
          ),
          MedicineTextLineEvidence(
            text: '05042025',
            left: 60,
            top: 0,
            width: 85,
            height: 14,
          ),
          MedicineTextLineEvidence(
            text: 'EXP',
            left: 0,
            top: 50,
            width: 40,
            height: 14,
          ),
          MedicineTextLineEvidence(
            text: '06042028',
            left: 60,
            top: 50,
            width: 85,
            height: 14,
          ),
        ],
      ),
    ]);
    _check(result.mfg?.value == '2025-04-05', 'Spatial MFG failed');
    _check(result.expiry?.value == '2028-04-06', 'Spatial EXP failed');
  },
  'no-model OCR preserves salt strength MFG and stored date precision': () {
    final payload = understandMedicineEvidenceV2Message({
      'referenceDate': '2026-09-12',
      'knowledge': <Object?>[],
      'catalog': <Object?>[],
      'evidence': [
        const MedicineFrameEvidence(
          text: 'DOLO 650\nTABLETS\nComposition\nParacetamol IP 650 mg\nMFG05042025\nEXP 06042028',
        ).toMessage(),
      ],
    });
    final drafts = MedicineUnderstandingResult.fromMessage(payload).drafts;
    _check(drafts.length == 1, 'One pack became ${drafts.length} drafts');
    final draft = drafts.single;
    _check(
      draft.mfg == '2025-04-05' && !draft.mfgMonthOnly,
      'Extractor/resolver lost MFG: ${draft.toMessage()}',
    );
    _check(
      draft.expiry == '2028-04-06' && !draft.expiryMonthOnly,
      'EXP precision lost',
    );
    _check(
      draft.salt.toLowerCase().contains('paracetamol') &&
          draft.strength.contains('650'),
      'Offline composition lost',
    );
    final record = Medicine.fromJson({
      'id': 'reviewed-pack',
      'name': draft.name.isEmpty ? 'Dolo 650' : draft.name,
      'salt': draft.salt,
      'strength': draft.strength,
      'mfg': draft.mfg,
      'expiry': draft.expiry,
    });
    final stored = Medicine.fromJson(record.toJson());
    _check(
      dateText(stored.mfg!) == '2025-04-05',
      'Database JSON contract lost MFG',
    );
  },
  'typed context error only recognizes the native budget contract': () {
    final error = LocalContextBudgetFailure.fromMessage(
      'Bad state: Local prompt needs 1800 input tokens plus 1000 reserved output tokens; context is 2048. Use a shorter request.',
    );
    _check(
      error?.inputTokens == 1800 && error?.contextTokens == 2048,
      'Native admission error not classified',
    );
    _check(
      LocalContextBudgetFailure.fromMessage(
            'Failed to create llama.cpp context',
          ) ==
          null,
      'Allocator failure misclassified',
    );
  },
  'local history rolls over once without losing current question': () async {
    var calls = 0, resets = 0;
    final result = await _chat(
      conversation: 'Owner: previous chat',
      onReset: () => resets++,
      generate: (payload, output) async {
        final input = jsonDecode(payload) as Map;
        _check(
          input['ownerRequest'] == 'नमस्ते भाई',
          'Current instruction was truncated',
        );
        if (calls++ == 0) {
          throw LocalContextBudgetFailure(
            inputTokens: 1900,
            outputTokens: output,
            contextTokens: 2048,
          );
        }
        _check(input['recentConversation'] == '', 'Old history sent again');
        return '{"reply":"नमस्ते","actions":[]}';
      },
    );
    _check(
      calls == 2 &&
          resets == 1 &&
          (jsonDecode(result) as Map)['reply'] == 'नमस्ते',
      'Fresh chat failed',
    );
  },
  'oversized Unicode history resets before inference, never sliced': () async {
    var resets = 0;
    await _chat(
      conversation: '🧪 पुरानी बात ' * 1000,
      onReset: () => resets++,
      generate: (payload, _) async {
        _check(
          (jsonDecode(payload) as Map)['recentConversation'] == '',
          'Half-message fragment retained',
        );
        return '{"reply":"Hello","actions":[]}';
      },
    );
    _check(resets == 1, 'History reset was not reported');
  },
  'exact native counts reduce output reserve in a fresh context': () async {
    var calls = 0;
    await _chat(
      generate: (_, output) async {
        if (calls++ == 0)
          throw LocalContextBudgetFailure(
            inputTokens: 1400,
            outputTokens: output,
            contextTokens: 2048,
          );
        _check(output == 616, 'Output reserve not sized from real context');
        return '{"reply":"Hello","actions":[]}';
      },
    );
    _check(calls == 2, 'Output budget retries unbounded');
  },
  'oversized current request fails once, not as model unavailable': () async {
    var calls = 0;
    try {
      await _chat(
        generate: (_, output) async {
          calls++;
          throw LocalContextBudgetFailure(
            inputTokens: 2100,
            outputTokens: output,
            contextTokens: 2048,
          );
        },
      );
      throw StateError('Impossible request accepted');
    } on FormatException catch (error) {
      _check(
        error.message.contains('still available') && calls == 1,
        'Wrong retry/error policy',
      );
    }
  },
  'unrelated model failures are not hidden as context rollover': () async {
    var resets = 0, calls = 0;
    try {
      await _chat(
        conversation: 'Owner: old',
        onReset: () => resets++,
        generate: (_, _) async {
          calls++;
          throw StateError('Invalid model file');
        },
      );
      throw ArgumentError('Expected native failure');
    } on StateError catch (error) {
      _check(
        error.message == 'Invalid model file' && calls == 1 && resets == 0,
        'Model failure was masked',
      );
    }
  },
  'cancel during rollover prevents a second native command': () async {
    var cancelled = false, calls = 0;
    try {
      await _chat(
        conversation: 'Owner: old',
        checkCurrent: () {
          if (cancelled) throw StateError('cancelled');
        },
        onReset: () => cancelled = true,
        generate: (_, output) async {
          calls++;
          throw LocalContextBudgetFailure(
            inputTokens: 1900,
            outputTokens: output,
            contextTokens: 2048,
          );
        },
      );
      throw ArgumentError('Expected cancellation');
    } on StateError catch (error) {
      _check(
        error.message == 'cancelled' && calls == 1,
        'Cancelled request retried',
      );
    }
  },
  'rollover keeps current-turn authoritative inventory tool results': () async {
    var calls = 0, resets = 0;
    await _chat(
      conversation: 'Owner: old',
      onReset: () => resets++,
      generate: (payload, output) async {
        final input = jsonDecode(payload) as Map;
        calls++;
        if (calls == 1) return '{"tool":"search","query":"","offset":0}';
        if (calls == 2)
          throw LocalContextBudgetFailure(
            inputTokens: 1800,
            outputTokens: output,
            contextTokens: 2048,
          );
        _check(
          input['recentConversation'] == '' &&
              (input['toolResults'] as List).isNotEmpty,
          'Verified read result lost',
        );
        return '{"reply":"No stock","actions":[]}';
      },
    );
    _check(calls == 3 && resets == 1, 'Tool-round rollover failed');
  },
};

Future<String> _chat({
  String conversation = '',
  void Function()? onReset,
  void Function()? checkCurrent,
  required Future<String> Function(String, int) generate,
}) => runLocalChatTurn(
  context: LocalInventoryContext(
    records: const [],
    sales: const [],
    revision: 4,
    today: DateTime.utc(2026, 9, 12),
  ),
  instruction: 'नमस्ते भाई',
  conversation: conversation,
  conversationLimit: 2000,
  outputTokens: 1000,
  inventoryRows: 2,
  generate: generate,
  checkCurrent: checkCurrent ?? () {},
  onContextReset: onReset,
);
