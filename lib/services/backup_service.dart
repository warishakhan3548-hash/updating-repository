import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../domain/backup.dart';

class BackupService {
  static const _channel = MethodChannel('com.aaris.pharmacy/documents');

  Future<void> share(PharmacyBackup backup) async {
    final encoded = backup.encode();
    await SharePlus.instance.share(
      ShareParams(
        title: 'Aaris Pharmacy backup',
        text:
            'Aaris Pharmacy backup created ${backup.createdAt.toIso8601String()}. Keep this private.',
        files: [
          XFile.fromData(utf8.encode(encoded), mimeType: 'application/json'),
        ],
        fileNameOverrides: [backup.fileName],
      ),
    );
  }

  Future<String?> pickBackupText() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return null;
    return _channel.invokeMethod<String>('pickTextDocument');
  }
}
