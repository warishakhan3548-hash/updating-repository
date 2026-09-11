from pathlib import Path


def read(path: str) -> str:
    return Path(path).read_text(encoding='utf-8')


def write(path: str, text: str) -> None:
    Path(path).write_text(text, encoding='utf-8')


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f'{label}: expected exactly one anchor, found {count}')
    return text.replace(old, new, 1)


# 1) Durable intake cleanup must never convert successful OCR into a failed job.
path = 'lib/services/medicine_intake_service.dart'
text = read(path)
text = replace_once(
    text,
    """    _jobs
      ..clear()
      ..addAll(restored);
    if (!_observingMemory) {""",
    """    _jobs
      ..clear()
      ..addAll(restored);
    await _cleanupOrphanedCaptureFiles(restored);
    if (!_observingMemory) {""",
    'startup orphan cleanup hook',
)
text = replace_once(
    text,
    """  String _capturePath(String id, String kind) =>
      '${_root!.path}/$id.${kind == 'video' ? 'mp4' : 'jpg'}';

  Future<void> _persist(MedicineIntakeJob job, {bool insert = false}) async {""",
    """  String _capturePath(String id, String kind) =>
      '${_root!.path}/$id.${kind == 'video' ? 'mp4' : 'jpg'}';

  Future<void> _cleanupOrphanedCaptureFiles(
    Iterable<MedicineIntakeJob> restored,
  ) async {
    final root = _root;
    if (root == null) return;
    final retained = restored
        .where((job) => job.path.isNotEmpty)
        .map((job) => job.path)
        .toSet();
    final captureName = RegExp(r'^[a-f0-9]{32}\\.(?:jpg|mp4)$');
    try {
      await for (final entity in root.list(followLinks: false)) {
        if (entity is! File ||
            retained.contains(entity.path) ||
            !captureName.hasMatch(entity.uri.pathSegments.last)) {
          continue;
        }
        try {
          await entity.delete();
        } on FileSystemException {
          // A pre-checkpoint orphan is housekeeping only. Never make the
          // authoritative queue unavailable because Android temporarily refused
          // to delete an otherwise unreferenced private capture.
        }
      }
    } on FileSystemException {
      // Directory enumeration is best-effort for the same reason. Restored jobs
      // have already had their exact private paths validated above.
    }
  }

  Future<void> _releaseProcessedSource(MedicineIntakeJob job) async {
    if (job.path.isEmpty) return;
    if (job.path != _capturePath(job.id, job.kind)) {
      throw StateError('Capture source path changed unexpectedly.');
    }
    final source = File(job.path);
    try {
      if (await source.exists()) await source.delete();
      job.path = '';
    } on FileSystemException {
      // OCR/drafts are already durably checkpointed. Keep the validated path in
      // the row so Retry/Dismiss or a later launch can attempt cleanup again;
      // a housekeeping failure must never downgrade valid recognition to failed.
    }
  }

  Future<void> _persist(MedicineIntakeJob job, {bool insert = false}) async {""",
    'add crash-safe source cleanup helpers',
)
text = replace_once(
    text,
    """    if (job.status != 'failed' && job.path.isNotEmpty) {
      await File(job.path).delete();
      job.path = '';
    }
""",
    """    if (job.status != 'failed') {
      await _releaseProcessedSource(job);
    }
""",
    'photo cleanup cannot fail completed OCR',
)
text = replace_once(
    text,
    """    if (window.complete && job.status != 'failed') {
      await File(job.path).delete();
      job.path = '';
    }
""",
    """    if (window.complete && job.status != 'failed') {
      await _releaseProcessedSource(job);
    }
""",
    'video cleanup cannot fail completed OCR',
)
write(path, text)

# 2) Explicit cloud scan is review-only, therefore cloud auto-save provenance is
# dead authority and must be removed from the deterministic commit API.
path = 'lib/domain/medicine_scan_commit.dart'
text = read(path)
text = replace_once(
    text,
    """enum ScanAutoSaveVerifier { localAi, cloudAi }

String scanAutoSaveVerifierLabel(ScanAutoSaveVerifier verifier) =>
    switch (verifier) {
      ScanAutoSaveVerifier.localAi => 'Local AI',
      ScanAutoSaveVerifier.cloudAi => 'Cloud AI',
    };
""",
    """enum ScanAutoSaveVerifier { localAi }

String scanAutoSaveVerifierLabel(ScanAutoSaveVerifier verifier) => 'Local AI';
""",
    'remove dead cloud auto-save authority',
)
text = replace_once(
    text,
    'requires this exact OCR draft to have crossed one source-verified AI route\n',
    'requires this exact OCR draft to have crossed the source-verified Local AI route\n',
    'autosave provenance comment',
)
write(path, text)

path = 'test/scan_auto_save_decision_test.dart'
text = read(path)
text = replace_once(
    text,
    """    expect(
      scanAutoSaveDecision(
        draft,
        resolution,
        verifier: ScanAutoSaveVerifier.cloudAi,
      ).allowed,
      isTrue,
    );
""",
    '',
    'remove obsolete cloud autosave test',
)
write(path, text)

path = 'test/scan_ingestion_privacy_contract_test.dart'
text = read(path)
text = replace_once(
    text,
    """    final capture = File('lib/ui/medicine_capture.dart').readAsStringSync();

    expect(normal, isNot(contains('CloudScanAiService')));""",
    """    final capture = File('lib/ui/medicine_capture.dart').readAsStringSync();
    final commitPolicy = File(
      'lib/domain/medicine_scan_commit.dart',
    ).readAsStringSync();

    expect(normal, isNot(contains('CloudScanAiService')));""",
    'load commit privacy source',
)
text = replace_once(
    text,
    """    expect(capture, contains('Scan with cloud AI'));
    expect(capture, contains('CloudScanReviewScreen'));
""",
    """    expect(capture, contains('Scan with cloud AI'));
    expect(capture, contains('CloudScanReviewScreen'));
    expect(commitPolicy, isNot(contains('cloudAi')));
""",
    'assert no cloud machine-save authority',
)
write(path, text)

path = 'docs/SCAN_AI_ROUTING_2026_09_11.md'
text = read(path)
text = replace_once(
    text,
    """A source-verified Local or Cloud AI result can proceed to automatic save only when
Brand + Salt + Strength + Form, overall confidence, batch/date integrity, duplicate
resolution, and live inventory revision all pass. Any ambiguity stops at review.
""",
    """A source-verified Local AI result can proceed to automatic save only when
Brand + Salt + Strength + Form, overall confidence, batch/date integrity, duplicate
resolution, and live inventory revision all pass. The explicit cloud lane is
review-only; cloud output never receives machine-save provenance. Any ambiguity
stops at review.
""",
    'document local-only machine save',
)
write(path, text)

path = 'docs/SCAN_INGESTION_HARDENING_2026_09_11.md'
text = read(path)
text += """

## Crash-consistency cleanup hardening

A successfully checkpointed photo/video draft is now independent from private-source housekeeping. If Android temporarily refuses source deletion, the job remains in its valid review/reasoning state and retains the validated private path for a later Retry/Dismiss cleanup attempt instead of being rewritten as `failed`.

Startup also removes only strict unreferenced `<32-hex-id>.jpg/.mp4` capture files from the private intake directory. This closes the narrow process-death window after private copy but before the SQLite job insert without touching database files or any source still referenced by a restored job.

## Machine-save authority cleanup

The explicit cloud scan screen is pharmacist-review-only, so the obsolete `ScanAutoSaveVerifier.cloudAi` authority was removed. Direct unattended scan save now has exactly one provenance: a source-verified, scan-verified Local AI route plus the deterministic duplicate/lot/date/confidence/revision gates.
"""
write(path, text)

print('Aaris intake cleanup hardening applied successfully.')
