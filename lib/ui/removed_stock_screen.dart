import 'dart:async';

import 'package:flutter/material.dart';

import '../domain/medicine.dart';
import '../domain/search.dart';
import '../state/pharmacy_controller.dart';
import 'design.dart';

/// Read-only discovery plus explicit reviewed recovery for archived stock.
///
/// Removed rows remain in the one authoritative medicine database. This screen
/// never owns a copy of inventory and never restores from a fuzzy match without
/// an exact row review + confirmation.
class RemovedStockScreen extends StatefulWidget {
  const RemovedStockScreen({
    super.key,
    required this.controller,
    this.initialQuery = '',
  });

  final PharmacyController controller;
  final String initialQuery;

  @override
  State<RemovedStockScreen> createState() => _RemovedStockScreenState();
}

class _RemovedStockScreenState extends State<RemovedStockScreen> {
  late final TextEditingController _query = TextEditingController(
    text: widget.initialQuery,
  );
  Timer? _debounce;
  List<SearchHit> _hits = const [];
  bool _loading = true;
  String _error = '';
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_inventoryChanged);
    unawaited(_search());
  }

  void _inventoryChanged() {
    _debounce?.cancel();
    if (mounted) unawaited(_search());
  }

  void _typed(String _) {
    _debounce?.cancel();
    if (mounted) {
      setState(() {
        _loading = true;
        _error = '';
      });
    }
    _debounce = Timer(
      const Duration(milliseconds: 150),
      () => unawaited(_search()),
    );
  }

  Future<void> _search() async {
    final generation = ++_generation;
    final query = _query.text;
    if (mounted) {
      setState(() {
        _loading = true;
        _error = '';
      });
    }
    try {
      final hits = await widget.controller.searchArchived(query);
      if (!mounted || generation != _generation) return;
      setState(() {
        _hits = hits;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _hits = const [];
        _loading = false;
        _error = 'Removed-stock search could not finish. Please try again.';
      });
    }
  }

  Future<void> _reviewRestore(Medicine record) async {
    late final ReviewedArchivedRestore review;
    try {
      review = widget.controller.reviewArchivedRestore(record.id);
    } catch (error) {
      if (mounted) showError(context, error);
      return;
    }

    final live = widget.controller.snapshot.records[review.stockId];
    if (live == null || !live.archived || !mounted) return;
    final facts = <String>[
      if (live.batchNumber.trim().isNotEmpty) 'Batch ${live.batchNumber.trim()}',
      live.expiry == null
          ? 'EXP not recorded'
          : 'EXP ${live.expiryMonthOnly ? dateText(live.expiry!).substring(0, 7) : dateText(live.expiry!)}',
      live.quantity == null ? 'Quantity unknown' : '${live.quantity} units',
      if (live.address.trim().isNotEmpty) live.address.trim(),
    ];
    final removedWhen = live.archivedAt == null
        ? 'Removal time not available'
        : 'Removed ${live.archivedAt!.toLocal().toString().split('.').first}';
    final reason = live.archiveReason.trim().isEmpty
        ? 'Legacy removal reason not available'
        : live.archiveReason.trim();

    final confirmed = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Restore this removed stock?'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  live.title,
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 8),
                if (facts.isNotEmpty)
                  Text(
                    facts.join(' · '),
                    style: const TextStyle(color: muted),
                  ),
                const SizedBox(height: 10),
                Text('$reason · $removedWhen'),
                const SizedBox(height: 14),
                const Text(
                  'This returns the same archived row to the Medicine Database. Existing SOLD, expiry, quantity and batch facts are preserved; Aaris does not invent or reset them. If inventory changes before confirmation, the restore is rejected and must be reviewed again.',
                  style: TextStyle(fontSize: 12, color: muted, height: 1.4),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel'),
              ),
              FilledButton.icon(
                onPressed: () => Navigator.pop(ctx, true),
                icon: const Icon(Icons.restore_rounded),
                label: const Text('Restore stock'),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed || !mounted) return;

    try {
      await widget.controller.applyArchivedRestore(review);
      if (mounted) {
        showSaved(
          context,
          '${live.title} restored to the Medicine Database. Undo is available in Activity.',
        );
      }
    } catch (error) {
      if (mounted) showError(context, error);
    }
  }

  @override
  void dispose() {
    ++_generation;
    widget.controller.removeListener(_inventoryChanged);
    _debounce?.cancel();
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final query = _query.text.trim();
    final rows = <(SearchHit, Medicine)>[];
    for (final hit in _hits) {
      final medicine = widget.controller.snapshot.records[hit.id];
      if (medicine != null && medicine.archived) rows.add((hit, medicine));
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Removed stock')),
      body: ListView(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        padding: const EdgeInsets.fromLTRB(22, 8, 22, 30),
        children: [
          const ScreenIntro(
            title: 'Find & restore removed stock',
            message:
                'Search local removed history by medicine, brand, salt, barcode, batch, expiry, location or scanned keywords. Restoring always requires an exact-row review.',
            icon: Icons.inventory_2_outlined,
            color: amber,
          ),
          Surface(
            padding: EdgeInsets.zero,
            child: TextField(
              controller: _query,
              onChanged: _typed,
              maxLength: 300,
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => unawaited(_search()),
              decoration: InputDecoration(
                counterText: '',
                hintText: 'Search removed medicines…',
                prefixIcon: const Icon(Icons.search_rounded),
                suffixIcon: query.isEmpty
                    ? null
                    : IconButton(
                        tooltip: 'Clear search',
                        onPressed: () {
                          _query.clear();
                          _typed('');
                        },
                        icon: const Icon(Icons.close_rounded),
                      ),
                border: InputBorder.none,
                contentPadding: const EdgeInsets.symmetric(vertical: 16),
              ),
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: Text(
                  query.isEmpty
                      ? '${rows.length} removed stock ${rows.length == 1 ? 'entry' : 'entries'}'
                      : '${rows.length} local ${rows.length == 1 ? 'match' : 'matches'} for “$query”',
                  style: const TextStyle(
                    color: muted,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (_loading)
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
            ],
          ),
          if (_error.isNotEmpty) ...[
            const SizedBox(height: 12),
            Surface(
              color: errorSoft,
              child: Text(_error, style: const TextStyle(color: red)),
            ),
          ],
          if (!_loading && _error.isEmpty && rows.isEmpty) ...[
            const SizedBox(height: 18),
            EmptyState(
              title: query.isEmpty ? 'No removed stock' : 'No removed match',
              message: query.isEmpty
                  ? 'Removed entries will appear here and remain recoverable.'
                  : 'Try the medicine name, barcode, batch number, strength or storage location. Aaris will not guess a different row.',
            ),
          ],
          const SizedBox(height: 8),
          for (final entry in rows)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: _RemovedStockCard(
                hit: entry.$1,
                record: entry.$2,
                showConfidence: query.isNotEmpty,
                onRestore: () => _reviewRestore(entry.$2),
              ),
            ),
        ],
      ),
    );
  }
}

class _RemovedStockCard extends StatelessWidget {
  const _RemovedStockCard({
    required this.hit,
    required this.record,
    required this.showConfidence,
    required this.onRestore,
  });

  final SearchHit hit;
  final Medicine record;
  final bool showConfidence;
  final VoidCallback onRestore;

  @override
  Widget build(BuildContext context) {
    final details = <String>[
      if (record.batchNumber.trim().isNotEmpty)
        'Batch ${record.batchNumber.trim()}',
      if (record.expiry != null)
        'EXP ${record.expiryMonthOnly ? dateText(record.expiry!).substring(0, 7) : dateText(record.expiry!)}',
      record.quantity == null ? 'Qty unknown' : 'Qty ${record.quantity}',
      if (record.address.trim().isNotEmpty) record.address.trim(),
    ];
    final removal = <String>[
      if (record.archiveReason.trim().isNotEmpty) record.archiveReason.trim(),
      if (record.archivedAt != null)
        'Removed ${record.archivedAt!.toLocal().toString().split('.').first}',
    ];

    return Surface(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const DepthIcon(
                Icons.archive_outlined,
                size: 40,
                color: amber,
                background: warningSoft,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      record.title,
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                    if (details.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        details.join(' · '),
                        style: const TextStyle(color: muted, fontSize: 12),
                      ),
                    ],
                    if (removal.isNotEmpty) ...[
                      const SizedBox(height: 5),
                      Text(
                        removal.join(' · '),
                        style: const TextStyle(color: muted, fontSize: 11),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
          if (showConfidence) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                StatusPill('${hit.confidence} match'),
                StatusPill(hit.reason),
              ],
            ),
          ],
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: onRestore,
              icon: const Icon(Icons.restore_rounded),
              label: const Text('Review restore'),
            ),
          ),
        ],
      ),
    );
  }
}
