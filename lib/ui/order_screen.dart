import 'dart:async';

import 'package:flutter/material.dart';

import '../domain/medicine.dart';
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

  void _ensureControllers(Iterable<ReorderSuggestion> suggestions) {
    for (final suggestion in suggestions) {
      if (_quantity.containsKey(suggestion.productKey)) continue;
      _quantity[suggestion.productKey] = TextEditingController(
        text: '${suggestion.suggestedQuantity}',
      );
      _cost[suggestion.productKey] = TextEditingController(
        text: suggestion.unitPricePaise == null
            ? ''
            : (suggestion.unitPricePaise! / 100).toStringAsFixed(2),
      );
      _selected.add(suggestion.productKey);
    }
  }

  @override
  void initState() {
    super.initState();
    _ensureControllers(_suggestions);
  }

  @override
  void dispose() {
    for (final controller in [..._quantity.values, ..._cost.values]) {
      controller.dispose();
    }
    super.dispose();
  }

  List<PurchaseOrderLine> _lines() {
    _ensureControllers(_suggestions);
    final lines = <PurchaseOrderLine>[];
    for (final suggestion in _suggestions) {
      if (!_selected.contains(suggestion.productKey)) continue;
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
        _ensureControllers(suggestions);
        return ListView(
          padding: const EdgeInsets.fromLTRB(22, 8, 22, 30),
          children: [
            const Text(
              'Review every suggested quantity and saved unit cost before sharing with a supplier.',
              style: TextStyle(color: muted, fontSize: 13),
            ),
            const SizedBox(height: 18),
            if (suggestions.isEmpty)
              const EmptyState(
                title: 'No reorder suggestions',
                message: 'Sold-out, low-stock or fast-moving medicines will appear here.',
              ),
            for (final suggestion in suggestions)
              Padding(
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
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                        subtitle: Text(
                          [
                            if (suggestion.salt.isNotEmpty) suggestion.salt,
                            suggestion.reason,
                          ].join(' · '),
                        ),
                        onChanged: (value) => setState(() {
                          if (value == true) {
                            _selected.add(suggestion.productKey);
                          } else {
                            _selected.remove(suggestion.productKey);
                          }
                        }),
                      ),
                      Wrap(
                        spacing: 10,
                        runSpacing: 10,
                        children: [
                          SizedBox(
                            width: 150,
                            child: TextField(
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
                        suggestion.currentQuantity == null
                            ? 'Current stock unknown'
                            : 'Current stock: ${suggestion.currentQuantity}',
                        style: const TextStyle(fontSize: 11, color: muted),
                      ),
                    ],
                  ),
                ),
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
                      : 'Create & share purchase-order PDF',
                ),
              ),
              const Padding(
                padding: EdgeInsets.only(top: 10),
                child: Text(
                  'Rows with no unit cost show “Amount unavailable”; they are never treated as ₹0.',
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
