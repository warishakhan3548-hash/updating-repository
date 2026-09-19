import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../domain/backup.dart';
import 'backup_file_codec.dart';

class BackupFileReference {
  const BackupFileReference({
    required this.path,
    required this.name,
    required this.sizeBytes,
  });

  final String path;
  final String name;
  final int sizeBytes;
}

class BackupExportResult {
  const BackupExportResult({
    required this.fileName,
    required this.sizeBytes,
    required this.savedLocation,
    required this.shareOpened,
    this.warning,
  });

  final String fileName;
  final int sizeBytes;
  final String? savedLocation;
  final bool shareOpened;
  final String? warning;
}

class BackupService {
  static const _channel = MethodChannel('com.aaris.pharmacy/documents');

  Future<BackupExportResult> exportAndShare(PharmacyBackup backup) async {
    final root = await getTemporaryDirectory();
    final directory = Directory('${root.path}/pharmacy_backups');
    await directory.create(recursive: true);
    await _prune(directory);

    final fileName = _portableFileName(backup.createdAt);
    final file = File('${directory.path}/$fileName');
    final sizeBytes = await PortableBackupCodec.write(file, backup);

    String? savedLocation;
    Object? saveError;
    try {
      if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
        final saved = await _channel.invokeMapMethod<String, dynamic>(
          'saveBackupToDownloads',
          <String, dynamic>{
            'path': file.path,
            'fileName': fileName,
          },
        );
        savedLocation = saved?['location']?.toString();
      } else {
        final downloads = await getDownloadsDirectory();
        if (downloads != null) {
          final folder = Directory('${downloads.path}/Aaris Pharmacy');
          await folder.create(recursive: true);
          await file.copy('${folder.path}/$fileName');
          savedLocation = folder.path;
        }
      }
    } catch (error) {
      saveError = error;
    }

    if (savedLocation == null) {
      try {
        final documents = await getApplicationDocumentsDirectory();
        final folder = Directory('${documents.path}/Aaris Pharmacy Backups');
        await folder.create(recursive: true);
        await file.copy('${folder.path}/$fileName');
        savedLocation = 'Aaris Pharmacy app storage';
      } catch (error) {
        saveError ??= error;
      }
    }

    var shareOpened = false;
    Object? shareError;
    try {
      await SharePlus.instance.share(
        ShareParams(
          title: 'Aaris Pharmacy full backup',
          text:
              'Aaris Pharmacy full backup created ${backup.createdAt.toIso8601String()}. Keep this private.',
          files: <XFile>[
            XFile(file.path, mimeType: 'text/plain'),
          ],
          fileNameOverrides: <String>[fileName],
        ),
      );
      shareOpened = true;
    } catch (error) {
      shareError = error;
    }

    if (savedLocation == null && !shareOpened) {
      throw StateError(
        'The backup file was created, but this device could neither save nor share it. ${shareError ?? saveError ?? ''}',
      );
    }

    final warnings = <String>[
      if (saveError != null && savedLocation == null)
        'The Downloads copy could not be created.',
      if (shareError != null) 'The share menu could not be opened.',
    ];
    return BackupExportResult(
      fileName: fileName,
      sizeBytes: sizeBytes,
      savedLocation: savedLocation,
      shareOpened: shareOpened,
      warning: warnings.isEmpty ? null : warnings.join(' '),
    );
  }

  Future<BackupFileReference?> pickBackupFile() async {
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      final picked = await _channel.invokeMapMethod<String, dynamic>(
        'pickBackupFile',
      );
      if (picked == null) return null;
      final path = picked['path']?.toString() ?? '';
      final name = picked['name']?.toString() ?? 'Aaris Pharmacy backup';
      final size = picked['size'];
      if (path.isEmpty) {
        throw const FormatException('The selected backup file has no readable path.');
      }
      return BackupFileReference(
        path: path,
        name: name,
        sizeBytes: size is num ? size.toInt() : await File(path).length(),
      );
    }

    const group = XTypeGroup(
      label: 'Aaris Pharmacy backup',
      extensions: <String>['txt', 'json'],
    );
    final picked = await openFile(
      acceptedTypeGroups: const <XTypeGroup>[group],
    );
    if (picked == null) return null;
    final file = File(picked.path);
    return BackupFileReference(
      path: picked.path,
      name: picked.name,
      sizeBytes: await file.length(),
    );
  }

  Future<PharmacyBackup> readBackupFile(BackupFileReference reference) async {
    final file = File(reference.path);
    if (!await file.exists()) {
      throw const FormatException('The selected backup file is no longer available.');
    }
    final size = await file.length();
    if (size <= 0) {
      throw const FormatException('The selected backup file is empty.');
    }
    if (size > maxPortableBackupBytes) {
      throw const FormatException(
        'Choose an Aaris Pharmacy backup smaller than 1 GB.',
      );
    }

    String firstLine;
    try {
      firstLine = await file
          .openRead(0, size < 65536 ? size : 65536)
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .first;
    } on StateError {
      throw const FormatException('The selected backup file is empty.');
    }

    if (PortableBackupCodec.isPortableHeader(firstLine)) {
      return PortableBackupCodec.read(file);
    }

    if (size > 96000000) {
      throw const FormatException(
        'This is a very large legacy JSON backup. Re-export it from the source phone with the current Aaris Pharmacy version to use the streaming .txt format.',
      );
    }
    return PharmacyBackup.parse(await file.readAsString());
  }

  Future<void> _prune(Directory directory) async {
    final cutoff = DateTime.now().subtract(const Duration(hours: 48));
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is! File) continue;
      try {
        final stat = await entity.stat();
        if (stat.modified.isBefore(cutoff)) await entity.delete();
      } catch (_) {}
    }
  }

  String _portableFileName(DateTime createdAt) {
    final local = createdAt.toLocal();
    String two(int value) => value.toString().padLeft(2, '0');
    return 'Aaris_Pharmacy_Full_Backup_${local.year}-${two(local.month)}-${two(local.day)}_${two(local.hour)}${two(local.minute)}${two(local.second)}.txt';
  }
}
