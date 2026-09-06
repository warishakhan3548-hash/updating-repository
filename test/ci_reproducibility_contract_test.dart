import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('APK workflow builds the exact committed application source', () {
    final workflow = File(
      '.github/workflows/aarish-kingdom-apk.yml',
    ).readAsStringSync();

    expect(workflow, contains('Verify committed architecture invariants'));
    expect(workflow, isNot(contains('final_voice_architecture_patch.py')));
    expect(workflow, isNot(contains('final_contract_alignment_patch.py')));
    expect(workflow, isNot(contains('final_patch_compat.py')));
    expect(workflow, isNot(contains('Persist validated architecture source')));
    expect(workflow, contains('flutter test'));
    expect(workflow, contains('flutter analyze'));
    expect(workflow, contains('flutter build apk --release'));
    expect(workflow, contains('Publish latest APK as GitHub Release'));
  });
}
