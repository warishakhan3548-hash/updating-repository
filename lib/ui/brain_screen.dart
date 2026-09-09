import 'dart:async';

import 'package:flutter/material.dart';

import '../domain/app_brain.dart';
import '../domain/attention.dart';
import '../domain/dispensing_plan.dart';
import '../domain/inventory.dart';
import '../domain/medicine.dart';
import '../domain/medicine_brief.dart';
import '../domain/search.dart';
import '../domain/tracking.dart';
import '../services/scan_service.dart';
import '../state/operational_context.dart';
import '../state/pharmacy_controller.dart';
import 'ai_screen.dart';
import 'attention_screen.dart';
import 'design.dart';
import 'editor_screen.dart';
import 'import_screen.dart';
import 'order_screen.dart';
import 'scanner_screen.dart';
import 'search_screen.dart';
import 'voice_sheet.dart';

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
  final _command = TextEditingController();
  bool _busy = false, _voiceOpening = false;
  String _reply =
      'Ready. Ask stock, expiry, location or FEFO from the local Medicine Database, open safe actions, or ask “aaj kya dekhna hai”.';

  @override
  void dispose() {
    _command.dispose();
    super.dispose();
  }

  Future<void> _run([String? supplied]) async {
    if (_busy) return;
    final raw = (supplied ?? _command.text).trim();
    if (raw.isEmpty) return;
    final intent = parseAppBrainIntent(raw);
    setState(() {
      _busy = true;
      _reply = 'Understanding command…';
      if (supplied != null) _command.text = supplied;
    });
    try {
      await _execute(intent, raw);
    } catch (error) {
      if (mounted) {
        setState(
          () => _reply = error.toString().replaceFirst(
            RegExp(r'^(FormatException|Bad state|StateError):\s*'),
            '',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _execute(AppBrainIntent intent, String raw) async {
    switch (intent.action) {
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
      case AppBrainAction.editMedicine:
      case AppBrainAction.setQuantity:
      case AppBrainAction.receiveStock:
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
      case AppBrainAction.attentionBrief:
        await _attentionBrief();
        return;
      case AppBrainAction.bulkRemoveBlocked:
        _bulkRemoveBlocked();
        return;
      case AppBrainAction.unknown:
        _unknown(raw);
        return;
    }
  }

  Future<void> _scanMedicine() async {
    if (!mounted) return;
    widget.onOpenSection(AppSection.stock);
    setState(
      () => _reply =
          'Opening the existing local scanner. Barcode + OCR evidence will be reviewed before any stock can change.',
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
        () => _reply =
            'The scan contained no usable barcode or medicine text. Nothing changed.',
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

    if (briefFocus != null && isAppBrainContextReference(query)) {
      final remembered = _rememberedTarget();
      if (remembered == null) {
        widget.onOpenSection(AppSection.stock);
        if (mounted) {
          setState(
            () => _reply =
                'I do not have a safe previous medicine target yet. Medicine Database opened so you can choose the exact medicine first.',
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
          () => _reply =
              'Medicine name, batch, barcode or an exact previous selection is missing. Medicine Database opened instead of guessing which medicine you meant.',
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
        emptyReply:
            'No safe local match found. Aaris will not guess an operational answer.',
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

  void _answerOperationalBrief(
    Medicine anchor,
    MedicineBriefFocus focus,
  ) {
    if (!mounted) return;
    final live = widget.controller.snapshot.records[anchor.id];
    if (live == null || live.archived) {
      widget.controller.clearOperationalTarget(anchor.id);
      setState(
        () => _reply =
            'That stock entry is no longer active. Choose the medicine again so Aaris can answer from the current inventory snapshot.',
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
    if (isAppBrainContextReference(query)) {
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
    );
  }

  Future<void> _openActionTarget(
    AppBrainAction action,
    Medicine record, {
    bool fromContext = false,
    int? requestedQuantity,
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
      _ => _editorInstruction(action, record),
    };
    setState(() => _reply = '$prefix$instruction');
    await Future<void>.delayed(Duration.zero);
    if (!mounted) return;

    // Short deterministic mutations always resolve an exact stock row first,
    // prepare a review tied to the current inventory revision, and still require
    // a pharmacist confirmation before the controller can commit anything.
    if (action == AppBrainAction.removeMedicine) {
      await _removeTarget(record);
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
      throw StateError('That stock entry is no longer active. Nothing changed.');
    }

    if (!review.changesQuantity && kind == StockAdjustmentKind.setExact) {
      setState(
        () => _reply = '${live.title} already has ${review.afterQuantity} units recorded. No inventory change was needed.',
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

  Future<void> _removeTarget(Medicine original) async {
    if (!mounted) return;
    final live = widget.controller.snapshot.records[original.id];
    if (live == null || live.archived) {
      setState(
        () => _reply = 'That stock entry is no longer active. Nothing changed.',
      );
      return;
    }
    final expectedRevision = widget.controller.snapshot.revision;
    final expired = isExpiredOn(live, widget.controller.today);
    final reasons = <String>[
      if (expired) 'Expired',
      if (!live.sold) 'Sold / stock finished',
      if (!expired) 'Expired',
      'Damaged',
      'Returned',
      'Correction',
    ];

    final reason = await showDialog<String>(
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
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 15),
              child: Text(item),
            ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx),
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 15),
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

    final confirmed =
        await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (ctx) => AlertDialog(
            title: Text('Remove ${live.name}?'),
            content: Text(
              '${_stockIdentityCue(live)}\n\nReason: $reason\n\nThis stock entry will leave active inventory, search and totals. It remains in removed history and can be restored or undone.',
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

    if (widget.controller.snapshot.revision != expectedRevision) {
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
    final expectedRevision = widget.controller.snapshot.revision;
    final confirmed =
        await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (ctx) => AlertDialog(
            title: Text('Mark ${live.name} SOLD?'),
            content: Text(
              '${_stockIdentityCue(live)}\n\nThis means this entire physical stock entry is finished. Quantity becomes 0 and the medicine enters reorder intelligence. It does not create a customer sale event.',
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
    if (widget.controller.snapshot.revision != expectedRevision) {
      throw StateError(
        'Inventory changed while you were confirming. Run the command again so Aaris can re-check this exact stock entry.',
      );
    }
    await widget.controller.markSold(live.id);
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
    if (!record.archived) widget.controller.rememberOperationalTarget(record.id);
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
                    return MedicineCard(
                      record: record,
                      settings: widget.controller.settings,
                      today: widget.controller.today,
                      onTap: () async {
                        Navigator.pop(sheetContext);
                        if (!mounted) return;
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
                        );
                      },
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
    final confirmed =
        await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Undo last inventory change?'),
            content: const Text(
              'Aaris will restore the immediately previous inventory state through the existing audited undo transaction.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Undo'),
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

  Future<void> _attentionBrief() async {
    final range = TrackingRange.lastDays(widget.controller.today, 30);
    final report = PharmacyAttentionReport.build(
      medicines: widget.controller.records,
      settings: widget.controller.settings,
      today: widget.controller.today,
      reorder: widget.controller.tracking(range).reorder,
    );
    if (mounted) {
      setState(
        () => _reply = report.isEmpty
            ? 'Attention brief: no deterministic operational issue needs attention right now.'
            : 'Attention queue: ${report.items.length} item${report.items.length == 1 ? '' : 's'} · ${report.critical} critical · ${report.high} high · ${report.medium} medium. Next: ${report.items.first.title}.',
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

  Future<void> _voice() async {
    if (_voiceOpening || _busy) return;
    setState(() => _voiceOpening = true);
    try {
      final words = await voiceSearch(
        context,
        offlineOnly: true,
        title: 'Speak an app command',
        actionLabel: 'Run command',
      );
      if (mounted && words != null && words.trim().isNotEmpty) {
        await _run(words.trim());
      }
    } finally {
      if (mounted) setState(() => _voiceOpening = false);
    }
  }

  Widget _brainBar(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(14, 8, 14, 3),
    child: Surface(
      color: primarySoft,
      padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.psychology_alt_rounded, color: primary),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Aaris App Brain · offline commands',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontWeight: FontWeight.w900, color: ink),
                ),
              ),
            ],
          ),
          const SizedBox(height: 7),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _command,
                  enabled: !_busy,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => unawaited(_run()),
                  decoration: const InputDecoration(
                    hintText:
                        'Dolo stock kitna · expiry kab · add 12 units · delete karo',
                    prefixIcon: Icon(Icons.bolt_rounded),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              IconButton.filledTonal(
                tooltip: 'Speak command',
                onPressed: _voiceOpening || _busy ? null : _voice,
                icon: const Icon(Icons.mic_rounded),
              ),
              const SizedBox(width: 2),
              IconButton.filled(
                tooltip: 'Run command',
                onPressed: _busy ? null : _run,
                icon: _busy
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.arrow_forward_rounded),
              ),
            ],
          ),
          const SizedBox(height: 7),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 72),
            child: SingleChildScrollView(
              primary: false,
              child: Text(
                _reply,
                style: const TextStyle(
                  color: muted,
                  fontSize: 11.5,
                  height: 1.35,
                ),
              ),
            ),
          ),
          const SizedBox(height: 6),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children:
                  [
                        _QuickCommand('Scan', 'scan medicine'),
                        _QuickCommand('Needs attention', 'aaj kya dekhna hai'),
                        _QuickCommand('Order review', 'order now'),
                        _QuickCommand('Expired', 'expired medicines dikhao'),
                        _QuickCommand('Sold', 'sold medicines dikhao'),
                        _QuickCommand('Stock summary', 'stock summary'),
                        _QuickCommand('Add medicine', 'add medicine'),
                        _QuickCommand('Undo', 'undo last'),
                      ]
                      .map(
                        (item) => Padding(
                          padding: const EdgeInsets.only(right: 7),
                          child: ActionChip(
                            label: Text(item.label),
                            onPressed: _busy ? null : () => _run(item.command),
                          ),
                        ),
                      )
                      .toList(),
            ),
          ),
        ],
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => Column(
    children: [
      _brainBar(context),
      Expanded(child: AiScreen(controller: widget.controller)),
    ],
  );
}

class _QuickCommand {
  const _QuickCommand(this.label, this.command);
  final String label, command;
}
