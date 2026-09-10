import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'local_ai_service.dart';

enum LocalBrainRouteReadiness { ready, retryWhenIdle, unavailable }

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

  static String? _selectedScanModelId(LocalAiService local) {
    final id = local.activeId;
    if (id == null || !local.scannerEnabled || local.activeModel == null) {
      return null;
    }
    return id;
  }

  static String? _activeScanReadyModelId(LocalAiService local) {
    final id = _selectedScanModelId(local);
    if (id == null || !local.isModelScanReady(id)) return null;
    return id;
  }

  /// Returns a capture-time proof that Aaris Brain was enabled and a selected
  /// Local AI route existed when this OCR work entered the durable queue.
  ///
  /// A selected model may have a stale/missing readiness proof after an app or
  /// runtime upgrade. Preserve that selection as the capture witness instead of
  /// silently downgrading the scan forever. [reasoningReadiness] can repair the
  /// live route only after OCR has already been durably saved. A capture made
  /// while Brain was OFF still receives no witness and can never wake Local AI
  /// later.
  ///
  /// The ID is an audit/routing witness, not a permanent model lease. A queued
  /// capture can outlive a model switch; [reasoningReadiness] deliberately
  /// rechecks the current active route immediately before inference so a healthy
  /// model change never strands already-saved OCR in a dead-end review state.
  ///
  /// Local model initialization is deliberately best-effort here. A damaged,
  /// stalled or temporarily unreadable model manifest must degrade to
  /// deterministic OCR, not reject a camera/photo/video capture that is
  /// otherwise perfectly valid.
  static Future<String?> captureModelId(LocalAiService local) async {
    // The persisted owner switch is the privacy boundary and is always checked
    // first. Once that asynchronous read returns, Dart cannot interleave another
    // event before the following synchronous live-route snapshot. If a model is
    // already selected, return immediately instead of redundantly awaiting
    // initialize() and reading secure storage a second time. Readiness is
    // revalidated immediately before inference.
    if (!await enabled()) return null;
    final selectedNow = _selectedScanModelId(local);
    if (selectedNow != null) return selectedNow;

    try {
      await local.initialize().timeout(_routeInitializationTimeout);

      // Initialization can cross an app lifecycle/configuration boundary.
      // Re-read the persisted Brain switch after that await so a capture can
      // never retain stale permission to wake a selected model the owner just
      // disabled.
      if (!await enabled()) return null;
      return _selectedScanModelId(local);
    } catch (_) {
      return null;
    }
  }

  /// Re-checks the privacy/user-control boundary immediately before inference.
  ///
  /// Unlike a boolean gate, this distinguishes a genuinely unavailable route
  /// from temporary lease contention. Foreground chat and scanner refinement
  /// share one native model runtime, so a capture must wait when chat wins a
  /// narrow race instead of permanently losing its Local AI refinement.
  static Future<LocalBrainRouteReadiness> reasoningReadiness(
    LocalAiService local,
    String? capturedModelId,
  ) async {
    if (capturedModelId == null) {
      return LocalBrainRouteReadiness.unavailable;
    }

    // Re-check consent first, then use an already-live route without inserting
    // avoidable setup/storage awaits into every queued draft.
    if (!await enabled()) return LocalBrainRouteReadiness.unavailable;
    if (_activeScanReadyModelId(local) != null) {
      return LocalBrainRouteReadiness.ready;
    }

    try {
      await local.initialize().timeout(_routeInitializationTimeout);
      if (!await enabled()) return LocalBrainRouteReadiness.unavailable;

      final activeId = _selectedScanModelId(local);
      if (activeId == null) return LocalBrainRouteReadiness.unavailable;
      if (local.isModelScanReady(activeId)) {
        return LocalBrainRouteReadiness.ready;
      }

      // A busy/transferring runtime is not proof that this route is invalid.
      // Keep the durable OCR job in reasoning state and retry when the shared
      // lease becomes idle; LocalAiService listeners close the lost-wakeup race.
      if (local.busy || local.transferring) {
        return LocalBrainRouteReadiness.retryWhenIdle;
      }

      // Explicit scan capture is allowed to repair the selected local route,
      // but only after OCR is safely persisted. activate() performs the existing
      // GGUF verification, adaptive-memory load and advisory extraction probe;
      // it never falls through to cloud. A real activation failure remains a
      // deterministic-review fallback.
      try {
        await local.activate(activeId);
      } catch (_) {
        return LocalBrainRouteReadiness.unavailable;
      }

      // Activation can take long enough for the owner to change the Brain
      // switch. Re-check consent and the live route before exposing OCR to the
      // model; stale activation completion never grants inference authority.
      if (!await enabled()) return LocalBrainRouteReadiness.unavailable;
      return local.activeId == activeId &&
              local.scannerEnabled &&
              local.isModelScanReady(activeId)
          ? LocalBrainRouteReadiness.ready
          : LocalBrainRouteReadiness.unavailable;
    } catch (_) {
      return LocalBrainRouteReadiness.unavailable;
    }
  }

  /// Compatibility boolean for call sites that cannot use retry semantics.
  static Future<bool> mayReasonWith(
    LocalAiService local,
    String? capturedModelId,
  ) async =>
      await reasoningReadiness(local, capturedModelId) ==
      LocalBrainRouteReadiness.ready;
}
