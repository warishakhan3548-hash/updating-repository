// Pure Dart regression fixtures. No model, network, Flutter runner or APK.
import 'dart:io';

import '../lib/domain/local_ai_protocol.dart';
import '../lib/domain/medicine_resolution_v2.dart';
import '../lib/domain/medicine_scan_commit.dart';
import '../lib/domain/medicine_understanding.dart';

var passed = 0, failed = 0;

void check(bool value, String label) {
  if (value) {
    passed++;
  } else {
    failed++;
    stderr.writeln('FAIL: $label');
  }
}

void rejects(void Function() action, String label) {
  try {
    action();
    check(false, label);
  } on FormatException {
    check(true, label);
  }
}

MedicineScanDraft draft(String source, {String? strength}) => MedicineScanDraft(
  fields: strength == null
      ? const {}
      : {
          for (final entry in {
            'brand': 'Sample',
            'salt': 'Paracetamol',
            'strength': strength,
            'form': 'Tablet',
          }.entries)
            entry.key: ExtractedMedicineField(
              value: entry.value,
              confidence: .95,
              support: 2,
              conflicted: false,
            ),
        },
  rawText: source,
  searchKeywords: '',
  frameSequences: const [0],
  overallConfidence: .95,
);

Map<String, dynamic> ingredient(String salt, String strength, String quote) => {
  'fields': <String, dynamic>{},
  'ingredients': [
    {'salt': salt, 'strength': strength, 'quote': quote},
  ],
};

void main() {
  for (final source in [
    'DOLOMET TABLETS',
    'DOLO-PLUS TABLETS',
    'PREDOLO TABLETS',
  ]) {
    rejects(
      () => validateLocalScan(draft(source), {
        'fields': {
          'brand': {'value': 'DOLO', 'quote': 'DOLO'},
        },
      }),
      'Short brand quote cannot certify $source',
    );
  }
  final brand = validateLocalScan(draft('Brand: DOLO\nTABLETS'), {
    'fields': {
      'brand': {'value': 'DOLO', 'quote': 'DOLO'},
    },
  });
  check(
    brand.brand == 'DOLO' && !brand.field('brand').conflicted,
    'Complete brand token remains usable',
  );
  final repeated = validateLocalScan(draft('DOLOMET\nBrand: DOLO\nTABLETS'), {
    'fields': {
      'brand': {'value': 'DOLO', 'quote': 'DOLO'},
    },
  });
  check(repeated.brand == 'DOLO', 'Find a later complete source occurrence');
  rejects(
    () => validateLocalScan(draft('DOLO-PLUS TABLETS'), {
      'fields': {
        'brand': {'value': 'DOLO', 'quote': 'DOLO-PLUS TABLETS'},
      },
    }),
    'A longer quote cannot hide a shortened product name',
  );

  rejects(
    () => validateLocalScan(
      draft('Notparacetamol IP 500 mg'),
      ingredient('Paracetamol', '500 mg', 'paracetamol IP 500 mg'),
    ),
    'An ingredient quote cannot cut through a different ingredient name',
  );

  for (final dose in [
    '2 mg/5 ml',
    '1% w/v',
    '50 µg',
    '50 μg',
    '40 units/ml',
    '0.5 mg',
    '0,125 mg',
    '2,5 mg',
    '5 mg/dose',
    '5 mg/actuation',
  ]) {
    final source = 'Paracetamol IP $dose';
    try {
      final result = validateLocalScan(
        draft(source),
        ingredient('Paracetamol', dose, source),
      );
      check(
        result.strength == dose && !result.field('strength').conflicted,
        'Preserve full printed dose $dose',
      );
    } on FormatException {
      check(false, 'Valid complete dose rejected: $dose');
    }
  }

  for (final example in [
    ('2 mg/5 ml', '2 mg'),
    ('1% w/v', '1%'),
    ('5 mg/dose', '5 mg'),
    ('5 mgood', '5 mg'),
    ('0.5 mg', '5 mg'),
  ]) {
    rejects(
      () => validateLocalScan(
        draft('Paracetamol IP ${example.$1}'),
        ingredient('Paracetamol', example.$2, 'Paracetamol IP ${example.$2}'),
      ),
      'Shortened/invalid dose ${example.$2} cannot certify ${example.$1}',
    );
  }

  // The final add gate must check the entire value, not one regex substring.
  for (final dose in [
    'unknown 500 mg',
    '500 mg guessed',
    '500 mgood',
    '5 mg/unknown',
    '5 mg/0 ml',
    '0 mg',
    '-5 mg',
    '.5 mg',
    '1,000 mg',
    '5 mg/1,000 ml',
    '500 mg +',
    '+ 500 mg',
  ]) {
    check(
      !scanQuickIdentityReady(draft('Sample TABLETS', strength: dose)),
      'Manual review required for invalid strength $dose',
    );
  }
  for (final dose in [
    '500 mg',
    '50 µg',
    '50 μg',
    '40 units/ml',
    '1% w/v',
    '5 mg/dose',
    '0.5 mg',
  ]) {
    check(
      scanQuickIdentityReady(draft('Sample TABLETS', strength: dose)),
      'Complete identity remains ready: $dose',
    );
  }

  for (final dose in ['.5 mg', '500 mgood', '5 mg/unknown', '1,000 mg']) {
    final evidence = [
      MedicineFrameEvidence(
        text: 'Brand: Sample\nTABLETS\nComposition:\nParacetamol IP $dose',
        source: 'lexical regression',
      ),
    ];
    final engines = [
      const MedicineUnderstandingEngine().understand(evidence),
      MedicineUnderstandingResult.fromMessage(
        understandMedicineEvidenceV2Message({
          'evidence': evidence.map((frame) => frame.toMessage()).toList(),
        }),
      ),
    ];
    for (var i = 0; i < engines.length; i++) {
      check(
        engines[i].drafts.every(
          (item) =>
              item.strength.isEmpty ||
              (dose == '1,000 mg' &&
                  item.strength.replaceAll(' ', '') == '1000mg') ||
              item.field('strength').conflicted ||
              item.field('strength').confidence < .78,
        ),
        'Engine $i cannot confidently truncate $dose',
      );
    }
  }

  CanonicalMedicineProduct product(String strength) => CanonicalMedicineProduct(
    productId: 'same',
    revision: 1,
    brand: 'Sample',
    salt: 'Sample ingredient',
    strength: strength,
    form: 'Solution',
  );
  check(
    product('5 mg/5 ml').fingerprint != product('5 mg + 5 ml').fingerprint,
    'Concentration and combination identities stay distinct',
  );
  check(
    product('1%').fingerprint != product('1').fingerprint,
    'Percent marker survives catalogue identity',
  );
  check(
    product('50 µg').fingerprint == product('50 mcg').fingerprint,
    'Microgram spellings share identity',
  );
  check(
    product('0.5 mg').fingerprint != product('5 mg').fingerprint,
    'Decimal strength is never a whole-number dose',
  );

  final dated = MedicineScanDraft(
    fields: const {
      'expiry': ExtractedMedicineField(
        value: '2028-06',
        confidence: .95,
        support: 2,
        conflicted: false,
      ),
    },
    rawText: 'EXP 06/2028 MFG 06/2026',
    searchKeywords: '',
    frameSequences: const [0],
    expiryMonthOnly: true,
  );
  final checked = validateLocalScan(dated, {
    'fields': {
      'expiry': {'value': '2026-06', 'quote': '06/2026'},
    },
  });
  check(
    checked.field('expiry').value == '2028-06' && checked.expiryMonthOnly,
    'AI cannot replace deterministic expiry or month precision',
  );

  stdout.writeln('Scan accuracy: $passed passed, $failed failed.');
  if (failed != 0) exitCode = 1;
}
