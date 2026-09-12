import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import '../lib/domain/capture_quality.dart';
import '../lib/domain/local_ai_protocol.dart';
import '../lib/domain/local_context_budget.dart';
import '../lib/domain/local_scan_evidence.dart';
import '../lib/domain/local_scan_handoff.dart';
import '../lib/domain/medicine_understanding.dart';
import '../lib/domain/medicine_ocr_text.dart';
import '../lib/domain/medicine_resolution_v2.dart';
import '../lib/services/local_scan_turn.dart';

void _check(bool value, String message) {
  if (!value) throw StateError(message);
}

Future<void> _reject(
  FutureOr<Object?> Function() run, {
  Type type = FormatException,
}) async {
  try {
    await run();
  } catch (error) {
    if (error.runtimeType == type) return;
    rethrow;
  }
  throw StateError('Expected $type');
}

MedicineScanDraft _draft(
  String text, {
  Map<String, ExtractedMedicineField> fields = const {},
}) => MedicineScanDraft(
  fields: fields,
  rawText: text,
  searchKeywords: 'private search memory',
  frameSequences: const [0],
);

const _pack =
    'ZORBEXA 650\nTABLETS\nCOMPOSITION\nParacetamol IP 650 mg\nMFG 05042025\nEXP 06042028';
const _reply =
    '{"fields":{"brand":{"value":"ZORBEXA 650","quote":"ZORBEXA 650"}}}';
const _overflow = LocalContextBudgetFailure(
  inputTokens: 5000,
  outputTokens: 512,
  contextTokens: 2048,
);
Map<String, dynamic> _pair(String salt, String strength, String quote) => {
  'fields': <String, dynamic>{},
  'ingredients': [
    {'salt': salt, 'strength': strength, 'quote': quote},
  ],
};

String _longPack() =>
    'ZORBEXA 650\nTABLETS\n${'storage directions\n' * 90}'
    'COMPOSITION\nParacetamol IP 650 mg\n${'keep dry\n' * 90}'
    'MFG\n05042025\nEXP\n06042028\nBatch LOT7';

CaptureQuality? _quality(
  List<int> bytes, {
  int width = 32,
  int height = 32,
  int stride = 32,
  int pixelStride = 1,
  bool bgra = false,
}) => CaptureQuality.fromPlane(
  bytes: Uint8List.fromList(bytes),
  width: width,
  height: height,
  bytesPerRow: stride,
  pixelStride: pixelStride,
  bgra: bgra,
);

Map<String, FutureOr<void> Function()> scanCaptureContract() => {
  'OCR merging preserves near-identical conflicting strengths': () {
    final lines = mergeMedicineOcrLines([
      'Each film coated tablet contains Paracetamol IP 650 mg',
      'Each film coated tablet contains Paracetamol IP 850 mg',
    ]);
    _check(lines.length == 2, 'Fuzzy merge silently chose a strength');
  },
  'no-model resolver receives conflicting OCR doses for review': () {
    final text = mergeMedicineOcrLines([
      'ZORBEXA',
      'TABLETS',
      'COMPOSITION',
      'Each film coated tablet contains Paracetamol IP 650 mg',
      'Each film coated tablet contains Paracetamol IP 850 mg',
      'MFG 05042025',
      'EXP 06042028',
    ]).join('\n');
    final result = MedicineUnderstandingResult.fromMessage(
      understandMedicineEvidenceV2Message({
        'referenceDate': '2026-09-12',
        'knowledge': <Object?>[],
        'catalog': <Object?>[],
        'evidence': [MedicineFrameEvidence(text: text).toMessage()],
      }),
    );
    _check(result.drafts.isNotEmpty, 'Conflict discarded the capture');
    for (final draft in result.drafts) {
      _check(
        draft.needsReview,
        'Conflicting doses became an unreviewed identity',
      );
    }
  },
  'OCR merging preserves numeric punctuation, dose units and date roles': () {
    final readings = [
      'Dexamethasone 0.5 mg',
      'Dexamethasone 0/5 mg',
      'Dexamethasone 5 mg',
      'Ingredient 500 mg',
      'Ingredient 500 mcg',
      'Manufacturing date MFG 05042025',
      'Manufacturing date MFG 06042025',
      'MFG 05042025',
      'EXP 05042025',
    ];
    _check(
      mergeMedicineOcrLines(readings).length == readings.length,
      'Critical OCR difference erased',
    );
  },
  'OCR merging removes exact duplicate translations without reordering panels':
      () {
        final readings = [
          'BRAND A',
          ...List.filled(13, 'storage instructions'),
          'BRAND B',
          'Paracetamol 500 mg',
          ' paracetamol   500 mg ',
          'निर्माण तिथि ०५०४२०२५',
          'निर्माण तिथि ०५०४२०२५',
        ];
        final lines = mergeMedicineOcrLines(readings);
        _check(
          lines.length == 5 &&
              lines[2] == 'BRAND B' &&
              lines[3] == 'Paracetamol 500 mg',
          'Reordered evidence or repeated ingredient',
        );
        _check(
          mergeMedicineOcrLines(List.generate(700, (i) => 'line $i')).length ==
              500,
          'Unbounded OCR merge',
        );
      },
  'handoff policy is compact and candidate hints cannot export stock/private memory':
      () {
        final handoff = LocalScanHandoff.fromDraft(
          _draft(
            _pack,
            fields: {
              'quantity': const ExtractedMedicineField(value: '9999'),
              'notes': const ExtractedMedicineField(value: 'private note'),
              'name': ExtractedMedicineField(value: 'x' * 101),
            },
          ),
        );
        _check(
          handoff.systemPrompt.length < 2600,
          'Repeated prompt policy overhead',
        );
        _check(
          !handoff.userPayload.contains('private') &&
              !handoff.userPayload.contains('9999'),
          'Private hints exported',
        );
        final message = jsonDecode(handoff.userPayload) as Map;
        _check(
          message['schemaVersion'] == 13 && message['SOURCE'] is List,
          'Unversioned excerpt protocol',
        );
        _check(
          (message['candidateHints'] as Map).isEmpty,
          'Oversized hints were truncated into facts',
        );
      },
  'short source is identical and untruncated': () {
    final source = LocalScanEvidence.select(_pack);
    _check(
      source.excerpts.single.text == _pack && !source.truncated,
      'Short source rewritten',
    );
  },
  'shared label grammar keeps compact MFG and percent/Unicode doses in view': () {
    for (final label in [
      'MFG05042025',
      'M.F.G.05042025',
      'निर्माण तिथि०५०४२०२५',
    ]) {
      for (final dose in [
        'Ingredient 1%',
        'Ingredient ५ mg',
        'Ingredient 2 g',
      ]) {
        final raw =
            'BRAND\n${'storage instructions\n' * 60}$dose\n${'store dry\n' * 60}$label';
        final evidence = LocalScanEvidence.select(raw, limit: 512);
        _check(
          evidence.excerpts.any((span) => span.text.contains(label)),
          'Date label grammar diverged',
        );
        _check(
          evidence.excerpts.any((span) => span.text.contains(dose)),
          'Dose locator omitted a printed unit',
        );
      }
    }
  },
  'late composition does not evict brand or labelled dates': () {
    final evidence = LocalScanEvidence.select(_longPack(), limit: 512);
    for (final text in [
      'ZORBEXA 650',
      'Paracetamol IP 650 mg',
      'MFG\n05042025',
      'EXP\n06042028',
    ]) {
      _check(
        evidence.excerpts.any((span) => span.text.contains(text)),
        'Missing $text',
      );
    }
    _check(evidence.excerpts.length > 1, 'Gaps were silently joined');
  },
  'budget matrix preserves exact ordered complete lines and Unicode': () {
    final random = Random(731);
    for (var caseIndex = 0; caseIndex < 40; caseIndex++) {
      final source = List.generate(
        80,
        (i) => switch (i % 13) {
          0 => 'MEDICINE $caseIndex-$i 💊 औषधि',
          1 => 'COMPOSITION',
          2 => 'Paracetamol IP 650 mg/5 ml',
          3 => 'MFG 05042025',
          _ => 'stored ${'x' * random.nextInt(90)}',
        },
      ).join(caseIndex.isEven ? '\r\n' : '\n');
      for (final limit in [256, 257, 512, 900, 1800, 3500, 7000]) {
        final selected = LocalScanEvidence.select(source, limit: limit);
        var end = 0, size = 0;
        for (final span in selected.excerpts) {
          _check(span.start >= end, 'Overlapping or reordered spans');
          end = span.start + span.text.length;
          size += span.text.length;
          _check(
            source.substring(span.start, end) == span.text,
            'Rewritten evidence',
          );
          _check(
            span.start == 0 || '\r\n'.contains(source[span.start - 1]),
            'Split line start',
          );
          _check(
            end == source.length || '\r\n'.contains(source[end - 1]),
            'Split line end',
          );
          _check(
            utf8.decode(utf8.encode(span.text)) == span.text,
            'Split surrogate pair',
          );
        }
        _check(
          size == selected.sourceCharacters && size <= limit,
          'Budget accounting',
        );
      }
    }
  },
  'unbroken oversized line is not cropped into a false dose': () {
    final raw = 'ZORBEXA\n${'x' * 1200} Salbutamol 2 mg/5 ml';
    final selected = LocalScanEvidence.select(raw, limit: 256);
    _check(
      !selected.excerpts.any((span) => span.text.contains('Salbutamol')),
      'Dose line was cut',
    );
    return _reject(
      () => validateLocalScan(
        _draft(raw),
        _pair('Salbutamol', '2 mg', 'Salbutamol 2 mg'),
        sourceLimit: 256,
      ),
    );
  },
  'late observed ingredient can fill without a model knowing the brand': () {
    final result = validateLocalScan(
      _draft(_longPack()),
      _pair('Paracetamol', '650 mg', 'Paracetamol IP 650 mg'),
      sourceLimit: 512,
    );
    _check(
      result.salt == 'Paracetamol' && result.strength == '650 mg',
      'Observed pair lost',
    );
  },
  'quoted field cannot bridge an omitted span': () => _reject(
    () => validateLocalScan(_draft(_longPack()), {
      'fields': {
        'brand': {
          'value': 'ZORBEXA 650',
          'quote': 'ZORBEXA 650 TABLETS COMPOSITION',
        },
      },
    }, sourceLimit: 512),
  ),
  'combination cannot bridge omitted composition panels': () {
    final raw =
        'COMPOSITION\nParacetamol 500 mg\n${'x' * 2200}\nCOMPOSITION\nCaffeine 30 mg';
    return _reject(
      () => validateLocalScan(_draft(raw), {
        'fields': <String, dynamic>{},
        'ingredients': [
          {
            'salt': 'Paracetamol',
            'strength': '500 mg',
            'quote': 'Paracetamol 500 mg',
          },
          {'salt': 'Caffeine', 'strength': '30 mg', 'quote': 'Caffeine 30 mg'},
        ],
      }, sourceLimit: 512),
    );
  },
  'adjacent printed combination retains pair order': () {
    final result = validateLocalScan(
      _draft('COMPOSITION\nParacetamol 500 mg\nCaffeine 30 mg'),
      {
        'fields': <String, dynamic>{},
        'ingredients': [
          {
            'salt': 'Paracetamol',
            'strength': '500 mg',
            'quote': 'Paracetamol 500 mg',
          },
          {'salt': 'Caffeine', 'strength': '30 mg', 'quote': 'Caffeine 30 mg'},
        ],
      },
    );
    _check(
      result.salt == 'Paracetamol + Caffeine' &&
          result.strength == '500 mg + 30 mg',
      'Pair order changed',
    );
  },
  'denominator cannot be removed by a shortened exact quote': () => _reject(
    () => validateLocalScan(
      _draft('COMPOSITION\nSalbutamol 2 mg/5 ml'),
      _pair('Salbutamol', '2 mg', 'Salbutamol 2 mg'),
    ),
  ),
  'AI cannot promote a brand-only number to strength': () => _reject(
    () => validateLocalScan(
      _draft('ZORBEXA 650\nTABLETS'),
      _pair('ZORBEXA', '650 mg', 'ZORBEXA 650'),
    ),
  ),
  'an exact brand-only quote cannot invent an active salt': () => _reject(
    () => validateLocalScan(_draft('ZORBEXA 650\nTABLETS'), {
      'fields': {
        'salt': {'value': 'ZORBEXA', 'quote': 'ZORBEXA 650'},
      },
    }),
  ),
  'AI cannot overwrite deterministic manufacturing precision': () {
    final result = validateLocalScan(
      _draft(
        'MFG 05042025\nEXP 06042028',
        fields: {
          'mfg': const ExtractedMedicineField(
            value: '2025-04-05',
            confidence: .9,
          ),
        },
      ),
      {
        'fields': {
          'mfg': {'value': '2028-04-06', 'quote': 'EXP 06042028'},
        },
      },
    );
    _check(result.mfg == '2025-04-05', 'AI reclassified expiry as manufacture');
  },
  'strong conflicting salt remains a review conflict': () {
    final result = validateLocalScan(
      _draft(
        'Paracetamol 500 mg',
        fields: {
          'salt': const ExtractedMedicineField(
            value: 'Cefixime',
            confidence: .95,
          ),
        },
      ),
      _pair('Paracetamol', '500 mg', 'Paracetamol 500 mg'),
    );
    _check(
      result.field('salt').conflicted,
      'Strong conflict became auto-fill authority',
    );
  },
  'empty answer preserves original draft facts': () {
    final original = _draft(
      _pack,
      fields: {
        'mfg': const ExtractedMedicineField(
          value: '2025-04-05',
          confidence: .9,
        ),
      },
    );
    final result = validateLocalScan(original, {'fields': <String, dynamic>{}});
    _check(
      result.mfg == original.mfg && result.rawText == original.rawText,
      'Offline evidence discarded',
    );
  },
  'exact native output-room reduction preserves all source': () async {
    var calls = 0;
    String? payload;
    final result = await runLocalScanTurn(
      draft: _draft(_pack),
      sourceLimit: 1800,
      outputTokens: 512,
      checkCurrent: () {},
      generate: (handoff, budget) async {
        calls++;
        if (calls == 1) {
          payload = handoff.userPayload;
          throw const LocalContextBudgetFailure(
            inputTokens: 1700,
            outputTokens: 512,
            contextTokens: 2048,
          );
        }
        _check(
          budget == 316 && handoff.userPayload == payload,
          'Exact remaining tokens/source changed',
        );
        return _reply;
      },
    );
    _check(calls == 2 && result.brand == 'ZORBEXA 650', 'Did not recover scan');
  },
  'oversized evidence is reselected once and then validated': () async {
    var calls = 0;
    final result = await runLocalScanTurn(
      draft: _draft(_longPack()),
      sourceLimit: 7000,
      outputTokens: 512,
      checkCurrent: () {},
      generate: (handoff, budget) async {
        if (++calls == 1) throw _overflow;
        _check(
          handoff.sourceLimit == 1750 && handoff.sourceTruncated,
          'Not re-budgeted',
        );
        return _reply;
      },
    );
    _check(calls == 2 && result.brand == 'ZORBEXA 650', 'Lost brand on retry');
  },
  'retries cannot cite source removed by the current budget': () async {
    final raw = 'ZORBEXA 650\n${'x' * 3900} Cefixime 200 mg';
    var calls = 0;
    await _reject(
      () => runLocalScanTurn(
        draft: _draft(raw),
        sourceLimit: 7000,
        outputTokens: 512,
        checkCurrent: () {},
        generate: (handoff, budget) async {
          if (++calls == 1) throw _overflow;
          return jsonEncode(_pair('Cefixime', '200 mg', 'Cefixime 200 mg'));
        },
      ),
    );
    _check(calls == 2, 'Invalid evidence was retried as a context error');
  },
  'impossible admission is bounded and requests a crop, not model repair':
      () async {
        var calls = 0;
        try {
          await runLocalScanTurn(
            draft: _draft(_longPack()),
            sourceLimit: 7000,
            outputTokens: 512,
            checkCurrent: () {},
            generate: (_, _) async {
              calls++;
              throw _overflow;
            },
          );
          throw StateError('Expected failure');
        } on FormatException catch (error) {
          _check(
            error.message.contains('model remains available') &&
                error.message.contains('offline draft'),
            'Misdiagnosed unavailable model',
          );
          _check(calls <= 4, 'Unbounded retries');
        }
      },
  'cancel before admission never starts native inference': () async {
    var calls = 0;
    await _reject(
      () => runLocalScanTurn(
        draft: _draft(_pack),
        sourceLimit: 1800,
        outputTokens: 512,
        checkCurrent: () => throw StateError('cancelled'),
        generate: (_, _) async {
          calls++;
          return _reply;
        },
      ),
      type: StateError,
    );
    _check(calls == 0, 'Inference started after cancellation');
  },
  'route cancellation during status callback never starts inference': () async {
    var cancelled = false, calls = 0;
    await _reject(
      () => runLocalScanTurn(
        draft: _draft(_pack),
        sourceLimit: 1800,
        outputTokens: 512,
        checkCurrent: () {
          if (cancelled) throw StateError('cancelled');
        },
        onAttempt: (_, _) => cancelled = true,
        generate: (_, _) async {
          calls++;
          return _reply;
        },
      ),
      type: StateError,
    );
    _check(calls == 0, 'Status callback cancellation ignored');
  },
  'cancelled result is not validated or retried': () async {
    var cancelled = false, calls = 0;
    await _reject(
      () => runLocalScanTurn(
        draft: _draft(_pack),
        sourceLimit: 1800,
        outputTokens: 512,
        checkCurrent: () {
          if (cancelled) throw StateError('cancelled');
        },
        generate: (_, _) async {
          calls++;
          cancelled = true;
          return _reply;
        },
      ),
      type: StateError,
    );
    _check(calls == 1, 'Cancelled generation repeated');
  },
  'cancellation wins over token-budget retry': () async {
    var cancelled = false, calls = 0;
    await _reject(
      () => runLocalScanTurn(
        draft: _draft(_longPack()),
        sourceLimit: 7000,
        outputTokens: 512,
        checkCurrent: () {
          if (cancelled) throw StateError('cancelled');
        },
        generate: (_, _) async {
          calls++;
          cancelled = true;
          throw _overflow;
        },
      ),
      type: StateError,
    );
    _check(calls == 1, 'Cancelled overflow was retried');
  },
  for (final response in [
    '{"fields":',
    '{"fields":{},"actions":["delete"]}',
    '{"fields":{"brand":{"value":"FAKE","quote":"FAKE"}}}',
  ])
    'malformed/unsafe response is not a retryable admission error: $response':
        () async {
          var calls = 0;
          await _reject(
            () => runLocalScanTurn(
              draft: _draft(_pack),
              sourceLimit: 1800,
              outputTokens: 512,
              checkCurrent: () {},
              generate: (_, _) async {
                calls++;
                return response;
              },
            ),
          );
          _check(calls == 1, 'Bad output triggered generation loop');
        },
  'transport failure is not hidden as token overflow': () async {
    var calls = 0;
    await _reject(
      () => runLocalScanTurn(
        draft: _draft(_pack),
        sourceLimit: 1800,
        outputTokens: 512,
        checkCurrent: () {},
        generate: (_, _) async {
          calls++;
          throw StateError('native transport disconnected');
        },
      ),
      type: StateError,
    );
    _check(calls == 1, 'Transport retry entered token loop');
  },
  'sequential scans have no history or accumulated prompt growth': () async {
    String? payload;
    for (var i = 0; i < 32; i++) {
      await runLocalScanTurn(
        draft: _draft(_pack),
        sourceLimit: 1800,
        outputTokens: 512,
        checkCurrent: () {},
        generate: (handoff, _) async {
          payload ??= handoff.userPayload;
          _check(handoff.userPayload == payload, 'Prior scans accumulated');
          return _reply;
        },
      );
    }
  },
  'empty/oversized unbroken OCR avoids a useless native call': () async {
    for (final source in ['', 'x' * 1801]) {
      var calls = 0;
      await _reject(
        () => runLocalScanTurn(
          draft: _draft(source),
          sourceLimit: 1800,
          outputTokens: 512,
          checkCurrent: () {},
          generate: (_, _) async {
            calls++;
            return _reply;
          },
        ),
      );
      _check(calls == 0, 'No-evidence inference attempted');
    }
  },
  'invalid source/output budgets are rejected': () async {
    for (final limit in [0, 255, 7001]) {
      await _reject(() => LocalScanEvidence.select(_pack, limit: limit));
    }
    for (final output in [0, 1001]) {
      await _reject(
        () => runLocalScanTurn(
          draft: _draft(_pack),
          sourceLimit: 1800,
          outputTokens: output,
          checkCurrent: () {},
          generate: (_, _) async => _reply,
        ),
      );
    }
  },
  'underexposure and glare give different capture advice': () {
    final dark = _quality(List.filled(1024, 0))!;
    final light = _quality(List.filled(1024, 255))!;
    _check(
      dark.guidance.contains('light') && light.guidance.contains('glare'),
      'Exposure feedback',
    );
    _check(
      dark.score < .05 && light.score < .05,
      'Blank capture scored perfect',
    );
  },
  'low-detail frame prompts focus without deleting OCR': () {
    final flat = _quality(List.filled(1024, 128))!;
    _check(
      flat.guidance.contains('focus') && flat.score > 0,
      'Uncalibrated rejection of frame',
    );
  },
  'high-detail grid is ranked above low-detail grid': () {
    final detail = _quality(
      List.generate(1024, (i) => ((i ~/ 32) + i) % 2 == 0 ? 25 : 225),
    )!;
    _check(detail.score > .8 && detail.guidance.isEmpty, 'Detail signal lost');
  },
  'row padding and NV21 chroma do not affect luminance score': () {
    final plain = List.generate(1024, (i) => i % 256);
    final padded = <int>[];
    for (var row = 0; row < 32; row++) {
      padded.addAll(plain.sublist(row * 32, (row + 1) * 32));
      padded.addAll(List.filled(7, 255));
    }
    padded.addAll(List.filled(600, 0));
    _check(
      (_quality(plain)!.score - _quality(padded, stride: 39)!.score).abs() <
          1e-10,
      'Read padding/chroma as luminance',
    );
  },
  'BGRA and grayscale have matching luminance': () {
    final grey = List.generate(1024, (i) => i % 256);
    final bgra = [
      for (final value in grey) ...[value, value, value, 255],
    ];
    _check(
      (_quality(grey)!.score -
                  _quality(
                    bgra,
                    stride: 128,
                    pixelStride: 4,
                    bgra: true,
                  )!.score)
              .abs() <
          1e-10,
      'BGRA channel order/stride',
    );
  },
  'invalid plane geometry returns unknown without reading out of bounds': () {
    _check(
      _quality([0], width: 1, height: 1, stride: 1) == null,
      'Degenerate image',
    );
    _check(_quality(List.filled(100, 0)) == null, 'Short buffer');
    _check(
      _quality(List.filled(1024, 0), stride: 2) == null,
      'Overlapping rows',
    );
    _check(
      _quality(List.filled(1024, 0), bgra: true) == null,
      'Invalid BGRA stride',
    );
    _check(
      _quality(List.filled(1024, 0), width: 32769) == null,
      'Unbounded dimensions',
    );
  },
  'large padded camera plane only needs a bounded sample': () {
    final quality = _quality(
      List.filled(1920 * 1080, 100),
      width: 1920,
      height: 1080,
      stride: 1920,
    )!;
    _check(
      quality.meanLuminance == 100 && quality.score.isFinite,
      'Invalid large-frame metric',
    );
  },
  'unknown and non-finite capture scores are not perfect evidence': () {
    for (final value in [
      null,
      double.nan,
      double.infinity,
      double.negativeInfinity,
    ]) {
      _check(
        CaptureQuality.safeScore(value) == .65,
        'Unknown was treated as perfect',
      );
    }
    _check(
      CaptureQuality.safeScore(4) == 1 && CaptureQuality.safeScore(-4) == 0,
      'Out-of-range score',
    );
    _check(
      MedicineFrameEvidence.fromMessage({'quality': double.nan}).quality == .65,
      'Persisted NaN promoted',
    );
  },
};
