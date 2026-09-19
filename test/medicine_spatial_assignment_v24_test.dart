import 'package:aaris_pharmacy/domain/medicine_understanding.dart';
import 'package:aaris_pharmacy/domain/spatial_traceability.dart';
import 'package:flutter_test/flutter_test.dart';

MedicineTextLineEvidence _line(
  String text, {
  required double left,
  required double top,
  double width = 50,
  double height = 12,
}) => MedicineTextLineEvidence(
  text: text,
  left: left,
  top: top,
  width: width,
  height: height,
);

void main() {
  group('spatial traceability assignment V24', () {
    test('maximum-weight assignment prevents greedy MFG/EXP inversion', () {
      final result = inferSpatialTraceability(<MedicineFrameEvidence>[
        MedicineFrameEvidence(
          text: 'MFG\nEXP\n04/2026\n04/2028',
          quality: 1,
          layoutLines: <MedicineTextLineEvidence>[
            _line('MFG', left: 0, top: 0, width: 30),
            _line('EXP', left: 100, top: 0, width: 30),
            _line('04/2026', left: 73, top: 0),
            _line('04/2028', left: 166, top: 0),
          ],
        ),
      ]);

      // Greedy confidence ordering chooses EXP->04/2026 first and is then
      // forced to assign MFG->04/2028. The globally optimal one-to-one pairing
      // is MFG->04/2026 plus EXP->04/2028.
      expect(result.mfg?.value, '2026-04');
      expect(result.expiry?.value, '2028-04');
      expect(result.mfg?.conflicted, isFalse);
      expect(result.expiry?.conflicted, isFalse);
    });

    test('duplicate print inside one frame is one support observation', () {
      final result = inferSpatialTraceability(<MedicineFrameEvidence>[
        MedicineFrameEvidence(
          text: 'EXP 04/2028\nEXP 04/2028\nEXP 04/2028',
          quality: .96,
          layoutLines: <MedicineTextLineEvidence>[
            _line('EXP 04/2028', left: 0, top: 0, width: 95),
            _line('EXP 04/2028', left: 0, top: 20, width: 95),
            _line('EXP 04/2028', left: 0, top: 40, width: 95),
          ],
        ),
      ]);

      expect(result.expiry?.value, '2028-04');
      expect(result.expiry?.support, 1);
      expect(result.expiry?.conflicted, isFalse);
    });
  });
}
