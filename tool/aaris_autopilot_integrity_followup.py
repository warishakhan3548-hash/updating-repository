from pathlib import Path


def replace_once(path: str, old: str, new: str) -> None:
    file = Path(path)
    text = file.read_text(encoding="utf-8")
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{path}: expected exactly one follow-up anchor, found {count}")
    file.write_text(text.replace(old, new, 1), encoding="utf-8")


# Fix the lifecycle regression test added by the first surgical patch: controller
# saves are revision-bound by design, including test callers.
replace_once(
    "test/autopilot_supervisor_test.dart",
    """        await controller.save(\n          Medicine.fromJson(<String, dynamic>{\n            'id': 'foreground-test',\n            'name': 'Dolo',\n            'quantity': 1,\n          }),\n        );\n""",
    """        await controller.save(\n          Medicine.fromJson(<String, dynamic>{\n            'id': 'foreground-test',\n            'name': 'Dolo',\n            'quantity': 1,\n          }),\n          expectedRevision: controller.snapshot.revision,\n        );\n""",
)

# Sale-history integrity is operational safety evidence, not demand velocity.
# Allow Attention callers to provide a dedicated audit slice while keeping the
# existing recent-sales input for reorder / expiry-waste calculations.
replace_once(
    "lib/domain/attention.dart",
    """    required DateTime today,\n    required Iterable<ReorderSuggestion> reorder,\n    Iterable<SaleEvent> sales = const <SaleEvent>[],\n  }) {\n""",
    """    required DateTime today,\n    required Iterable<ReorderSuggestion> reorder,\n    Iterable<SaleEvent> sales = const <SaleEvent>[],\n    Iterable<SaleEvent>? saleHistorySales,\n  }) {\n""",
)
replace_once(
    "lib/domain/attention.dart",
    """    final saleHistoryIntegrity = SaleHistoryIntegrityReport.build(\n      medicines: active,\n      sales: sales,\n      today: day,\n    );\n""",
    """    final saleHistoryIntegrity = SaleHistoryIntegrityReport.build(\n      medicines: active,\n      sales: saleHistorySales ?? sales,\n      today: day,\n    );\n""",
)

# Expose the exact deterministic prefilter used by Autopilot. It returns true
# only when a persisted event can actually become a SaleHistoryIntegrity issue;
# no medical inference and no mutation are involved.
replace_once(
    "lib/domain/sale_history_integrity.dart",
    """class SaleHistoryIntegrityReport {\n""",
    """bool isSaleHistoryIntegrityCandidate({\n  required Medicine? stock,\n  required SaleEvent sale,\n  required DateTime today,\n}) {\n  if (stock == null || stock.archived) return false;\n\n  final day = civilDay(today);\n  final saleDay = civilDay(sale.occurredAt);\n  if (saleDay.isAfter(day)) return true;\n\n  // A later pharmacist identity correction deliberately severs chronology\n  // comparison with today's MFG/EXP facts. The immutable sale snapshot remains\n  // honest history and must not become a false alert for the corrected product.\n  if (sale.productKey != stock.identity) return false;\n\n  return (stock.mfg != null && saleDay.isBefore(civilDay(stock.mfg!))) ||\n      (stock.expiry != null && saleDay.isAfter(civilDay(stock.expiry!)));\n}\n\nclass SaleHistoryIntegrityReport {\n""",
)

# Autopilot previously transferred only the recent 30-day demand window to its
# isolate, then reused that truncated list for sale-history integrity. That made
# future-dated events and older lifecycle contradictions invisible to the global
# Brain badge/task planner. Transfer recent demand plus only full-history events
# that can actually generate an audit issue: bounded in normal operation, exact,
# local-only, and no duplicate database.
replace_once(
    "lib/state/autopilot_supervisor.dart",
    """import '../domain/operations_plan.dart';\nimport '../domain/tracking.dart';\n""",
    """import '../domain/operations_plan.dart';\nimport '../domain/sale_history_integrity.dart';\nimport '../domain/tracking.dart';\n""",
)

replace_once(
    "lib/state/autopilot_supervisor.dart",
    """  final sales = <SaleEvent>[\n    for (final raw in payload['sales'] as List<dynamic>)\n      SaleEvent.fromJson(Map<String, dynamic>.from(raw as Map)),\n  ];\n  final settings = WarningSettings.fromJson(\n""",
    """  final sales = <SaleEvent>[\n    for (final raw in payload['sales'] as List<dynamic>)\n      SaleEvent.fromJson(Map<String, dynamic>.from(raw as Map)),\n  ];\n  final saleHistorySales = <SaleEvent>[\n    for (final raw in payload['saleHistorySales'] as List<dynamic>)\n      SaleEvent.fromJson(Map<String, dynamic>.from(raw as Map)),\n  ];\n  final settings = WarningSettings.fromJson(\n""",
)

replace_once(
    "lib/state/autopilot_supervisor.dart",
    """    reorder: tracking.reorder,\n    sales: sales,\n  );\n""",
    """    reorder: tracking.reorder,\n    sales: sales,\n    saleHistorySales: saleHistorySales,\n  );\n""",
)

# Coalesce controller notifications by authoritative facts. The controller also
# notifies for AI progress / transient UI work; those changes should not rescan
# sale history or launch an operations isolate when revision and civil day did
# not change.
replace_once(
    "lib/state/autopilot_supervisor.dart",
    """    controller.addListener(_onControllerChanged);\n    refreshNow();\n  }\n""",
    """    _observedRevision = controller.snapshot.revision;\n    _observedDay = dateText(controller.today);\n    controller.addListener(_onControllerChanged);\n    refreshNow();\n  }\n""",
)

replace_once(
    "lib/state/autopilot_supervisor.dart",
    """  bool _rerunRequested = false;\n  bool _lifecycleActive = true;\n\n  bool get lifecycleActive => _lifecycleActive;\n""",
    """  bool _rerunRequested = false;\n  bool _lifecycleActive = true;\n  int _observedRevision = -1;\n  String _observedDay = '';\n\n  bool get lifecycleActive => _lifecycleActive;\n""",
)

replace_once(
    "lib/state/autopilot_supervisor.dart",
    """  void _onControllerChanged() => _schedule();\n\n  void _schedule() {\n""",
    """  void _onControllerChanged() {\n    final revision = controller.snapshot.revision;\n    final day = dateText(controller.today);\n    if (revision == _observedRevision && day == _observedDay) return;\n    _observedRevision = revision;\n    _observedDay = day;\n    _schedule();\n  }\n\n  void _schedule() {\n""",
)

replace_once(
    "lib/state/autopilot_supervisor.dart",
    """      final today = controller.today;\n      final start = today.subtract(const Duration(days: 29));\n\n      // Capture only operational fields. Large OCR/notes text is intentionally\n      // excluded because it is irrelevant to integrity, FEFO, risk and reorder.\n      // Sales are bounded to the exact 30-day evidence window consumed by both\n      // TrackingStats and PharmacyStockRiskReport.\n      final payload = <String, dynamic>{\n""",
    """      final today = controller.today;\n      final start = today.subtract(const Duration(days: 29));\n      final activeById = <String, Medicine>{\n        for (final medicine in controller.records)\n          if (!medicine.archived) medicine.id: medicine,\n      };\n      final recentSales = <Map<String, dynamic>>[];\n      final saleHistorySales = <Map<String, dynamic>>[];\n      for (final sale in controller.sales) {\n        final saleDay = civilDay(sale.occurredAt);\n        if (!saleDay.isBefore(start) && !saleDay.isAfter(today)) {\n          recentSales.add(sale.toJson());\n        }\n        if (isSaleHistoryIntegrityCandidate(\n          stock: activeById[sale.stockId],\n          sale: sale,\n          today: today,\n        )) {\n          saleHistorySales.add(sale.toJson());\n        }\n      }\n\n      // Capture only operational fields. Large OCR/notes text is intentionally\n      // excluded because it is irrelevant to integrity, FEFO, risk and reorder.\n      // Recent sales drive velocity/risk; the second list contains only exact\n      // full-history anomalies that can become immutable-ledger safety tasks.\n      final payload = <String, dynamic>{\n""",
)

replace_once(
    "lib/state/autopilot_supervisor.dart",
    """        'sales': <Map<String, dynamic>>[\n          for (final sale in controller.sales)\n            if (!civilDay(sale.occurredAt).isBefore(start) &&\n                !civilDay(sale.occurredAt).isAfter(today))\n              sale.toJson(),\n        ],\n        'settings': controller.settings.toJson(),\n""",
    """        'sales': recentSales,\n        'saleHistorySales': saleHistorySales,\n        'settings': controller.settings.toJson(),\n""",
)

# Add immutable-sale type for the new end-to-end Autopilot regression test.
replace_once(
    "test/autopilot_supervisor_test.dart",
    """import 'package:aaris_pharmacy/domain/operations_plan.dart';\n""",
    """import 'package:aaris_pharmacy/domain/operations_plan.dart';\nimport 'package:aaris_pharmacy/domain/tracking.dart';\n""",
)

replace_once(
    "test/autopilot_supervisor_test.dart",
    """    test(\n      'background suspension drops stale work and resume catches up once',\n""",
    """    test(\n      'future recovered sale history remains visible outside demand window',\n      () async {\n        final medicine = Medicine.fromJson(<String, dynamic>{\n          'id': 'future-sale-stock',\n          'name': 'Dolo',\n          'strength': '650mg',\n          'form': 'Tablet',\n          'mfg': '2026-01-01',\n          'expiry': '2027-01-31',\n          'quantity': 10,\n          'location': 'Rack A',\n        });\n        final sale = SaleEvent(\n          id: 'future-sale-event',\n          stockId: medicine.id,\n          medicineName: medicine.name,\n          strength: medicine.strength,\n          form: medicine.form,\n          salt: medicine.salt,\n          quantity: 1,\n          occurredAt: DateTime(2026, 9, 11, 9),\n        );\n        final controller = PharmacyController(\n          MemoryInventoryStorage(\n            InventorySnapshot(\n              records: <String, Medicine>{medicine.id: medicine},\n              sales: <String, SaleEvent>{sale.id: sale},\n            ),\n          ),\n          clock: () => DateTime(2026, 9, 10, 10),\n          backgroundSearch: false,\n        );\n        await controller.initialize();\n        final supervisor = AarisAutopilotSupervisor(\n          controller,\n          debounce: Duration.zero,\n        );\n        addTearDown(() {\n          supervisor.dispose();\n          controller.dispose();\n        });\n\n        for (var attempt = 0; attempt < 50; attempt++) {\n          if (supervisor.digest.isReady &&\n              supervisor.digest.inventoryRevision ==\n                  controller.snapshot.revision) {\n            break;\n          }\n          await Future<void>.delayed(const Duration(milliseconds: 20));\n        }\n\n        expect(supervisor.digest.highCount, greaterThanOrEqualTo(1));\n        expect(\n          supervisor.digest.nextKind,\n          AttentionKind.futureSaleHistory,\n        );\n      },\n    );\n\n    test(\n      'background suspension drops stale work and resume catches up once',\n""",
)

print("Aaris Autopilot integrity follow-up applied.")
