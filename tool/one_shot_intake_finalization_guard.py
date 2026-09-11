from pathlib import Path


def replace_once(path: Path, old: str, new: str, label: str) -> None:
    text = path.read_text()
    count = text.count(old)
    if count != 1:
        raise SystemExit(f'{path}: {label} expected once, found {count}')
    path.write_text(text.replace(old, new, 1))


domain = Path('lib/domain/medicine_intake.dart')
replace_once(
    domain,
    "import 'medicine.dart';",
    "import 'dart:async';\n\nimport 'medicine.dart';",
    'async import anchor',
)

scheduler_anchor = "/// Alternate durable OCR/capture work with Local AI reasoning when both are\n"
barrier = '''/// Coordinates one worker-owned capture with user terminal actions.
///
/// OCR/video processing deliberately checkpoints durable review state before
/// private source cleanup finishes. The UI can therefore observe `review` or
/// `failed` for a few asynchronous instructions while the worker still owns the
/// same row. Retry/Dismiss must wait for that exact ownership lease to end; a
/// global queue lock would unnecessarily block unrelated captures.
class MedicineIntakeWorkBarrier {
  String? _activeId;
  Completer<void>? _released;

  bool owns(String id) => _activeId == id;

  void begin(String id) {
    if (_released != null) {
      throw StateError('A medicine intake worker lease is already active.');
    }
    _activeId = id;
    _released = Completer<void>();
  }

  Future<void> wait(String id) {
    final released = _activeId == id ? _released : null;
    return released?.future ?? Future<void>.value();
  }

  void finish(String id) {
    // A stale finalizer can never release a newer capture's lease.
    if (_activeId != id) return;
    final released = _released;
    _activeId = null;
    _released = null;
    if (released != null && !released.isCompleted) released.complete();
  }
}

'''
replace_once(domain, scheduler_anchor, barrier + scheduler_anchor, 'scheduler anchor')

service = Path('lib/services/medicine_intake_service.dart')
replace_once(
    service,
    "  Future<void> _intakeWrites = Future.value();\n  bool _running = false, _paused = false, _appActive = true;",
    "  Future<void> _intakeWrites = Future.value();\n  final _workBarrier = MedicineIntakeWorkBarrier();\n  bool _running = false, _paused = false, _appActive = true;",
    'worker barrier field anchor',
)

pump_anchor = '''        try {
          if (job.status == 'reasoning') {
            _preferReasoning = false;
            await _reason(job);
          } else {
            _preferReasoning = true;
            job.status = 'processing';
            await _persist(job);
            if (job.kind == 'video') {
              await _videoStep(job);
            } else {
              await _photoStep(job);
            }
          }
          await _persist(job);
        } catch (e) {
          job.status = 'failed';
          job.error = e.toString();
          await _persist(job);
        }
'''
pump_replacement = '''        _workBarrier.begin(job.id);
        try {
          try {
            if (job.status == 'reasoning') {
              _preferReasoning = false;
              await _reason(job);
            } else {
              _preferReasoning = true;
              job.status = 'processing';
              await _persist(job);
              if (job.kind == 'video') {
                await _videoStep(job);
              } else {
                await _photoStep(job);
              }
            }
            await _persist(job);
          } catch (e) {
            job.status = 'failed';
            job.error = e.toString();
            await _persist(job);
          }
        } finally {
          // Terminal state may have been checkpointed earlier by the OCR/video
          // step. Release only after the worker's final row write/cleanup path is
          // completely finished so Retry/Dismiss cannot delete beneath it.
          _workBarrier.finish(job.id);
        }
'''
replace_once(service, pump_anchor, pump_replacement, 'pump ownership anchor')

terminal_anchor = '''  Future<void> retry(MedicineIntakeJob job) async {
    if (!job.terminal) return;
    if (job.kind == 'video' &&
        job.path.isNotEmpty &&
        job.cursorMs < job.durationMs) {
      job.status = 'queued';
    } else if (job.drafts.isNotEmpty) {
      job.modelId = await LocalBrainRoutePolicy.captureModelId(
        LocalAiService.instance,
      );
      job.aiIndex = 0;
      job.status = job.modelId == null ? 'review' : 'reasoning';
    } else {
      job.status = 'queued';
    }
    job.error = '';
    persistenceError = '';
    await _persist(job);
    _kick();
  }

  Future<void> dismiss(MedicineIntakeJob job) async {
    if (!job.terminal) {
      throw StateError('Pause/finish processing before dismissing a capture.');
    }
    await _database!.delete('jobs', where: 'id=?', whereArgs: [job.id]);
    _jobs.remove(job);
    if (job.path.isNotEmpty && job.path == _capturePath(job.id, job.kind)) {
      final file = File(job.path);
      if (await file.exists()) await file.delete();
    }
    notifyListeners();
  }
'''
terminal_replacement = '''  Future<void> retry(MedicineIntakeJob job) async {
    // A durable terminal checkpoint can become visible before the worker has
    // finished source cleanup/final persistence. Wait only for this exact job;
    // unrelated captures continue to enqueue and process independently.
    await _workBarrier.wait(job.id);
    await _enqueue(() async {
      if (!_jobs.contains(job) || !job.terminal) return;
      if (job.kind == 'video' &&
          job.path.isNotEmpty &&
          job.cursorMs < job.durationMs) {
        job.status = 'queued';
      } else if (job.drafts.isNotEmpty) {
        job.modelId = await LocalBrainRoutePolicy.captureModelId(
          LocalAiService.instance,
        );
        job.aiIndex = 0;
        job.status = job.modelId == null ? 'review' : 'reasoning';
      } else {
        job.status = 'queued';
      }
      job.error = '';
      persistenceError = '';
      await _persist(job);
    });
    _kick();
  }

  Future<void> dismiss(MedicineIntakeJob job) async {
    await _workBarrier.wait(job.id);
    await _enqueue(() async {
      if (!_jobs.contains(job)) return;
      if (!job.terminal) {
        throw StateError('Pause/finish processing before dismissing a capture.');
      }
      final deleted = await _database!.delete(
        'jobs',
        where: 'id=?',
        whereArgs: [job.id],
      );
      if (deleted != 1) {
        throw StateError('Capture draft could not be dismissed safely.');
      }
      _jobs.remove(job);

      // SQLite owns dismissal. Source-file cleanup is housekeeping and must not
      // turn a successfully removed durable job into a false dismissal failure.
      if (job.path.isNotEmpty && job.path == _capturePath(job.id, job.kind)) {
        try {
          final file = File(job.path);
          if (await file.exists()) await file.delete();
        } catch (_) {}
      }
      notifyListeners();
    });
  }
'''
replace_once(service, terminal_anchor, terminal_replacement, 'terminal action anchor')

Path('test/medicine_intake_concurrency_test.dart').write_text('''import 'package:flutter_test/flutter_test.dart';

import '../lib/domain/medicine_intake.dart';

void main() {
  test('terminal action waits for the exact worker-owned capture', () async {
    final barrier = MedicineIntakeWorkBarrier();
    barrier.begin('capture-a');

    var released = false;
    final waiter = barrier.wait('capture-a').then((_) => released = true);
    await Future<void>.delayed(Duration.zero);
    expect(released, isFalse);

    barrier.finish('capture-a');
    await waiter;
    expect(released, isTrue);
  });

  test('unrelated capture never waits behind the active worker lease', () async {
    final barrier = MedicineIntakeWorkBarrier();
    barrier.begin('capture-a');

    await barrier
        .wait('capture-b')
        .timeout(const Duration(milliseconds: 100));
    barrier.finish('capture-a');
  });

  test('stale finalizer cannot release a newer capture lease', () async {
    final barrier = MedicineIntakeWorkBarrier();
    barrier.begin('capture-a');
    barrier.finish('capture-a');
    barrier.begin('capture-b');

    var released = false;
    final waiter = barrier.wait('capture-b').then((_) => released = true);
    barrier.finish('capture-a');
    await Future<void>.delayed(Duration.zero);
    expect(released, isFalse);

    barrier.finish('capture-b');
    await waiter;
    expect(released, isTrue);
  });
}
''')

doc = Path('docs/CODEBASE_TREE.md')
text = doc.read_text()
heading = '## Intake finalization intersection\n'
if heading not in text:
    text += '''

## Intake finalization intersection

The capture queue has an intentional two-phase durability boundary:

`OCR/video evidence -> durable terminal/reasoning checkpoint -> private source cleanup -> final row checkpoint -> worker lease release -> Retry/Dismiss`

A terminal card may render after the first checkpoint, before the worker has
finished the final cleanup/write. `MedicineIntakeWorkBarrier` binds that tiny
window to the exact job ID. Retry/Dismiss wait only for that job and then enter
the existing serialized intake-write lane, preventing delete/update races without
blocking unrelated captures or adding a second queue engine. Dismissal treats
SQLite row removal as authoritative and source-file deletion as best-effort
housekeeping.
'''
doc.write_text(text)
