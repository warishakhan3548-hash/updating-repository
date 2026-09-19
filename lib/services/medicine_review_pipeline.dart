import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../domain/medicine.dart';
import '../domain/medicine_evidence_normalization.dart';

import '../domain/medicine_resolution_v2.dart';
import '../domain/medicine_review_cardinality.dart';
import '../domain/local_scan_request.dart';
import '../domain/medicine_scan_commit.dart';
import '../domain/medicine_understanding.dart';
import 'ai_service.dart';
import 'canonical_medicine_catalog_service.dart';
import 'cloud_scan_ai_service.dart';
import 'local_ai_service.dart';
import 'local_brain_route_policy.dart';
import 'offline_recognition_memory_service.dart';

export '../domain/medicine_evidence_normalization.dart'
    show normalizeMedicineReviewEvidence;

enum MedicineReviewInputKind { prepared, localEvidence, cloudEvidence }

class MedicineReviewInput {
  const MedicineReviewInput._({
    required this.kind,
    required this.evidence,
    required this.preparedDrafts,
    required this.autoSaveReadyDrafts,
    required this.singlePackExpected,
  });

  const MedicineReviewInput.prepared(
    List<MedicineScanDraft> drafts, {
    bool singlePackExpected = false,
  }) : this._(
          kind: MedicineReviewInputKind.prepared,
          evidence: const <MedicineFrameEvidence>[],
          preparedDrafts: drafts,
          autoSaveReadyDrafts: false,
          singlePackExpected: singlePackExpected,
        );

  MedicineReviewInput.localEvidence(
    List<MedicineFrameEvidence> evidence, {
    bool autoSaveReadyDrafts = false,
    bool? singlePackExpected,
  }) : this._(
          kind: MedicineReviewInputKind.localEvidence,
          evidence: evidence,
          preparedDrafts: const <MedicineScanDraft>[],
          autoSaveReadyDrafts: autoSaveReadyDrafts,
          // Structured list imports mark explicit row boundaries. Camera scans
          // do not, so they naturally become one-physical-pack review sessions
          // without every caller needing source-specific UI logic.
          singlePackExpected:
              singlePackExpected ?? !evidence.any((item) => item.startsNewItem),
        );

  const MedicineReviewInput.cloudEvidence(
    List<MedicineFrameEvidence> evidence, {
    bool singlePackExpected = true,
  }) : this._(
          kind: MedicineReviewInputKind.cloudEvidence,
          evidence: evidence,
          preparedDrafts: const <MedicineScanDraft>[],
          autoSaveReadyDrafts: false,
          singlePackExpected: singlePackExpected,
        );

  final MedicineReviewInputKind kind;
  final List<MedicineFrameEvidence> evidence;
  final List<MedicineScanDraft> preparedDrafts;
  final bool autoSaveReadyDrafts;
  final bool singlePackExpected;
}

class PreparedMedicineReviewDraft {
  const PreparedMedicineReviewDraft({
    required this.draft,
    this.autoSaveVerifier,
  });

  final MedicineScanDraft draft;
  final ScanAutoSaveVerifier? autoSaveVerifier;
}

class MedicineReviewPreparation {
  const MedicineReviewPreparation({
    required this.drafts,
    this.ignoredFrames = 0,
    this.warning = '',
    this.routeLabel = '',
  });

  final List<PreparedMedicineReviewDraft> drafts;
  final int ignoredFrames;
  final String warning;
  final String routeLabel;
}

/// Backoff policy for a local-model lease that is temporarily owned by another
/// turn. The review pipeline must never hot-spin on a synchronous "busy" error:
/// eight bounded waits cost at most 1.88 s, after which the caller falls back to
/// the deterministic offline draft instead of freezing the scanner journey.
Duration? medicineReviewContentionDelay(int attempt) {
  if (attempt < 0 || attempt >= 8) return null;
  final step = attempt > 3 ? 3 : attempt;
  return Duration(milliseconds: 40 * (1 << step));
}

/// One authoritative preparation pipeline for every medicine-review entrypoint.
///
/// Capture sources may differ, but review semantics do not. Prepared durable
/// queue drafts are never reinterpreted semantically. Local evidence keeps the
/// existing Offline Core + optional Local AI route. Explicit cloud evidence keeps
/// the strict bounded-evidence privacy boundary. A single physical-pack lane is
/// normalized here before AI refinement, so OCR segmentation noise can never
/// become several pharmacist-facing medicines.
class MedicineReviewPipeline {
  MedicineReviewPipeline({CloudScanAiService? cloud})
      : _cloud = cloud ?? CloudScanAiService();

  static const int _maxSemanticCacheEntries = 24;

  final CloudScanAiService _cloud;
  final Map<String, MedicineScanDraft> _semanticCache =
      <String, MedicineScanDraft>{};
  bool _cancelled = false;
  LocalScanRequest? _localScanRequest;

  void _ensureActive() {
    if (_cancelled) throw StateError('Medicine review cancelled.');
  }

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    _cloud.cancel();
    _localScanRequest?.cancel();
    _semanticCache.clear();
  }

  Future<MedicineReviewPreparation> prepare(
    MedicineReviewInput input,
    Iterable<Medicine> records,
  ) async {
    _ensureActive();
    switch (input.kind) {
      case MedicineReviewInputKind.prepared:
        final normalized = normalizeMedicineReviewDrafts(
          input.preparedDrafts,
          singlePackExpected: input.singlePackExpected,
        );
        _ensureActive();
        return MedicineReviewPreparation(
          drafts: List<PreparedMedicineReviewDraft>.unmodifiable(
            normalized.map(
              (draft) => PreparedMedicineReviewDraft(draft: draft),
            ),
          ),
        );
      case MedicineReviewInputKind.localEvidence:
        final evidence = normalizeMedicineReviewEvidence(input.evidence);
        _validateEvidence(evidence);
        return _prepareLocal(input, records, evidence);
      case MedicineReviewInputKind.cloudEvidence:
        final evidence = normalizeMedicineReviewEvidence(input.evidence);
        _validateEvidence(evidence);
        return _prepareCloud(input, records, evidence);
    }
  }

  void _validateEvidence(List<MedicineFrameEvidence> evidence) {
    if (evidence.isEmpty ||
        evidence.every(
          (item) => item.text.trim().isEmpty && item.allBarcodes.isEmpty,
        )) {
      throw const FormatException('No barcode or medicine text was captured.');
    }
  }

  Future<MedicineReviewPreparation> _prepareLocal(
    MedicineReviewInput input,
    Iterable<Medicine> records,
    List<MedicineFrameEvidence> evidence,
  ) async {
    final local = LocalAiService.instance;
    var warning = '';
    String? scanModelId;

    try {
      final brainEnabled = await LocalBrainRoutePolicy.enabled();
      _ensureActive();
      if (brainEnabled) {
        scanModelId = await LocalBrainRoutePolicy.captureModelId(local);
        _ensureActive();
        if (scanModelId == null) {
          warning = local.hasSelection && local.scannerEnabled && !local.scanReady
              ? 'Local AI is not ready yet. Aaris kept the on-device result.'
              : 'Local AI is unavailable right now. Aaris kept the on-device result.';
        }
      }
    } catch (_) {
      if (_cancelled) _ensureActive();
      scanModelId = null;
      warning = 'Local AI could not be checked. Aaris kept the on-device result.';
    }

    final baseKnowledge = medicineKnowledgeFromRecords(records);
    final knowledge =
        await OfflineRecognitionMemoryService.instance.enrichKnowledge(
      baseKnowledge,
      evidence,
    );
    _ensureActive();
    final catalogue = await CanonicalMedicineCatalogService.instance
        .candidatesForEvidence(evidence);
    _ensureActive();

    final payload = await compute(
      understandMedicineEvidenceV2Message,
      <String, Object?>{
        'evidence': evidence
            .map((item) => item.toMessage())
            .toList(growable: false),
        'knowledge': knowledge
            .map((entry) => entry.toMessage())
            .toList(growable: false),
        'catalog': catalogue
            .map((entry) => entry.toMessage())
            .toList(growable: false),
      },
    );
    _ensureActive();
    final understanding = MedicineUnderstandingResult.fromMessage(payload);
    final reviewDrafts = normalizeMedicineReviewDrafts(
      understanding.drafts,
      singlePackExpected: input.singlePackExpected,
    );
    if (reviewDrafts.isEmpty) {
      throw const FormatException(
        'No medicine could be read. Take a closer, steadier scan.',
      );
    }

    final prepared = <PreparedMedicineReviewDraft>[];
    var localBrainUsed = false;
    final scanRequest = LocalScanRequest();
    _localScanRequest = scanRequest;
    try {
      for (final original in reviewDrafts) {
        _ensureActive();
        var draft = original;
        ScanAutoSaveVerifier? autoSaveVerifier;
        final leasedModelId = scanModelId;
        if (leasedModelId != null) {
          try {
            final mayReason = await LocalBrainRoutePolicy.mayReasonWith(
              local,
              leasedModelId,
              scanRequest: scanRequest,
            );
            _ensureActive();
            if (!mayReason) {
              scanModelId = null;
              warning = 'Local AI changed or became busy. Aaris kept the on-device result.';
            } else {
              final routedModelId = local.activeId;
              if (routedModelId == null) {
                scanModelId = null;
                warning = 'Local AI became unavailable. Aaris kept the on-device result.';
              } else {
                final key =
                    '$routedModelId:${jsonEncode(original.toMessage())}';
                final candidate =
                    _takeSemanticCache(key) ??
                    await _understandWithRecovery(
                      local,
                      routedModelId,
                      original,
                      scanRequest,
                    );
                _ensureActive();
                final leaseStillValid =
                    await LocalBrainRoutePolicy.mayReasonWith(
                      local,
                      routedModelId,
                      scanRequest: scanRequest,
                    ) &&
                    local.activeId == routedModelId;
                _ensureActive();
                if (leaseStillValid) {
                  draft = candidate;
                  _rememberSemanticCache(key, candidate);
                  localBrainUsed = true;
                  if (local.isModelScanVerified(routedModelId)) {
                    autoSaveVerifier = ScanAutoSaveVerifier.localAi;
                  }
                  scanModelId = routedModelId;
                } else {
                  scanModelId = null;
                  warning = 'Local AI changed during review. Aaris kept the on-device result.';
                }
              }
            }
          } catch (_) {
            if (_cancelled) _ensureActive();
            if (scanRequest.cancelled) scanModelId = null;
            warning = 'Local AI could not finish this scan. Aaris kept the on-device result.';
          }
        }
        prepared.add(
          PreparedMedicineReviewDraft(
            draft: draft,
            autoSaveVerifier: autoSaveVerifier,
          ),
        );
      }
    } finally {
      scanRequest.close();
      if (identical(_localScanRequest, scanRequest)) _localScanRequest = null;
    }

    _ensureActive();
    return MedicineReviewPreparation(
      drafts: List<PreparedMedicineReviewDraft>.unmodifiable(prepared),
      ignoredFrames: understanding.ignoredFrames,
      warning: warning,
      routeLabel: localBrainUsed ? 'Aaris Brain' : 'Aaris Offline Core',
    );
  }

  Future<MedicineReviewPreparation> _prepareCloud(
    MedicineReviewInput input,
    Iterable<Medicine> records,
    List<MedicineFrameEvidence> evidence,
  ) async {
    var warning = '';
    var routeLabel = '';
    AiConfiguration? config;
    try {
      config = await _cloud.requireConfiguration();
      _ensureActive();
      routeLabel = _cloud.routeLabel(config);
    } catch (error) {
      if (_cancelled) _ensureActive();
      warning =
          '${_cleanError(error)} Aaris kept the on-device result; nothing was sent externally.';
    }

    // With a configured cloud route, private inventory knowledge, learned OCR
    // corrections and catalogue hints stay out of the provider-bound draft.
    // Without a cloud route nothing can leave the device, so the strongest local
    // deterministic fallback may use those private local sources.
    final baseKnowledge = config == null
        ? medicineKnowledgeFromRecords(records)
        : const <MedicineKnowledgeEntry>[];
    final knowledge = config == null
        ? await OfflineRecognitionMemoryService.instance.enrichKnowledge(
            baseKnowledge,
            evidence,
          )
        : const <MedicineKnowledgeEntry>[];
    _ensureActive();
    final catalogue = config == null
        ? await CanonicalMedicineCatalogService.instance
            .candidatesForEvidence(evidence)
        : const <CanonicalMedicineProduct>[];
    _ensureActive();

    final payload = await compute(
      understandMedicineEvidenceV2Message,
      <String, Object?>{
        'evidence': evidence
            .map((item) => item.toMessage())
            .toList(growable: false),
        'knowledge': knowledge
            .map((item) => item.toMessage())
            .toList(growable: false),
        'catalog': catalogue
            .map((item) => item.toMessage())
            .toList(growable: false),
      },
    );
    _ensureActive();
    final deterministic = MedicineUnderstandingResult.fromMessage(payload);
    final reviewDrafts = normalizeMedicineReviewDrafts(
      deterministic.drafts,
      singlePackExpected: input.singlePackExpected,
    );
    if (reviewDrafts.isEmpty) {
      throw const FormatException(
        'No medicine could be read. Take a closer, steadier scan.',
      );
    }

    final prepared = <PreparedMedicineReviewDraft>[];
    for (final original in reviewDrafts) {
      _ensureActive();
      if (config == null) {
        prepared.add(PreparedMedicineReviewDraft(draft: original));
        continue;
      }
      try {
        final refined = await _cloud.refine(config, original);
        _ensureActive();
        prepared.add(PreparedMedicineReviewDraft(draft: refined));
      } catch (error) {
        if (_cancelled) _ensureActive();
        prepared.add(PreparedMedicineReviewDraft(draft: original));
        warning =
            'Cloud AI could not safely validate every medicine. Aaris kept the on-device result. ${_cleanError(error)}';
      }
    }

    _ensureActive();
    return MedicineReviewPreparation(
      drafts: List<PreparedMedicineReviewDraft>.unmodifiable(prepared),
      ignoredFrames: deterministic.ignoredFrames,
      warning: warning,
      routeLabel: routeLabel.isEmpty ? 'Aaris Offline Core' : routeLabel,
    );
  }

  MedicineScanDraft? _takeSemanticCache(String key) {
    final value = _semanticCache.remove(key);
    if (value != null) _semanticCache[key] = value;
    return value;
  }

  void _rememberSemanticCache(String key, MedicineScanDraft value) {
    _semanticCache.remove(key);
    _semanticCache[key] = value;
    while (_semanticCache.length > _maxSemanticCacheEntries) {
      _semanticCache.remove(_semanticCache.keys.first);
    }
  }

  bool _recoverableLocalTransportFailure(Object error) {
    if (error is FormatException || error is ArgumentError) return false;
    final message = error.toString().toLowerCase();
    if (message.contains('cancel') ||
        message.contains('busy') ||
        message.contains('select a local model') ||
        message.contains('selected model is missing') ||
        message.contains('model file is incomplete') ||
        message.contains('invalid model') ||
        message.contains('unsupported context')) {
      return false;
    }
    return message.contains('runtime') ||
        message.contains('transport') ||
        message.contains('connection') ||
        message.contains('closed') ||
        message.contains('isolate') ||
        message.contains('native');
  }

  bool _localLeaseContention(Object error) {
    final message = error.toString().toLowerCase();
    return message.contains('local ai is busy') ||
        message.contains('runtime is unavailable or still processing') ||
        message.contains('runtime is busy or closing') ||
        message.contains('runtime is still processing a failed model load');
  }

  Future<bool> _routeStillOwnsScan(
    LocalAiService local,
    String routedModelId,
    LocalScanRequest scanRequest,
  ) async {
    _ensureActive();
    scanRequest.checkCurrent();
    final owns =
        await LocalBrainRoutePolicy.mayReasonWith(
          local,
          routedModelId,
          scanRequest: scanRequest,
        ) &&
        local.activeId == routedModelId;
    _ensureActive();
    scanRequest.checkCurrent();
    return owns;
  }

  Future<MedicineScanDraft> _understandWithRecovery(
    LocalAiService local,
    String routedModelId,
    MedicineScanDraft draft,
    LocalScanRequest scanRequest,
  ) async {
    var transportRecovered = false;
    var contentionAttempt = 0;
    while (true) {
      _ensureActive();
      scanRequest.checkCurrent();
      try {
        return await local.understand(draft, scanRequest: scanRequest);
      } catch (error, stack) {
        if (_cancelled) _ensureActive();
        scanRequest.checkCurrent();
        if (_localLeaseContention(error)) {
          if (!await _routeStillOwnsScan(local, routedModelId, scanRequest)) {
            throw StateError(
              'Local AI route changed while this scan was waiting.',
            );
          }
          final delay = medicineReviewContentionDelay(contentionAttempt++);
          if (delay == null) {
            throw StateError(
              'Local AI stayed busy. Aaris will use the offline scan result.',
            );
          }
          await Future<void>.delayed(delay);
          _ensureActive();
          continue;
        }
        if (transportRecovered || !_recoverableLocalTransportFailure(error)) {
          Error.throwWithStackTrace(error, stack);
        }
        transportRecovered = true;
        var suspendAttempt = 0;
        while (true) {
          _ensureActive();
          scanRequest.checkCurrent();
          try {
            await local.suspend(scanRequest: scanRequest);
            _ensureActive();
            break;
          } catch (suspendError) {
            if (_cancelled) _ensureActive();
            scanRequest.checkCurrent();
            if (!_localLeaseContention(suspendError) ||
                !await _routeStillOwnsScan(local, routedModelId, scanRequest)) {
              Error.throwWithStackTrace(error, stack);
            }
            final delay = medicineReviewContentionDelay(suspendAttempt++);
            if (delay == null) {
              Error.throwWithStackTrace(error, stack);
            }
            await Future<void>.delayed(delay);
            _ensureActive();
          }
        }
        if (!await _routeStillOwnsScan(local, routedModelId, scanRequest)) {
          throw StateError(
            'Local AI route changed while recovering this scan.',
          );
        }
        contentionAttempt = 0;
      }
    }
  }

  String _cleanError(Object error) => error
      .toString()
      .replaceFirst(
        RegExp(r'^(Exception|FormatException|Bad state|StateError):\s*'),
        '',
      )
      .trim();
}
