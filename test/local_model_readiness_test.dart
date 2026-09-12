import 'package:aaris_pharmacy/domain/local_model.dart';
import 'package:flutter_test/flutter_test.dart';

InstalledLocalModel model({required bool loaded, required bool scanTested}) =>
    InstalledLocalModel(
      id: 'a' * 64,
      label: 'Qwen2.5-0.5B.gguf',
      bytes: 339 * 1024 * 1024,
      loadTestPassed: loaded,
      smokeTestPassed: scanTested,
    );

void main() {
  test(
    'Scan admission follows native load; extraction verification is advisory',
    () {
      final installedOnly = model(loaded: false, scanTested: false);
      expect(
        isLocalModelReady(model: installedOnly, activeId: installedOnly.id),
        isFalse,
      );
      expect(
        isLocalModelScanReady(model: installedOnly, activeId: installedOnly.id),
        isFalse,
      );

      final chatReady = model(loaded: true, scanTested: false);
      expect(
        isLocalModelReady(model: chatReady, activeId: chatReady.id),
        isTrue,
      );
      expect(
        isLocalModelScanReady(model: chatReady, activeId: chatReady.id),
        isTrue,
      );
      expect(
        isLocalModelScanVerified(model: chatReady, activeId: chatReady.id),
        isFalse,
      );

      final verified = model(loaded: true, scanTested: true);
      expect(isLocalModelReady(model: verified, activeId: null), isFalse);
      expect(isLocalModelReady(model: verified, activeId: 'b' * 64), isFalse);
      expect(isLocalModelReady(model: verified, activeId: verified.id), isTrue);
      expect(
        isLocalModelScanReady(model: verified, activeId: verified.id),
        isTrue,
      );
      expect(
        isLocalModelScanVerified(model: verified, activeId: verified.id),
        isTrue,
      );
    },
  );

  test('Old smoke-tested manifests migrate as chat-ready', () {
    final legacy = InstalledLocalModel.fromJson({
      'id': 'b' * 64,
      'label': 'Legacy.gguf',
      'bytes': 4096,
      'smokeTestPassed': true,
    });
    expect(legacy.loadTestPassed, isTrue);
    expect(legacy.smokeTestPassed, isTrue);
  });
}
