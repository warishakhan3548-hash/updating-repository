import 'package:aaris_pharmacy/domain/local_model.dart';
import 'package:flutter_test/flutter_test.dart';

InstalledLocalModel model({required bool tested}) => InstalledLocalModel(
  id: 'a' * 64,
  label: 'Qwen2.5-0.5B.gguf',
  bytes: 339 * 1024 * 1024,
  smokeTestPassed: tested,
);

void main() {
  test(
    'Ready requires both active selection and passed on-device setup test',
    () {
      final downloadedOnly = model(tested: false);
      expect(
        isLocalModelReady(model: downloadedOnly, activeId: downloadedOnly.id),
        isFalse,
      );

      final tested = model(tested: true);
      expect(isLocalModelReady(model: tested, activeId: null), isFalse);
      expect(isLocalModelReady(model: tested, activeId: 'b' * 64), isFalse);
      expect(isLocalModelReady(model: tested, activeId: tested.id), isTrue);
    },
  );
}
