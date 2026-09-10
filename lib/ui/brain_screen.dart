import 'dart:async';

import 'package:flutter/material.dart';

import '../domain/app_brain.dart';
import '../domain/attention.dart';
import '../domain/brain_analytics.dart';
import '../domain/brain_clarification.dart';
import '../domain/brain_operations.dart';
import '../domain/dispensing_plan.dart';
import '../domain/inventory.dart';
import '../domain/medicine.dart';
import '../domain/medicine_brief.dart';
import '../domain/operations_plan.dart';
import '../domain/search.dart';
import '../domain/tracking.dart';
import '../services/scan_service.dart';
import '../state/operational_context.dart';
import '../state/pharmacy_controller.dart';
import '../state/stock_location_operations.dart';
import 'ai_screen.dart';
import 'attention_screen.dart';
import 'design.dart';
import 'editor_screen.dart';
import 'import_screen.dart';
import 'order_screen.dart';
import 'removed_stock_screen.dart';
import 'scanner_screen.dart';
import 'search_screen.dart';

class BrainScreen extends StatefulWidget {
  const BrainScreen({
    super.key,
    required this.controller,
    required this.onOpenSection,
  });

  final PharmacyController controller;
  final ValueChanged<AppSection> onOpenSection;

  @override
  State<BrainScreen> createState() => _BrainScreenState();
}

class _BrainScreenState extends State<BrainScreen> {
  bool _busy = false;
  PendingBrainChoice? _pendingChoice;
  String _reply =
      'Ready. Ask stock, expiry, location or FEFO from the local Medicine Database, open safe actions, recover removed stock, or ask “aaj kya dekhna hai”.';

  Future<String?> _handleUnifiedCommand(String raw) async {
    if (_busy) return 'Aaris is finishing the previous local command.';
    final text = raw.trim();
    if (text.isEmpty) return null;

    // With no pending exact-row clarification, only deterministic App Brain
    // intents are intercepted here. Unknown text falls straight through to the
    // existing AI/JSON composer, so one field safely serves both engines.
    final preParsed = _pendingChoice == null ? parseAppBrainIntent(text) : null;
    if (_pendingChoice == null &&
        (preParsed == null ||
            preParsed.action == AppBrainAction.unknown ||
            preParsed.confidence < .90)) {
      return null;
    }

    if (mounted) {
      setState(() {
        _busy = true;
        _reply = 'Understanding local command…';
      });
    }
    try {
      if (await _continuePendingChoice(text)) return _reply;
      final intent = preParsed ?? parseAppBrainIntent(text);
      if (intent.action == AppBrainAction.unknown) return null;
      await _execute(intent, text);
      return _reply;
    } catch (error) {
      final message = error.toString().replaceFirst(
        RegExp(r'^(FormatException|Bad state|StateError):\s*'),
        '',
      );
      if (mounted) setState(() => _reply = message);
      return message;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool> _continuePendingChoice(String raw) async {
    final pending = _pendingChoice;
    if (pending == null) return false;
    final result = pending.resolve(
      raw,
      records: widget.controller.snapshot.records,
      now: widget.controller.clock(),
    );
    switch (result.kind) {
      case BrainChoiceResolutionKind.cancelled:
        _pendingChoice = null;
        if (mounted) {
          setState(
            () =>
                _reply = 'Pending medicine choice cancelled. Nothing changed.',
          );
        }
        return true;
      case BrainChoiceResolutionKind.stale:
        _pendingChoice = null;
        final fresh = parseAppBrainIntent(raw);
        if (fresh.action != AppBrainAction.unknown) return false;
        if (mounted) {
          setState(
            () => _reply = 'That medicine-choice list expired or one of its stock rows changed. Nothing changed. Run the command again so Aaris can rank the live Medicine Database.',
          );
        }
        return true;
      case BrainChoiceResolutionKind.resolved:
        final stockId = result.stockId;
        final record = stockId == null
            ? null
            : widget.controller.snapshot.records[stockId];
        _pendingChoice = null;
        if (record == null || record.archived) {
          if (mounted) {
            setState(
              () => _reply = 'That exact stock row is no longer active. Nothing changed; choose again from the live Medicine Database.',
            );
          }
          return true;
        }
        await _resumePendingChoice(pending.intent, record);
        return true;
      case BrainChoiceResolutionKind.ambiguous:
        if (mounted) {
          setState(
            () => _reply =
                '${_pendingChoicePrompt(pending)} That exact cue still belongs to more than one displayed row, so Aaris did not guess.',
          );
        }
        return true;
      case BrainChoiceResolutionKind.noMatch:
        final fresh = parseAppBrainIntent(raw);
        if (fresh.action != AppBrainAction.unknown) {
          _pendingChoice = null;
          return false;
        }
        if (mounted) setState(() => _reply = _pendingChoicePrompt(pending));
        return true;
    }
  }

  Future<void> _resumePendingChoice(
    AppBrainIntent intent,
    Medicine record,
  ) async {
    _remember(record);
    final focus = intent.briefFocus;
    if (focus != null) {
      _answerOperationalBrief(record, focus);
      return;
    }
    if (intent.action == AppBrainAction.search) {
      widget.onOpenSection(AppSection.stock);
      if (mounted) {
        setState(
          () => _reply =
              '${record.title} selected from the exact displayed options. This stock row is now the session context.',
        );
      }
      await Future<void>.delayed(Duration.zero);
      if (mounted) await openEditor(context, widget.controller, record: record);
      return;
    }
    await _openActionTarget(
      intent.action,
      record,
      requestedQuantity: intent.quantity,
      locationPatch: intent.locationPatch,
      removalReason: intent.removalReason,
    );
  }

  String _pendingChoicePrompt(PendingBrainChoice pending) {
    final shown = <String>[];
    for (var i = 0; i < pending.candidates.length && i < 4; i++) {
      shown.add('${i + 1}: ${pending.candidates[i].displayCue}');
    }
    final more = pending.candidates.length > 4
        ? ' · +${pending.candidates.length - 4} more'
        : '';
    return 'Aaris is waiting for an exact choice from the displayed local rows. Say “first one”, “second one”, an exact batch/barcode/block/row/vertical/location, or “cancel”. ${shown.join(' · ')}$more';
  }

  Future<void> _execute(AppBrainIntent intent, String raw) async {
    switch (intent.action) {
      case AppBrainAction.safetyBlocked:
        if (mounted) {
          setState(
            () => _reply = intent.safetyReason?.message ?? 'Nothing changed. This command did not pass the deterministic inventory-action safety check.',
          );
        }
        return;
      case AppBrainAction.navigate:
        final section = intent.section;
        if (section == null) {
          _unknown(raw);
          return;
        }
        widget.onOpenSection(section);
        if (mounted) setState(() => _reply = _sectionReply(section));
        return;
      case AppBrainAction.addMedicine:
        if (mounted) {
          widget.onOpenSection(AppSection.stock);
          setState(() => _reply = 'Opening a fresh medicine entry.');
          await Future<void>.delayed(Duration.zero);
          if (mounted) await openEditor(context, widget.controller);
        }
        return;
      case AppBrainAction.scanMedicine:
        await _scanMedicine();
        return;
      case AppBrainAction.search:
        await _searchIntent(intent);
        return;
      case AppBrainAction.restoreMedicine:
      case AppBrainAction.removedStockReview:
        await _removedStock(intent);
        return;
      case AppBrainAction.editMedicine:
      case AppBrainAction.setQuantity:
      case AppBrainAction.receiveStock:
      case AppBrainAction.relocateMedicine:
      case AppBrainAction.removeMedicine:
      case AppBrainAction.markSold:
      case AppBrainAction.recordSale:
        await _medicineAction(intent);
        return;
      case AppBrainAction.reorderReview:
        await _reorderReview();
        return;
      case AppBrainAction.undoLast:
        await _undo();
        return;
      case AppBrainAction.inventorySummary:
        _summary();
        return;
      case AppBrainAction.analyticsBrief:
        final request = intent.analyticsRequest;
        if (request == null) {
          _unknown(raw);
          return;
        }
        _analyticsBrief(request);
        return;
      case AppBrainAction.attentionBrief:
        await _attentionBrief();
        return;
      case AppBrainAction.nextAttentionTask:
        await _attentionBrief(focusNext: true);
        return;
      case AppBrainAction.bulkRemoveBlocked:
        _bulkRemoveBlocked();
        return;
      case AppBrainAction.unknown:
        _unknown(raw);
        return;
    }
  }

  Future<void> _removedStock(AppBrainIntent intent) async {
    if (!mounted) return;
    final query = intent.query.trim();
    widget.onOpenSection(AppSection.profile);
    setState(
      () => _reply = query.isEmpty
          ? 'Opening Removed stock. Search and recovery stay local; every restore requires an exact archived-row review and explicit confirmation.'
          : 'Opening Removed stock filtered for “$query”. Aaris will rank local archived rows but will not restore from a fuzzy match automatically.',
    );
    await Future<void>.delayed(Duration.zero);
    if (!mounted) return;
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => RemovedStockScreen(
          controller: widget.controller,
          initialQuery: query,
        ),
      ),
    );
    if (!mounted) return;
    setState(
      () => _reply = 'Removed-stock review closed. Nothing is restored unless you explicitly confirm the exact archived row; stale reviews fail closed if inventory changes.',
    );
  }

  Future<void> _scanMedicine() async {
    if (!mounted) return;
    widget.onOpenSection(AppSection.stock);
    setState(
      () => _reply = 'Opening the existing local scanner. Barcode + OCR evidence will be reviewed before any stock can change.',
    );
    await Future<void>.delayed(Duration.zero);
    if (!mounted) return;

    final result = await Navigator.push<ScanResult>(
      context,
      MaterialPageRoute(builder: (_) => const ScannerScreen()),
    );
    if (!mounted) return;
    if (result == null) {
      setState(() => _reply = 'Scan cancelled. Nothing changed.');
      return;
    }
    if (result.barcode.trim().isEmpty && result.text.trim().isEmpty) {
      setState(
        () => _reply = 'The scan contained no usable barcode or medicine text. Nothing changed.',
      );
      return;
    }

    // Remember an exact existing match only when the same confidence gate used
    // by other Brain actions can isolate one stock row. The import inbox still
    // remains authoritative for deciding existing batch vs new entry.
    final rawQuery = result.barcode.trim().isNotEmpty
        ? result.barcode.trim()
        : result.text.trim();
    final boundedQuery = rawQuery.length <= 30000
        ? rawQuery
        : rawQuery.substring(0, 30000);
    final hits = await widget.controller.search(boundedQuery, SearchScope.all);
    if (!mounted) return;
    final direct = _singleSafeTarget(
      hits.where((hit) => hit.score >= .90).take(8).toList(),
    );
    if (direct != null) {
      final record = widget.controller.snapshot.records[direct.id];
      if (record != null && !record.archived) _remember(record);
    }

    final evidence = result.evidence.isNotEmpty
        ? result.evidence
        : <ScanEvidence>[
            ScanEvidence(
              barcode: result.barcode,
              text: result.text,
              source: 'Aaris Brain scanner',
            ),
          ];
    setState(
      () => _reply = direct == null
          ? 'Scan captured. Review the ranked local matches or create a new stock entry; Aaris will not guess an ambiguous batch.'
          : 'Scan captured and one high-confidence local stock match was found. Review it before editing or creating another batch.',
    );
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => ImportInboxScreen(
          controller: widget.controller,
          evidence: evidence,
        ),
      ),
    );
    if (!mounted) return;
    final remembered = _rememberedTarget();
    setState(
      () => _reply = remembered == null
          ? 'Scan review closed. No stock was changed automatically.'
          : '${remembered.title} is now the exact session context. You can say “isko edit karo”, “isko stock kitna hai”, “isko remove karo”, or another reviewed command.',
    );
  }

  Future<void> _searchIntent(AppBrainIntent intent) async {
    final query = intent.query.trim();
    final briefFocus = intent.briefFocus;

    if (briefFocus != null &&
        (query.isEmpty || isAppBrainContextReference(query))) {
      final remembered = _rememberedTarget();
      if (remembered == null) {
        widget.onOpenSection(AppSection.stock);
        if (mounted) {
          setState(
            () => _reply = 'I do not have a safe previous medicine target yet. Medicine Database opened so you can choose the exact medicine first.',
          );
        }
        return;
      }
      _answerOperationalBrief(remembered, briefFocus);
      return;
    }

    if (query.isEmpty) {
      if (!mounted) return;
      if (briefFocus != null) {
        widget.onOpenSection(AppSection.stock);
        setState(
          () => _reply = 'Medicine name, batch, barcode or an exact previous selection is missing. Medicine Database opened instead of guessing which medicine you meant.',
        );
        return;
      }
      if (intent.scope == SearchScope.all) {
        widget.onOpenSection(AppSection.stock);
        setState(() => _reply = 'Medicine Database opened.');
        return;
      }
      setState(
        () => _reply =
            'Opening ${scopeTitle(intent.scope, widget.controller.settings)}.',
      );
      await Navigator.push<void>(
        context,
        MaterialPageRoute(
          builder: (_) =>
              SearchScreen(controller: widget.controller, scope: intent.scope),
        ),
      );
      return;
    }

    final hits = await widget.controller.search(query, intent.scope);
    if (!mounted) return;
    final viable = hits.where((hit) => hit.score >= .90).take(12).toList();

    if (briefFocus != null) {
      if (viable.isEmpty) {
        widget.onOpenSection(AppSection.stock);
        setState(
          () => _reply =
              'I could not safely identify “$query” in the local Medicine Database. I will not invent a stock, expiry, location or FEFO answer.',
        );
        return;
      }
      final productTarget = _singleSafeReadProductTarget(viable);
      if (productTarget != null) {
        _answerOperationalBrief(productTarget, briefFocus);
        return;
      }
      await _showMatches(
        viable,
        title: 'Choose medicine for ${_briefLabel(briefFocus)} · $query',
        emptyReply: 'No safe local match found. Aaris will not guess an operational answer.',
        briefFocus: briefFocus,
      );
      return;
    }

    final direct = _singleSafeTarget(viable.take(8).toList());
    if (direct != null) {
      final record = widget.controller.snapshot.records[direct.id];
      if (record != null && !record.archived) _remember(record);
    }
    await _showMatches(
      hits,
      title: 'Matches for “$query”',
      emptyReply:
          'No confident local stock match for “$query”. I opened the Medicine Database so you can scan or search another spelling.',
    );
  }

  void _answerOperationalBrief(Medicine anchor, MedicineBriefFocus focus) {
    if (!mounted) return;
    final live = widget.controller.snapshot.records[anchor.id];
    if (live == null || live.archived) {
      widget.controller.clearOperationalTarget(anchor.id);
      setState(
        () => _reply = 'That stock entry is no longer active. Choose the medicine again so Aaris can answer from the current inventory snapshot.',
      );
      return;
    }
    final brief = MedicineOperationalBrief.build(
      records: widget.controller.records,
      anchor: live,
      today: widget.controller.today,
    );
    _remember(live);
    setState(() => _reply = brief.describe(focus));
  }

  Future<void> _medicineAction(AppBrainIntent intent) async {
    final query = intent.query.trim();
    if ((query.isEmpty && intent.canUseImplicitExactContext) ||
        isAppBrainContextReference(query)) {
      final remembered = _rememberedTarget();
      if (remembered == null) {
        widget.onOpenSection(AppSection.stock);
        if (mounted) {
          setState(
            () => _reply = 'I do not have a safe previous medicine target yet. Medicine Database opened so you can choose the exact stock entry first.',
          );
        }
        return;
      }
      await _openActionTarget(
        intent.action,
        remembered,
        fromContext: true,
        requestedQuantity: intent.quantity,
        locationPatch: intent.locationPatch,
        removalReason: intent.removalReason,
      );
      return;
    }

    if (query.isEmpty) {
      if (!mounted) return;
      widget.onOpenSection(AppSection.stock);
      setState(
        () => _reply = 'Medicine name, batch, barcode or location is missing. Medicine Database opened so you can choose the exact stock entry safely.',
      );
      return;
    }

    final hits = await widget.controller.search(query, SearchScope.all);
    if (!mounted) return;
    final viable = hits.where((hit) => hit.score >= .90).take(8).toList();
    if (viable.isEmpty) {
      widget.onOpenSection(AppSection.stock);
      setState(
        () => _reply =
            'I could not safely identify “$query”. Medicine Database opened instead of guessing the wrong stock entry.',
      );
      return;
    }

    if (intent.action == AppBrainAction.recordSale && intent.quantity != null) {
      final productTarget = _singleSafeProductTarget(viable);
      if (productTarget != null) {
        await _openActionTarget(
          intent.action,
          productTarget,
          requestedQuantity: intent.quantity,
          locationPatch: intent.locationPatch,
          removalReason: intent.removalReason,
        );
        return;
      }
    }

    final direct = _singleSafeTarget(viable);
    if (direct != null) {
      final record = widget.controller.snapshot.records[direct.id];
      if (record != null && !record.archived) {
        await _openActionTarget(
          intent.action,
          record,
          requestedQuantity: intent.quantity,
          locationPatch: intent.locationPatch,
          removalReason: intent.removalReason,
        );
        return;
      }
    }

    await _showMatches(
      viable,
      title: _choiceTitle(intent.action, query),
      emptyReply: 'No safe match found. I will not guess a medicine or batch.',
      action: intent.action,
      requestedQuantity: intent.quantity,
      locationPatch: intent.locationPatch,
      removalReason: intent.removalReason,
    );
  }

  Future<void> _openActionTarget(
    AppBrainAction action,
    Medicine record, {
    bool fromContext = false,
    int? requestedQuantity,
    StockLocationPatch? locationPatch,
    RemovalReasonHint? removalReason,
  }) async {
    _remember(record);
    widget.onOpenSection(AppSection.stock);
    if (!mounted) return;

    final prefix = fromContext
        ? 'Using your last exact selection: ${record.title}. '
        : '';
    final instruction = switch (action) {
      AppBrainAction.recordSale when requestedQuantity != null =>
        '${record.title} matched. Preparing a deterministic $requestedQuantity-unit FEFO allocation across active batches.',
      AppBrainAction.setQuantity when requestedQuantity != null =>
        '${record.title} matched. Preparing an exact stock correction to $requestedQuantity units.',
      AppBrainAction.receiveStock when requestedQuantity != null =>
        '${record.title} matched. Preparing a reviewed +$requestedQuantity-unit stock receipt.',
      AppBrainAction.relocateMedicine when locationPatch != null =>
        '${record.title} matched. Preparing a reviewed location change: ${describeStockLocationPatch(locationPatch)}.',
      _ => _editorInstruction(action, record),
    };
    setState(() => _reply = '$prefix$instruction');
    await Future<void>.delayed(Duration.zero);
    if (!mounted) return;

    // Short deterministic mutations always resolve an exact stock row first,
    // prepare a review tied to the current inventory revision, and still require
    // a pharmacist confirmation before the controller can commit anything.
    if (action == AppBrainAction.removeMedicine) {
      if (removalReason == RemovalReasonHint.soldOut) {
        await _markSoldTarget(record);
      } else {
        await _removeTarget(record, reasonHint: removalReason);
      }
      return;
    }
    if (action == AppBrainAction.relocateMedicine) {
      if (locationPatch == null) {
        throw StateError(
          'The reviewed location command is incomplete. Nothing changed.',
        );
      }
      await _reviewLocationUpdate(record, locationPatch);
      return;
    }
    if (action == AppBrainAction.markSold) {
      await _markSoldTarget(record);
      return;
    }
    if (action == AppBrainAction.recordSale && requestedQuantity != null) {
      await _recordFefoSale(record, requestedQuantity);
      return;
    }
    if ((action == AppBrainAction.setQuantity ||
            action == AppBrainAction.receiveStock) &&
        requestedQuantity != null) {
      await _reviewStockAdjustment(record, action, requestedQuantity);
      return;
    }

    // Editing and sales without an explicit unit quantity keep the richer editor
    // because it owns amount entry, historical-sale validation and field review.
    await openEditor(context, widget.controller, record: record);
  }

  Future<void> _reviewStockAdjustment(
    Medicine original,
    AppBrainAction action,
    int quantity,
  ) async {
    if (!mounted) return;
    final kind = action == AppBrainAction.receiveStock
        ? StockAdjustmentKind.receive
        : StockAdjustmentKind.setExact;
    final review = widget.controller.reviewStockAdjustment(
      original.id,
      kind: kind,
      quantity: quantity,
    );
    final live = widget.controller.snapshot.records[review.stockId];
    if (live == null || live.archived) {
      throw StateError(
        'That stock entry is no longer active. Nothing changed.',
      );
    }

    if (!review.changesQuantity && kind == StockAdjustmentKind.setExact) {
      setState(
        () => _reply =
            '${live.title} already has ${review.afterQuantity} units recorded. No inventory change was needed.',
      );
      return;
    }

    final before = review.beforeQuantity == null
        ? 'unknown'
        : '${review.beforeQuantity} units';
    final content = kind == StockAdjustmentKind.receive
        ? '${_stockIdentityCue(live)}\n\nReceive: +${review.requestedQuantity} units\nBefore: $before\nAfter: ${review.afterQuantity} units\n\n${review.wasSold ? 'This stock entry is currently SOLD. Confirming will explicitly reopen it for the received stock; historical sales remain unchanged.\n\n' : ''}This is a stock receipt, not a customer sale. Aaris will save one audited, undoable inventory transaction.'
        : '${_stockIdentityCue(live)}\n\nCorrect recorded quantity\nBefore: $before\nAfter: ${review.afterQuantity} units\n\nThis is an inventory correction, not a sale. It will not invent a sale event or change sales history.${review.afterQuantity == 0 && !live.sold ? ' Zero quantity does not silently mark the entry SOLD.' : ''}';
    final confirmed =
        await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (ctx) => AlertDialog(
            title: Text(
              kind == StockAdjustmentKind.receive
                  ? 'Receive ${review.requestedQuantity} units?'
                  : 'Set stock to ${review.afterQuantity} units?',
            ),
            content: Text(content),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: Text(
                  kind == StockAdjustmentKind.receive
                      ? 'Receive stock'
                      : 'Save correction',
                ),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed || !mounted) {
      setState(() => _reply = 'Stock action cancelled. Nothing changed.');
      return;
    }

    await widget.controller.applyStockAdjustment(review);
    if (!mounted) return;
    setState(
      () => _reply = kind == StockAdjustmentKind.receive
          ? '${live.title}: +${review.requestedQuantity} units received; stock is now ${review.afterQuantity}. The transaction is audited and Undo is available.'
          : '${live.title}: recorded stock corrected to ${review.afterQuantity} units. Sales history was not changed; Undo is available.',
    );
  }

  Future<void> _reviewLocationUpdate(
    Medicine original,
    StockLocationPatch patch,
  ) async {
    if (!mounted) return;
    final review = widget.controller.reviewStockLocationUpdate(
      original.id,
      patch,
    );
    final live = widget.controller.snapshot.records[review.stockId];
    if (live == null || live.archived) {
      throw StateError(
        'That stock entry is no longer active. Nothing changed.',
      );
    }
    if (!review.changesLocation) {
      setState(
        () => _reply =
            '${live.title} already has that stock location. No inventory change was needed.',
      );
      return;
    }

    final confirmed =
        await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (ctx) => AlertDialog(
            title: Text('Update ${live.name} location?'),
            content: Text(
              '${_stockIdentityCue(live)}\n\nBefore: ${review.beforeDisplay}\nAfter: ${review.afterDisplay}\n\nOnly physical storage-location fields will change. Medicine identity, expiry, quantity, price and sales are untouched. The write is revision-checked and Undo remains available.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Update location'),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed || !mounted) {
      setState(() => _reply = 'Location update cancelled. Nothing changed.');
      return;
    }

    await widget.controller.applyStockLocationUpdate(review);
    if (!mounted) return;
    final updated = widget.controller.snapshot.records[live.id];
    if (updated != null && !updated.archived) _remember(updated);
    setState(
      () => _reply =
          '${live.title} moved to ${review.afterDisplay}. The reviewed location change is audited and Undo is available.',
    );
  }

  Future<void> _removeTarget(
    Medicine original, {
    RemovalReasonHint? reasonHint,
  }) async {
    if (!mounted) return;
    final live = widget.controller.snapshot.records[original.id];
    if (live == null || live.archived) {
      setState(
        () => _reply = 'That stock entry is no longer active. Nothing changed.',
      );
      return;
    }
    final expired = isExpiredOn(live, widget.controller.today);
    final reasons = <String>[
      if (expired) 'Expired',
      if (!live.sold) 'Sold / stock finished',
      if (!expired) 'Expired',
      'Damaged',
      'Returned',
      'Correction',
    ];

    final reason =
        reasonHint?.archiveReason ??
        await showDialog<String>(
          context: context,
          barrierDismissible: false,
          builder: (ctx) => SimpleDialog(
            title: Text('Why remove ${live.name}?'),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 10),
                child: Text(
                  _stockIdentityCue(live),
                  style: const TextStyle(color: muted, fontSize: 12),
                ),
              ),
              for (final item in reasons)
                SimpleDialogOption(
                  onPressed: () => Navigator.pop(ctx, item),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 15,
                  ),
                  child: Text(item),
                ),
              SimpleDialogOption(
                onPressed: () => Navigator.pop(ctx),
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 15,
                ),
                child: const Text('Cancel', style: TextStyle(color: muted)),
              ),
            ],
          ),
        );
    if (reason == null || !mounted) {
      setState(() => _reply = 'Remove cancelled. Nothing changed.');
      return;
    }

    if (reason.startsWith('Sold')) {
      await _markSoldTarget(live);
      return;
    }

    final review = widget.controller.reviewArchive(live.id, reason);
    final reviewed = review.record;
    final confirmed =
        await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (ctx) => AlertDialog(
            title: Text('Remove ${reviewed.name}?'),
            content: Text(
              '${_stockIdentityCue(reviewed)}\n\nReason: ${review.reason}\n\nThis stock entry will leave active inventory, search and totals. It remains in removed history and can be restored or undone.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Remove'),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed || !mounted) {
      setState(() => _reply = 'Remove cancelled. Nothing changed.');
      return;
    }

    await widget.controller.applyArchive(review);
    if (!mounted) return;
    widget.controller.clearOperationalTarget(reviewed.id);
    setState(
      () => _reply =
          '${reviewed.title} removed with reason “${review.reason}”. It is still recoverable from removed history, and Undo is available for this latest change.',
    );
  }

  Future<void> _markSoldTarget(Medicine original) async {
    if (!mounted) return;
    final live = widget.controller.snapshot.records[original.id];
    if (live == null || live.archived) {
      setState(
        () => _reply = 'That stock entry is no longer active. Nothing changed.',
      );
      return;
    }
    if (live.sold) {
      setState(() => _reply = '${live.title} is already marked SOLD.');
      return;
    }
    if (isExpiredOn(live, widget.controller.today)) {
      setState(
        () => _reply =
            '${live.title} is expired, so Aaris blocked SOLD. Remove it with reason Expired to keep expiry and reorder history correct.',
      );
      return;
    }
    final review = widget.controller.reviewMarkSold(live.id);
    final reviewed = review.record;
    final confirmed =
        await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (ctx) => AlertDialog(
            title: Text('Mark ${reviewed.name} SOLD?'),
            content: Text(
              '${_stockIdentityCue(reviewed)}\n\nThis means this entire physical stock entry is finished. Quantity becomes 0 and the medicine enters reorder intelligence. It does not create a customer sale event.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Mark SOLD'),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed || !mounted) {
      setState(() => _reply = 'SOLD action cancelled. Nothing changed.');
      return;
    }
    await widget.controller.applyMarkSold(review);
    if (mounted) {
      setState(
        () => _reply =
            '${live.title} marked SOLD. Reorder intelligence is updated and the latest change remains undoable.',
      );
    }
  }

  Future<void> _recordFefoSale(Medicine anchor, int quantity) async {
    final review = widget.controller.reviewFefoSale(
      anchor.id,
      quantity: quantity,
    );
    final plan = review.plan;
    if (!plan.complete) {
      if (!mounted) return;
      setState(() {
        _reply = plan.blockedByUnknownQuantity
            ? 'FEFO automation stopped safely: an earlier-priority batch has unknown quantity. Verify that physical batch first; no stock or sale was changed.'
            : 'FEFO automation found only ${plan.plannedQuantity} safely allocatable known units for the requested ${plan.requestedQuantity}. No sale was recorded.';
      });
      return;
    }

    String allocationLine(FefoAllocation allocation) {
      final expiry = allocation.expiry == null
          ? 'EXP unknown'
          : allocation.expiryMonthOnly
          ? 'EXP ${dateText(allocation.expiry!).substring(0, 7)}'
          : 'EXP ${dateText(allocation.expiry!)}';
      final batch = allocation.batchNumber.trim().isEmpty
          ? 'Batch not set'
          : 'Batch ${allocation.batchNumber.trim()}';
      final location = allocation.address.trim().isEmpty
          ? 'Location not set'
          : allocation.address.trim();
      return '${allocation.quantity} units · $batch · $expiry · $location${allocation.emptiesStock ? ' · stock finishes' : ''}';
    }

    final lines = plan.allocations.map(allocationLine).join('\n');
    final expiryWarning = plan.requiresExpiryVerification
        ? '\n\nAt least one allocated batch has no recorded expiry. Verify its physical pack before confirming.'
        : '';
    final confirmed =
        await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (ctx) => AlertDialog(
            title: Text('Record FEFO sale · ${plan.requestedQuantity} units?'),
            content: SingleChildScrollView(
              child: Text(
                'Aaris will use the earliest valid expiry first and split this sale across ${plan.allocations.length} ${plan.allocations.length == 1 ? 'batch' : 'batches'}:\n\n$lines$expiryWarning\n\nExpired, SOLD, removed and future-manufacturing-date stock is excluded. The reviewed movements save as one atomic, undoable inventory transaction. No customer or patient data is collected.',
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Record FEFO sale'),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed || !mounted) {
      setState(() => _reply = 'FEFO sale cancelled. Nothing changed.');
      return;
    }

    await widget.controller.applyFefoSale(review);
    if (!mounted) return;
    setState(
      () => _reply =
          '${plan.requestedQuantity} units recorded across ${plan.allocations.length} FEFO ${plan.allocations.length == 1 ? 'batch' : 'batches'}. Stock, sales tracking and reorder intelligence updated atomically; Undo is available.',
    );
  }

  String _stockIdentityCue(Medicine record) {
    final parts = <String>[
      record.title,
      if (record.batchNumber.trim().isNotEmpty)
        'Batch ${record.batchNumber.trim()}',
      if (record.barcode.trim().isNotEmpty) 'Barcode ${record.barcode.trim()}',
      if (record.address.trim().isNotEmpty) record.address.trim(),
      if (record.quantity != null) '${record.quantity} units',
    ];
    return parts.join(' · ');
  }

  void _remember(Medicine record) {
    if (!record.archived) {
      widget.controller.rememberOperationalTarget(record.id);
    }
  }

  Medicine? _rememberedTarget() => widget.controller.operationalTarget;

  SearchHit? _singleSafeTarget(List<SearchHit> hits) {
    if (hits.isEmpty) return null;
    final first = hits.first;
    if (first.uncertain || first.score < .95) return null;
    if (hits.length == 1) return first;
    final second = hits[1];
    if (second.score >= .90 && (first.score - second.score).abs() < .08) {
      return null;
    }
    return first;
  }

  Medicine? _singleSafeProductTarget(List<SearchHit> hits) {
    if (hits.isEmpty || hits.first.uncertain || hits.first.score < .95) {
      return null;
    }
    final records = hits
        .map((hit) => widget.controller.snapshot.records[hit.id])
        .whereType<Medicine>()
        .where((medicine) => !medicine.archived && !medicine.sold)
        .toList(growable: false);
    if (records.isEmpty) return null;
    if (records.map((medicine) => medicine.identity).toSet().length != 1) {
      return null;
    }
    return records.first;
  }

  Medicine? _singleSafeReadProductTarget(List<SearchHit> hits) {
    if (hits.isEmpty || hits.first.uncertain || hits.first.score < .95) {
      return null;
    }
    final records = hits
        .map((hit) => widget.controller.snapshot.records[hit.id])
        .whereType<Medicine>()
        .where((medicine) => !medicine.archived)
        .toList(growable: false);
    if (records.isEmpty) return null;
    if (records.map((medicine) => medicine.identity).toSet().length != 1) {
      return null;
    }
    return records.first;
  }

  Future<void> _showMatches(
    List<SearchHit> hits, {
    required String title,
    required String emptyReply,
    AppBrainAction action = AppBrainAction.search,
    int? requestedQuantity,
    MedicineBriefFocus? briefFocus,
    StockLocationPatch? locationPatch,
    RemovalReasonHint? removalReason,
  }) async {
    final records = <Medicine>[];
    final seen = <String>{};
    for (final hit in hits) {
      final record = widget.controller.snapshot.records[hit.id];
      if (record != null && !record.archived && seen.add(record.id)) {
        records.add(record);
      }
      if (records.length >= 12) break;
    }
    if (records.isEmpty) {
      widget.onOpenSection(AppSection.stock);
      if (mounted) setState(() => _reply = emptyReply);
      return;
    }
    if (records.length > 1) {
      _pendingChoice = PendingBrainChoice(
        intent: AppBrainIntent(
          action: action,
          quantity: requestedQuantity,
          briefFocus: briefFocus,
          locationPatch: locationPatch,
          removalReason: removalReason,
        ),
        candidates: records,
        createdAt: widget.controller.clock(),
      );
    } else {
      _pendingChoice = null;
    }
    setState(
      () => _reply = briefFocus != null
          ? records.length == 1
                ? '1 stock entry found. Select it and Aaris will answer read-only from the current Medicine Database.'
                : '${records.length} possible stock entries found. Choose the exact medicine/batch; Aaris will not combine ambiguous products.'
          : records.length == 1
          ? '1 stock entry found. Open it to make that exact batch the context for follow-up commands.'
          : '${records.length} possible stock entries found. Choose the exact batch; Aaris will not guess.',
    );
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => FractionallySizedBox(
        heightFactor: .82,
        child: Material(
          color: Theme.of(context).scaffoldBackgroundColor,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 12, 10),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        title,
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ),
                    IconButton(
                      tooltip: 'Close',
                      onPressed: () => Navigator.pop(sheetContext),
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ],
                ),
              ),
              if (records.length > 1)
                const Padding(
                  padding: EdgeInsets.fromLTRB(20, 0, 20, 10),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'Hands-free exact choice: close this list and say “first one”, “second one”, or an exact batch/barcode/block/row/vertical/location. The option map expires and any stock-row revision change invalidates it.',
                      style: TextStyle(
                        color: primary,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        height: 1.35,
                      ),
                    ),
                  ),
                ),
              if (briefFocus != null)
                const Padding(
                  padding: EdgeInsets.fromLTRB(20, 0, 20, 10),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'Read-only answer from saved inventory facts. Selecting a row does not edit, sell, remove or otherwise mutate stock.',
                      style: TextStyle(color: muted, fontSize: 12),
                    ),
                  ),
                )
              else if (action != AppBrainAction.search)
                const Padding(
                  padding: EdgeInsets.fromLTRB(20, 0, 20, 10),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'Choose the exact medicine/batch. Aaris will remember this choice; existing safety confirmation remains mandatory.',
                      style: TextStyle(color: muted, fontSize: 12),
                    ),
                  ),
                ),
              Expanded(
                child: ListView.builder(
                  padding: const EdgeInsets.fromLTRB(18, 4, 18, 24),
                  itemCount: records.length,
                  itemBuilder: (_, index) {
                    final record = records[index];
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (records.length > 1)
                          Padding(
                            padding: const EdgeInsets.fromLTRB(4, 7, 4, 2),
                            child: Text(
                              'OPTION ${index + 1}',
                              style: const TextStyle(
                                color: primary,
                                fontSize: 10,
                                fontWeight: FontWeight.w900,
                                letterSpacing: .8,
                              ),
                            ),
                          ),
                        MedicineCard(
                          record: record,
                          settings: widget.controller.settings,
                          today: widget.controller.today,
                          onTap: () async {
                            Navigator.pop(sheetContext);
                            if (!mounted) return;
                            _pendingChoice = null;
                            _remember(record);
                            if (briefFocus != null) {
                              _answerOperationalBrief(record, briefFocus);
                              return;
                            }
                            if (action == AppBrainAction.search) {
                              widget.onOpenSection(AppSection.stock);
                              setState(
                                () => _reply =
                                    '${record.title} selected. I will remember this exact stock entry for your next command.',
                              );
                              await Future<void>.delayed(Duration.zero);
                              if (mounted) {
                                await openEditor(
                                  context,
                                  widget.controller,
                                  record: record,
                                );
                              }
                              return;
                            }
                            await _openActionTarget(
                              action,
                              record,
                              requestedQuantity: requestedQuantity,
                              locationPatch: locationPatch,
                              removalReason: removalReason,
                            );
                          },
                        ),
                      ],
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _reorderReview() async {
    final range = TrackingRange.lastDays(widget.controller.today, 30);
    final suggestions = widget.controller.tracking(range).reorder;
    final urgent = suggestions
        .where((item) => item.priority == ReorderPriority.urgent)
        .length;
    final review = suggestions.where((item) => item.reviewRequired).length;

    if (mounted) {
      setState(
        () => _reply = suggestions.isEmpty
            ? 'No deterministic reorder trigger is active from current stock and recorded sales. Opening Order Review so you can verify.'
            : 'Order Review: ${suggestions.length} suggestion${suggestions.length == 1 ? '' : 's'} · $urgent urgent · $review need pharmacist evidence review. Weak-evidence rows are never preselected.',
      );
    }
    widget.onOpenSection(AppSection.calculator);
    await Future<void>.delayed(Duration.zero);
    if (!mounted) return;
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) =>
            OrderScreen(controller: widget.controller, range: range),
      ),
    );
  }

  Future<void> _undo() async {
    if (!widget.controller.canUndo) {
      setState(() => _reply = 'There is no current change available to undo.');
      return;
    }

    // Bind the confirmation copy to the exact newest audited event. The
    // controller still rechecks canUndo/revision when committing, so this is an
    // explainability improvement rather than a second authority over recovery.
    final event = widget.controller.snapshot.events.first;
    final label = event['label'] is String
        ? event['label'] as String
        : 'Latest inventory change';
    final revision = event['revision'] is int
        ? event['revision'] as int
        : widget.controller.snapshot.revision;
    final businessDay = event['businessDay'] is String
        ? event['businessDay'] as String
        : '';
    final rawTime = event['time'] is String ? event['time'] as String : '';
    final parsedTime = DateTime.tryParse(rawTime);
    final localTime = parsedTime?.toLocal();
    final timeLabel = localTime == null
        ? 'Time unavailable'
        : localTime.toString().split('.').first;

    final confirmed =
        await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Undo this exact inventory change?'),
            content: Text(
              '$label\n\nRevision $revision${businessDay.isEmpty ? '' : ' · business day $businessDay'}\n$timeLabel\n\nAaris will restore the immediately previous audited inventory state. If anything changes before this confirmation commits, the revision-protected undo will fail closed.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Undo this change'),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed || !mounted) {
      setState(() => _reply = 'Undo cancelled. Nothing changed.');
      return;
    }
    await widget.controller.undo();
    if (mounted) {
      setState(() => _reply = 'Last reviewed inventory change was undone.');
    }
  }

  void _summary() {
    final stats = widget.controller.stats;
    final active = widget.controller.records.where((m) => !m.archived).length;
    final expired = widget.controller.list(SearchScope.expired).length;
    final sold = widget.controller.list(SearchScope.sold).length;
    setState(
      () => _reply =
          'Inventory now: $active active stock entries · ${stats.uniqueMedicines} unique medicines · ${stats.knownUnits} known units · $expired expired · $sold sold/reorder entries · ${stats.unknownQuantity} entries with unknown quantity.',
    );
  }

  void _analyticsBrief(BrainAnalyticsRequest request) {
    final range = request.resolveRange(widget.controller.today);
    final stats = widget.controller.tracking(range);
    final brief = buildBrainAnalyticsBrief(
      request: request,
      stats: stats,
      today: widget.controller.today,
    );
    setState(() => _reply = brief);
  }

  PharmacyAttentionReport _currentAttentionReport() {
    final range = TrackingRange.lastDays(widget.controller.today, 30);
    return PharmacyAttentionReport.build(
      medicines: widget.controller.records,
      settings: widget.controller.settings,
      today: widget.controller.today,
      reorder: widget.controller.tracking(range).reorder,
      sales: widget.controller.sales,
    );
  }

  PharmacyOperationsPlan _currentOperationsPlan(
    PharmacyAttentionReport report,
  ) => PharmacyOperationsPlan.build(
    items: report.items,
    medicines: widget.controller.records,
  );

  OperationsPlanStep? _findPlanStep(PharmacyOperationsPlan plan, String key) {
    for (final step in plan.steps) {
      if (step.item.key == key) return step;
    }
    return null;
  }

  Future<void> _openRecommendedAttentionStep(
    OperationsPlanStep proposed,
  ) async {
    if (!mounted) return;

    // Never route from a cached operational recommendation. Rebuild the
    // deterministic report and require the exact attention key to still exist
    // and still be unblocked immediately before navigation. A concurrent stock
    // change therefore invalidates the recommendation instead of acting on a
    // stale task.
    final liveReport = _currentAttentionReport();
    final livePlan = _currentOperationsPlan(liveReport);
    final step = _findPlanStep(livePlan, proposed.item.key);
    if (step == null || step.blocked) {
      final replacement = livePlan.nextStep;
      setState(
        () => _reply = replacement == null
            ? 'The operating queue changed before this task opened. Aaris stopped instead of using a stale recommendation. Open Needs attention to review the current verified blockers.'
            : 'The operating queue changed before this task opened. Nothing was changed. The new next safe task is ${replacement.item.title}.',
      );
      if (replacement == null) {
        await Navigator.push<void>(
          context,
          MaterialPageRoute(
            builder: (_) => AttentionScreen(controller: widget.controller),
          ),
        );
      }
      return;
    }

    final item = step.item;
    if (item.isReorder) {
      await _reorderReview();
      return;
    }

    final records = item.stockIds
        .map((id) => widget.controller.snapshot.records[id])
        .whereType<Medicine>()
        .where((medicine) => !medicine.archived)
        .toList(growable: false);

    // Cross-row conflicts and grouped FEFO-readiness findings deliberately
    // require an explicit row choice. Aaris may prioritize the work, but it may
    // not guess which physical pack the pharmacist intends to correct.
    if (records.length != 1) {
      setState(
        () => _reply = records.isEmpty
            ? 'That recommended task changed while Aaris was opening it. Nothing was changed; the live operating plan is opening for re-evaluation.'
            : '${item.title} involves ${records.length} exact stock rows. Aaris opened the operating plan so you can choose the physical row instead of guessing.',
      );
      await Navigator.push<void>(
        context,
        MaterialPageRoute(
          builder: (_) => AttentionScreen(controller: widget.controller),
        ),
      );
      return;
    }

    final record = records.single;
    _remember(record);
    widget.onOpenSection(AppSection.stock);
    setState(
      () => _reply =
          'Starting the next safe task: ${item.title}. ${step.actionLabel} Aaris has selected only this exact stock ID; no inventory change happens without the existing review/confirmation boundary.',
    );
    await Future<void>.delayed(Duration.zero);
    if (!mounted) return;

    if (item.kind == AttentionKind.expiredStock) {
      // Expiry itself is a deterministic stored-date fact. Route straight into
      // the existing protected Expired removal review, which still shows the
      // exact stock identity and requires explicit confirmation before archive.
      await _removeTarget(record, reasonHint: RemovalReasonHint.expired);
      return;
    }

    // Verification, quantity, location, FEFO-placement and integrity work all
    // reuse the authoritative editor. The task router does not prefill uncertain
    // values and cannot bypass editor/controller validation.
    await openEditor(context, widget.controller, record: record);
  }

  void _refreshAttentionReply(String attemptedKey) {
    if (!mounted) return;
    final report = _currentAttentionReport();
    if (report.isEmpty) {
      setState(
        () => _reply = 'Task review closed. The deterministic operating queue is clear right now.',
      );
      return;
    }

    final plan = _currentOperationsPlan(report);
    final attempted = _findPlanStep(plan, attemptedKey);
    final next = plan.nextStep;
    setState(() {
      if (attempted != null) {
        _reply =
            'Task review closed. “${attempted.item.title}” still needs attention, so Aaris kept it in the live queue instead of pretending it was completed.${next == null ? '' : ' Next safe task: ${next.item.title}.'}';
      } else if (next != null) {
        _reply =
            'The reviewed task is no longer in the live attention queue. Aaris recalculated from current inventory; next safe task: ${next.item.title}.';
      } else {
        _reply = 'The reviewed task changed the queue. Remaining work is waiting on verified prerequisites, so Aaris will not advance automatically.';
      }
    });
  }

  Future<void> _attentionBrief({bool focusNext = false}) async {
    final report = _currentAttentionReport();
    final plan = _currentOperationsPlan(report);
    final next = plan.nextStep;

    if (report.isEmpty) {
      if (mounted) {
        setState(
          () => _reply = focusNext
              ? 'There is no deterministic pharmacist task waiting right now. Nothing changed.'
              : 'Attention brief: no deterministic operational issue needs attention right now.',
        );
      }
      return;
    }

    if (!focusNext) {
      if (mounted) {
        setState(
          () => _reply = next == null
              ? 'Attention queue: ${report.items.length} items, but no downstream task is safe to start until its recorded prerequisites are rechecked. Opening the operating plan; nothing will be changed automatically.'
              : 'Attention queue: ${report.items.length} item${report.items.length == 1 ? '' : 's'} · ${report.critical} critical · ${report.high} high · ${report.medium} medium · ${plan.readyCount} ready now · ${plan.blockedCount} waiting on prerequisites. Next safe task: ${next.item.title}.',
        );
      }
      await Future<void>.delayed(Duration.zero);
      if (!mounted) return;
      await Navigator.push<void>(
        context,
        MaterialPageRoute(
          builder: (_) => AttentionScreen(controller: widget.controller),
        ),
      );
      return;
    }

    if (next == null) {
      if (mounted) {
        setState(
          () => _reply = 'No task can be started safely from the current queue because the remaining work is waiting on verified prerequisites. Opening the operating plan instead; nothing will be changed automatically.',
        );
      }
      await Future<void>.delayed(Duration.zero);
      if (!mounted) return;
      await Navigator.push<void>(
        context,
        MaterialPageRoute(
          builder: (_) => AttentionScreen(controller: widget.controller),
        ),
      );
      return;
    }

    if (mounted) {
      setState(
        () => _reply =
            'Recommended next: ${next.item.title}. Revalidating the live queue before opening the exact safe workflow…',
      );
    }
    await Future<void>.delayed(Duration.zero);
    if (!mounted) return;
    await _openRecommendedAttentionStep(next);
    if (!mounted) return;
    _refreshAttentionReply(next.item.key);
  }

  void _bulkRemoveBlocked() {
    widget.onOpenSection(AppSection.profile);
    setState(
      () => _reply = 'Bulk removal is intentionally blocked from natural-language commands. Profile opened at the protected owner area; “Remove all inventory” still requires its dedicated multi-step confirmation and a revision-bound inventory review so a voice/AI misunderstanding cannot wipe stock.',
    );
  }

  void _unknown(String raw) {
    setState(
      () => _reply =
          '“$raw” looks like a deeper reasoning request rather than a deterministic app command. Use the AI Controller composer directly below; its Local AI → Aaris Default AI → configured provider safety pipeline remains authoritative for complex reasoning and proposed inventory changes.',
    );
  }

  Future<String?> _handleQuickAction(AiHubQuickAction action) async {
    return switch (action) {
      AiHubQuickAction.sold => _handleUnifiedCommand('sold medicines dikhao'),
      AiHubQuickAction.removed => _handleUnifiedCommand('removed stock dikhao'),
      AiHubQuickAction.stockSummary => _handleUnifiedCommand('stock summary'),
      AiHubQuickAction.add => _handleUnifiedCommand('add medicine'),
      AiHubQuickAction.delete => _openQuickTargetPicker(
        AppBrainAction.removeMedicine,
      ),
      AiHubQuickAction.modify => _openQuickTargetPicker(
        AppBrainAction.editMedicine,
      ),
    };
  }

  Future<String?> _openQuickTargetPicker(AppBrainAction action) async {
    if (_busy) return 'Aaris is finishing the previous local command.';
    if (action != AppBrainAction.removeMedicine &&
        action != AppBrainAction.editMedicine) {
      return null;
    }
    if (mounted) {
      setState(() {
        _busy = true;
        _reply = action == AppBrainAction.removeMedicine
            ? 'Choose the exact medicine to delete. The protected Remove review remains mandatory.'
            : 'Choose the exact medicine to modify.';
      });
    }
    try {
      final hits = await widget.controller.search('', SearchScope.all);
      if (!mounted) return null;
      if (hits.isEmpty) {
        setState(
          () => _reply = 'No active medicine is available for this action.',
        );
        return _reply;
      }
      await _showMatches(
        hits,
        title: action == AppBrainAction.removeMedicine
            ? 'Choose medicine to delete'
            : 'Choose medicine to modify',
        emptyReply: 'No active medicine is available for this action.',
        action: action,
      );
      return _reply;
    } catch (error) {
      final message = error.toString().replaceFirst(
        RegExp(r'^(FormatException|Bad state|StateError):\s*'),
        '',
      );
      if (mounted) setState(() => _reply = message);
      return message;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _editorInstruction(
    AppBrainAction action,
    Medicine record,
  ) => switch (action) {
    AppBrainAction.removeMedicine =>
      '${record.title} matched exactly. Medicine Database opened and the protected Remove flow is ready now.',
    AppBrainAction.markSold =>
      '${record.title} matched exactly. Medicine Database opened and the whole-stock SOLD confirmation is ready now.',
    AppBrainAction.recordSale =>
      '${record.title} opened in Medicine Database. The sale dialog remains inside the editor so FEFO, expiry date, quantity and historical-sale validation stay authoritative.',
    AppBrainAction.setQuantity =>
      '${record.title} opened for an exact stock correction review.',
    AppBrainAction.receiveStock =>
      '${record.title} opened for a received-stock review.',
    AppBrainAction.relocateMedicine =>
      '${record.title} opened for a reviewed stock-location change.',
    AppBrainAction.editMedicine =>
      '${record.title} opened in Medicine Database for review/edit.',
    _ => '${record.title} opened.',
  };

  String _choiceTitle(AppBrainAction action, String query) => switch (action) {
    AppBrainAction.removeMedicine => 'Choose stock to remove · $query',
    AppBrainAction.markSold => 'Choose stock to mark sold · $query',
    AppBrainAction.recordSale => 'Choose stock for sale · $query',
    AppBrainAction.setQuantity => 'Choose stock to correct · $query',
    AppBrainAction.receiveStock => 'Choose stock to receive · $query',
    AppBrainAction.relocateMedicine => 'Choose stock to relocate · $query',
    AppBrainAction.editMedicine => 'Choose stock to edit · $query',
    _ => 'Choose medicine · $query',
  };

  String _briefLabel(MedicineBriefFocus focus) => switch (focus) {
    MedicineBriefFocus.stock => 'stock',
    MedicineBriefFocus.expiry => 'expiry',
    MedicineBriefFocus.location => 'location',
    MedicineBriefFocus.fefo => 'FEFO',
    MedicineBriefFocus.summary => 'operational summary',
  };

  String _sectionReply(AppSection section) => switch (section) {
    AppSection.home => 'Home opened.',
    AppSection.stock => 'Medicine Database opened.',
    AppSection.ai => 'AI Controller is already open.',
    AppSection.calculator => 'Calculator opened.',
    AppSection.profile => 'Profile opened.',
  };

  @override
  Widget build(BuildContext context) => AiScreen(
    controller: widget.controller,
    onLocalCommand: _handleUnifiedCommand,
    onQuickAction: _handleQuickAction,
  );
}
