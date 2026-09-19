import 'dart:async';

import 'package:flutter/material.dart';

import '../domain/attention.dart';
import '../domain/medicine.dart';
import '../domain/operations_plan.dart';
import '../domain/stock_guidance.dart';
import '../domain/tracking.dart';
import '../services/purchase_order_service.dart';
import '../state/pharmacy_controller.dart';
import 'design.dart';
import 'demand_history_sheet.dart';
import 'editor_screen.dart';

class OrderScreen extends StatefulWidget {
  const OrderScreen({
    super.key,
    required this.controller,
    required this.range,
    this.focusProductKey,
  });

  final PharmacyController controller;
  final TrackingRange range;
  final String? focusProductKey;

  @override
  State<OrderScreen> createState() => _OrderScreenState();
}

class _OrderScreenState extends State<OrderScreen> {
  final _service = PurchaseOrderService();
  final Map<String, TextEditingController> _quantity = {};
  final Map<String, TextEditingController> _cost = {};
  final Set<String> _selected = {};
  final Set<String> _seenSuggestions = {};
  final Set<String> _editedQuantity = {};
  final Set<String> _editedCost = {};
  final Set<String> _manualSelection = {};
  bool _sharing = false;
  bool _reviewing = false;

  Object? _readRecords;
  Object? _readSales;
  DateTime? _readDay;
  TrackingRange? _readRange;
  String? _readFocus;
  List<ReorderSuggestion>? _readSuggestions;
  List<ReorderSuggestion>? _planSuggestions;
  Object? _planSettings;
  DateTime? _planDay;
  PharmacyOperationsPlan? _readPlan;

  List<ReorderSuggestion> get _suggestions {
    final snapshot = widget.controller.snapshot;
    final day = widget.controller.today;
    if (identical(snapshot.records, _readRecords) &&
        identical(snapshot.sales, _readSales) &&
        day == _readDay &&
        widget.range.start == _readRange?.start &&
        widget.range.end == _readRange?.end &&
        _readFocus == widget.focusProductKey) {
      return _readSuggestions!;
    }
    final source = widget.controller.tracking(widget.range).reorder;
    _readSuggestions = [
      ...source.where((item) => item.productKey == widget.focusProductKey),
      ...source.where((item) => item.productKey != widget.focusProductKey),
    ];
    _readRecords = snapshot.records;
    _readSales = snapshot.sales;
    _readDay = day;
    _readRange = widget.range;
    _readFocus = widget.focusProductKey;
    return _readSuggestions!;
  }

  PharmacyOperationsPlan _operationsPlan(List<ReorderSuggestion> suggestions) {
    final settings = widget.controller.snapshot.settings;
    final day = widget.controller.today;
    if (identical(suggestions, _planSuggestions) &&
        identical(settings, _planSettings) &&
        day == _planDay) {
      return _readPlan!;
    }
    final attention = PharmacyAttentionReport.build(
      medicines: widget.controller.records,
      settings: settings,
      today: day,
      reorder: suggestions,
      sales: widget.controller.sales,
    );
    final plan = PharmacyOperationsPlan.build(
      items: attention.items,
      medicines: widget.controller.records,
    );
    _planSuggestions = suggestions;
    _planSettings = settings;
    _planDay = day;
    return _readPlan = plan;
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

  void _syncSelection(
    Iterable<ReorderSuggestion> suggestions, {
    Set<String> blockedProductKeys = const <String>{},
    bool selectNew = true,
  }) {
    final liveKeys = suggestions.map((item) => item.productKey).toSet();

    // A reorder suggestion is a live planning cycle, not durable form state.
    // Once a product leaves the plan, retire every transient decision/edit tied
    // to that old cycle. If it later becomes reorder-worthy again, it must enter
    // with fresh defaults and normal auto-selection instead of silently reusing
    // a stale quantity/cost or an old manual-review decision.
    _selected.retainAll(liveKeys);
    _seenSuggestions.retainAll(liveKeys);
    _editedQuantity.retainAll(liveKeys);
    _editedCost.retainAll(liveKeys);
    _manualSelection.retainAll(liveKeys);

    final retiredControllers = <TextEditingController>[];
    void retireMissing(Map<String, TextEditingController> fields) {
      for (final key in fields.keys.toList(growable: false)) {
        if (liveKeys.contains(key)) continue;
        final controller = fields.remove(key);
        if (controller != null) retiredControllers.add(controller);
      }
    }

    retireMissing(_quantity);
    retireMissing(_cost);
    if (retiredControllers.isNotEmpty) {
      // _syncSelection also runs during build. Dispose only after that frame so
      // TextField states being removed can detach from their controllers first.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        for (final controller in retiredControllers) {
          controller.dispose();
        }
      });
    }

    for (final suggestion in suggestions) {
      final isNew = _seenSuggestions.add(suggestion.productKey);

      // Deterministic reorder confidence is necessary but not sufficient. A
      // currently known physical-fact/integrity blocker for this product wins
      // over any previous selection, including a stale manual selection.
      if (blockedProductKeys.contains(suggestion.productKey) ||
          (suggestion.reviewRequired &&
              !_manualSelection.contains(suggestion.productKey))) {
        _selected.remove(suggestion.productKey);
      } else if (selectNew &&
          isNew &&
          !suggestion.reviewRequired &&
          suggestion.suggestedQuantity != null) {
        _selected.add(suggestion.productKey);
      }
    }
  }

  void _prepareFields(ReorderSuggestion suggestion) {
    // Only visible rows need editing controllers. Selected rows outside the
    // viewport use the same validated defaults when the PDF is prepared.
    final field = _quantity.putIfAbsent(
      suggestion.productKey,
      () => TextEditingController(text: _defaultQuantity(suggestion)),
    );
    final latest = _defaultQuantity(suggestion);
    if (!_editedQuantity.contains(suggestion.productKey) &&
        field.text != latest) {
      field.value = TextEditingValue(
        text: latest,
        selection: TextSelection.collapsed(offset: latest.length),
      );
    }
    final cost = _cost.putIfAbsent(
      suggestion.productKey,
      () => TextEditingController(text: _defaultCost(suggestion)),
    );
    final latestCost = _defaultCost(suggestion);
    if (!_editedCost.contains(suggestion.productKey) &&
        cost.text != latestCost) {
      cost.value = TextEditingValue(
        text: latestCost,
        selection: TextSelection.collapsed(offset: latestCost.length),
      );
    }
  }

  String _defaultQuantity(ReorderSuggestion suggestion) =>
      suggestion.reviewRequired || suggestion.suggestedQuantity == null
      ? ''
      : '${suggestion.suggestedQuantity}';

  String _defaultCost(ReorderSuggestion suggestion) =>
      suggestion.unitPricePaise == null
      ? ''
      : (suggestion.unitPricePaise! / 100).toStringAsFixed(2);

  @override
  void initState() {
    super.initState();
    final suggestions = _suggestions;
    final blocked = _blockedOrders(_operationsPlan(suggestions)).keys.toSet();
    _syncSelection(suggestions, blockedProductKeys: blocked);
  }

  @override
  void dispose() {
    for (final controller in [..._quantity.values, ..._cost.values]) {
      controller.dispose();
    }
    super.dispose();
  }

  List<PurchaseOrderLine> _lines() {
    final previousSelection = Set<String>.of(_selected);
    final suggestions = _suggestions;
    final blocked = _blockedOrders(_operationsPlan(suggestions));
    _syncSelection(
      suggestions,
      blockedProductKeys: blocked.keys.toSet(),
      selectNew: false,
    );
    if (previousSelection.any((key) => !_selected.contains(key))) {
      throw const FormatException(
        'स्टॉक बदल गया है। चुनी हुई दवाएँ दोबारा जाँचें।',
      );
    }
    final lines = <PurchaseOrderLine>[];
    for (final suggestion in suggestions) {
      if (!_selected.contains(suggestion.productKey)) continue;
      final quantity = int.tryParse(
        (_editedQuantity.contains(suggestion.productKey)
                ? (_quantity[suggestion.productKey]?.text ?? '')
                : _defaultQuantity(suggestion))
            .trim(),
      );
      if (quantity == null || quantity < 1 || quantity > 100000000) {
        throw FormatException(
          '${suggestion.title}: मँगाने की मात्रा 1 या उससे अधिक लिखें।',
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
          unitCostPaise: parseMoney(
            _editedCost.contains(suggestion.productKey)
                ? (_cost[suggestion.productKey]?.text ?? '')
                : _defaultCost(suggestion),
          ),
        ),
      );
    }
    return lines;
  }

  Future<void> _history(ReorderSuggestion suggestion) async {
    if (_reviewing || _sharing) return;
    _reviewing = true;
    try {
      await showDemandHistory(
        context,
        widget.controller,
        productKey: suggestion.productKey,
        title: suggestion.title,
      );
    } finally {
      _reviewing = false;
    }
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

  Future<void> _reviewBlocker(ReorderSuggestion suggestion) async {
    if (_reviewing || _sharing) return;
    setState(() => _reviewing = true);
    try {
      final liveStep = _blockedOrders(
        _operationsPlan(_suggestions),
      )[suggestion.productKey];
      if (liveStep == null) return;
      final fact = liveStep.prerequisites.first;
      final records = fact.stockIds
          .map((id) => widget.controller.snapshot.records[id])
          .whereType<Medicine>()
          .where((record) => !record.archived)
          .toList(growable: false);
      if (records.isEmpty) return;
      var id = records.first.id;
      if (records.length > 1) {
        final selected = await showModalBottomSheet<String>(
          context: context,
          useSafeArea: true,
          builder: (sheetContext) => ListView.builder(
            itemCount: records.length,
            itemBuilder: (_, index) {
              final record = records[index];
              return ListTile(
                title: Text(record.title),
                subtitle: Text(
                  record.address.isEmpty ? 'स्टॉक चुनें' : record.address,
                ),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => Navigator.pop(sheetContext, record.id),
              );
            },
          ),
        );
        if (selected == null || !mounted) return;
        id = selected;
      }
      final live = widget.controller.snapshot.records[id];
      if (mounted && live != null && !live.archived) {
        await openEditor(context, widget.controller, record: live);
      }
    } finally {
      if (mounted) setState(() => _reviewing = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('दवाएँ मँगाएँ')),
    body: SafeArea(
      top: false,
      child: ActiveListenableBuilder(
        listenable: widget.controller,
        rebuildToken: () => (
          widget.controller.snapshot.records,
          widget.controller.snapshot.sales,
          widget.controller.snapshot.settings,
          widget.controller.today,
        ),
        builder: (context, _) {
          final suggestions = _suggestions;
          final blocked = _blockedOrders(_operationsPlan(suggestions));
          _syncSelection(suggestions, blockedProductKeys: blocked.keys.toSet());
          final indices = {
            for (var i = 0; i < suggestions.length; i++)
              suggestions[i].productKey: i + 1,
          };
          return ListView.builder(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            itemCount: suggestions.length + 2,
            findChildIndexCallback: (key) =>
                key is ValueKey<String> ? indices[key.value] : null,
            itemBuilder: (context, index) {
              if (index == 0) {
                return Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: Text(
                    suggestions.isEmpty
                        ? 'अभी कोई नया ऑर्डर सुझाया नहीं गया है।'
                        : '${_selected.length} दवाएँ चुनीं · मात्रा जाँचकर PDF भेजें',
                    style: const TextStyle(color: muted, fontSize: 13),
                  ),
                );
              }
              if (index <= suggestions.length) {
                final suggestion = suggestions[index - 1];
                return _orderCard(suggestion, blocked[suggestion.productKey]);
              }
              if (suggestions.isEmpty) return const SizedBox.shrink();
              return Padding(
                padding: const EdgeInsets.only(top: 8),
                child: FilledButton.icon(
                  onPressed: _sharing || _selected.isEmpty
                      ? null
                      : () => unawaited(_share()),
                  icon: const Icon(Icons.picture_as_pdf_outlined),
                  label: Text(_sharing ? 'PDF बन रही है…' : 'ऑर्डर PDF भेजें'),
                ),
              );
            },
          );
        },
      ),
    ),
  );

  Widget _orderCard(ReorderSuggestion suggestion, OperationsPlanStep? blocker) {
    if (blocker == null) _prepareFields(suggestion);
    final enabled = !_sharing && blocker == null;
    final action = blocker != null
        ? 'पहले ${stockActionLabel(blocker.prerequisites.first.kind)}'
        : suggestion.reviewRequired || suggestion.suggestedQuantity == null
        ? 'मँगाने की मात्रा भरें'
        : '${suggestion.suggestedQuantity} यूनिट मँगाएँ';
    return Card(
      key: ValueKey(suggestion.productKey),
      margin: const EdgeInsets.only(bottom: 10),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: primary.withValues(alpha: .12)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              action,
              style: TextStyle(
                color: blocker == null ? primary : amber,
                fontSize: 14,
                fontWeight: FontWeight.w800,
              ),
            ),
            CheckboxListTile(
              value: _selected.contains(suggestion.productKey),
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.trailing,
              title: Text(
                suggestion.title,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              subtitle: Text(
                reorderSummary(suggestion, widget.range.days),
                style: const TextStyle(color: muted, fontSize: 12),
              ),
              onChanged: enabled
                  ? (value) => setState(() {
                      if (value == true) {
                        _manualSelection.add(suggestion.productKey);
                        _selected.add(suggestion.productKey);
                      } else {
                        _manualSelection.remove(suggestion.productKey);
                        _selected.remove(suggestion.productKey);
                      }
                    })
                  : null,
            ),
            if (suggestion.demand != null)
              TextButton.icon(
                onPressed: _sharing ? null : () => _history(suggestion),
                icon: const Icon(Icons.bar_chart_rounded, size: 18),
                label: const Text('दिनवार बिक्री'),
              ),
            if (blocker != null)
              TextButton.icon(
                onPressed: _sharing || _reviewing
                    ? null
                    : () => _reviewBlocker(suggestion),
                icon: const Icon(Icons.edit_note_rounded),
                label: const Text('जानकारी जाँचें'),
              )
            else ...[
              const SizedBox(height: 8),
              LayoutBuilder(
                builder: (context, constraints) {
                  final fieldWidth = constraints.maxWidth < 290
                      ? constraints.maxWidth
                      : (constraints.maxWidth - 12) / 2;
                  return Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      SizedBox(
                        width: fieldWidth,
                        child: TextField(
                          enabled: enabled,
                          textInputAction: TextInputAction.next,
                          controller: _quantity[suggestion.productKey],
                          onChanged: (_) =>
                              _editedQuantity.add(suggestion.productKey),
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            labelText: 'मात्रा · यूनिट',
                          ),
                        ),
                      ),
                      SizedBox(
                        width: fieldWidth,
                        child: TextField(
                          enabled: enabled,
                          textInputAction: TextInputAction.done,
                          controller: _cost[suggestion.productKey],
                          onChanged: (_) =>
                              _editedCost.add(suggestion.productKey),
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          decoration: const InputDecoration(
                            labelText: 'प्रति यूनिट · ₹',
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ],
          ],
        ),
      ),
    );
  }
}
