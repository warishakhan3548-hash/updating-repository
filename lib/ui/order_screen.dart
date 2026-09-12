import 'dart:async';

import 'package:flutter/material.dart';

import '../domain/attention.dart';
import '../domain/medicine.dart';
import '../domain/operations_plan.dart';
import '../domain/tracking.dart';
import '../services/purchase_order_service.dart';
import '../state/pharmacy_controller.dart';
import 'design.dart';

class OrderScreen extends StatefulWidget {
  const OrderScreen({super.key, required this.controller, required this.range});

  final PharmacyController controller;
  final TrackingRange range;

  @override
  State<OrderScreen> createState() => _OrderScreenState();
}

class _OrderScreenState extends State<OrderScreen> {
  final _service = PurchaseOrderService();
  final Map<String, TextEditingController> _quantity = {};
  final Map<String, TextEditingController> _cost = {};
  final Set<String> _selected = {};
  bool _sharing = false;

  List<ReorderSuggestion> get _suggestions =>
      widget.controller.tracking(widget.range).reorder;

  PharmacyOperationsPlan _operationsPlan(List<ReorderSuggestion> suggestions) {
    final attention = PharmacyAttentionReport.build(
      medicines: widget.controller.records,
      settings: widget.controller.settings,
      today: widget.controller.today,
      reorder: suggestions,
      sales: widget.controller.sales,
    );
    return PharmacyOperationsPlan.build(
      items: attention.items,
      medicines: widget.controller.records,
    );
  }

  Map<String, OperationsPlanStep> _blockedOrders(PharmacyOperationsPlan plan) {
    final blocked = <String, OperationsPlanStep>{};
    for (final step in plan.steps) {
      final productKey = step.item.productKey;
      if (step.item.isReorder &&
          step.blocked &&
          productKey != null &&
          productKey.isNotEmpty) {
        blocked[productKey] = step;
      }
    }
    return blocked;
  }

  void _ensureControllers(
    Iterable<ReorderSuggestion> suggestions, {
    Set<String> blockedProductKeys = const <String>{},
  }) {
    for (final suggestion in suggestions) {
      final isNew = !_quantity.containsKey(suggestion.productKey);
      if (isNew) {
        _quantity[suggestion.productKey] = TextEditingController(
          text: '${suggestion.suggestedQuantity}',
        );
        _cost[suggestion.productKey] = TextEditingController(
          text: suggestion.unitPricePaise == null
              ? ''
              : (suggestion.unitPricePaise! / 100).toStringAsFixed(2),
        );
      }

      // Deterministic reorder confidence is necessary but not sufficient. A
      // currently known physical-fact/integrity blocker for this product wins
      // over any previous selection, including a stale manual selection.
      if (blockedProductKeys.contains(suggestion.productKey)) {
        _selected.remove(suggestion.productKey);
      } else if (isNew && !suggestion.reviewRequired) {
        _selected.add(suggestion.productKey);
      }
    }
  }

  @override
  void initState() {
    super.initState();
    final suggestions = _suggestions;
    final blocked = _blockedOrders(_operationsPlan(suggestions)).keys.toSet();
    _ensureControllers(suggestions, blockedProductKeys: blocked);
  }

  @override
  void dispose() {
    for (final controller in [..._quantity.values, ..._cost.values]) {
      controller.dispose();
    }
    super.dispose();
  }

  List<PurchaseOrderLine> _lines() {
    final suggestions = _suggestions;
    final blocked = _blockedOrders(_operationsPlan(suggestions));
    _ensureControllers(suggestions, blockedProductKeys: blocked.keys.toSet());
    final lines = <PurchaseOrderLine>[];
    for (final suggestion in suggestions) {
      if (!_selected.contains(suggestion.productKey)) continue;
      final blocker = blocked[suggestion.productKey];
      if (blocker != null) {
        throw FormatException(
          '${suggestion.title} is waiting on ${blocker.prerequisites.length} verified stock ${blocker.prerequisites.length == 1 ? 'fact' : 'facts'}. Resolve Needs Attention before adding it to a purchase order.',
        );
      }
      final quantity = int.tryParse(
        _quantity[suggestion.productKey]!.text.trim(),
      );
      if (quantity == null || quantity < 1 || quantity > 100000000) {
        throw FormatException(
          'Enter a positive whole-number quantity for ${suggestion.title}.',
        );
      }
      lines.add(
        PurchaseOrderLine(
          name: suggestion.name,
          salt: suggestion.salt,
          strength: suggestion.strength,
          reason: suggestion.reason,
          quantity: quantity,
          currentQuantity: suggestion.currentQuantity,
          unitCostPaise: parseMoney(_cost[suggestion.productKey]!.text),
        ),
      );
    }
    return lines;
  }

  Future<void> _share() async {
    if (_sharing) return;
    setState(() => _sharing = true);
    try {
      await _service.share(lines: _lines(), date: widget.controller.today);
    } catch (error) {
      if (mounted) showError(context, error);
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Order Now')),
    body: AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) {
        final suggestions = _suggestions;
        final operationsPlan = _operationsPlan(suggestions);
        final blockedOrders = _blockedOrders(operationsPlan);
        _ensureControllers(
          suggestions,
          blockedProductKeys: blockedOrders.keys.toSet(),
        );
        final needsReview = suggestions
            .where((suggestion) => suggestion.reviewRequired)
            .length;
        return ListView(
          padding: const EdgeInsets.fromLTRB(22, 8, 22, 30),
          children: [
            const ScreenIntro(
              title: 'Prepare your order',
              message: 'Aaris uses recorded stock, expiry and sales movement to prepare reorder suggestions. Uncertain suggestions stay unselected, and known data-integrity blockers must be resolved before ordering.',
              icon: Icons.shopping_bag_outlined,
            ),
            const FlowSteps(['Verify blockers', 'Check quantity', 'Share PDF']),
            if (suggestions.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    StatusPill(
                      '${_selected.length} medicines selected',
                      color: amber,
                    ),
                    if (needsReview > 0)
                      StatusPill('$needsReview need review', color: primary),
                    if (blockedOrders.isNotEmpty)
                      StatusPill(
                        '${blockedOrders.length} blocked by stock facts',
                        color: red,
                      ),
                  ],
                ),
              ),
            if (suggestions.isEmpty)
              const EmptyState(
                title: 'No reorder suggestions',
                message: 'Sold-out, low-stock or expiring-before-lead-time medicines will appear here when recorded facts support a suggestion.',
              ),
            for (final suggestion in suggestions)
              Builder(
                builder: (context) {
                  final blocked = blockedOrders[suggestion.productKey];
                  final prerequisites =
                      blocked?.prerequisites ?? const <AttentionItem>[];
                  final enabled = !_sharing && blocked == null;
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Surface(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          CheckboxListTile(
                            value: _selected.contains(suggestion.productKey),
                            contentPadding: EdgeInsets.zero,
                            controlAffinity: ListTileControlAffinity.leading,
                            title: Text(
                              suggestion.title,
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            subtitle: Text(
                              [
                                if (suggestion.salt.isNotEmpty) suggestion.salt,
                                suggestion.reason,
                                suggestion.confidenceLabel,
                                if (suggestion.unitPricePaise == null)
                                  'Unit cost needs review',
                                if (suggestion.reviewRequired)
                                  'Manual review required',
                                if (blocked != null)
                                  'Blocked by ${prerequisites.length} verified-stock prerequisite${prerequisites.length == 1 ? '' : 's'}',
                              ].join(' · '),
                            ),
                            onChanged: enabled
                                ? (value) => setState(() {
                                    if (value == true) {
                                      _selected.add(suggestion.productKey);
                                    } else {
                                      _selected.remove(suggestion.productKey);
                                    }
                                  })
                                : null,
                          ),
                          if (blocked != null) ...[
                            Container(
                              width: double.infinity,
                              margin: const EdgeInsets.only(bottom: 12),
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: red.withValues(alpha: .08),
                                borderRadius: BorderRadius.circular(14),
                              ),
                              child: Text(
                                'Resolve first: ${prerequisites.first.title}. Aaris has removed this medicine from the current order selection until the authoritative stock facts are corrected.',
                                style: const TextStyle(
                                  color: red,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w800,
                                  height: 1.4,
                                ),
                              ),
                            ),
                          ],
                          Wrap(
                            spacing: 10,
                            runSpacing: 10,
                            children: [
                              SizedBox(
                                width: 150,
                                child: TextField(
                                  enabled: enabled,
                                  textInputAction: TextInputAction.next,
                                  controller: _quantity[suggestion.productKey],
                                  keyboardType: TextInputType.number,
                                  onChanged: (_) => setState(() {}),
                                  decoration: const InputDecoration(
                                    labelText: 'Order quantity',
                                  ),
                                ),
                              ),
                              SizedBox(
                                width: 170,
                                child: TextField(
                                  enabled: enabled,
                                  textInputAction: TextInputAction.next,
                                  controller: _cost[suggestion.productKey],
                                  keyboardType:
                                      const TextInputType.numberWithOptions(
                                        decimal: true,
                                      ),
                                  onChanged: (_) => setState(() {}),
                                  decoration: const InputDecoration(
                                    labelText: 'Unit cost · ₹',
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 10),
                          Text(
                            [
                              suggestion.currentQuantity == null
                                  ? 'Current stock unknown'
                                  : 'Current stock: ${suggestion.currentQuantity}',
                              if (suggestion.coverageDays != null)
                                'Coverage ≈ ${suggestion.coverageDays!.toStringAsFixed(1)} days from recorded sales',
                              if (suggestion.expiringWithinLeadUnits > 0)
                                '${suggestion.expiringWithinLeadUnits} known units expire inside the lead window',
                            ].join(' · '),
                            style: const TextStyle(fontSize: 11, color: muted),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            if (suggestions.isNotEmpty) ...[
              const SizedBox(height: 8),
              FilledButton.icon(
                onPressed: _sharing || _selected.isEmpty
                    ? null
                    : () => unawaited(_share()),
                icon: const Icon(Icons.picture_as_pdf_outlined),
                label: Text(
                  _sharing
                      ? 'Preparing purchase order…'
                      : 'Share purchase-order PDF',
                ),
              ),
              const Padding(
                padding: EdgeInsets.only(top: 10),
                child: Text(
                  'Suggested quantities are operational estimates from your recorded inventory and sales—not medical advice. Missing or conflicting facts cannot enter a purchase order silently.',
                  style: TextStyle(fontSize: 11, color: muted),
                  textAlign: TextAlign.center,
                ),
              ),
            ],
          ],
        );
      },
    ),
  );
}
