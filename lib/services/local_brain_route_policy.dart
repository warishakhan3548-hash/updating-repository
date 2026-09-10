import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'local_ai_service.dart';

/// Read-only routing authority for capture-time Local AI handoff.
///
/// A selected model is not the same thing as an enabled Aaris Brain route:
/// `suspend()` deliberately retains the selection so it can be resumed later.
/// Scan/import code must therefore consult the persisted Brain switch before it
/// is allowed to lease that model. Any unreadable/missing configuration fails
/// closed to deterministic OCR + manual review; inventory is never blocked.
class LocalBrainRoutePolicy {
  LocalBrainRoutePolicy._();

  static const _storage = FlutterSecureStorage();
  static const configurationKey = 'pharmacy.ai.configuration';
  static const _maxConfigurationCharacters = 64 * 1024;

  static Future<bool> enabled() async {
    try {
      final raw = await _storage.read(key: configurationKey);
      if (raw == null ||
          raw.isEmpty ||
          raw.length > _maxConfigurationCharacters) {
        return false;
      }
      final decoded = jsonDecode(raw);
      return decoded is Map && decoded['localBrainEnabled'] == true;
    } catch (_) {
      // Routing must fail closed. OCR/deterministic extraction remains usable
      // even if secure configuration storage is temporarily unavailable.
      return false;
    }
  }

  /// Returns the exact capture-time model lease only when all routing gates are
  /// true. This prevents a suspended-but-selected model from being silently
  /// reloaded by the scanner after the owner turned Aaris Brain off.
  static Future<String?> captureModelId(LocalAiService local) async {
    if (!await enabled()) return null;
    await local.initialize();

    // Initialization can cross an app lifecycle/configuration boundary. Re-read
    // the persisted Brain switch after that await so a capture can never retain
    // a stale permission to wake a selected model that the owner just disabled.
    if (!await enabled()) return null;
    final id = local.activeId;
    if (id == null ||
        !local.scannerEnabled ||
        !local.isModelScanReady(id)) {
      return null;
    }
    return id;
  }

  /// Re-check immediately before inference so a Brain-OFF toggle that happens
  /// after OCR was queued cannot leak into a later Local AI reasoning step.
  static Future<bool> mayReasonWith(
    LocalAiService local,
    String? capturedModelId,
  ) async {
    if (capturedModelId == null) return false;
    await local.initialize();
    if (!await enabled()) return false;
    final id = local.activeId;
    return id == capturedModelId &&
        local.scannerEnabled &&
        local.isModelScanReady(capturedModelId);
  }
}
