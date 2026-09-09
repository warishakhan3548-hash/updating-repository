import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../domain/default_local_model.dart';
import 'local_ai_service.dart';

/// Owns only the *role* "Aaris default model". Weight storage, download
/// verification, GGUF inspection, RAM admission and inference remain owned by
/// LocalAiService so there is still one authoritative local runtime.
class AarisDefaultAiService extends ChangeNotifier {
  static final instance = AarisDefaultAiService();

  final LocalAiService _local = LocalAiService.instance;
  Future<void>? _initializing;
  Directory? _directory;
  String? _defaultId;
  bool _busy = false;
  String _status = 'Aaris Default AI is not installed';

  bool get supported => _local.supported;
  bool get busy => _busy || _local.busy || _local.transferring;
  double? get progress => _local.progress;
  String get status => _status;
  String? get defaultId => _defaultId;

  bool get hasDefault =>
      _defaultId != null && _local.installed.any((m) => m.id == _defaultId);
  bool get active => hasDefault && _local.activeId == _defaultId;

  Future<void> initialize() =>
      _initializing ??= _initialize().catchError((Object error) {
        _initializing = null;
        throw error;
      });

  Future<void> _initialize() async {
    await _local.initialize();
    if (!supported) return;
    final support = await getApplicationSupportDirectory();
    _directory = await Directory(
      '${support.path}/local_ai',
    ).create(recursive: true);
    final file = File('${_directory!.path}/aaris_default_ai.json');
    if (await file.exists()) {
      try {
        if (await file.length() > 4096) {
          throw const FormatException('Default AI manifest is too large.');
        }
        final raw = jsonDecode(await file.readAsString());
        if (raw is! Map || raw['version'] != 1 || raw['defaultId'] is! String) {
          throw const FormatException('Invalid Aaris Default AI manifest.');
        }
        final id = raw['defaultId'] as String;
        if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(id)) {
          throw const FormatException('Invalid Aaris Default AI id.');
        }
        _defaultId = id;
      } catch (_) {
        _defaultId = null;
        await file.delete();
      }
    }
    if (_defaultId != null && !hasDefault) {
      _defaultId = null;
      if (await file.exists()) await file.delete();
    }
    _status = active
        ? 'Aaris Default AI active'
        : hasDefault
        ? 'Aaris Default AI installed · ready as fallback'
        : 'Aaris Default AI is not installed';
    notifyListeners();
  }

  Future<void> _persistDefault(String id) async {
    final directory = _directory;
    if (directory == null) throw StateError('Default AI store is unavailable.');
    final next = File('${directory.path}/aaris_default_ai.json.next');
    await next.writeAsString(
      jsonEncode({
        'version': 1,
        'defaultId': id,
        'repository': aarisDefaultModelRepository,
      }),
      flush: true,
    );
    await next.rename('${directory.path}/aaris_default_ai.json');
    _defaultId = id;
  }

  /// Restores the downloaded default only when no user-selected local model is
  /// already active. This is the priority rule:
  /// user model > Aaris default > deterministic scanner/field extractor.
  Future<bool> ensureActiveIfInstalled() async {
    await initialize();
    if (!supported || !hasDefault) return false;
    if (_local.hasSelection) {
      _status = active
          ? 'Aaris Default AI active'
          : 'User-selected local AI active · Aaris default kept as fallback';
      notifyListeners();
      return active;
    }
    _status = 'Restoring Aaris Default AI…';
    notifyListeners();
    await _local.activate(_defaultId!);
    _status = 'Aaris Default AI active';
    notifyListeners();
    return true;
  }

  Future<void> installAndActivate() async {
    await initialize();
    if (!supported) {
      throw UnsupportedError(
        'Aaris Default Local AI is unavailable on this platform.',
      );
    }
    if (_busy) throw StateError('Aaris Default AI setup is already running.');
    _busy = true;
    notifyListeners();
    try {
      if (hasDefault) {
        _status = 'Loading installed Aaris Default AI…';
        notifyListeners();
        await _local.activate(_defaultId!);
        _status = 'Aaris Default AI active';
        return;
      }

      _status = 'Finding the recommended ~$aarisDefaultModelDownloadHint model…';
      notifyListeners();
      final repository = await _local.repositoryFiles(
        aarisDefaultModelRepository,
      );
      if (repository.gated) {
        throw StateError(
          'The recommended model currently requires publisher access. Use the Model Hub or continue with the offline scanner.',
        );
      }
      final model = chooseAarisDefaultModel(repository.files);
      if (model == null) {
        throw StateError(
          'The recommended 300–400 MB model file is temporarily unavailable. Continue with the offline scanner or choose another model in the Model Hub.',
        );
      }

      final alreadyInstalled = _local.installed.any((m) => m.id == model.sha256);
      if (!alreadyInstalled) {
        _status =
            'Downloading ${modelSize(model.bytes)} Aaris Default AI · inventory stays on device';
        notifyListeners();
        await _local.download(model);
      }

      _status = 'Verifying and activating Aaris Default AI…';
      notifyListeners();
      await _local.activate(model.sha256);
      await _persistDefault(model.sha256);
      _status = 'Aaris Default AI active · permanent fallback ready';
    } catch (error) {
      _status =
          'Default AI not active · offline pharmacy scanner remains available';
      rethrow;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  void cancel() {
    if (_local.transferring) {
      _local.cancelTransfer();
    } else if (_local.busy) {
      _local.cancelRequest();
    }
  }
}
