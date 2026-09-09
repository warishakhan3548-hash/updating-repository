import 'package:aaris_pharmacy/domain/pharmacy_brain.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('PharmacyBrain', () {
    test('routes explicit delete to destructive reviewed stock workflow', () {
      final plan = PharmacyBrain.understand('Dolo 650 delete kar do');

      expect(plan.intent, PharmacyBrainIntent.removeMedicine);
      expect(plan.query, 'dolo 650');
      expect(plan.risk, PharmacyBrainRisk.destructive);
      expect(plan.confidence, greaterThanOrEqualTo(.95));
    });

    test('understands Hindi delete command and medicine alias', () {
      final plan = PharmacyBrain.understand('इस डोलो 650 को हटा दो');

      expect(plan.intent, PharmacyBrainIntent.removeMedicine);
      expect(plan.query, 'dolo 650');
      expect(plan.risk, PharmacyBrainRisk.destructive);
    });

    test('routes sold command without treating it as sold-list browsing', () {
      final plan = PharmacyBrain.understand('Dolo 650 sold kar do');

      expect(plan.intent, PharmacyBrainIntent.sellMedicine);
      expect(plan.query, 'dolo 650');
      expect(plan.risk, PharmacyBrainRisk.reviewRequired);
    });

    test('routes edit command to exact medicine workflow', () {
      final plan = PharmacyBrain.understand('Paracetamol 500 edit karo');

      expect(plan.intent, PharmacyBrainIntent.editMedicine);
      expect(plan.query, 'paracetamol 500');
      expect(plan.risk, PharmacyBrainRisk.reviewRequired);
    });

    test('opens expiry and sold scopes deterministically', () {
      expect(
        PharmacyBrain.understand('expired medicines dikhao').intent,
        PharmacyBrainIntent.showExpired,
      );
      expect(
        PharmacyBrain.understand('short expiry medicines').intent,
        PharmacyBrainIntent.showShortExpiry,
      );
      expect(
        PharmacyBrain.understand('month expiry medicines').intent,
        PharmacyBrainIntent.showMonthExpiry,
      );
      expect(
        PharmacyBrain.understand('sold medicines dikhao').intent,
        PharmacyBrainIntent.showSold,
      );
    });

    test('opens operational tools locally', () {
      expect(
        PharmacyBrain.understand('scan karo').intent,
        PharmacyBrainIntent.scanMedicine,
      );
      expect(
        PharmacyBrain.understand('add medicine').intent,
        PharmacyBrainIntent.addMedicine,
      );
      expect(
        PharmacyBrain.understand('backup kholo').intent,
        PharmacyBrainIntent.openBackup,
      );
      expect(
        PharmacyBrain.understand('reorder list kholo').intent,
        PharmacyBrainIntent.openOrders,
      );
    });

    test('compact medicine phrase becomes local database lookup', () {
      final plan = PharmacyBrain.understand('Drotaverine 80 mg');

      expect(plan.intent, PharmacyBrainIntent.findMedicine);
      expect(plan.query, 'drotaverine 80mg');
      expect(plan.risk, PharmacyBrainRisk.readOnly);
    });

    test('questions do not accidentally become stock actions', () {
      final plan = PharmacyBrain.understand('Paracetamol kya hai?');

      expect(plan.intent, PharmacyBrainIntent.none);
      expect(plan.handled, isFalse);
    });
  });
}
