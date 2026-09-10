import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'local_ai_service.dart';

/// Read-only routing authority for capture-time Local AI handoff.
///
/// A selected model is not the same thing as an enabled Aaris Brain route:
/// `suspend()` deliberately retains the selection so it can be resumed later.
/// Scan/import code must therefore consult the persisted Brain switch before it
/// is allowed to lease that model. Any unreadable/missing configuration or
/// Local-AI setup failure fails closed to deterministic OCR + manual review;
/// inventory capture itself must never be blocked by an optional AI route.
class LocalBrainRoutePolicy {
  LocalBrainRoutePolicy._();

  static const _storage = FlutterSecureStorage();
  static const configurationKey = 'pharmacy.ai.configuration';
  static const _maxConfigurationCharacters = 64 * 1024;
  static const _configurationReadTimeout = Duration(seconds: 4);
  static const _routeInitializationTimeout = Duration(seconds: 7);

  static Future<bool> enabled() async {
    try {
      final raw = await _storage
          .read(key: configurationKey)
          .timeout(
            _configurationReadTimeout,
            onTimeout: () => null,
          );
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

  /// Returns a capture-time proof that Aaris Brain was enabled and a scan-ready
  /// Local AI route existed when this OCR work entered the durable queue.
  ///
  /// The ID is an audit/routing witness, not a permanent model lease. A queued
  /// capture can outlive a model switch; [mayReasonWith] deliberately rechecks
  /// the current active route immediately before inference so a healthy model
  /// change never strands already-saved OCR in a dead-end review state.
  ///
  /// Local model initialization is deliberately best-effort here. A damaged,
  /// stalled or temporarily unreadable model manifest must degrade to
  /// deterministic OCR, not reject a camera/photo/video capture that is
  /// otherwise perfectly valid.
  static Future<String?> captureModelId(LocalAiService local) async {
    if (!await enabled()) return null;
    try {
      await local.initialize().timeout(_routeInitializationTimeout);

      // Initialization can cross an app lifecycle/configuration boundary.
      // Re-read the persisted Brain switch after that await so a capture can
      // never retain stale permission to wake a selected model the owner just
      // disabled.
      if (!await enabled()) return null;
      final id = local.activeId;
      if (id == null ||
          !local.scannerEnabled ||
          !local.isModelScanReady(id)) {
        return null;
      }
      return id;
    } catch (_) {
      return null;
    }
  }

  /// Re-checks the privacy/user-control boundary immediately before inference.
  ///
  /// A non-null [capturedModelId] proves that Local AI was explicitly available
  /// at capture time. If the owner keeps Aaris Brain ON but selects a different
  /// scan-ready Local AI while OCR is queued, use that *current* active model.
  /// This closes the capture-model-switch race without ever waking Local AI for
  /// a scan captured while Brain was OFF. Turning Brain OFF, disabling scan AI,
  /// leaving no ready model, or a setup failure still fails closed to the
  /// evidence-grounded deterministic preview with no network fallback.
  static Future<bool> mayReasonWith(
    LocalAiService local,
    String? capturedModelId,
  ) async {
    if (capturedModelId == null) return false;
    try {
      await local.initialize().timeout(_routeInitializationTimeout);
      if (!await enabled()) return false;

      // Both calls above are asynchronous. Re-evaluate the live route only
      // after they complete; the model active *now* is the only model allowed
      // to receive this already-saved OCR payload.
      final activeId = local.activeId;
      return activeId != null &&
          local.scannerEnabled &&
          local.isModelScanReady(activeId);
    } catch (_) {
      return false;
    }
  }
}
