import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('backup transfer is file-only and disk-backed', () {
    final ui = File('lib/ui/backup_screen.dart').readAsStringSync();
    final service = File('lib/services/backup_service.dart').readAsStringSync();
    final codec = File(
      'lib/services/backup_file_codec.dart',
    ).readAsStringSync();
    final android = File(
      'android/app/src/main/kotlin/com/aaris/pharmacy/MainActivity.kt',
    ).readAsStringSync();

    expect(ui, contains("'Import backup file'"));
    expect(ui, contains("'Next'"));
    expect(ui, isNot(contains('content_paste_rounded')));
    expect(ui, isNot(contains('Aaris Pharmacy backup JSON')));
    expect(ui, isNot(contains('TextEditingController')));

    expect(service, contains("'saveBackupToDownloads'"));
    expect(service, contains("'pickBackupFile'"));
    expect(service, contains('PortableBackupCodec.write'));
    expect(service, contains('PortableBackupCodec.read'));

    expect(codec, contains("aaris.pharmacy.portable.v3"));
    expect(codec, contains("sha256-chain:"));
    expect(codec, contains('openRead()'));

    expect(android, contains('"saveBackupToDownloads"'));
    expect(android, contains('"pickBackupFile"'));
    expect(android, contains('MediaStore.Downloads.EXTERNAL_CONTENT_URI'));
    expect(android, contains('File(cacheDir, "pharmacy_backup_imports")'));
    expect(android, isNot(contains('output.size() > 12_000_000')));
  });
}
