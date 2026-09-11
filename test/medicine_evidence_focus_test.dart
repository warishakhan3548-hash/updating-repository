import 'package:flutter_test/flutter_test.dart';

import 'package:aaris_pharmacy/domain/medicine_evidence_focus.dart';
import 'package:aaris_pharmacy/domain/medicine_understanding.dart';

MedicineTextLineEvidence _line(
  String text,
  double top, {
  double left = 80,
  double width = 440,
  double height = 34,
}) => MedicineTextLineEvidence(
  text: text,
  left: left,
  top: top,
  width: width,
  height: height,
);

void main() {
  group('layout-aware medicine evidence focus', () {
    test('browser screenshot keeps Cefixime pack and rejects browser chrome', () {
      final raw = '''
11:59:05
Cafoli Lifecare
google.com/search
12gm/30ml Pedaking
Cefixime Oral Suspension IP
Cefzlora 50
WITH STERILE WATER FOR RECONSTITUTION
FOR PAEDIATRIC USE ONLY
''';
      final frame = MedicineFrameEvidence(
        text: raw,
        layoutLines: <MedicineTextLineEvidence>[
          _line('11:59:05', 18, left: 20, width: 150),
          _line('Cafoli Lifecare', 105, left: 25, width: 260),
          _line('google.com/search', 148, left: 20, width: 310),
          _line('12gm/30ml Pedaking', 470, left: 85, width: 260),
          _line('Cefixime Oral Suspension IP', 535, left: 80, width: 470),
          _line('Cefzlora 50', 610, left: 115, width: 270, height: 48),
          _line('WITH STERILE WATER FOR RECONSTITUTION', 680, width: 500),
          _line('FOR PAEDIATRIC USE ONLY', 730, width: 430),
        ],
      );

      final focused = focusMedicineFrameEvidence(frame);
      final value = focused.text.toLowerCase();
      expect(value, contains('cefixime oral suspension ip'));
      expect(value, contains('cefzlora 50'));
      expect(value, isNot(contains('google.com')));
      expect(value, isNot(contains('cafoli lifecare')));
      expect(value, isNot(contains('11:59:05')));
      expect(value, isNot(contains('12gm/30ml')));
      // Decision filtering never mutates the raw evidence object.
      expect(frame.text, contains('google.com/search'));
      expect(frame.text, contains('12gm/30ml Pedaking'));
    });

    test('YouTube screenshot keeps Metrogyl composition and drops UI/promotional text', () {
      final frame = MedicineFrameEvidence(
        text: '''
Shorts
Metrogyl use karne ke fayde
Subscribe
METRONIDAZOLE TABLETS IP 400 mg
metrogyl 400
15 Tablets
Share
Save
''',
        layoutLines: <MedicineTextLineEvidence>[
          _line('Shorts', 40, left: 30, width: 100),
          _line('Metrogyl use karne ke fayde', 150, left: 35, width: 520, height: 52),
          _line('Subscribe', 260, left: 450, width: 140),
          _line('METRONIDAZOLE TABLETS IP 400 mg', 505, width: 500),
          _line('metrogyl 400', 575, left: 120, width: 300, height: 50),
          _line('15 Tablets', 640, left: 390, width: 150),
          _line('Share', 850, left: 520, width: 100),
          _line('Save', 930, left: 520, width: 100),
        ],
      );

      final focused = focusMedicineFrameEvidence(frame).text.toLowerCase();
      expect(focused, contains('metronidazole tablets ip 400 mg'));
      expect(focused, contains('metrogyl 400'));
      expect(focused, isNot(contains('subscribe')));
      expect(focused, isNot(contains('fayde')));
      expect(focused, isNot(contains('share')));
    });

    test('raw and focused channels remain explicitly separable', () {
      final combined = composeRawAndFocusedOcr(
        rawOcr: 'google.com/search\nPARACETAM0L\n650 MG',
        focusedEvidence: 'PARACETAM0L\n650 MG',
      );
      expect(rawOcrTextFromDraft(combined), contains('google.com/search'));
      expect(medicineDecisionTextFromDraft(combined), isNot(contains('google.com')));
      expect(medicineDecisionTextFromDraft(combined), contains('PARACETAM0L'));
    });

    test('structured text without geometry is not screenshot-filtered', () {
      const frame = MedicineFrameEvidence(
        text: 'Paracetamol 500 mg Tablet',
        startsNewItem: true,
      );
      expect(focusMedicineFrameEvidence(frame).text, frame.text);
    });
  });
}
