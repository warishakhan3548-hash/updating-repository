// Executes the real recognition policy; requires crypto and platform import
// declarations. Native IO is deliberately not called by these fixtures.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import '../lib/domain/medicine.dart';
import '../lib/domain/medicine_understanding.dart';
import '../lib/services/offline_recognition_memory_service.dart';

var passed = 0;
void check(bool value, String label) {
  if (!value) throw StateError(label);
  passed++;
}

MedicineKnowledgeEntry entry(
  String strength, {
  String form = 'Tablet',
  String barcode = '1111111111111',
}) => MedicineKnowledgeEntry(
  name: 'Dolo',
  brand: 'Dolo',
  salt: 'Paracetamol',
  strength: strength,
  form: form,
  barcode: barcode,
);
String key(MedicineKnowledgeEntry entry) => recognitionIdentityKey(
  name: entry.name,
  brand: entry.brand,
  salt: entry.salt,
  strength: entry.strength,
  form: entry.form,
);
MedicineFrameEvidence frame(
  String text, {
  String barcode = '',
  int sequence = 0,
}) => MedicineFrameEvidence(
  sequence: sequence,
  quality: .95,
  text: text,
  barcode: barcode,
);
Set<String> compatible(
  List<MedicineKnowledgeEntry> entries,
  List<MedicineFrameEvidence> frames,
) => recognitionVariantCompatibleIdentityKeys(
  alias: 'D0L0',
  candidates: entries,
  evidence: frames,
);
void main() {
  try {
    final adult = entry('500 mg');
    final child = entry(
      '125 mg/5 ml',
      form: 'Suspension',
      barcode: '2222222222222',
    );
    check(
      compatible(
            [adult, child],
            [frame('D0L0\n125 mg/5 ml\nSUSPENSION')],
          ).single ==
          key(child),
      'Full concentration and form resolve child variant',
    );
    check(
      compatible([adult, child], [frame('D0L0')]).length == 2,
      'No variant clue leaves ambiguity',
    );
    check(
      compatible(
            [adult, child],
            [
              frame('D0L0'),
              frame('OTHER BRAND\n125 mg/5 ml\nSUSPENSION', sequence: 1),
            ],
          ).length ==
          2,
      'Other medicine cannot contribute variant clues',
    );
    check(
      compatible(
        [adult, child],
        [frame('D0L0\n125 mg/5 ml\nSUSPENSION', barcode: adult.barcode)],
      ).isEmpty,
      'Contradictory barcode and strength abstain',
    );
    check(
      compatible(
            [adult, child],
            [frame('D0L0', barcode: adult.barcode)],
          ).single ==
          key(adult),
      'Exact barcode with no contradictory text works',
    );
    check(
      compatible([adult], [frame('D0L0\n650 mg\nTABLETS')]).isEmpty,
      'A sole saved candidate still rejects another dose',
    );
    check(
      compatible([adult], [frame('D0L0\n500 mg\nCAPSULES')]).isEmpty,
      'A sole saved candidate still rejects another form',
    );
    check(
      compatible([adult], [frame('OTHER BRAND\n500 mg')]).isEmpty,
      'Alias must actually occur',
    );
    check(
      compatible(
        [adult, child],
        [
          frame('D0L0\n500 mg\nTABLETS'),
          frame('D0L0\n125 mg/5 ml\nSUSPENSION', sequence: 1),
        ],
      ).isEmpty,
      'Same alias on two products cannot teach one global correction',
    );
    check(
      compatible(
        [adult],
        [frame('D0L0\n500 mg'), frame('D0L0\n650 mg', sequence: 1)],
      ).isEmpty,
      'Later contradictory frame invalidates sole candidate',
    );
    check(
      compatible(
            [adult],
            [frame('D0L0\n500 mg'), frame('D0L0\n500 mg', sequence: 1)],
          ).single ==
          key(adult),
      'Repeated consistent evidence remains usable',
    );
    check(
      compatible([entry('125 mg')], [frame('D0L0\n125 mg/5 ml')]).isEmpty,
      'Concentration cannot match just numerator',
    );
    check(
      compatible([entry('1%')], [frame('D0L0\n2%')]).isEmpty,
      'Different percentages reject',
    );
    check(
      compatible([entry('1%')], [frame('D0L0\n1%')]).length == 1,
      'Same percentage supports',
    );
    check(
      compatible([entry('50 mcg')], [frame('D0L0\n50 µg')]).length == 1,
      'Microgram spelling is normalized',
    );
    check(
      compatible(
            [child],
            [frame('D0L0\n125 mg/5 ml\n100 ml\nSUSPENSION')],
          ).length ==
          1,
      'Bottle volume does not replace ingredient concentration',
    );
    check(
      compatible([entry('500 mg')], [frame('D0L0\n500 mg + 65 mg')]).isEmpty,
      'Combination evidence cannot become one ingredient',
    );
    check(
      compatible(
            [entry('500 mg + 65 mg')],
            [frame('D0L0\n500 mg + 65 mg')],
          ).length ==
          1,
      'Complete matching combination is retained',
    );
    check(
      key(entry('2 mg/5 ml')) != key(entry('2 mg + 5 ml')),
      'Memory identity preserves concentration versus combination',
    );
    check(
      key(entry('1%')) != key(entry('1')),
      'Memory identity preserves percentage',
    );
    check(
      key(entry('50 µg')) == key(entry('50 mcg')),
      'Memory microgram spelling has one key',
    );
    check(
      key(adult) ==
          sha256
              .convert(utf8.encode('dolo|dolo|paracetamol|500mg|tablet'))
              .toString(),
      'Ordinary existing memory keeps its key',
    );
    final hindi = recognitionIdentityKey(
      name: 'औषधि',
      brand: 'देसी',
      salt: '',
      strength: '',
      form: 'Tablet',
    );
    check(
      hindi == sha256.convert(utf8.encode('औषधि|देसी|||tablet')).toString(),
      'Hindi identity uses complete UTF-8 bytes',
    );
    final rows = [
      {
        'identity_key': 'a',
        'alias': 'D0L0',
        'normalized_alias': 'd0l0',
        'support': 3,
        'last_confirmed': 1,
      },
      {
        'identity_key': 'b',
        'alias': 'D0L0',
        'normalized_alias': 'd0l0',
        'support': 1,
        'last_confirmed': 1,
      },
    ];
    check(
      completeRecognitionAliasGroups(rows, {'d0l0': 2}).length == 1,
      'Complete collision groups remain visible',
    );
    check(
      completeRecognitionAliasGroups(rows.take(1).toList(), {
        'd0l0': 2,
      }).isEmpty,
      'Truncated collision cannot masquerade as unique',
    );
    final draft = MedicineScanDraft(
      fields: const {
        'brand': ExtractedMedicineField(
          value: 'D0L0',
          confidence: .8,
          support: 1,
        ),
      },
      rawText: 'D0L0\nParacetamol 500 mg',
      searchKeywords: '',
      frameSequences: const [0],
      overallConfidence: .8,
    );
    final medicine = Medicine(
      id: 'a',
      name: 'Dolo',
      brand: 'Dolo',
      salt: 'Paracetamol',
      strength: '500 mg',
      form: 'Tablet',
    );
    check(
      deriveLearnableIdentityAliases(draft, medicine).contains('d0l0'),
      'Explicit OCR correction is still learnable',
    );
    stdout.writeln('Recognition memory policy: $passed passed.');
  } catch (error, stack) {
    stderr.writeln('$error\n$stack');
    exitCode = 1;
  }
}
