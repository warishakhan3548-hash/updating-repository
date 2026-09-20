import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('release build never falls back to debug signing', () {
    final gradle = File('android/app/build.gradle.kts').readAsStringSync();

    expect(gradle, contains('CM_KEYSTORE_PATH'));
    expect(gradle, contains('CM_KEYSTORE_PASSWORD'));
    expect(gradle, contains('CM_KEY_ALIAS'));
    expect(gradle, contains('CM_KEY_PASSWORD'));
    expect(gradle, contains('signingConfigs.getByName("release")'));
    expect(gradle, contains('Permanent release signing credentials are missing'));
    expect(
      gradle,
      isNot(contains('signingConfig = signingConfigs.getByName("debug")')),
    );
  });

  test('Codemagic release locks the permanent certificate and builds APK plus AAB', () {
    final yaml = File('codemagic.yaml').readAsStringSync();

    expect(yaml, contains('aaris_permanent'));
    expect(yaml, contains('EXPECTED_KEY_ALIAS: "upload"'));
    expect(
      yaml,
      contains(
        'EXPECTED_SIGNING_SHA256: "330D1611849C7C9B1F9F592C458932F25AE6F3ABA1BC7E8ABFBC9E6868EF004F"',
      ),
    );
    expect(yaml, contains('flutter build apk --release'));
    expect(yaml, contains('flutter build appbundle --release'));
    expect(yaml, contains('PROJECT_BUILD_NUMBER + RELEASE_BUILD_OFFSET'));
  });

  test('private signing files remain excluded from Git', () {
    final ignore = File('.gitignore').readAsStringSync();

    expect(ignore, contains('android/key.properties'));
    expect(ignore, contains('*.jks'));
    expect(ignore, contains('*.keystore'));
  });
}
