import 'package:aaris_pharmacy/domain/app_brain.dart';
import 'package:aaris_pharmacy/domain/medicine_brief.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Aaris Brain human field-edit routing', () {
    test('routes natural field corrections into exact medicine editing', () {
      final expiry = parseAppBrainIntent('Dolo 650 expiry change karo');
      expect(expiry.action, AppBrainAction.editMedicine);
      expect(expiry.query, 'Dolo 650');

      final batch = parseAppBrainIntent('Dolo 650 batch number update karo');
      expect(batch.action, AppBrainAction.editMedicine);
      expect(batch.query, 'Dolo 650');

      final price = parseAppBrainIntent('Dolo 650 price correct karo');
      expect(price.action, AppBrainAction.editMedicine);
      expect(price.query, 'Dolo 650');

      final hindi = parseAppBrainIntent('Dolo 650 एक्सपायरी बदल दो');
      expect(hindi.action, AppBrainAction.editMedicine);
      expect(hindi.query, 'Dolo 650');
    });

    test(
      'contextual field edit can reuse only the exact remembered target',
      () {
        final intent = parseAppBrainIntent('isko expiry update karo');
        expect(intent.action, AppBrainAction.editMedicine);
        expect(intent.query, 'isko');
        expect(isAppBrainContextReference(intent.query), isTrue);
        expect(intent.canUseImplicitExactContext, isTrue);
      },
    );

    test('read-only expiry question stays read-only', () {
      final intent = parseAppBrainIntent('Dolo 650 expiry kab hai');
      expect(intent.action, AppBrainAction.search);
      expect(intent.briefFocus, MedicineBriefFocus.expiry);
      expect(intent.query, 'Dolo 650');
    });

    test('stock quantity and location retain their specialized operations', () {
      final quantity = parseAppBrainIntent('Dolo 650 quantity 20 set karo');
      expect(quantity.action, AppBrainAction.setQuantity);
      expect(quantity.quantity, 20);

      final location = parseAppBrainIntent('Dolo 650 location Rack C set karo');
      expect(location.action, AppBrainAction.relocateMedicine);
      expect(location.locationPatch?.location, 'Rack C');
    });

    test('negative deferred and compound field edits fail closed', () {
      final negative = parseAppBrainIntent("don't change Dolo 650 expiry");
      expect(negative.action, AppBrainAction.safetyBlocked);
      expect(negative.safetyReason, AppBrainSafetyReason.negatedMutation);

      final deferred = parseAppBrainIntent('kal Dolo 650 expiry update karo');
      expect(deferred.action, AppBrainAction.safetyBlocked);
      expect(deferred.safetyReason, AppBrainSafetyReason.deferredMutation);

      final compound = parseAppBrainIntent(
        'Dolo 650 expiry change karo then remove Dolo 650',
      );
      expect(compound.action, AppBrainAction.safetyBlocked);
      expect(compound.safetyReason, AppBrainSafetyReason.compoundMutation);
    });
  });
}
