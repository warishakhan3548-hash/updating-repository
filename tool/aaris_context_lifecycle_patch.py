from pathlib import Path


def replace_once(path: str, old: str, new: str) -> None:
    p = Path(path)
    text = p.read_text()
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{path}: expected exactly one anchor, found {count}")
    p.write_text(text.replace(old, new, 1))


# 1) Brain intent contract: exact session context may satisfy only a
# deterministic single-target command whose target text is omitted.
replace_once(
    "lib/domain/app_brain.dart",
    """  bool get mutatesInventory => switch (action) {
    AppBrainAction.setQuantity ||
    AppBrainAction.receiveStock ||
    AppBrainAction.relocateMedicine ||
    AppBrainAction.removeMedicine ||
    AppBrainAction.restoreMedicine ||
    AppBrainAction.markSold ||
    AppBrainAction.recordSale ||
    AppBrainAction.undoLast => true,
    _ => false,
  };
}
""",
    """  bool get mutatesInventory => switch (action) {
    AppBrainAction.setQuantity ||
    AppBrainAction.receiveStock ||
    AppBrainAction.relocateMedicine ||
    AppBrainAction.removeMedicine ||
    AppBrainAction.restoreMedicine ||
    AppBrainAction.markSold ||
    AppBrainAction.recordSale ||
    AppBrainAction.undoLast => true,
    _ => false,
  };

  /// Whether a command with no medicine words may reuse the session's exact
  /// active-stock context. This never authorizes fuzzy or guessed targeting.
  /// The executor still requires an exact live ID/fingerprint and all existing
  /// review/confirmation gates remain mandatory for mutations.
  bool get canUseImplicitExactContext =>
      briefFocus != null ||
      switch (action) {
        AppBrainAction.editMedicine ||
        AppBrainAction.setQuantity ||
        AppBrainAction.receiveStock ||
        AppBrainAction.relocateMedicine ||
        AppBrainAction.removeMedicine ||
        AppBrainAction.markSold ||
        AppBrainAction.recordSale => true,
        _ => false,
      };
}
""",
)

# Keep targetless "stock khatam" informational, while an explicit
# "mark sold" command may safely continue on exact selected context.
replace_once(
    "lib/domain/app_brain.dart",
    """  if (_containsAny(text, _soldTerms)) {
    final query = _extractMedicineQuery(raw, _soldTerms);
    // "stock khatam" without a target is informational, never an implicit
    // mutation. It opens the SOLD/reorder projection instead.
    if (query.isEmpty) {
      return const AppBrainIntent(
        action: AppBrainAction.search,
        scope: SearchScope.sold,
        confidence: .94,
      );
    }
    return AppBrainIntent(
      action: AppBrainAction.markSold,
      query: query,
      confidence: .98,
    );
  }
""",
    """  if (_containsAny(text, _soldTerms)) {
    final query = _extractMedicineQuery(raw, _soldTerms);
    // Ambiguous status wording such as "stock khatam" remains informational
    // when it has no target. Only an explicit whole-stock mutation phrase may
    // reuse exact session context; the UI still requires confirmation.
    if (query.isEmpty) {
      final explicitContextMutation = _containsAny(text, const [
        'mark sold',
        'sold mark',
        'poora stock bik gaya',
        'pura stock bik gaya',
        'पूरा स्टॉक बिक गया',
      ]);
      if (explicitContextMutation) {
        return const AppBrainIntent(
          action: AppBrainAction.markSold,
          confidence: .96,
        );
      }
      return const AppBrainIntent(
        action: AppBrainAction.search,
        scope: SearchScope.sold,
        confidence: .94,
      );
    }
    return AppBrainIntent(
      action: AppBrainAction.markSold,
      query: query,
      confidence: .98,
    );
  }
""",
)

replace_once(
    "lib/domain/app_brain.dart",
    """  if (query.isEmpty) return null;
  return AppBrainIntent(
    action: AppBrainAction.recordSale,
""",
    """  // A quantity-qualified imperative such as "5 units sell" is
  // sufficiently explicit to continue on exact session context. A bare
  // targetless "sell" remains unknown instead of becoming a mutation.
  if (query.isEmpty && saleInput.quantity == null) return null;
  return AppBrainIntent(
    action: AppBrainAction.recordSale,
""",
)

# 2) Complete location commands may omit medicine words and then bind only to
# exact selected context at execution time.
replace_once(
    "lib/domain/brain_operations.dart",
    """    if (target.isEmpty) return null;
    return ParsedStockLocationCommand(
      query: target,
      patch: const StockLocationPatch.clear(),
    );
""",
    """    return ParsedStockLocationCommand(
      query: target,
      patch: const StockLocationPatch.clear(),
    );
""",
)
replace_once(
    "lib/domain/brain_operations.dart",
    """  final target = _targetAfterRemoving(raw, spans);
  if (target.isEmpty) return null;
  return ParsedStockLocationCommand(query: target, patch: patch);
}
""",
    """  final target = _targetAfterRemoving(raw, spans);
  return ParsedStockLocationCommand(query: target, patch: patch);
}
""",
)

# 3) Controller lifecycle reviews bind confirmations to the exact row, not to
# unrelated global inventory traffic.
replace_once(
    "lib/state/pharmacy_controller.dart",
    "class BulkArchiveReview {\n",
    """class ReviewedArchive {
  const ReviewedArchive({
    required this.baseRevision,
    required this.record,
    required this.reason,
  });

  final int baseRevision;
  final Medicine record;
  final String reason;
  String get stockId => record.id;
}

class ReviewedMarkSold {
  const ReviewedMarkSold({
    required this.baseRevision,
    required this.record,
  });

  final int baseRevision;
  final Medicine record;
  String get stockId => record.id;
}

bool _sameReviewedMedicine(Medicine live, Medicine reviewed) =>
    mapEquals(live.toJson(), reviewed.toJson());

class BulkArchiveReview {
""",
)

replace_once(
    "lib/state/pharmacy_controller.dart",
    """  Future<void> _commit(InventoryMutation mutation) {
    // Stamp once at the authoritative controller boundary. Every downstream
    // date-sensitive guard and the durable audit event uses this exact instant,
    // so a transaction cannot observe two different business days around
    // midnight or diverge from an injected/test business clock.
    final committedMutation = mutation.withOperationTime(clock());
""",
    """  Future<void> _commit(
    InventoryMutation mutation, {
    DateTime? operationTime,
  }) {
    // Stamp once at the authoritative controller boundary. A lifecycle action
    // may pass the same instant used to construct its stock transition, which
    // keeps archivedAt/soldAt and the audit business day coherent even if the
    // confirmation lands exactly across midnight.
    final committedMutation = mutation.withOperationTime(operationTime ?? clock());
""",
)

replace_once(
    "lib/state/pharmacy_controller.dart",
    """  Future<void> markSold(String id) async {
    final m = snapshot.records[id];
    if (m == null || m.archived) throw StateError('This entry is unavailable.');
    if (m.sold) return;
    final now = clock();
    if (isExpiredOn(m, now)) {
      throw const FormatException(
        'Expired stock cannot be marked SOLD. Remove it with reason Expired instead.',
      );
    }
    await _commit(
      InventoryMutation(
        expectedRevision: snapshot.revision,
        label: 'Marked ${m.name} sold',
        upserts: [
          m.patch({
            'sold': true,
            'quantity': 0,
            'soldAt': now.toIso8601String(),
            'soldQuantity': m.quantity,
            'soldUnitPricePaise': m.unitPricePaise,
          }),
        ],
      ),
    );
  }

""",
    """  ReviewedMarkSold reviewMarkSold(String id) {
    final medicine = snapshot.records[id];
    if (medicine == null || medicine.archived) {
      throw StateError('Choose an active stock entry before marking SOLD.');
    }
    if (medicine.sold) {
      throw StateError('This stock entry is already marked SOLD.');
    }
    if (isExpiredOn(medicine, clock())) {
      throw const FormatException(
        'Expired stock cannot be marked SOLD. Remove it with reason Expired instead.',
      );
    }
    return ReviewedMarkSold(
      baseRevision: snapshot.revision,
      record: Medicine.fromJson(medicine.toJson()),
    );
  }

  Future<void> applyMarkSold(ReviewedMarkSold review) async {
    final live = snapshot.records[review.stockId];
    if (live == null ||
        live.archived ||
        live.sold ||
        !_sameReviewedMedicine(live, review.record)) {
      throw StateError(
        'The reviewed stock entry changed or is no longer active. Review SOLD again.',
      );
    }
    final now = clock();
    if (isExpiredOn(live, now)) {
      throw const FormatException(
        'This stock expired after the SOLD review was opened. Remove it with reason Expired instead; nothing was changed.',
      );
    }
    await _commit(
      InventoryMutation(
        expectedRevision: snapshot.revision,
        label: 'Marked ${live.name} sold',
        upserts: [
          live.patch({
            'sold': true,
            'quantity': 0,
            'soldAt': now.toIso8601String(),
            'soldQuantity': live.quantity,
            'soldUnitPricePaise': live.unitPricePaise,
          }),
        ],
      ),
      operationTime: now,
    );
  }

  /// Immediate compatibility gateway for callers with no confirmation delay.
  /// User-facing flows use reviewMarkSold/applyMarkSold so stale dialogs are
  /// dependency-scoped rather than tied to unrelated global inventory traffic.
  Future<void> markSold(String id) async {
    final medicine = snapshot.records[id];
    if (medicine == null || medicine.archived) {
      throw StateError('This entry is unavailable.');
    }
    if (medicine.sold) return;
    await applyMarkSold(reviewMarkSold(id));
  }

""",
)

replace_once(
    "lib/state/pharmacy_controller.dart",
    """  Future<void> archive(
    String id,
    String reason, {
    int? expectedRevision,
  }) async {
    if (expectedRevision != null && expectedRevision != snapshot.revision) {
      throw StateError(
        'Inventory changed. Reopen this entry before removing it.',
      );
    }
    final m = snapshot.records[id];
    if (m == null || m.archived) return;
    await _commit(
      InventoryMutation(
        expectedRevision: snapshot.revision,
        label: 'Removed ${m.name} · $reason',
        upserts: [archiveMedicine(m, reason: reason, at: clock())],
      ),
    );
  }

""",
    """  ReviewedArchive reviewArchive(String id, String reason) {
    final medicine = snapshot.records[id];
    if (medicine == null || medicine.archived) {
      throw StateError('Choose an active stock entry before removing it.');
    }
    final cleanReason = reason.replaceAll(RegExp(r'\\s+'), ' ').trim();
    if (cleanReason.isEmpty || cleanReason.length > 300) {
      throw const FormatException('Choose a valid removal reason.');
    }
    return ReviewedArchive(
      baseRevision: snapshot.revision,
      record: Medicine.fromJson(medicine.toJson()),
      reason: cleanReason,
    );
  }

  Future<void> applyArchive(ReviewedArchive review) async {
    final live = snapshot.records[review.stockId];
    if (live == null ||
        live.archived ||
        !_sameReviewedMedicine(live, review.record)) {
      throw StateError(
        'The reviewed stock entry changed or is no longer active. Review removal again.',
      );
    }
    final fresh = reviewArchive(live.id, review.reason);
    final removedAt = clock();
    await _commit(
      InventoryMutation(
        expectedRevision: fresh.baseRevision,
        label: 'Removed ${live.name} · ${fresh.reason}',
        upserts: [
          archiveMedicine(live, reason: fresh.reason, at: removedAt),
        ],
      ),
      operationTime: removedAt,
    );
  }

  /// Immediate compatibility gateway. User-facing confirmation flows should
  /// prepare an exact-row review and apply it only after the user confirms.
  Future<void> archive(
    String id,
    String reason, {
    int? expectedRevision,
  }) async {
    if (expectedRevision != null && expectedRevision != snapshot.revision) {
      throw StateError(
        'Inventory changed. Reopen this entry before removing it.',
      );
    }
    final medicine = snapshot.records[id];
    if (medicine == null || medicine.archived) return;
    await applyArchive(reviewArchive(id, reason));
  }

""",
)

# 4) Brain executor: omitted targets can use only exact live context.
replace_once(
    "lib/ui/brain_screen.dart",
    """    if (briefFocus != null && isAppBrainContextReference(query)) {
      final remembered = _rememberedTarget();
""",
    """    if (briefFocus != null &&
        (query.isEmpty || isAppBrainContextReference(query))) {
      final remembered = _rememberedTarget();
""",
)
replace_once(
    "lib/ui/brain_screen.dart",
    """    if (isAppBrainContextReference(query)) {
      final remembered = _rememberedTarget();
""",
    """    if ((query.isEmpty && intent.canUseImplicitExactContext) ||
        isAppBrainContextReference(query)) {
      final remembered = _rememberedTarget();
""",
)

# Brain removal now reviews exact row facts before the final dialog.
replace_once(
    "lib/ui/brain_screen.dart",
    """    final expectedRevision = widget.controller.snapshot.revision;
    final expired = isExpiredOn(live, widget.controller.today);
""",
    """    final expired = isExpiredOn(live, widget.controller.today);
""",
)
replace_once(
    "lib/ui/brain_screen.dart",
    """    if (reason.startsWith('Sold')) {
      await _markSoldTarget(live);
      return;
    }

    final confirmed =
""",
    """    if (reason.startsWith('Sold')) {
      await _markSoldTarget(live);
      return;
    }

    final review = widget.controller.reviewArchive(live.id, reason);
    final reviewed = review.record;
    final confirmed =
""",
)
replace_once(
    "lib/ui/brain_screen.dart",
    """            title: Text('Remove ${live.name}?'),
            content: Text(
              '${_stockIdentityCue(live)}\\n\\nReason: $reason\\n\\nThis stock entry will leave active inventory, search and totals. It remains in removed history and can be restored or undone.',
""",
    """            title: Text('Remove ${reviewed.name}?'),
            content: Text(
              '${_stockIdentityCue(reviewed)}\\n\\nReason: ${review.reason}\\n\\nThis stock entry will leave active inventory, search and totals. It remains in removed history and can be restored or undone.',
""",
)
replace_once(
    "lib/ui/brain_screen.dart",
    """    if (widget.controller.snapshot.revision != expectedRevision) {
      throw StateError(
        'Inventory changed while you were confirming. Reopen the command so Aaris can verify the exact stock entry again.',
      );
    }
    await widget.controller.archive(
      live.id,
      reason,
      expectedRevision: expectedRevision,
    );
    if (!mounted) return;
    widget.controller.clearOperationalTarget(live.id);
    setState(
      () => _reply =
          '${live.title} removed with reason “$reason”. It is still recoverable from removed history, and Undo is available for this latest change.',
    );
""",
    """    await widget.controller.applyArchive(review);
    if (!mounted) return;
    widget.controller.clearOperationalTarget(reviewed.id);
    setState(
      () => _reply =
          '${reviewed.title} removed with reason “${review.reason}”. It is still recoverable from removed history, and Undo is available for this latest change.',
    );
""",
)

# Brain whole-stock SOLD also becomes an exact-row reviewed action.
replace_once(
    "lib/ui/brain_screen.dart",
    """    final expectedRevision = widget.controller.snapshot.revision;
    final confirmed =
        await showDialog<bool>(
""",
    """    final review = widget.controller.reviewMarkSold(live.id);
    final reviewed = review.record;
    final confirmed =
        await showDialog<bool>(
""",
)
replace_once(
    "lib/ui/brain_screen.dart",
    """            title: Text('Mark ${live.name} SOLD?'),
            content: Text(
              '${_stockIdentityCue(live)}\\n\\nThis means this entire physical stock entry is finished. Quantity becomes 0 and the medicine enters reorder intelligence. It does not create a customer sale event.',
""",
    """            title: Text('Mark ${reviewed.name} SOLD?'),
            content: Text(
              '${_stockIdentityCue(reviewed)}\\n\\nThis means this entire physical stock entry is finished. Quantity becomes 0 and the medicine enters reorder intelligence. It does not create a customer sale event.',
""",
)
replace_once(
    "lib/ui/brain_screen.dart",
    """    if (widget.controller.snapshot.revision != expectedRevision) {
      throw StateError(
        'Inventory changed while you were confirming. Run the command again so Aaris can re-check this exact stock entry.',
      );
    }
    await widget.controller.markSold(live.id);
""",
    """    await widget.controller.applyMarkSold(review);
""",
)

# 5) Parser/domain regression coverage.
replace_once(
    "test/app_brain_test.dart",
    """    test('routes mark-sold target separately from sold list', () {
      final intent = parseAppBrainIntent('Dolo 650 stock khatam');
      expect(intent.action, AppBrainAction.markSold);
      expect(intent.query, 'Dolo 650');
      expect(intent.destructive, isTrue);
    });
""",
    """    test('routes mark-sold target separately from sold list', () {
      final intent = parseAppBrainIntent('Dolo 650 stock khatam');
      expect(intent.action, AppBrainAction.markSold);
      expect(intent.query, 'Dolo 650');
      expect(intent.destructive, isTrue);

      final contextual = parseAppBrainIntent('mark sold');
      expect(contextual.action, AppBrainAction.markSold);
      expect(contextual.query, isEmpty);
      expect(contextual.canUseImplicitExactContext, isTrue);
    });
""",
)
replace_once(
    "test/app_brain_test.dart",
    """    test('explicit record-sale command still owns the write path', () {
      final intent = parseAppBrainIntent('Dolo 650 record sale');
      expect(intent.action, AppBrainAction.recordSale);
      expect(intent.query, 'Dolo 650');
      expect(intent.destructive, isTrue);
    });
""",
    """    test('explicit record-sale command still owns the write path', () {
      final intent = parseAppBrainIntent('Dolo 650 record sale');
      expect(intent.action, AppBrainAction.recordSale);
      expect(intent.query, 'Dolo 650');
      expect(intent.destructive, isTrue);

      final contextual = parseAppBrainIntent('5 units sell');
      expect(contextual.action, AppBrainAction.recordSale);
      expect(contextual.query, isEmpty);
      expect(contextual.quantity, 5);
      expect(contextual.canUseImplicitExactContext, isTrue);

      final unsafeBare = parseAppBrainIntent('sell');
      expect(unsafeBare.action, isNot(AppBrainAction.recordSale));
    });
""",
)

replace_once(
    "test/autonomous_stock_operations_test.dart",
    """    test('medicine strength is never consumed as a stock command quantity', () {
""",
    """    test('complete targetless operations can bind only at execution context', () {
      final receive = parseAppBrainIntent('stock add 7 units');
      expect(receive.action, AppBrainAction.receiveStock);
      expect(receive.query, isEmpty);
      expect(receive.canUseImplicitExactContext, isTrue);

      final relocate = parseAppBrainIntent('location Rack C set karo');
      expect(relocate.action, AppBrainAction.relocateMedicine);
      expect(relocate.query, isEmpty);
      expect(relocate.locationPatch?.location, 'Rack C');
      expect(relocate.canUseImplicitExactContext, isTrue);
    });

    test('medicine strength is never consumed as a stock command quantity', () {
""",
)

replace_once(
    "test/autonomous_stock_operations_test.dart",
    """    test(
      'unknown stock cannot be marked fully sold by an arbitrary sale quantity',
""",
    """    test('reviewed removal survives unrelated writes but rejects target edits', () async {
      final controller = await controllerWithClock();
      addTearDown(controller.dispose);
      await controller.save(stock('a'), expectedRevision: 0);
      final review = controller.reviewArchive('a', 'Damaged');
      await controller.save(stock('b'), expectedRevision: 1);

      await controller.applyArchive(review);
      expect(controller.snapshot.records['a']!.archived, isTrue);
      expect(controller.snapshot.records['a']!.archiveReason, 'Damaged');
      expect(controller.snapshot.records['b']!.archived, isFalse);

      await controller.undo();
      final stale = controller.reviewArchive('a', 'Correction');
      final live = controller.snapshot.records['a']!;
      await controller.save(
        live.patch({'notes': 'changed after confirmation opened'}),
        expectedRevision: controller.snapshot.revision,
      );
      await expectLater(controller.applyArchive(stale), throwsStateError);
      expect(controller.snapshot.records['a']!.archived, isFalse);
    });

    test('reviewed SOLD survives unrelated writes but rejects target edits', () async {
      final controller = await controllerWithClock();
      addTearDown(controller.dispose);
      await controller.save(stock('a'), expectedRevision: 0);
      final review = controller.reviewMarkSold('a');
      await controller.save(stock('b'), expectedRevision: 1);

      await controller.applyMarkSold(review);
      final sold = controller.snapshot.records['a']!;
      expect(sold.sold, isTrue);
      expect(sold.quantity, 0);
      expect(controller.sales, isEmpty);

      await controller.undo();
      final stale = controller.reviewMarkSold('a');
      final live = controller.snapshot.records['a']!;
      await controller.save(
        live.patch({'notes': 'count verified'}),
        expectedRevision: controller.snapshot.revision,
      );
      await expectLater(controller.applyMarkSold(stale), throwsStateError);
      expect(controller.snapshot.records['a']!.sold, isFalse);
    });

    test(
      'unknown stock cannot be marked fully sold by an arbitrary sale quantity',
""",
)

# 6) Widget-level proof: a targetless explicit stock command reuses an exact
# selection but still pauses at the protected review dialog.
p = Path("test/brain_screen_test.dart")
text = p.read_text()
marker = "\n}\n"
idx = text.rfind(marker)
if idx < 0:
    raise SystemExit("brain_screen_test.dart final brace not found")
addition = r'''

  testWidgets(
    'Brain reuses exact context for targetless explicit operation without skipping review',
    (tester) async {
      final medicine = _stock(
        'context-receive',
        name: 'Crocin',
        strength: '500mg',
        expiry: '2027-12',
        quantity: 10,
      );
      final controller = PharmacyController(
        MemoryInventoryStorage(
          InventorySnapshot(records: {medicine.id: medicine}),
        ),
        clock: () => _today,
        backgroundSearch: false,
      );
      await controller.initialize();
      addTearDown(controller.dispose);
      controller.rememberOperationalTarget(medicine.id);

      await tester.pumpWidget(
        MaterialApp(
          theme: pharmacyTheme(),
          home: Scaffold(
            body: BrainScreen(
              controller: controller,
              onOpenSection: (_) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).first, 'stock add 5 units');
      await tester.tap(find.byTooltip('Run command').first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('Receive 5 units?'), findsOneWidget);
      expect(controller.snapshot.records[medicine.id]!.quantity, 10);
      await tester.tap(find.widgetWithText(FilledButton, 'Receive stock'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(controller.snapshot.records[medicine.id]!.quantity, 15);
      expect(controller.sales, isEmpty);
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
      await tester.pump();
    },
  );
'''
p.write_text(text[:idx] + addition + text[idx:])

# 7) Architecture note for future maintainers.
Path("docs/AARIS_EXACT_CONTEXT_AND_LIFECYCLE_HARDENING_2026_09_10.md").write_text(
    """# Aaris Exact Context & Lifecycle Hardening — 2026-09-10

This pass extends the existing Aaris Pharmacy architecture without adding a second database, a parallel AI mutation path, or any cloud dependency.

## Human-like exact context, without guessing

Aaris Brain may now continue a deterministic single-medicine command when the pharmacist omits the medicine name **only if** the current session already holds one exact active stock ID whose physical-identity fingerprint still matches the authoritative Medicine Database.

Examples after an exact medicine/batch is selected include stock receiving/correction, explicit sale commands, edit/remove, reviewed location changes and read-only expiry/location/FEFO questions. Ambiguous status wording such as targetless `stock khatam` remains informational. A bare targetless `sell` is not promoted into a mutation; quantity-qualified sale wording can reuse exact context but still enters the existing reviewed FEFO flow.

No operational facts are cached in conversational memory. Quantity, dates, price, status and location are re-read from the live inventory snapshot on every command. If exact context is absent or its identity fingerprint no longer matches, the command fails closed and asks the pharmacist to choose a row.

## Dependency-scoped lifecycle confirmations

Single-row Remove and whole-stock SOLD confirmations now use immutable review tokens. The reviewed token contains the exact medicine row shown to the pharmacist. At apply time Aaris compares the current authoritative row against that review:

- unrelated inventory traffic no longer forces a valid confirmation to be repeated;
- any change to the reviewed target row invalidates the confirmation;
- SOLD is rechecked against expiry at the apply-time business clock;
- Remove preserves the reviewed reason;
- no sale event is invented by whole-stock SOLD;
- all writes still pass through `PharmacyController -> InventoryStorage`, SQLite CAS, integrity guards and audit history.

The lifecycle transition timestamp and inventory audit timestamp now share one controller-captured instant, eliminating a midnight-edge mismatch between `archivedAt`/`soldAt` and the durable transaction business day.

## Safety invariants preserved

- one authoritative medicine database;
- no silent destructive action;
- no fuzzy mutation target from implicit context;
- no AI/OCR write bypass;
- no invented medical facts;
- local-first/privacy behavior unchanged;
- existing FEFO, sale-ledger, integrity, Undo, backup and removed-stock recovery guards remain authoritative.
"""
)
