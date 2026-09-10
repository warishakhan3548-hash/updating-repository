import 'dart:async';
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

  // Instant review is allowed to queue briefly behind a foreground Local-AI
  // inference turn instead of silently dropping the OCR handoff. This is
  // intentionally bounded. Model download/import is different: it can last
  // minutes, so instant review fails open to deterministic OCR immediately while
  // durable intake jobs keep their retryWhenIdle queue semantics.
  static const _instantLeaseWaitTimeout = Duration(seconds: 30);

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

  static bool _leaseContention(Object error) {
    final message = error.toString().toLowerCase();
    return message.contains('local ai is busy') ||
        message.contains('runtime is unavailable or still processing') ||
        message.contains('runtime is busy or closing') ||
        message.contains('runtime is still processing a failed model load');
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

    // Re-check consent first. A load-tested model can still be actively leased
    // by chat or another scan, so lease state must be checked BEFORE returning
    // Ready. The old ordering could advertise Ready and then immediately throw
    // "Local AI is busy" from understand(), dropping an otherwise valid OCR
    // handoff into deterministic-only review.
    if (!await enabled()) return LocalBrainRouteReadiness.unavailable;
    if (local.busy || local.transferring) {
      return LocalBrainRouteReadiness.retryWhenIdle;
    }
    if (_activeScanReadyModelId(local) != null) {
      return LocalBrainRouteReadiness.ready;
    }

    try {
      await local.initialize().timeout(_routeInitializationTimeout);
      if (!await enabled()) return LocalBrainRouteReadiness.unavailable;

      // initialize()/secure-storage awaits can cross a foreground Send or model
      // operation. Re-snapshot lease state before trusting readiness or trying
      // activation so two callers never race into the exclusive native runtime.
      if (local.busy || local.transferring) {
        return LocalBrainRouteReadiness.retryWhenIdle;
      }

      final activeId = _selectedScanModelId(local);
      if (activeId == null) return LocalBrainRouteReadiness.unavailable;
      if (local.isModelScanReady(activeId)) {
        return LocalBrainRouteReadiness.ready;
      }

      // Explicit scan capture is allowed to repair the selected local route,
      // but only after OCR is safely persisted. activate() performs the existing
      // GGUF verification, adaptive-memory load and advisory extraction probe;
      // it never falls through to cloud. A real activation failure remains a
      // deterministic-review fallback.
      try {
        await local.activate(activeId);
      } catch (error) {
        // A foreground Send/model operation can acquire the exclusive lease in
        // the final event-loop gap after the busy snapshot above. That is queue
        // contention, not evidence that the selected model became invalid.
        if (local.busy || local.transferring || _leaseContention(error)) {
          return LocalBrainRouteReadiness.retryWhenIdle;
        }
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
    } catch (error) {
      // Initialization can also overlap a native lease transition. Preserve the
      // queued handoff only when current state/error identifies contention;
      // malformed configuration or a real model-load failure still fails closed.
      if (local.busy || local.transferring || _leaseContention(error)) {
        return LocalBrainRouteReadiness.retryWhenIdle;
      }
      return LocalBrainRouteReadiness.unavailable;
    }
  }

  /// Compatibility boolean for instant-review call sites.
  ///
  /// If the only blocker is a currently leased local inference runtime, wait for
  /// the service's own ChangeNotifier idle edge and re-run the full privacy/route
  /// check. Model transfer/setup is deliberately not waited here because a
  /// multi-GB download/import would freeze an otherwise usable OCR preview;
  /// durable capture jobs call [reasoningReadiness] directly and remain queued.
  static Future<bool> mayReasonWith(
    LocalAiService local,
    String? capturedModelId,
  ) async {
    var readiness = await reasoningReadiness(local, capturedModelId);
    if (readiness == LocalBrainRouteReadiness.ready) return true;
    if (readiness != LocalBrainRouteReadiness.retryWhenIdle) return false;
    if (local.transferring) return false;

    final watch = Stopwatch()..start();
    while (readiness == LocalBrainRouteReadiness.retryWhenIdle) {
      // A transfer may begin while we were queued behind a short inference turn.
      // Instant review must stop waiting at that boundary; the deterministic OCR
      // preview remains available and no stale model lease is granted.
      if (local.transferring) return false;
      final remaining = _instantLeaseWaitTimeout - watch.elapsed;
      if (remaining.isNegative ||
          remaining == Duration.zero ||
          !await _waitUntilLocalLeaseIsIdle(local, remaining)) {
        return false;
      }
      readiness = await reasoningReadiness(local, capturedModelId);
    }
    return readiness == LocalBrainRouteReadiness.ready;
  }

  static Future<bool> _waitUntilLocalLeaseIsIdle(
    LocalAiService local,
    Duration timeout,
  ) async {
    if (!local.busy && !local.transferring) return true;
    if (timeout.isNegative || timeout == Duration.zero) return false;

    final idle = Completer<void>();
    void onChanged() {
      if (!local.busy && !local.transferring && !idle.isCompleted) {
        idle.complete();
      }
    }

    local.addListener(onChanged);
    try {
      // Close the lost-wakeup window between the synchronous check above and
      // listener registration. notifyListeners() also fires when _exclusive or
      // a transfer releases its lease.
      onChanged();
      await idle.future.timeout(timeout);
      return true;
    } on TimeoutException {
      return false;
    } finally {
      local.removeListener(onChanged);
    }
  }
}
