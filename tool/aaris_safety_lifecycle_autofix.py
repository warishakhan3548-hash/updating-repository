from pathlib import Path


def replace_once(path: str, old: str, new: str) -> None:
    file = Path(path)
    text = file.read_text(encoding="utf-8")
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{path}: expected exactly one patch anchor, found {count}")
    file.write_text(text.replace(old, new, 1), encoding="utf-8")


# 1) Aaris Brain: fail closed on multi-target/chained stock-changing commands
# even when every clause belongs to the same mutation family. This happens before
# fuzzy target resolution, so a sentence such as "delete A and B" can never be
# reduced into one accidental stock target.
replace_once(
    "lib/domain/app_brain.dart",
    """  if (_containsAny(text, _deferredWriteSafetyTerms) ||\n      _looksLikeScheduledMutation(raw)) {\n    return AppBrainSafetyReason.deferredMutation;\n  }\n\n  final sequencedOrChoice = _containsAny(text, _sequenceOrChoiceSafetyTerms);\n""",
    """  if (_containsAny(text, _deferredWriteSafetyTerms) ||\n      _looksLikeScheduledMutation(raw)) {\n    return AppBrainSafetyReason.deferredMutation;\n  }\n\n  // A single mutation family can still contain multiple targets/actions:\n  // “delete Dolo and Crocin”, “sell A and sell B”, or two commands separated\n  // by a semicolon/newline. Never let query cleanup collapse such a sentence\n  // into one fuzzy medicine target. Editor-only field/location wording is not\n  // included here because those paths open a human review surface rather than\n  // committing a stock-state transition.\n  if (_hasMultiTargetOrChainedStockMutation(raw, text, families)) {\n    return AppBrainSafetyReason.compoundMutation;\n  }\n\n  final sequencedOrChoice = _containsAny(text, _sequenceOrChoiceSafetyTerms);\n""",
)

replace_once(
    "lib/domain/app_brain.dart",
    """  if (families.length > 1) {\n    return AppBrainSafetyReason.compoundMutation;\n  }\n  return null;\n}\n\nbool _looksLikeLocationMutation(String text) =>\n""",
    """  if (families.length > 1) {\n    return AppBrainSafetyReason.compoundMutation;\n  }\n  return null;\n}\n\nconst _multiTargetSensitiveMutationFamilies = <String>{\n  'remove',\n  'sold',\n  'sale',\n  'restore',\n  'undo',\n  'set-quantity',\n  'receive-stock',\n};\n\nbool _hasMultiTargetOrChainedStockMutation(\n  String raw,\n  String text,\n  Set<String> families,\n) {\n  if (!families.any(_multiTargetSensitiveMutationFamilies.contains)) {\n    return false;\n  }\n\n  // “backup and restore” belongs to the dedicated data-recovery surface and\n  // does not mean restore an archived medicine row. Preserve that navigation.\n  if (_containsAny(text, _backupRestoreTerms)) return false;\n\n  // Explicit hard separators are always treated as multiple instructions for a\n  // stock-changing sentence. Commas are intentionally excluded because they can\n  // legitimately occur inside medicine/composition names.\n  if (RegExp(r'[;\\r\\n]').hasMatch(raw)) return true;\n\n  if (_containsAny(text, _sequenceOrChoiceSafetyTerms)) return true;\n\n  // Plain conjunctions were historically harmless when different write families\n  // were present because the family-count guard caught them. They are dangerous\n  // for repeated/same-family writes, where target cleanup could otherwise turn\n  // “A and B” into one fuzzy lookup.\n  return _containsAny(text, const <String>['and', 'aur', 'और']);\n}\n\nbool _looksLikeLocationMutation(String text) =>\n""",
)

# Regression coverage for the intent firewall and the backup/restore carve-out.
replace_once(
    "test/app_brain_test.dart",
    """    test('blocks bulk destructive natural-language commands', () {\n      final intent = parseAppBrainIntent('sab medicines delete karo');\n      expect(intent.action, AppBrainAction.bulkRemoveBlocked);\n      expect(intent.confidence, 1);\n      expect(intent.destructive, isTrue);\n    });\n""",
    """    test('blocks bulk destructive natural-language commands', () {\n      final intent = parseAppBrainIntent('sab medicines delete karo');\n      expect(intent.action, AppBrainAction.bulkRemoveBlocked);\n      expect(intent.confidence, 1);\n      expect(intent.destructive, isTrue);\n    });\n\n    test(\n      'blocks same-family multi-target writes before fuzzy target resolution',\n      () {\n        for (final command in <String>[\n          'Dolo delete karo aur Crocin delete karo',\n          'Dolo delete karo and Crocin',\n          'Dolo 5 units sell and Crocin 3 units sell',\n          'Dolo remove; Crocin remove',\n        ]) {\n          final intent = parseAppBrainIntent(command);\n          expect(\n            intent.action,\n            AppBrainAction.safetyBlocked,\n            reason: command,\n          );\n          expect(\n            intent.safetyReason,\n            AppBrainSafetyReason.compoundMutation,\n            reason: command,\n          );\n          expect(intent.mutatesInventory, isFalse, reason: command);\n        }\n      },\n    );\n\n    test('backup and restore remains data-recovery navigation', () {\n      final intent = parseAppBrainIntent('backup and restore kholo');\n      expect(intent.action, AppBrainAction.navigate);\n      expect(intent.section, AppSection.profile);\n      expect(intent.safetyReason, isNull);\n    });\n""",
)

# 2) Persistent scan/intake queue: stop launching more OCR/reasoning work while
# the app is not foreground-resumed. Let an already admitted checkpoint finish so
# no durable job/file is left half-written, then resume automatically later.
replace_once(
    "lib/services/medicine_intake_service.dart",
    """  bool _running = false, _paused = false;\n""",
    """  bool _running = false, _paused = false, _appActive = true;\n""",
)

replace_once(
    "lib/services/medicine_intake_service.dart",
    """    if (!_observingMemory) {\n      WidgetsBinding.instance.addObserver(this);\n      _observingMemory = true;\n    }\n    _ready = true;\n""",
    """    if (!_observingMemory) {\n      WidgetsBinding.instance.addObserver(this);\n      _observingMemory = true;\n    }\n    final lifecycle = WidgetsBinding.instance.lifecycleState;\n    _appActive =\n        lifecycle == null || lifecycle == AppLifecycleState.resumed;\n    _ready = true;\n""",
)

replace_once(
    "lib/services/medicine_intake_service.dart",
    """  @override\n  void didHaveMemoryPressure() {\n    _paused = true;\n    pauseReason =\n        'Device memory is low. Close other apps, then resume this saved queue.';\n    _knowledge = null;\n    _knowledgeRevision = null;\n    notifyListeners();\n  }\n\n  void setPaused(bool value) {\n""",
    """  @override\n  void didHaveMemoryPressure() {\n    _paused = true;\n    pauseReason =\n        'Device memory is low. Close other apps, then resume this saved queue.';\n    _knowledge = null;\n    _knowledgeRevision = null;\n    notifyListeners();\n  }\n\n  @override\n  void didChangeAppLifecycleState(AppLifecycleState state) {\n    final active = state == AppLifecycleState.resumed;\n    if (_appActive == active) return;\n    _appActive = active;\n\n    // Identity-only derived knowledge can be rebuilt cheaply after resume and\n    // need not occupy memory while the app is backgrounded. Do not rewrite the\n    // user's explicit/manual pause state here.\n    if (!active) {\n      _knowledge = null;\n      _knowledgeRevision = null;\n      notifyListeners();\n      return;\n    }\n\n    notifyListeners();\n    _kick();\n  }\n\n  void setPaused(bool value) {\n""",
)

replace_once(
    "lib/services/medicine_intake_service.dart",
    """    if (_running ||\n        _paused ||\n        !_ready ||\n""",
    """    if (_running ||\n        _paused ||\n        !_appActive ||\n        !_ready ||\n""",
)

replace_once(
    "lib/services/medicine_intake_service.dart",
    """      while (!_paused) {\n""",
    """      while (!_paused && _appActive) {\n""",
)

# 3) Read-only Autopilot: suspend expensive isolate analysis when the app is in
# the background. Generation invalidation guarantees an in-flight stale result is
# discarded, while resume performs one fresh authoritative pass.
replace_once(
    "lib/state/autopilot_supervisor.dart",
    """  bool _disposed = false;\n  bool _computing = false;\n  bool _rerunRequested = false;\n\n  void _onControllerChanged() => _schedule();\n\n  void _schedule() {\n    if (_disposed) return;\n""",
    """  bool _disposed = false;\n  bool _computing = false;\n  bool _rerunRequested = false;\n  bool _lifecycleActive = true;\n\n  bool get lifecycleActive => _lifecycleActive;\n\n  /// Pauses read-only background planning outside the foreground lifecycle. Any\n  /// in-flight result is generation-invalidated and therefore cannot publish a\n  /// stale badge/task after the app was backgrounded. Resume always requests one\n  /// fresh pass from the authoritative controller snapshot.\n  void setLifecycleActive(bool active) {\n    if (_disposed) return;\n    if (_lifecycleActive == active) {\n      if (active) refreshNow();\n      return;\n    }\n\n    _lifecycleActive = active;\n    _timer?.cancel();\n    _timer = null;\n    ++_generation;\n    _rerunRequested = false;\n    if (active) refreshNow();\n  }\n\n  void _onControllerChanged() => _schedule();\n\n  void _schedule() {\n    if (_disposed || !_lifecycleActive) return;\n""",
)

replace_once(
    "lib/state/autopilot_supervisor.dart",
    """  void refreshNow() {\n    if (_disposed) return;\n""",
    """  void refreshNow() {\n    if (_disposed || !_lifecycleActive) return;\n""",
)

replace_once(
    "lib/state/autopilot_supervisor.dart",
    """  void _launch(int generation) {\n    if (_disposed || generation != _generation) return;\n""",
    """  void _launch(int generation) {\n    if (_disposed || !_lifecycleActive || generation != _generation) return;\n""",
)

replace_once(
    "lib/state/autopilot_supervisor.dart",
    """  Future<void> _rebuild(int generation) async {\n    if (_disposed || generation != _generation) return;\n""",
    """  Future<void> _rebuild(int generation) async {\n    if (_disposed || !_lifecycleActive || generation != _generation) return;\n""",
)

replace_once(
    "lib/state/autopilot_supervisor.dart",
    """      final result = await compute(_evaluateAutopilot, payload);\n      if (_disposed || generation != _generation) return;\n""",
    """      final result = await compute(_evaluateAutopilot, payload);\n      if (_disposed || !_lifecycleActive || generation != _generation) return;\n""",
)

replace_once(
    "lib/state/autopilot_supervisor.dart",
    """    } catch (_) {\n      if (_disposed || generation != _generation) return;\n""",
    """    } catch (_) {\n      if (_disposed || !_lifecycleActive || generation != _generation) return;\n""",
)

# Connect the supervisor to the app lifecycle, including controller replacement
# while the app is already backgrounded.
replace_once(
    "lib/app.dart",
    """    _autopilot = AarisAutopilotSupervisor(widget.controller);\n  }\n\n  @override\n  void didUpdateWidget(covariant PharmacyApp oldWidget) {\n""",
    """    _autopilot = AarisAutopilotSupervisor(widget.controller);\n    _autopilot.setLifecycleActive(_isForeground);\n  }\n\n  bool get _isForeground {\n    final state = WidgetsBinding.instance.lifecycleState;\n    return state == null || state == AppLifecycleState.resumed;\n  }\n\n  @override\n  void didUpdateWidget(covariant PharmacyApp oldWidget) {\n""",
)

replace_once(
    "lib/app.dart",
    """    if (oldWidget.controller != widget.controller) {\n      _autopilot.dispose();\n      _autopilot = AarisAutopilotSupervisor(widget.controller);\n    }\n""",
    """    if (oldWidget.controller != widget.controller) {\n      _autopilot.dispose();\n      _autopilot = AarisAutopilotSupervisor(widget.controller);\n      _autopilot.setLifecycleActive(_isForeground);\n    }\n""",
)

replace_once(
    "lib/app.dart",
    """  void didChangeAppLifecycleState(AppLifecycleState state) {\n    if (state == AppLifecycleState.resumed) {\n      widget.controller.refreshDay();\n      _autopilot.refreshNow();\n    }\n  }\n""",
    """  void didChangeAppLifecycleState(AppLifecycleState state) {\n    if (state == AppLifecycleState.resumed) {\n      // Refresh the civil business day first; the resumed Autopilot pass then\n      // observes the final authoritative day/revision instead of doing two\n      // expensive isolate evaluations.\n      widget.controller.refreshDay();\n      _autopilot.setLifecycleActive(true);\n      return;\n    }\n    _autopilot.setLifecycleActive(false);\n  }\n""",
)

# Lifecycle regression test for generation invalidation and foreground catch-up.
replace_once(
    "test/autopilot_supervisor_test.dart",
    """import 'package:aaris_pharmacy/domain/attention.dart';\n""",
    """import 'package:aaris_pharmacy/data/inventory_database.dart';\nimport 'package:aaris_pharmacy/domain/attention.dart';\n""",
)
replace_once(
    "test/autopilot_supervisor_test.dart",
    """import 'package:aaris_pharmacy/state/autopilot_supervisor.dart';\n""",
    """import 'package:aaris_pharmacy/state/autopilot_supervisor.dart';\nimport 'package:aaris_pharmacy/state/pharmacy_controller.dart';\n""",
)

replace_once(
    "test/autopilot_supervisor_test.dart",
    """    test('autopilot calculation failure is fail-visible, never a false clear', () {\n      final digest = AarisAutopilotDigest.degraded(\n        inventoryRevision: 46,\n        evaluatedAt: DateTime(2026, 9, 10, 10),\n      );\n\n      expect(digest.health, AarisAutopilotHealth.degraded);\n      expect(digest.issueCount, 0);\n      expect(digest.needsProminentSignal, isTrue);\n      expect(digest.navigationBadgeCount, 1);\n      expect(digest.accessibilitySummary, contains('retry'));\n    });\n""",
    """    test('autopilot calculation failure is fail-visible, never a false clear', () {\n      final digest = AarisAutopilotDigest.degraded(\n        inventoryRevision: 46,\n        evaluatedAt: DateTime(2026, 9, 10, 10),\n      );\n\n      expect(digest.health, AarisAutopilotHealth.degraded);\n      expect(digest.issueCount, 0);\n      expect(digest.needsProminentSignal, isTrue);\n      expect(digest.navigationBadgeCount, 1);\n      expect(digest.accessibilitySummary, contains('retry'));\n    });\n\n    test(\n      'background suspension drops stale work and resume catches up once',\n      () async {\n        final controller = PharmacyController(\n          MemoryInventoryStorage(),\n          clock: () => DateTime(2026, 9, 10, 10),\n          backgroundSearch: false,\n        );\n        await controller.initialize();\n        final supervisor = AarisAutopilotSupervisor(\n          controller,\n          debounce: Duration.zero,\n        );\n        addTearDown(() {\n          supervisor.dispose();\n          controller.dispose();\n        });\n\n        // Suspend before the constructor's scheduled microtask can publish.\n        supervisor.setLifecycleActive(false);\n        expect(supervisor.lifecycleActive, isFalse);\n\n        await controller.save(\n          Medicine.fromJson(<String, dynamic>{\n            'id': 'foreground-test',\n            'name': 'Dolo',\n            'quantity': 1,\n          }),\n        );\n        await Future<void>.delayed(const Duration(milliseconds: 40));\n        expect(supervisor.digest.inventoryRevision, 0);\n\n        supervisor.setLifecycleActive(true);\n        for (var attempt = 0; attempt < 50; attempt++) {\n          if (supervisor.digest.inventoryRevision ==\n              controller.snapshot.revision) {\n            break;\n          }\n          await Future<void>.delayed(const Duration(milliseconds: 20));\n        }\n        expect(supervisor.lifecycleActive, isTrue);\n        expect(\n          supervisor.digest.inventoryRevision,\n          controller.snapshot.revision,\n        );\n      },\n    );\n""",
)

print("Aaris safety/lifecycle surgical patch applied.")
